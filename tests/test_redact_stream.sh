#!/usr/bin/env bash
set -euo pipefail

# Unit test for bin/lucairn's redact_stream (OBS-06 hardening).
#
# The support bundle is the one diagnostic artifact DESIGNED to leave the
# customer boundary, so its redaction must scrub every high-confidence secret
# class — including Bearer tokens, JWTs, emails, and E.164 phone numbers that
# appear free-form in compose logs, AND sk-/lcr- keys that sit on a
# NON-secret-named "KEY=value" line (the pre-hardening bug: the
# `index($0,"=")>0` early-return bypassed the inline key scrub).
#
# T-675: it must ALSO scrub credentials embedded in URLs. `docker compose
# config` resolves the customer's Postgres DSNs into the bundle
# (redacted/compose-resolved.yml), e.g.
#   DATABASE_URL: postgres://veil:<password>@postgres-veil:5432/veil?sslmode=disable
# Pre-fix this printed VERBATIM: the line contains "=" (from `sslmode=`), so
# the structural KEY=value branch derived a "key" ending in `sslmode`, which
# matched no secret-key name, and no inline rule looked at URL userinfo.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Pull the redact_stream function definition out of bin/lucairn and source it
# so we exercise the exact shipped code, not a copy. (Extract to a temp file
# rather than process substitution — the latter races under `set -e` on some
# bash/macOS combos and leaves the function undefined.)
FUNC_FILE="$TMPDIR/redact_stream.sh"
sed -n '/^redact_stream() {/,/^}/p' "$ROOT/bin/lucairn" > "$FUNC_FILE"
# shellcheck disable=SC1090
source "$FUNC_FILE"

SAMPLE="$TMPDIR/sample.log"
cat > "$SAMPLE" <<'LOG'
# comment line stays intact
DSA_ADMIN_KEY=sk-ant-api03-SECRETKEY_on_secret_named_line
note=please use sk-ant-api03-LEAKED_on_plain_line for testing
comment=customer key is lcr_live_LEAKEDkey456abc
Authorization: Bearer abc123BearerTokenValue
raw jwt: eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoiYm9iIn0.abcSIGNATURExyz
support contact admin@customer.example reached out
escalation phone +14155552671 on call
plain_value=keep-this-visible
GATEWAY_BASE_URL=https://lucairn.customer.example
      DATABASE_URL: postgres://veil:PgVeilPassLEAK001@postgres-veil:5432/veil?sslmode=disable
      AUDIT_DATABASE_URL: postgres://audit_app:PgAuditPassLEAK002@postgres-audit:5432/audit?sslmode=disable
      BRIDGE_DATABASE_URL: postgres://dsa:PgBridgePassLEAK003@postgres-bridge:5432/bridge?sslmode=disable
      SANDBOX_A_DATABASE_URL: postgres://dsa:PgSandboxAPassLEAK004@postgres-sandbox-a:5432/sandbox_a?sslmode=disable
LUCAIRN_DASHBOARD_AUDIT_DB_URL=postgres://lucairn_dashboard_ro:PgDashPassLEAK005@postgres-veil:5432/veil?sslmode=require
SANITIZER_STREAM_STATE_REDIS_URL=redis://default:RedisPassLEAK006@redis-sanitizer-cache:6379/0
MODEL_RUNTIME_URL=http://model-runtime:8000/v1
docs link https://docs.lucairn.eu/install#step-3 stays readable
      GATEWAY_KEYSTORE_KEY: aGFyZGNvZGVkS2V5c3RvcmVCb2R5Rk9SVEVTVA==
      DATABASE_URL: postgres://veil:h1zcBxno/mEMYWP8d1dE8gsaCmIMoxe9ylN4Cn5BK3w=@postgres-veil:5432/veil?sslmode=disable
log line: connecting to postgres://veil:Quo"teSlash/Pw77@postgres-veil:5432/veil now
      SANDBOX_B_REDIS_URL: redis://:HelmShapeNoUserPw88@sandbox-b-redis:6379
error: dial postgres://veil:RdsHostPw99@lucairn-db.abc123.eu-central-1.rds.amazonaws.com:5432/veil failed
      password: LowerCaseYamlPw11
      postgres_password: LowerCaseYamlPw22
      - DATABASE_URL=postgres://veil:ListFormPw33@postgres-veil:5432/veil?sslmode=disable
LOG

OUT="$TMPDIR/out.log"
redact_stream < "$SAMPLE" > "$OUT"

fail() {
  echo "redact_stream test FAILED: $*" >&2
  echo "--- redacted output ---" >&2
  cat "$OUT" >&2
  exit 1
}

# 1. Comments and benign values survive untouched.
grep -q "^# comment line stays intact$" "$OUT" || fail "comment line was altered"
grep -q "^plain_value=keep-this-visible$" "$OUT" || fail "benign value was redacted"
grep -q "^GATEWAY_BASE_URL=https://lucairn.customer.example$" "$OUT" || fail "non-secret URL was redacted"

# 2. EVERY secret literal must be gone from the output.
declare -a LEAKS=(
  "sk-ant-api03-SECRETKEY_on_secret_named_line"
  "sk-ant-api03-LEAKED_on_plain_line"
  "lcr_live_LEAKEDkey456abc"
  "abc123BearerTokenValue"
  "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoiYm9iIn0.abcSIGNATURExyz"
  "admin@customer.example"
  "+14155552671"
  # T-675: Postgres/Redis DSN passwords resolved into the bundle.
  "PgVeilPassLEAK001"
  "PgAuditPassLEAK002"
  "PgBridgePassLEAK003"
  "PgSandboxAPassLEAK004"
  "PgDashPassLEAK005"
  "RedisPassLEAK006"
  # T-675 round 2 — merge-blocking fixtures from the security gate.
  # (a) base64 value whose "=" padding made the KEY=value branch re-emit the
  #     whole secret body and redact only the padding.
  "aGFyZGNvZGVkS2V5c3RvcmVCb2R5Rk9SVEVTVA"
  # (b) a real `openssl rand -base64 32` password — contains "/" and "=".
  "h1zcBxno/mEMYWP8d1dE8gsaCmIMoxe9ylN4Cn5BK3w"
  # (b2) password carrying BOTH a double-quote and a slash, on a line whose key
  #      name is NOT secret-shaped, so only the inline URL rule can catch it.
  'Quo"teSlash/Pw77'
  # (c) userless DSN — the shape the sandbox-b Helm chart emits.
  "HelmShapeNoUserPw88"
  # (d) dotted-FQDN external host (RDS-style): the email rule used to eat the
  #     host here and leave the password behind.
  "RdsHostPw99"
  # (f) lowercase YAML password keys.
  "LowerCaseYamlPw11"
  "LowerCaseYamlPw22"
  # compose list form "- KEY=value" must not lose its key to truncation.
  "ListFormPw33"
)
for leak in "${LEAKS[@]}"; do
  if grep -Fq -- "$leak" "$OUT"; then
    fail "leaked secret literal: $leak"
  fi
done

# 3. The redaction marker is present for each scrubbed class (smoke check).
grep -q "DSA_ADMIN_KEY=<redacted>" "$OUT" || fail "secret-named KEY=value not redacted"
grep -q "note=please use <redacted> for testing" "$OUT" || fail "sk- key on plain =line not redacted (early-return bypass regression)"
grep -q "comment=customer key is <redacted>" "$OUT" || fail "lcr- key on plain =line not redacted"
grep -q "Authorization: Bearer <redacted>" "$OUT" || fail "Bearer token not redacted"
grep -q "raw jwt: <redacted>" "$OUT" || fail "bare JWT not redacted"
grep -q "support contact <redacted> reached out" "$OUT" || fail "email not redacted"
grep -q "escalation phone <redacted> on call" "$OUT" || fail "E.164 phone not redacted"

# 4. T-675 — TWO COMPLEMENTARY PATHS, with different (correct) outputs.
#
#    (i) A line whose KEY NAME is secret-shaped is redacted WHOLE by the
#        key-name branch: the value never reaches the output at all, so the
#        host is not echoed either. This is the stronger outcome and applies to
#        the four DSN sites `compose config` resolves into the bundle.
grep -q "^      DATABASE_URL: <redacted>$" "$OUT" || fail "DATABASE_URL not redacted whole"
grep -q "^      AUDIT_DATABASE_URL: <redacted>$" "$OUT" || fail "AUDIT_DATABASE_URL not redacted whole"
grep -q "^      BRIDGE_DATABASE_URL: <redacted>$" "$OUT" || fail "BRIDGE_DATABASE_URL not redacted whole"
grep -q "^      SANDBOX_A_DATABASE_URL: <redacted>$" "$OUT" || fail "SANDBOX_A_DATABASE_URL not redacted whole"
grep -q "^LUCAIRN_DASHBOARD_AUDIT_DB_URL=<redacted>$" "$OUT" || fail "DB_URL-named key not redacted whole"
#
#   (ii) A DSN under a NON-secret key name (or free in a log line) is reachable
#        only by the inline URL rule, which keeps scheme/user/host/port/db so
#        the bundle stays diagnosable. SANITIZER_STREAM_STATE_REDIS_URL matches
#        no secret-key name, which is exactly why this path has to exist.
grep -q "^SANITIZER_STREAM_STATE_REDIS_URL=redis://default:<redacted>@redis-sanitizer-cache:6379/0$" "$OUT" \
  || fail "non-secret-named redis DSN: password not redacted or host destroyed"
# The DSN lines arrive as INDENTED `compose config` YAML; the secret-key branch
# must re-emit that indent or redacted/compose-resolved.yml stops parsing.
grep -q "^      DATABASE_URL: " "$OUT" || fail "YAML indent lost on a redacted DSN line (compose-resolved.yml would not parse)"

# 5. T-675 negative cases — URLs WITHOUT userinfo must survive verbatim, or the
#    bundle stops being diagnosable (a host:port is not a credential).
grep -q "^MODEL_RUNTIME_URL=http://model-runtime:8000/v1$" "$OUT" || fail "credential-free host:port URL was redacted"
grep -q "^docs link https://docs.lucairn.eu/install#step-3 stays readable$" "$OUT" || fail "plain https URL was redacted"

# 6. T-675 round 2 — SEPARATOR PRESERVATION. A YAML "KEY: value" line must stay
#    a YAML "KEY: value" line after redaction. Rewriting it as "KEY=<redacted>"
#    would trade a leak for a bundle that no longer parses.
grep -q "^      GATEWAY_KEYSTORE_KEY: <redacted>$" "$OUT" || fail "base64 KEY: value not redacted with its YAML separator"
grep -q "^      password: <redacted>$" "$OUT" || fail "lowercase password: not redacted"
grep -q "^      postgres_password: <redacted>$" "$OUT" || fail "lowercase postgres_password: not redacted"
# The compose list marker survives: truncating the derived key must not eat it.
grep -q "^      - DATABASE_URL=<redacted>$" "$OUT" || fail "compose list-form key lost its '- ' marker"

# 7. T-675 round 2 — the userless DSN keeps its shape, and the external RDS
#    HOST survives (the email rule must not start inside a URL authority).
grep -q "redis://:<redacted>@sandbox-b-redis:6379" "$OUT" || fail "userless redis DSN not redacted / shape lost"
grep -q "postgres://veil:<redacted>@lucairn-db.abc123.eu-central-1.rds.amazonaws.com:5432/veil" "$OUT" \
  || fail "dotted-FQDN host was destroyed or password survived (email-rule anchoring)"
# A free-standing email is still redacted — anchoring narrowed the rule, it did
# not disable it.
grep -q "support contact <redacted> reached out" "$OUT" || fail "free-standing email no longer redacted"

# 8. T-675 round 2 — YAML PARSEABILITY of the redacted compose-resolved output.
#    Build a realistic `docker compose config` fragment, redact it, and parse.
YIN="$TMPDIR/compose-resolved.yml"
cat > "$YIN" <<'YAML'
services:
  veil-witness:
    environment:
      DATABASE_URL: postgres://veil:YamlProbePw@postgres-veil:5432/veil?sslmode=disable
      GATEWAY_KEYSTORE_KEY: aGFyZGNvZGVkS2V5c3RvcmVCb2R5Rk9SVEVTVA==
      GATEWAY_BASE_URL: https://lucairn.customer.example
      password: YamlProbeLower
YAML
YOUT="$TMPDIR/compose-resolved.redacted.yml"
redact_stream < "$YIN" > "$YOUT"

if grep -Fq "YamlProbePw" "$YOUT" || grep -Fq "YamlProbeLower" "$YOUT" \
   || grep -Fq "aGFyZGNvZGVkS2V5c3RvcmVCb2R5Rk9SVEVTVA" "$YOUT"; then
  echo "redact_stream test FAILED: compose-resolved probe leaked" >&2
  cat "$YOUT" >&2
  exit 1
fi

# Parser-independent structural assertion — ALWAYS runs, so this check can
# never silently degrade to a skip when PyYAML is absent.
while IFS= read -r yline; do
  [ -n "$yline" ] || continue
  case "$yline" in
    *:*) ;;
    *) echo "redact_stream test FAILED: redacted YAML line lost its key: [$yline]" >&2; exit 1 ;;
  esac
done < "$YOUT"

if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$YOUT" <<'PY' || { echo "redact_stream test FAILED: redacted compose-resolved.yml does not parse" >&2; cat "$YOUT" >&2; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
env = doc["services"]["veil-witness"]["environment"]
assert env["DATABASE_URL"] == "<redacted>", env["DATABASE_URL"]
assert env["GATEWAY_KEYSTORE_KEY"] == "<redacted>", env["GATEWAY_KEYSTORE_KEY"]
assert env["GATEWAY_BASE_URL"] == "https://lucairn.customer.example", env["GATEWAY_BASE_URL"]
assert env["password"] == "<redacted>", env["password"]
print("compose-resolved.yml still parses after redaction: ok")
PY
else
  echo "compose-resolved.yml YAML-parse assertion: NOT RUN (no PyYAML) — structural assertion above still ran" >&2
fi

echo "redact_stream tests: ok"
