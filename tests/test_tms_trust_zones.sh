#!/usr/bin/env bash
#
# Focused unit tests for bin/lucairn's check_tms_trust_zones (TMS Slice 4
# Phase-8 doctor pre-flight). Sources bin/lucairn and calls the function
# directly against crafted env files — no Docker / network required.
#
# bin/lucairn runs `main "$@"` unconditionally at the bottom; sourcing it with
# no positional args hits the `--help`/usage branch (prints help, returns 0,
# no side effects). We then disable `set -euo pipefail` (which bin/lucairn
# enables at its top) so a failing case's non-zero return does not abort the
# harness, and exercise the function per case.
#
# Covers the reviewer-chain hardening: version gate (semver / non-semver /
# sort-V), JSON validity (object / null / {} / array / scalar / dup-key /
# unknown-segment), invalid-zone fail, and python3-absent degradation.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1090
source "$ROOT/bin/lucairn" >/dev/null 2>&1
# bin/lucairn turned on `set -euo pipefail`; turn it back off for the harness so
# we can capture non-zero returns from the function under test.
set +e +u +o pipefail

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT

FAILS=0
N=0

# assert_case NAME ENV_CONTENTS EXPECT_RC [EXPECT_SUBSTRING]
assert_case() {
  local name="$1" contents="$2" expect_rc="$3" needle="${4:-}"
  N=$((N + 1))
  local f="$WK/$name.env"
  printf '%s\n' "$contents" > "$f"
  local out rc
  out="$(check_tms_trust_zones "$f" 2>&1)"
  rc=$?
  local ok=1
  if [ "$rc" -ne "$expect_rc" ]; then
    ok=0
    echo "FAIL [$name]: expected rc=$expect_rc, got rc=$rc"
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    ok=0
    echo "FAIL [$name]: output did not contain: $needle"
  fi
  if [ "$ok" -eq 1 ]; then
    echo "ok   [$name] (rc=$rc)"
  else
    echo "     output was: $out"
    FAILS=$((FAILS + 1))
  fi
}

# assert_case_degraded NAME ENV_CONTENTS EXPECT_RC EXPECT_SUBSTRING EXTRA_PATH_PREFIX
# Runs the function in a subshell with a constrained PATH (used to simulate a
# host without python3, or with a sort that lacks -V).
assert_case_degraded() {
  local name="$1" contents="$2" expect_rc="$3" needle="$4" path_override="$5"
  N=$((N + 1))
  local f="$WK/$name.env"
  printf '%s\n' "$contents" > "$f"
  local out rc
  out="$(PATH="$path_override" bash -c '
    set +e
    source "'"$ROOT"'/bin/lucairn" >/dev/null 2>&1
    set +e +u +o pipefail
    check_tms_trust_zones "'"$f"'" 2>&1
  ')"
  rc=$?
  local ok=1
  if [ "$rc" -ne "$expect_rc" ]; then
    ok=0
    echo "FAIL [$name]: expected rc=$expect_rc, got rc=$rc"
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    ok=0
    echo "FAIL [$name]: output did not contain: $needle"
  fi
  if [ "$ok" -eq 1 ]; then
    echo "ok   [$name] (rc=$rc, degraded PATH)"
  else
    echo "     output was: $out"
    FAILS=$((FAILS + 1))
  fi
}

# --- Core cases (a)-(f) from the PR brief --------------------------------
# (a) unset policy -> ok
assert_case "a_unset" '' 0 "ok (not configured"

# (b) valid policy + tag 0.5.1 -> ok
assert_case "b_valid_051" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={"system_prompt":"full_scan"}' 0 "ok"

# (c) invalid zone value -> fail (names key + value)
assert_case "c_invalid_zone" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={"user_content":"bogus"}' 1 'unknown zone value "bogus"'

# (d) valid policy + tag 0.5.0 -> fail (version gate)
assert_case "d_tag_050" \
  'LUCAIRN_IMAGE_TAG=0.5.0
GATEWAY_TMS_TRUST_ZONES={"code_block":"full_scan"}' 1 "requires gateway image >= 0.5.1"

# (e) valid policy + non-semver tag 'latest' -> fail (fail-closed)
assert_case "e_tag_latest" \
  'LUCAIRN_IMAGE_TAG=latest
GATEWAY_TMS_TRUST_ZONES={"code_block":"full_scan"}' 1 "is not an exact semver pin"

# (f) null -> ok (no-policy short-circuit, matches gateway identity behaviour)
assert_case "f_null_identity" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES=null' 0 "not configured"

# --- Additional robustness cases (reviewer-chain hardening) --------------
# Weaker-than-default override allowed (operator owns the risk).
assert_case "weaker_ok" \
  'LUCAIRN_IMAGE_TAG=0.5.2
GATEWAY_TMS_TRUST_ZONES={"tool_result_content":"shallow"}' 0 "ok"

# Empty object {} -> ok (no-policy short-circuit, matches gateway identity behaviour).
assert_case "empty_obj_identity" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={}' 0 "not configured"

# Array top-level -> fail with a CLEAN message (not a traceback).
assert_case "array_invalid" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES=["full_scan"]' 1 "must be a JSON object (got array)"

# Scalar top-level -> fail with a clean message.
assert_case "scalar_invalid" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES=42' 1 "must be a JSON object (got number)"

# Malformed JSON -> fail (clean message, no traceback).
assert_case "bad_json" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={not json' 1 "is not valid JSON"

# Duplicate key -> fail.
assert_case "dup_key" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={"user_content":"full_scan","user_content":"bogus"}' 1 "duplicate segment-type key"

# Unknown segment type -> warn + ok (forward-compat).
assert_case "unknown_segment" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={"future_segment":"full_scan"}' 0 "unknown segment type"

# Bare two-segment tag 0.5 -> fail (not an exact MAJOR.MINOR.PATCH pin).
assert_case "tag_short" \
  'LUCAIRN_IMAGE_TAG=0.5
GATEWAY_TMS_TRUST_ZONES={"code_block":"full_scan"}' 1 "is not an exact semver pin"

# v-prefix tag -> fail (non-semver).
assert_case "tag_vprefix" \
  'LUCAIRN_IMAGE_TAG=v0.5.1
GATEWAY_TMS_TRUST_ZONES={"code_block":"full_scan"}' 1 "is not an exact semver pin"

# 0.5.10 >= 0.5.1 -> ok (real semver ordering, not lexical).
assert_case "tag_0510_ok" \
  'LUCAIRN_IMAGE_TAG=0.5.10
GATEWAY_TMS_TRUST_ZONES={"code_block":"full_scan"}' 0 "ok"

# --- FIX P1: null / {} / whitespace-{} must skip the version gate --------
# {} + old image tag 0.5.0 -> ok (version gate NOT fired — identity short-circuit)
assert_case "p1_empty_obj_050" \
  'LUCAIRN_IMAGE_TAG=0.5.0
GATEWAY_TMS_TRUST_ZONES={}' 0 "not configured"

# null + old image tag 0.5.0 -> ok
assert_case "p1_null_050" \
  'LUCAIRN_IMAGE_TAG=0.5.0
GATEWAY_TMS_TRUST_ZONES=null' 0 "not configured"

# { } (whitespace inside) + 0.5.0 -> ok
assert_case "p1_ws_obj_050" \
  'LUCAIRN_IMAGE_TAG=0.5.0
GATEWAY_TMS_TRUST_ZONES={ }' 0 "not configured"

# Positive control: a real override with 0.5.0 must still FAIL the version gate
# (proves FIX P1 did NOT weaken the gate for non-empty policies).
assert_case "p1_real_policy_050_still_fails" \
  'LUCAIRN_IMAGE_TAG=0.5.0
GATEWAY_TMS_TRUST_ZONES={"system_prompt":"full_scan"}' 1 "requires gateway image >= 0.5.1"

# --- FIX P2: empty JSON key must fail with the EMPTY-KEY message ----------
# {"":"full_scan"} + 0.5.1 -> fail, message contains "empty segment-type key"
assert_case "p2_empty_key_fail" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={"":"full_scan"}' 1 "empty segment-type key"

# --- Degraded-environment cases ------------------------------------------
# Build a PATH that has the usual tools but NOT python3, to prove the JSON
# validation degrades to a warn (rc 0) instead of a false hard-fail.
NOPY="$WK/nopy"
mkdir -p "$NOPY"
for t in bash sh env mktemp rm grep sed awk sort printf cat head tail command tr cut dirname basename; do
  src="$(command -v "$t" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$NOPY/$t"
done
assert_case_degraded "python3_absent_warn" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={"system_prompt":"full_scan"}' \
  0 "python3 unavailable" "$NOPY"

# Shadow `sort` with a BusyBox-like stub that rejects -V, to prove the version
# gate fails CLOSED (rc 1) rather than silently skipping when the policy is set.
BBSORT="$WK/bbsort"
mkdir -p "$BBSORT"
REAL_SORT="$(command -v sort)"
cat > "$BBSORT/sort" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "-V" ]; then echo "sort: unrecognized option: V" >&2; exit 2; fi
done
exec "$REAL_SORT" "\$@"
STUB
chmod +x "$BBSORT/sort"
assert_case_degraded "sortV_absent_failclosed" \
  'LUCAIRN_IMAGE_TAG=0.5.1
GATEWAY_TMS_TRUST_ZONES={"system_prompt":"full_scan"}' \
  1 "sort -V unavailable" "$BBSORT:$PATH"

echo
echo "ran $N case(s)"
if [ "$FAILS" -ne 0 ]; then
  echo "tms trust-zone doctor tests: FAILED ($FAILS)" >&2
  exit 1
fi
echo "tms trust-zone doctor tests: ok"
