#!/usr/bin/env bash
# Test of tests/lib/make_test_license.py — the synthetic licence helper for
# Lucairn's OWN test installs (not a customer licence, not in the customer path).
#
# Checks: the file is mode 0600 and never overwritten; it holds exactly the two
# fields bin/lucairn-init requires (license_key + signing_key, read the way
# lucairn-init reads them); the license_key verifies the way the gateway's
# license.ValidateKey does at images 1.1.1 (last-dot split, base64url without
# padding, HMAC-SHA256 keyed by the signing_key string, expires_at in the
# future); a changed payload or another signing key fails that check; no key
# value is printed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/tests/lib/make_test_license.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

head -3 "$HELPER" | grep -q "FOR LUCAIRN'S OWN TEST INSTALLS ONLY; NOT A CUSTOMER LICENCE." \
  || fail "helper header does not say it is for Lucairn's own test installs only"

out="$(python3 "$HELPER" --out "$TMP/license.json" --days 30)"
printf '%s\n' "$out" | grep -q 'not a customer licence' || fail "helper output lacks the not-a-customer-licence note"

mode="$(stat -c '%a' "$TMP/license.json" 2>/dev/null || stat -f '%Lp' "$TMP/license.json")"
[ "$mode" = "600" ] || fail "licence file mode is $mode, want 600"

key="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("license_key",""))' "$TMP/license.json")"
sk="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("signing_key",""))' "$TMP/license.json")"
[ -n "$key" ] && [ -n "$sk" ] || fail "license_key or signing_key empty (lucairn-init exit 5 path)"
case "$out" in *"$key"*|*"$sk"*) fail "helper printed a key value" ;; esac
if command -v jq >/dev/null 2>&1; then
  [ "$(jq -r '.license_key // empty' "$TMP/license.json")" = "$key" ] || fail "jq read of license_key differs"
  [ "$(jq -r '.signing_key // empty' "$TMP/license.json")" = "$sk" ] || fail "jq read of signing_key differs"
fi
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sorted(d)==["license_key","signing_key"] else 1)' "$TMP/license.json" \
  || fail "licence file holds other fields than license_key + signing_key"

# Mirror of license.ValidateKey (images 1.1.1). Exit 0 = valid, 1 = invalid.
cat > "$TMP/validate.py" <<'PY'
import base64, hashlib, hmac, json, sys
from datetime import datetime, timezone
def unb64(s):
    if "=" in s: raise ValueError("padding")
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
token, key = sys.argv[1], sys.argv[2]
dot = token.rfind(".")
if dot < 0: sys.exit(1)
payload, sig = token[:dot], token[dot + 1:]
if not hmac.compare_digest(unb64(sig), hmac.new(key.encode(), payload.encode(), hashlib.sha256).digest()): sys.exit(1)
lic = json.loads(unb64(payload))
exp = datetime.strptime(lic["expires_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
if datetime.now(timezone.utc) >= exp: sys.exit(1)
if lic["tier"] != "enterprise": sys.exit(1)
sys.exit(0)
PY
python3 "$TMP/validate.py" "$key" "$sk" || fail "licence does not verify like license.ValidateKey"

# Tampered payload and a different signing key must fail.
payload="${key%.*}"; sig="${key##*.}"
other="$(python3 -c 'import base64,json,sys; p=sys.argv[1]; d=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))); d["tier"]="free"; print(base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode())' "$payload")"
if python3 "$TMP/validate.py" "$other.$sig" "$sk"; then fail "tampered payload verified"; fi
if python3 "$TMP/validate.py" "$key" "x$sk"; then fail "other signing key verified"; fi

# Never overwrites an existing file.
printf 'keep\n' > "$TMP/existing.json"
if python3 "$HELPER" --out "$TMP/existing.json" >/dev/null 2>&1; then fail "helper overwrote an existing file"; fi
[ "$(cat "$TMP/existing.json")" = "keep" ] || fail "existing file changed"

# Short-lived only.
if python3 "$HELPER" --out "$TMP/long.json" --days 365 >/dev/null 2>&1; then fail "helper accepted --days 365"; fi

# Not in the customer path: neither INSTALL.md nor docs/ name the helper.
if grep -rq "make_test_license" "$ROOT/INSTALL.md" "$ROOT/docs" "$ROOT/README.md"; then
  fail "the test-licence helper is named in a customer document"
fi

printf 'PASS: make_test_license.py (mode 0600, two fields, verifies like license.ValidateKey, tamper refused, no overwrite, not in customer docs)\n'
