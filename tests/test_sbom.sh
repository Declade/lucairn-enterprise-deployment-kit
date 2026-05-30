#!/usr/bin/env bash
# test_sbom.sh — tests for `lucairn sbom` (B1 Slice 2). Covers arg-parsing,
# the SPDX-JSON summary logic (against a committed synthetic fixture), and the
# missing-cosign / missing-key fail-fast guards. The full fetch+verify of a
# real cosign-signed SBOM attestation needs cosign + GHCR access + the live
# attestations (an issuer-host ceremony step) and is the post-merge edge-verify
# (PRD § Acceptance / Slice 2 edge-verify) — NOT covered here.
#
# The synthetic fixture (tests/fixtures/sample.spdx.json) is used because this
# kit repo + dev boxes have no syft/cosign and no GHCR pull creds; it lists 3
# packages with valid SPDX-2.3 structure so the summary logic is exercised
# deterministically (real syft output would vary release-to-release).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/lucairn"
FIXTURE="$ROOT/tests/fixtures/sample.spdx.json"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# 1. Syntax.
bash -n "$CLI"
echo "sbom: bash -n syntax ok"

# 2. sbom --help works + advertises the subcommand in the top-level usage.
"$CLI" sbom --help > "$TMPDIR/sbom-help.out"
grep -q "lucairn sbom <image-ref>" "$TMPDIR/sbom-help.out"
grep -q -- "--download PATH" "$TMPDIR/sbom-help.out"
"$CLI" --help > "$TMPDIR/help.out"
grep -q "lucairn sbom <image-ref>" "$TMPDIR/help.out"
echo "sbom: --help + top-level usage advertise the subcommand ok"

# 3. Missing <image-ref> -> non-zero (usage + a clear error).
set +e
out="$("$CLI" sbom 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: 'sbom' with no image-ref should be non-zero" >&2; exit 1; }
printf '%s' "$out" | grep -qi "an <image-ref> is required" \
  || { echo "FAIL: 'sbom' with no image-ref should explain the requirement" >&2; exit 1; }
echo "sbom: no-image-ref fail-fast ok"

# 4. Unknown option + duplicate image-ref -> non-zero.
set +e
"$CLI" sbom --bogus ghcr.io/declade/dsa-gateway:0.5.0 >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: unknown option should be non-zero" >&2; exit 1; }
set +e
"$CLI" sbom ghcr.io/declade/dsa-gateway:0.5.0 ghcr.io/declade/dsa-audit:0.5.0 >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: two image-refs should be non-zero" >&2; exit 1; }
echo "sbom: arg-parse rejects unknown option + duplicate image-ref ok"

# 5. SPDX-JSON summary logic against the synthetic fixture. Source the CLI (with
#    no positional args it runs `main ""` -> usage, harmless) so the helper
#    function is defined, then summarize the fixture and assert the package
#    count (3), SPDX version, and document name are reported.
SUMMARY="$(
  set -euo pipefail
  source "$CLI" >/dev/null 2>&1
  sbom_summarize_spdx "$FIXTURE" 2>&1
)"
printf '%s\n' "$SUMMARY"
printf '%s' "$SUMMARY" | grep -q "packages=3" \
  || { echo "FAIL: summary should report packages=3 for the fixture" >&2; exit 1; }
printf '%s' "$SUMMARY" | grep -q "format=SPDX-JSON" \
  || { echo "FAIL: summary should report format=SPDX-JSON" >&2; exit 1; }
printf '%s' "$SUMMARY" | grep -q "spdxVersion=SPDX-2.3" \
  || { echo "FAIL: summary should report the SPDX version" >&2; exit 1; }
printf '%s' "$SUMMARY" | grep -q "document=ghcr.io/declade/dsa-gateway:0.5.0" \
  || { echo "FAIL: summary should report the document name" >&2; exit 1; }
echo "sbom: SPDX-JSON fixture summary ok (3 packages, version + name)"

# 5b. The fallback (jq-less) summary path must ALSO count 3 packages from the
#     same fixture. Force the fallback by shadowing `jq` to a missing state:
#     run with a PATH that has bash but no jq, and confirm packages=3 still.
NOJQ_BIN="$TMPDIR/nojq"
mkdir -p "$NOJQ_BIN"
ln -s "$(command -v bash)" "$NOJQ_BIN/bash"
ln -s "$(command -v grep)" "$NOJQ_BIN/grep"
ln -s "$(command -v sed)"  "$NOJQ_BIN/sed"
ln -s "$(command -v wc)"   "$NOJQ_BIN/wc"
ln -s "$(command -v head)" "$NOJQ_BIN/head"
ln -s "$(command -v tr)"   "$NOJQ_BIN/tr"
ln -s "$(command -v cat)"  "$NOJQ_BIN/cat"
FALLBACK="$(
  set -euo pipefail
  PATH="$NOJQ_BIN" bash -c '
    source "'"$CLI"'" >/dev/null 2>&1
    sbom_summarize_spdx "'"$FIXTURE"'" 2>&1
  '
)"
printf '%s\n' "$FALLBACK"
printf '%s' "$FALLBACK" | grep -q "packages=3" \
  || { echo "FAIL: jq-less fallback summary should still count 3 packages" >&2; exit 1; }
echo "sbom: jq-less fallback summary counts 3 packages ok"

# 6. Missing cosign -> clean fail-fast (no attestation fetch). This box has no
#    cosign on the real PATH, so the standard PATH already exercises the
#    cosign-presence guard (real coreutils like dirname/awk stay available).
#    A `command -v cosign` guard asserts the precondition so the test is honest
#    on any host that DOES have cosign installed.
if command -v cosign >/dev/null 2>&1; then
  echo "sbom: missing-cosign fail-fast SKIPPED (cosign is installed on this host)"
else
  set +e
  out="$("$CLI" sbom ghcr.io/declade/dsa-gateway:0.5.0 2>&1)"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || { echo "FAIL: sbom without cosign should be non-zero" >&2; exit 1; }
  printf '%s' "$out" | grep -qi "'cosign' not found on PATH" \
    || { echo "FAIL: sbom without cosign should report cosign not found; got: $out" >&2; exit 1; }
  echo "sbom: missing-cosign fail-fast ok"
fi

# 7. cosign present but the public key missing -> fail-fast before any fetch.
#    PREPEND a shim dir (with a fake cosign answering `version` v2.x) to the
#    REAL PATH so coreutils (dirname/awk/grep/...) still resolve, then point
#    --key at a nonexistent file and assert a clean key-not-found error. The
#    shim cosign exits 99 if ever asked to verify-attestation, proving the
#    fail-fast happens before any fetch.
SHIM="$TMPDIR/shim"
mkdir -p "$SHIM"
cat > "$SHIM/cosign" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "version" ]; then echo "GitVersion: v2.4.1"; exit 0; fi
echo "cosign shim must not reach verify-attestation in this test: $*" >&2
exit 99
SH
chmod +x "$SHIM/cosign"
set +e
out="$(PATH="$SHIM:$PATH" "$CLI" sbom --key "$TMPDIR/nope.pub" ghcr.io/declade/dsa-gateway:0.5.0 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: sbom with missing key should be non-zero" >&2; exit 1; }
printf '%s' "$out" | grep -qi "public key not found" \
  || { echo "FAIL: sbom with missing key should report key not found; got: $out" >&2; exit 1; }
printf '%s' "$out" | grep -qi "verify-attestation" \
  && { echo "FAIL: sbom reached verify-attestation despite missing key" >&2; exit 1; }
echo "sbom: missing-key fail-fast ok (no verify-attestation reached)"

echo "lucairn sbom tests: ok"
