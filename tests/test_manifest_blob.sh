#!/usr/bin/env bash
# test_manifest_blob.sh — unit tests for the check_manifest_blob doctor
# pre-flight (overnight follow-up 2026-06-15, sign-manifest BLOCKER-3
# containment).
#
# check_manifest_blob is production-gated: when DSA_ENV=production it FAILS if
# the witness-signed manifest blob (LCR/VEIL_WITNESS_SIGNED_MANIFEST_PATH, kit
# default /certs/witness-signed-manifest.json) is unset/missing/empty, turning
# the gateway's boot-time log.Fatal (dual-sandbox-architecture
# services/gateway/internal/api/veil.go:182-197) into an actionable doctor
# failure with the ceremony pointer. In DSA_ENV=development/test it SKIPS (the
# gateway tolerates a missing blob and falls back to the legacy single-sig
# path), so a local/sandbox install is never blocked.
#
# Pure unit test: source bin/lucairn with EMPTY args (so the trailing
# `main "$@"` becomes a harmless `main` -> usage) and call check_manifest_blob
# directly with hand-built env fixtures + a temp blob path. No docker / cosign /
# network needed — runs in the static gate alongside test_digest_pin.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/lucairn"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# bash -n syntax (cheap, catches a broken edit before anything else).
bash -n "$CLI"
echo "manifest-blob: bash -n syntax ok"

# run_check sources the CLI fresh and runs check_manifest_blob against $1 (env
# file). Captures combined stdout/stderr in $OUT and the rc in $RC.
run_check() {
  local envf="$1"
  set +e
  OUT="$(
    set --                      # empty args -> sourced `main` is harmless
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    check_manifest_blob "$envf" 2>&1
  )"
  RC=$?
  set -e
}

BLOB="$TMP/witness-signed-manifest.json"
printf '{"canonical_body_b64":"e30=","witness_signature_hex":"00"}\n' > "$BLOB"

# ---------------------------------------------------------------------------
# 1. prod + path set + blob MISSING -> FAIL (non-zero), with the ceremony
#    pointer + the honest "sign-manifest not in the image" note.
# ---------------------------------------------------------------------------
ENV_PROD_MISSING="$TMP/prod-missing.env"
printf 'DSA_ENV=production\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s/does-not-exist.json\n' "$TMP" > "$ENV_PROD_MISSING"
run_check "$ENV_PROD_MISSING"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + missing blob should FAIL (non-zero), got $RC"; }
printf '%s' "$OUT" | grep -qi "manifest blob: failed" \
  || fail "prod + missing blob should report 'manifest blob: failed'"
printf '%s' "$OUT" | grep -qi "OPS.md" \
  || fail "prod + missing blob should point at the OPS.md ceremony"
printf '%s' "$OUT" | grep -qi "not yet shipped in the pinned image" \
  || fail "prod + missing blob should honestly note sign-manifest is not in the image"
echo "manifest-blob: prod + missing blob -> FAIL with ceremony + honest-residual note ok"

# ---------------------------------------------------------------------------
# 2. dev + blob MISSING -> SKIP (rc=0, no output). A local/sandbox install must
#    never be blocked (the gateway falls back to the legacy single-sig path).
# ---------------------------------------------------------------------------
ENV_DEV_MISSING="$TMP/dev-missing.env"
printf 'DSA_ENV=development\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s/does-not-exist.json\n' "$TMP" > "$ENV_DEV_MISSING"
run_check "$ENV_DEV_MISSING"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "dev + missing blob should SKIP (rc=0), got $RC"; }
[ -z "$OUT" ] || { printf '%s\n' "$OUT" >&2; fail "dev + missing blob should be silent (no output), got: $OUT"; }
echo "manifest-blob: dev + missing blob -> SKIP (rc=0, silent) ok"

# 2b. test env -> also SKIP.
ENV_TEST_MISSING="$TMP/test-missing.env"
printf 'DSA_ENV=test\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s/does-not-exist.json\n' "$TMP" > "$ENV_TEST_MISSING"
run_check "$ENV_TEST_MISSING"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "test env + missing blob should SKIP (rc=0), got $RC"; }
echo "manifest-blob: test env + missing blob -> SKIP (rc=0) ok"

# ---------------------------------------------------------------------------
# 3. prod + blob PRESENT (non-empty) -> PASS (rc=0, silent).
# ---------------------------------------------------------------------------
ENV_PROD_PRESENT="$TMP/prod-present.env"
printf 'DSA_ENV=production\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s\n' "$BLOB" > "$ENV_PROD_PRESENT"
run_check "$ENV_PROD_PRESENT"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + present blob should PASS (rc=0), got $RC"; }
[ -z "$OUT" ] || { printf '%s\n' "$OUT" >&2; fail "prod + present blob should be silent, got: $OUT"; }
echo "manifest-blob: prod + present blob -> PASS (rc=0, silent) ok"

# ---------------------------------------------------------------------------
# 4. prod + blob present but EMPTY (0 bytes) -> FAIL (the gateway treats a
#    malformed/empty blob as a hard fatal even in dev).
# ---------------------------------------------------------------------------
EMPTY_BLOB="$TMP/empty-witness-signed-manifest.json"
: > "$EMPTY_BLOB"
ENV_PROD_EMPTY="$TMP/prod-empty.env"
printf 'DSA_ENV=production\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s\n' "$EMPTY_BLOB" > "$ENV_PROD_EMPTY"
run_check "$ENV_PROD_EMPTY"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + empty blob should FAIL (non-zero), got $RC"; }
printf '%s' "$OUT" | grep -qi "empty (0 bytes)" \
  || fail "prod + empty blob should report the empty-file reason"
echo "manifest-blob: prod + empty blob -> FAIL (0-byte reason) ok"

# ---------------------------------------------------------------------------
# 5. prod + path UNSET in the env -> still FAIL: the check falls back to the
#    kit compose default /certs/witness-signed-manifest.json, which does not
#    exist on a CI/build host, so an env that omits the var is checked against
#    the path the gateway will actually use.
# ---------------------------------------------------------------------------
ENV_PROD_UNSET="$TMP/prod-unset.env"
printf 'DSA_ENV=production\n' > "$ENV_PROD_UNSET"
run_check "$ENV_PROD_UNSET"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + unset path should FAIL via the /certs default, got $RC"; }
printf '%s' "$OUT" | grep -qi "/certs/witness-signed-manifest.json" \
  || fail "prod + unset path should reference the kit compose default /certs path"
echo "manifest-blob: prod + unset path -> FAIL via /certs default ok"

# ---------------------------------------------------------------------------
# 6. prod + LEGACY var only (VEIL_WITNESS_SIGNED_MANIFEST_PATH) + present blob
#    -> PASS. Confirms env_value_with_legacy fallback is honored.
# ---------------------------------------------------------------------------
ENV_PROD_LEGACY="$TMP/prod-legacy.env"
printf 'DSA_ENV=production\nVEIL_WITNESS_SIGNED_MANIFEST_PATH=%s\n' "$BLOB" > "$ENV_PROD_LEGACY"
run_check "$ENV_PROD_LEGACY"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + legacy VEIL_ var + present blob should PASS (rc=0), got $RC"; }
echo "manifest-blob: prod + legacy VEIL_ path var + present blob -> PASS ok"

echo "lucairn manifest-blob tests: ok"
