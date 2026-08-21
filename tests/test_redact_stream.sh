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

# 4. T-675 — URL userinfo: the PASSWORD goes, the host/port/db stay so the
#    bundle is still diagnosable. Covers the four DSN sites `compose config`
#    resolves into the bundle plus the dashboard/redis URLs.
grep -q "postgres://veil:<redacted>@postgres-veil:5432" "$OUT" || fail "DATABASE_URL DSN password not redacted"
grep -q "postgres://audit_app:<redacted>@postgres-audit:5432" "$OUT" || fail "AUDIT_DATABASE_URL DSN password not redacted"
grep -q "postgres://dsa:<redacted>@postgres-bridge:5432" "$OUT" || fail "BRIDGE_DATABASE_URL DSN password not redacted"
grep -q "postgres://dsa:<redacted>@postgres-sandbox-a:5432" "$OUT" || fail "SANDBOX_A_DATABASE_URL DSN password not redacted"
grep -q "redis://default:<redacted>@redis-sanitizer-cache:6379" "$OUT" || fail "redis DSN password not redacted"
# Defense-in-depth: a *DB_URL-named KEY=value line is redacted whole by the
# secret-key-name matcher, not only by the inline URL rule.
grep -q "^LUCAIRN_DASHBOARD_AUDIT_DB_URL=<redacted>$" "$OUT" || fail "DB_URL-named key not redacted by name matcher"
# The DSN lines arrive as INDENTED `compose config` YAML; the secret-key branch
# must re-emit that indent or redacted/compose-resolved.yml stops parsing.
grep -q "^      DATABASE_URL: " "$OUT" || fail "YAML indent lost on a redacted DSN line (compose-resolved.yml would not parse)"

# 5. T-675 negative cases — URLs WITHOUT userinfo must survive verbatim, or the
#    bundle stops being diagnosable (a host:port is not a credential).
grep -q "^MODEL_RUNTIME_URL=http://model-runtime:8000/v1$" "$OUT" || fail "credential-free host:port URL was redacted"
grep -q "^docs link https://docs.lucairn.eu/install#step-3 stays readable$" "$OUT" || fail "plain https URL was redacted"

echo "redact_stream tests: ok"
