#!/usr/bin/env bash
set -euo pipefail

# Unit + behavioral tests for the version-awareness helpers in bin/lucairn:
#   * ver_lt  — SemVer-correct "<" with numeric core comparison + prerelease
#               precedence (1.0.0-rc1 < 1.0.0). Regression shield for the Codex
#               r1 HIGH: the old impl stripped the -prerelease suffix before
#               comparing, so a prerelease at/below minimum-secure was reported
#               "ahead of the feed" instead of triggering the SECURITY path.
#   * check-updates — the consuming behavior: a current=1.0.0-rc1 against a feed
#               whose minimum_secure is 1.0.0 must take the below-minimum-secure
#               SECURITY branch, not the "ahead of the published feed" branch.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# --- Load the helper functions out of bin/lucairn -----------------------------
# bin/lucairn ends with `main "$@"`, so we can't source it directly (it would run
# the CLI). Copy it, strip the final dispatch line, and source the rest so the
# pure helper functions become available in this shell. ROOT/VERSION resolution
# at the top of the script still works because we source from the same checkout.
LIB="$TMPDIR/lucairn-lib.sh"
sed '/^main "\$@"$/d' "$ROOT/bin/lucairn" > "$LIB"
# shellcheck disable=SC1090  # dynamic path is the extracted lib above
. "$LIB"

fail_test() { echo "FAIL: $*" >&2; exit 1; }

# ver_lt A B EXPECT   (EXPECT = true|false: is A < B ?)
check_ver_lt() {
  local a="$1" b="$2" expect="$3" got
  if ver_lt "$a" "$b"; then got=true; else got=false; fi
  if [ "$got" != "$expect" ]; then
    fail_test "ver_lt '$a' '$b' = $got, expected $expect"
  fi
  echo "  ok: ver_lt '$a' '$b' = $got"
}

echo "ver_lt unit tests:"
# The 8 prompt-specified cases (the Codex r1 HIGH bug cases + ordering checks).
check_ver_lt "1.0.0-rc1" "1.0.0"      true    # prerelease < release (the bug)
check_ver_lt "1.0.0"     "1.0.0-rc1"  false   # release > prerelease
check_ver_lt "1.0.0-rc1" "1.0.0-rc2"  true    # rc1 < rc2 (numeric prerelease)
check_ver_lt "1.0.0-rc2" "1.0.0-rc1"  false
check_ver_lt "1.0.0-rc1" "1.0.0-rc1"  false   # equal prerelease -> not less
check_ver_lt "0.9.0"     "0.10.0"     true    # numeric core, not lexical
check_ver_lt "1.0.0"     "1.0.0"      false   # equal release
check_ver_lt "1.0.0+build" "1.0.0"    false   # build metadata ignored

# Extra coverage of the SemVer precedence corners.
check_ver_lt "0.10.0"    "0.9.0"      false   # symmetric numeric-core check
check_ver_lt "1.2.3"     "2.0.0"      true    # major dominates
check_ver_lt "2.0.0"     "1.9.9"      false
check_ver_lt "1.0.0-alpha" "1.0.0-beta" true  # alphanumeric lexical
check_ver_lt "1.0.0-beta"  "1.0.0-alpha" false
check_ver_lt "1.0.0-alpha" "1.0.0-alpha.1" true  # fewer identifiers is lower
check_ver_lt "1.0.0-alpha.1" "1.0.0-alpha" false
check_ver_lt "1.0.0-1"   "1.0.0-alpha" true   # numeric ident < alphanumeric
check_ver_lt "1.0.0+a"   "1.0.0+b"     false  # build metadata: equal precedence
check_ver_lt "1.0.0-rc1+x" "1.0.0"    true    # +build stripped, then -pre < rel

echo "ver_lt unit tests: ok"

# --- Behavioral: check-updates takes the SECURITY branch for a below-min ------
# prerelease. Stub curl (serves a local signed-feed pair) + cosign (always OK) on
# PATH so we exercise the real _check_updates_online -> ver_lt path with NO
# network and NO real signature. jq is genuinely needed and assumed present.
if ! command -v jq >/dev/null 2>&1; then
  echo "check-updates behavioral test: skipped (jq not installed)"
  echo "lucairn check-updates tests: ok"
  exit 0
fi

# The feed: latest 1.0.0, minimum_secure 1.0.0. A current of 1.0.0-rc1 is BELOW
# the 1.0.0 minimum-secure floor (the whole point of the fix).
FEED="$TMPDIR/version-feed.json"
cat > "$FEED" <<'JSON'
{
  "schema": 1,
  "latest": { "kit_version": "1.0.0", "image_tag": "0.5.4", "tag": "v1.0.0", "released": "2026-06-21", "security": true },
  "minimum_secure": { "kit_version": "1.0.0" },
  "advisories": [
    { "id": "LUCAIRN-2026-001", "severity": "High", "fixed_in": "1.0.0", "summary": "test advisory", "url": "https://lucairn.eu/security" }
  ]
}
JSON

STUBBIN="$TMPDIR/stubbin"
mkdir -p "$STUBBIN"

# Stub curl: -o writes the requested artifact. The feed body comes from $FEED;
# the .sig request gets any non-empty bytes (cosign is stubbed so content is
# irrelevant). Mirrors `curl -sSfL --max-time N URL -o OUT`.
cat > "$STUBBIN/curl" <<CURL
#!/usr/bin/env bash
out=""
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    http*|file*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "\$out" ] || exit 0
case "\$url" in
  *.sig) printf 'stub-signature\n' > "\$out" ;;
  *)     cat "$FEED" > "\$out" ;;
esac
exit 0
CURL
chmod +x "$STUBBIN/curl"

# Stub cosign: verify-blob always succeeds (we are testing the version logic,
# not the cryptography — the real cosign path is exercised on the box).
cat > "$STUBBIN/cosign" <<'COSIGN'
#!/usr/bin/env bash
exit 0
COSIGN
chmod +x "$STUBBIN/cosign"

# A keys/lucairn-cosign.pub must exist for the prerequisite check; the stub
# cosign ignores it. The real key already ships in the kit, but assert+create
# defensively into a throwaway ROOT so the test is self-contained.
RUN_ROOT="$TMPDIR/kitroot"
mkdir -p "$RUN_ROOT/bin" "$RUN_ROOT/keys"
cp "$ROOT/bin/lucairn" "$RUN_ROOT/bin/lucairn"
printf '1.0.0-rc1\n' > "$RUN_ROOT/VERSION"
printf -- '-----BEGIN PUBLIC KEY-----\nstub\n-----END PUBLIC KEY-----\n' > "$RUN_ROOT/keys/lucairn-cosign.pub"

OUT="$TMPDIR/check-updates.out"
set +e
PATH="$STUBBIN:$PATH" "$RUN_ROOT/bin/lucairn" check-updates --feed-url "https://stub/version-feed.json" > "$OUT" 2>&1
CU_STATUS=$?
set -e

if [ "$CU_STATUS" -ne 0 ]; then
  echo "check-updates exited $CU_STATUS (expected 0)"; cat "$OUT" >&2; exit 1
fi
# The fix: a below-minimum-secure prerelease takes the SECURITY branch...
grep -q "SECURITY: your kit (1.0.0-rc1) is BELOW the minimum-secure version (1.0.0)" "$OUT" \
  || { echo "FAIL: expected the SECURITY below-minimum-secure line"; cat "$OUT" >&2; exit 1; }
# ...and must NOT fall through to the "ahead of the published feed" branch.
if grep -q "ahead of the published feed" "$OUT"; then
  echo "FAIL: prerelease at/below minimum-secure wrongly reported as 'ahead of the feed'" >&2
  cat "$OUT" >&2; exit 1
fi
echo "  ok: 1.0.0-rc1 vs minimum_secure 1.0.0 -> SECURITY branch (not 'ahead of feed')"

echo "lucairn check-updates tests: ok"
