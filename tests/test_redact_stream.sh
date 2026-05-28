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

echo "redact_stream tests: ok"
