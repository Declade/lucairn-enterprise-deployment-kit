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
# Codex r1 BLOCKER + HIGH (fix-up r1): the configured path is the CONTAINER
# path the gateway reads (/certs/...), bind-mounted from the host dir
# ${SANDBOX_B_CERT_DIR:-./.certs} (docker-compose.customer.yml:766). The doctor
# runs on the HOST, so it must stat the host-side bind-mount source — not /certs
# on the host's own filesystem (which never exists -> a correct prod install
# would FALSE-FAIL). It also requires a regular READABLE non-empty FILE (a
# directory or unreadable file at the path -> the gateway can't read the blob).
# These tests exercise the container->host mapping + the file-vs-directory gate.
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
# file) + optional $2 (compose file, so the relative ${SANDBOX_B_CERT_DIR}
# bind-mount source resolves against the right dir). Captures combined
# stdout/stderr in $OUT and the rc in $RC.
run_check() {
  local envf="$1" composef="${2:-}"
  set +e
  OUT="$(
    set --                      # empty args -> sourced `main` is harmless
    # shellcheck disable=SC1090
    source "$CLI" >/dev/null 2>&1
    check_manifest_blob "$envf" "$composef" 2>&1
  )"
  RC=$?
  set -e
}

BLOB="$TMP/witness-signed-manifest.json"
printf '{"canonical_body_b64":"e30=","witness_signature_hex":"00"}\n' > "$BLOB"

# A minimal compose file standing in for docker-compose.customer.yml, so the
# relative ${SANDBOX_B_CERT_DIR:-./.certs} bind-mount source resolves against
# this dir (the doctor passes the resolved --compose path; we mirror that).
COMPOSE="$TMP/docker-compose.customer.yml"
: > "$COMPOSE"

# ===========================================================================
# CONTAINER -> HOST bind-mount mapping (the Codex r1 BLOCKER cases).
# In a real prod install LCR_WITNESS_SIGNED_MANIFEST_PATH is the CONTAINER path
# (/certs/...); the file lives on the host at ${SANDBOX_B_CERT_DIR:-./.certs}/.
# ===========================================================================

# ---------------------------------------------------------------------------
# A. prod + default container /certs path + blob present at the HOST bind-mount
#    source (default ./.certs, relative to the compose dir) -> PASS.
#    This is the case a CORRECT prod install hits and that the OLD code
#    false-failed (it stat'd /certs/... on the host).
# ---------------------------------------------------------------------------
HOST_CERTS_DEFAULT="$TMP/.certs"
mkdir -p "$HOST_CERTS_DEFAULT"
printf '{"x":1}\n' > "$HOST_CERTS_DEFAULT/witness-signed-manifest.json"
ENV_PROD_DEFAULT="$TMP/prod-default-certs.env"
printf 'DSA_ENV=production\n' > "$ENV_PROD_DEFAULT"   # no path set -> /certs default
run_check "$ENV_PROD_DEFAULT" "$COMPOSE"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + default /certs + host blob present (default ./.certs) should PASS (rc=0), got $RC"; }
[ -z "$OUT" ] || { printf '%s\n' "$OUT" >&2; fail "prod + present host blob should be silent, got: $OUT"; }
echo "manifest-blob: prod + /certs default mapped to host ./.certs (present) -> PASS ok"

# ---------------------------------------------------------------------------
# B. prod + explicit container /certs path + custom SANDBOX_B_CERT_DIR (absolute
#    host dir) + blob present there -> PASS. Confirms the /certs prefix maps to
#    the operator's SANDBOX_B_CERT_DIR, not the literal /certs on the host.
# ---------------------------------------------------------------------------
HOST_CERTS_CUSTOM="$TMP/custom-certs"
mkdir -p "$HOST_CERTS_CUSTOM"
printf '{"x":1}\n' > "$HOST_CERTS_CUSTOM/witness-signed-manifest.json"
ENV_PROD_CUSTOMDIR="$TMP/prod-customdir.env"
printf 'DSA_ENV=production\nSANDBOX_B_CERT_DIR=%s\nLCR_WITNESS_SIGNED_MANIFEST_PATH=/certs/witness-signed-manifest.json\n' \
  "$HOST_CERTS_CUSTOM" > "$ENV_PROD_CUSTOMDIR"
run_check "$ENV_PROD_CUSTOMDIR" "$COMPOSE"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + /certs path + custom SANDBOX_B_CERT_DIR (blob present) should PASS, got $RC"; }
echo "manifest-blob: prod + /certs mapped to custom SANDBOX_B_CERT_DIR (present) -> PASS ok"

# ---------------------------------------------------------------------------
# C. prod + container /certs path but blob MISSING at the host source -> FAIL,
#    and the message must name the HOST path (not /certs on the host) + the
#    ceremony + the turnkey sign-manifest remediation (docker run
#    --entrypoint sign-manifest …, pointing at INSTALL.md § 4b; the tool now
#    ships inside the pinned dsa-veil-witness:0.5.2 image).
# ---------------------------------------------------------------------------
HOST_CERTS_EMPTY="$TMP/empty-certs-dir"
mkdir -p "$HOST_CERTS_EMPTY"   # dir exists, but no manifest file inside
ENV_PROD_HOSTMISS="$TMP/prod-host-missing.env"
printf 'DSA_ENV=production\nSANDBOX_B_CERT_DIR=%s\n' "$HOST_CERTS_EMPTY" > "$ENV_PROD_HOSTMISS"
run_check "$ENV_PROD_HOSTMISS" "$COMPOSE"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + /certs default + missing host blob should FAIL, got $RC"; }
printf '%s' "$OUT" | grep -qi "manifest blob: failed" \
  || fail "prod + missing host blob should report 'manifest blob: failed'"
printf '%s' "$OUT" | grep -qF "$HOST_CERTS_EMPTY/witness-signed-manifest.json" \
  || fail "prod + missing host blob should name the resolved HOST path, not /certs on the host"
printf '%s' "$OUT" | grep -qi "OPS.md" \
  || fail "prod + missing host blob should point at the OPS.md ceremony"
printf '%s' "$OUT" | grep -qi "sign-manifest" \
  || fail "prod + missing host blob should give the sign-manifest remediation"
printf '%s' "$OUT" | grep -qi "docker run" \
  || fail "prod + missing host blob should give the turnkey 'docker run --entrypoint sign-manifest' remediation"
printf '%s' "$OUT" | grep -qi "INSTALL.md" \
  || fail "prod + missing host blob should point at INSTALL.md § 4b for the full sign-manifest command"
echo "manifest-blob: prod + /certs default + host blob MISSING -> FAIL (names host path + ceremony) ok"

# ---------------------------------------------------------------------------
# D. prod + a DIRECTORY at the resolved host path -> FAIL (the gateway needs a
#    regular readable file; -e/-s alone would pass a directory). Codex r1 HIGH.
# ---------------------------------------------------------------------------
HOST_CERTS_DIRBLOB="$TMP/dirblob-certs"
mkdir -p "$HOST_CERTS_DIRBLOB/witness-signed-manifest.json"   # a DIRECTORY at the blob path
ENV_PROD_DIRBLOB="$TMP/prod-dirblob.env"
printf 'DSA_ENV=production\nSANDBOX_B_CERT_DIR=%s\n' "$HOST_CERTS_DIRBLOB" > "$ENV_PROD_DIRBLOB"
run_check "$ENV_PROD_DIRBLOB" "$COMPOSE"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + DIRECTORY at the blob path should FAIL, got $RC"; }
printf '%s' "$OUT" | grep -qi "not a regular file" \
  || fail "prod + directory at the blob path should report 'not a regular file'"
echo "manifest-blob: prod + DIRECTORY at host path -> FAIL (regular-file gate) ok"

# ===========================================================================
# Operator-override (absolute host path, not /certs) + dev/test skip + legacy.
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. prod + path set to an ABSOLUTE host path NOT under /certs + blob present
#    -> PASS (operator override; stat as-is). Mirrors the test_sec_hardening.sh
#    fixture (LCR_WITNESS_SIGNED_MANIFEST_PATH=$TMPDIR/witness-signed-manifest.json).
# ---------------------------------------------------------------------------
ENV_PROD_ABS="$TMP/prod-abs.env"
printf 'DSA_ENV=production\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s\n' "$BLOB" > "$ENV_PROD_ABS"
run_check "$ENV_PROD_ABS" "$COMPOSE"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + absolute host path (present) should PASS (rc=0), got $RC"; }
[ -z "$OUT" ] || { printf '%s\n' "$OUT" >&2; fail "prod + present absolute blob should be silent, got: $OUT"; }
echo "manifest-blob: prod + absolute host override (present) -> PASS ok"

# 1b. prod + absolute host path NOT under /certs + blob MISSING -> FAIL.
ENV_PROD_ABS_MISS="$TMP/prod-abs-missing.env"
printf 'DSA_ENV=production\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s/does-not-exist.json\n' "$TMP" > "$ENV_PROD_ABS_MISS"
run_check "$ENV_PROD_ABS_MISS" "$COMPOSE"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + absolute host path missing should FAIL, got $RC"; }
printf '%s' "$OUT" | grep -qi "manifest blob: failed" \
  || fail "prod + absolute missing should report 'manifest blob: failed'"
echo "manifest-blob: prod + absolute host override (missing) -> FAIL ok"

# ---------------------------------------------------------------------------
# 2. dev + blob MISSING -> SKIP (rc=0, no output). A local/sandbox install must
#    never be blocked (the gateway falls back to the legacy single-sig path).
# ---------------------------------------------------------------------------
ENV_DEV_MISSING="$TMP/dev-missing.env"
printf 'DSA_ENV=development\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s/does-not-exist.json\n' "$TMP" > "$ENV_DEV_MISSING"
run_check "$ENV_DEV_MISSING" "$COMPOSE"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "dev + missing blob should SKIP (rc=0), got $RC"; }
[ -z "$OUT" ] || { printf '%s\n' "$OUT" >&2; fail "dev + missing blob should be silent (no output), got: $OUT"; }
echo "manifest-blob: dev + missing blob -> SKIP (rc=0, silent) ok"

# 2b. test env -> also SKIP.
ENV_TEST_MISSING="$TMP/test-missing.env"
printf 'DSA_ENV=test\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s/does-not-exist.json\n' "$TMP" > "$ENV_TEST_MISSING"
run_check "$ENV_TEST_MISSING" "$COMPOSE"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "test env + missing blob should SKIP (rc=0), got $RC"; }
echo "manifest-blob: test env + missing blob -> SKIP (rc=0) ok"

# ---------------------------------------------------------------------------
# 3. prod + absolute host path present but EMPTY (0 bytes) -> FAIL (the gateway
#    treats a malformed/empty blob as a hard fatal).
# ---------------------------------------------------------------------------
EMPTY_BLOB="$TMP/empty-witness-signed-manifest.json"
: > "$EMPTY_BLOB"
ENV_PROD_EMPTY="$TMP/prod-empty.env"
printf 'DSA_ENV=production\nLCR_WITNESS_SIGNED_MANIFEST_PATH=%s\n' "$EMPTY_BLOB" > "$ENV_PROD_EMPTY"
run_check "$ENV_PROD_EMPTY" "$COMPOSE"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + empty blob should FAIL (non-zero), got $RC"; }
printf '%s' "$OUT" | grep -qi "empty (0 bytes)" \
  || fail "prod + empty blob should report the empty-file reason"
echo "manifest-blob: prod + empty blob -> FAIL (0-byte reason) ok"

# ---------------------------------------------------------------------------
# 4. prod + path UNSET in the env -> FAIL via the /certs default mapped to the
#    default ./.certs host source, which has no blob under THIS (fresh) compose
#    dir. Confirms an env that omits the var is checked against the host path
#    the gateway will actually read.
# ---------------------------------------------------------------------------
FRESH_DIR="$TMP/fresh-install"
mkdir -p "$FRESH_DIR"
FRESH_COMPOSE="$FRESH_DIR/docker-compose.customer.yml"
: > "$FRESH_COMPOSE"
ENV_PROD_UNSET="$TMP/prod-unset.env"
printf 'DSA_ENV=production\n' > "$ENV_PROD_UNSET"
run_check "$ENV_PROD_UNSET" "$FRESH_COMPOSE"
[ "$RC" -ne 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + unset path should FAIL via the /certs->./.certs default, got $RC"; }
printf '%s' "$OUT" | grep -qF "$FRESH_DIR/.certs/witness-signed-manifest.json" \
  || fail "prod + unset path should reference the default ./.certs host source under the compose dir"
echo "manifest-blob: prod + unset path -> FAIL via /certs->./.certs default ok"

# ---------------------------------------------------------------------------
# 5. prod + LEGACY var only (VEIL_WITNESS_SIGNED_MANIFEST_PATH) as an absolute
#    host path + present blob -> PASS. Confirms env_value_with_legacy fallback.
# ---------------------------------------------------------------------------
ENV_PROD_LEGACY="$TMP/prod-legacy.env"
printf 'DSA_ENV=production\nVEIL_WITNESS_SIGNED_MANIFEST_PATH=%s\n' "$BLOB" > "$ENV_PROD_LEGACY"
run_check "$ENV_PROD_LEGACY" "$COMPOSE"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + legacy VEIL_ var + present blob should PASS (rc=0), got $RC"; }
echo "manifest-blob: prod + legacy VEIL_ path var + present blob -> PASS ok"

# ---------------------------------------------------------------------------
# 6. prod + a RELATIVE, non-/certs container path -> WARN-and-skip (rc=0): the
#    doctor can't map an arbitrary relative container path to a host source, so
#    it must NOT false-fail a non-standard-but-valid setup.
# ---------------------------------------------------------------------------
ENV_PROD_RELPATH="$TMP/prod-relpath.env"
printf 'DSA_ENV=production\nLCR_WITNESS_SIGNED_MANIFEST_PATH=relative/manifest.json\n' > "$ENV_PROD_RELPATH"
run_check "$ENV_PROD_RELPATH" "$COMPOSE"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; fail "prod + relative non-/certs path should WARN-and-skip (rc=0), not fail, got $RC"; }
printf '%s' "$OUT" | grep -qi "cannot map" \
  || fail "prod + relative non-/certs path should emit a warn explaining it cannot map the path"
echo "manifest-blob: prod + relative non-/certs path -> WARN-and-skip (rc=0) ok"

echo "lucairn manifest-blob tests: ok"
