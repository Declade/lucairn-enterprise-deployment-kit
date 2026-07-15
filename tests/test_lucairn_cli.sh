#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
# Also remove the kit-local customer_id state file the A9 auto-fill sub-tests
# write into $ROOT (it is gitignored, but clean it up on every exit path so a
# mid-run abort never leaves it behind).
trap 'rm -rf "$TMPDIR"; rm -f "$ROOT/.lucairn-customer-id"' EXIT

REMOTE_CREDENTIALS="$TMPDIR/lucairn-issued-remote-credentials.env"
printf 'sandbox_b_api_key=lcr-issued-test-api-key_123\nsandbox_b_public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n' > "$REMOTE_CREDENTIALS"

# Generate the base customer.env with bin/lucairn-init (real, coherent Ed25519
# keypairs + non-sentinel secrets) instead of a hand-frozen heredoc. The frozen
# heredoc bit-rotted against later doctor checks (the repeating-character
# "sentinel" reject added 2026-05-15 + the production manifest-blob gate added
# 2026-06-15), since CI only `bash -n`'s this file and never executed it. Using
# --dev keeps doctor green (no production manifest gate) and additionally
# exercises the lucairn-init code path A9 modifies.
# Use the kit's default image tag (image-manifest.yaml default_lucairn_image_tag,
# within the sanitizer_config_compat range) so the sanitizer-drift check passes.
ENV_FILE="$TMPDIR/customer.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name acme-support-llm --model-file acme-support-q4.gguf --model-path . \
  --output "$ENV_FILE" --skip-doctor >/dev/null 2>&1
KIT_IMAGE_TAG="$(grep -E '^LUCAIRN_IMAGE_TAG=' "$ENV_FILE" | tail -1 | sed 's/^[^=]*=//')"

copy_profiled_env() {
  cp "$1" "$2"
  cp "$1.runtime-profile.yaml" "$2.runtime-profile.yaml"
  cp "$1.image-manifest.yaml" "$2.image-manifest.yaml"
}

# The support-bundle redaction asserts below need DSA_LICENSE_KEY +
# SANDBOX_B_API_KEY present in the env file. --dev leaves DSA_LICENSE_KEY empty
# and SANDBOX_B_API_KEY blank, so set dummy values for the redaction coverage.
# (DSA_LICENSE_KEY here is a redaction-test sentinel, not a real license — the
# gateway never sees this file.)
{
  printf 'DSA_LICENSE_KEY=lcr_enterprise_test_secret\n'
  printf 'DSA_LICENSE_SIGNING_KEY=test-license-signing-secret\n'
  printf 'SANDBOX_B_API_KEY=sk-test-sandbox-b-secret\n'
} >> "$ENV_FILE"

"$ROOT/bin/lucairn" doctor \
  --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor.out"

grep -q "doctor: ok" "$TMPDIR/doctor.out"
grep -q "required secrets: ok" "$TMPDIR/doctor.out"
grep -q "compose file: ok" "$TMPDIR/doctor.out"

# A9: with no LUCAIRN_LICENSE_* set, doctor reports the entitlement as
# unregistered (a WARN-class informational line) and still PASSES — an empty
# deployment entitlement is a valid posture (core pipeline runs).
grep -q "entitlement: empty LUCAIRN_LICENSE_KEY" "$TMPDIR/doctor.out"

"$ROOT/bin/lucairn" support-bundle \
  --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --output "$TMPDIR/bundles" \
  --offline > "$TMPDIR/support.out"

BUNDLE="$(find "$TMPDIR/bundles" -name 'lucairn-support-bundle-*.tar.gz' -print -quit)"
test -n "$BUNDLE"

EXTRACTED="$TMPDIR/extracted"
mkdir -p "$EXTRACTED"
tar -xzf "$BUNDLE" -C "$EXTRACTED"

grep -R "DSA_LICENSE_KEY=<redacted>" "$EXTRACTED"
grep -R "SANDBOX_B_API_KEY=<redacted>" "$EXTRACTED"

if grep -R "lcr_enterprise_test_secret\\|sk-test-sandbox-b-secret\\|postgres-audit-secret\\|portal-api-key-secret" "$EXTRACTED"; then
  echo "support bundle leaked a secret" >&2
  exit 1
fi

echo "lucairn cli tests: ok"

# S1 strict runtime-profile grammar: no ambiguous YAML state can reach a
# support archive. These mutate independent copies so the normal CLI battery
# continues to exercise the generated valid profile.
expect_profile_reject() {
  local name profile
  name="$1"
  profile="$TMPDIR/${name}.env.runtime-profile.yaml"
  cp "$ENV_FILE" "$TMPDIR/${name}.env"
  cp "$ENV_FILE.runtime-profile.yaml" "$profile"
  shift
  "$@" "$profile"
  set +e
  "$ROOT/bin/lucairn" support-bundle --env "$TMPDIR/${name}.env" \
    --compose "$ROOT/docker-compose.customer.yml" --output "$TMPDIR/${name}-support" --offline > "$TMPDIR/${name}.out" 2>&1
  local status=$?
  set -e
  [ "$status" -ne 0 ] || { echo "ambiguous profile should be rejected: $name" >&2; exit 1; }
  test ! -e "$TMPDIR/${name}-support"
  grep -q 'runtime profile: failed' "$TMPDIR/${name}.out"
}

expect_profile_reject blank-runtime sh -c 'sed "s/^runtime_mode:.*/runtime_mode:/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh
expect_profile_reject duplicate-runtime sh -c 'printf "runtime_mode: split-remote\\n" >> "$1"' sh
expect_profile_reject nested-runtime sh -c 'printf "  runtime_mode: split-remote\\n" >> "$1"' sh
expect_profile_reject second-overlays sh -c 'printf "overlays:\\n  - docker-compose.customer.yml\\n" >> "$1"' sh
expect_profile_reject unknown-secret sh -c 'printf "api_key: should-never-copy\\n" >> "$1"' sh
expect_profile_reject malformed-indent sh -c 'sed "s/^  provenance:/   provenance:/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh
expect_profile_reject bad-profile-hash sh -c 'sed "s/^  sha256:.*/  sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh
expect_profile_reject bad-image-digest sh -c 'sed "s/^      digest: .*/      digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh
expect_profile_reject omitted-image-digest sh -c 'sed "/^      digest:/d" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh
expect_profile_reject duplicate-image-ref sh -c 'sed -n "/^    - ref:/,/^      digest:/p" "$1" >> "$1"' sh

# A symlink profile is rejected before it can be read or copied.
ln -s "$ENV_FILE.runtime-profile.yaml" "$TMPDIR/symlink-profile.env.runtime-profile.yaml"
cp "$ENV_FILE" "$TMPDIR/symlink-profile.env"
set +e
"$ROOT/bin/lucairn" support-bundle --env "$TMPDIR/symlink-profile.env" --compose "$ROOT/docker-compose.customer.yml" --output "$TMPDIR/symlink-profile-support" --offline > "$TMPDIR/symlink-profile.out" 2>&1
SYMLINK_PROFILE_STATUS=$?
set -e
[ "$SYMLINK_PROFILE_STATUS" -ne 0 ]
test ! -e "$TMPDIR/symlink-profile-support"

# Endpoint syntax allows a normal FQDN + port + escaped path, but rejects
# literals and local-only names without doing a network lookup.
for BAD_ENDPOINT in https://127.0.0.1 https://localhost https://runtime; do
  set +e
  "$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint "$BAD_ENDPOINT" --output "$TMPDIR/bad-endpoint.env" --skip-doctor > "$TMPDIR/bad-endpoint.out" 2>&1
  BAD_ENDPOINT_STATUS=$?
  set -e
  [ "$BAD_ENDPOINT_STATUS" -ne 0 ] || { echo "endpoint should be rejected: $BAD_ENDPOINT" >&2; exit 1; }
done
"$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint 'https://inference.enterprise.example:8443/v1/models%2Fcurrent' --remote-credentials "$REMOTE_CREDENTIALS" --output "$TMPDIR/good-endpoint.env" --skip-doctor >/dev/null 2>&1

# BYOK records the exact allowlist, rather than merely asserting that one is
# present in customer.env.
"$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$TMPDIR/byok-drift.env" --skip-doctor >/dev/null 2>&1
sed 's/^byok_egress_allowlist:.*/byok_egress_allowlist: api.drift.example/' "$TMPDIR/byok-drift.env.runtime-profile.yaml" > "$TMPDIR/byok-drift.profile" && mv "$TMPDIR/byok-drift.profile" "$TMPDIR/byok-drift.env.runtime-profile.yaml"
set +e
"$ROOT/bin/lucairn" doctor --env "$TMPDIR/byok-drift.env" --compose "$ROOT/docker-compose.customer.yml" --offline --skip-image-check > "$TMPDIR/byok-drift.out" 2>&1
BYOK_DRIFT_STATUS=$?
set -e
[ "$BYOK_DRIFT_STATUS" -ne 0 ] || { echo "BYOK allowlist drift should be rejected" >&2; exit 1; }
grep -q 'runtime profile: failed' "$TMPDIR/byok-drift.out"

echo "lucairn strict runtime-profile tests: ok"

# --- A9: deployment-entitlement doctor coverage ------------------------------

# Both entitlement vars set -> doctor reports "configured" and still passes.
ENV_ENT="$TMPDIR/customer-entitlement.env"
copy_profiled_env "$ENV_FILE" "$ENV_ENT"
{
  printf 'LUCAIRN_LICENSE_KEY=ent_token_dummy\n'
  printf 'LUCAIRN_LICENSE_PUBLIC_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\n'
  printf 'LUCAIRN_LICENSE_GRACE_DAYS=14\n'
} >> "$ENV_ENT"
set +e
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_ENT" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-ent.out"
DOCTOR_ENT_STATUS=$?
set -e
[ "$DOCTOR_ENT_STATUS" -eq 0 ] || { cat "$TMPDIR/doctor-ent.out" >&2; exit 1; }
grep -q "doctor: ok" "$TMPDIR/doctor-ent.out"
grep -q "entitlement: LUCAIRN_LICENSE_KEY + LUCAIRN_LICENSE_PUBLIC_KEY set" "$TMPDIR/doctor-ent.out"

# Exactly one entitlement var set -> doctor WARNs (to stderr) but does NOT fail
# (an incomplete entitlement is a config smell, not an install blocker).
ENV_ENT_HALF="$TMPDIR/customer-entitlement-half.env"
copy_profiled_env "$ENV_FILE" "$ENV_ENT_HALF"
printf 'LUCAIRN_LICENSE_KEY=ent_token_dummy_only\n' >> "$ENV_ENT_HALF"
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_ENT_HALF" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-ent-half.out" 2> "$TMPDIR/doctor-ent-half.err"
grep -q "doctor: ok" "$TMPDIR/doctor-ent-half.out"
grep -q "warn: entitlement:" "$TMPDIR/doctor-ent-half.err"
grep -Fq "Re-run bin/lucairn-init --production --runtime-mode <mode> --license <path> with the selected mode's compatible required flags and a complete license bundle" "$TMPDIR/doctor-ent-half.err"
if grep -Fq "Re-run bin/lucairn-init --production with" "$TMPDIR/doctor-ent-half.err"; then
  echo "entitlement recovery guidance must not regress to a bare production init command" >&2
  exit 1
fi

# --- A9 fixup: CRASHLOOP-class format/range guards + prod reminder -----------

# (a) Gap 1: a malformed LUCAIRN_LICENSE_PUBLIC_KEY (not 64-hex) -> doctor FAILS.
# The gateway's LoadPublicKeyHex log.Fatals on a non-64-hex pubkey on a pinned
# boot, so doctor must ERROR here instead of going green-then-crashloop. Both a
# non-hex token AND a too-short (32-char) hex string must be rejected.
for BAD_PUB in "not-hex" "0011223344556677889900112233aabb"; do
  ENV_BADPUB="$TMPDIR/customer-entitlement-badpub.env"
  copy_profiled_env "$ENV_FILE" "$ENV_BADPUB"
  {
    printf 'LUCAIRN_LICENSE_KEY=ent_token_dummy\n'
    printf 'LUCAIRN_LICENSE_PUBLIC_KEY=%s\n' "$BAD_PUB"
  } >> "$ENV_BADPUB"
  set +e
  "$ROOT/bin/lucairn" doctor \
    --env "$ENV_BADPUB" \
    --compose "$ROOT/docker-compose.customer.yml" \
    --offline > "$TMPDIR/doctor-badpub.out" 2>&1
  BADPUB_STATUS=$?
  set -e
  if [ "$BADPUB_STATUS" -eq 0 ]; then
    echo "doctor should FAIL on a malformed LUCAIRN_LICENSE_PUBLIC_KEY ('$BAD_PUB')" >&2
    exit 1
  fi
  grep -q "secret format: LUCAIRN_LICENSE_PUBLIC_KEY must be 64 hex chars" "$TMPDIR/doctor-badpub.out"
done

# (b) Gap 1 happy path: a valid 64-hex LUCAIRN_LICENSE_PUBLIC_KEY -> doctor passes.
ENV_GOODPUB="$TMPDIR/customer-entitlement-goodpub.env"
copy_profiled_env "$ENV_FILE" "$ENV_GOODPUB"
{
  printf 'LUCAIRN_LICENSE_KEY=ent_token_dummy\n'
  printf 'LUCAIRN_LICENSE_PUBLIC_KEY=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
} >> "$ENV_GOODPUB"
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_GOODPUB" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-goodpub.out"
grep -q "doctor: ok" "$TMPDIR/doctor-goodpub.out"
grep -q "secret formats: ok" "$TMPDIR/doctor-goodpub.out"

# (c) Gap 2: a non-integer LUCAIRN_LICENSE_GRACE_DAYS (e.g. "14d") -> doctor
# FAILS; a plain integer ("14") -> doctor passes. The gateway rejects a
# non-integer grace at boot (fatal), so doctor must block it pre-flight.
ENV_BADGRACE="$TMPDIR/customer-entitlement-badgrace.env"
copy_profiled_env "$ENV_FILE" "$ENV_BADGRACE"
printf 'LUCAIRN_LICENSE_GRACE_DAYS=14d\n' >> "$ENV_BADGRACE"
set +e
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_BADGRACE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-badgrace.out" 2>&1
BADGRACE_STATUS=$?
set -e
if [ "$BADGRACE_STATUS" -eq 0 ]; then
  echo "doctor should FAIL on a non-integer LUCAIRN_LICENSE_GRACE_DAYS ('14d')" >&2
  exit 1
fi
grep -q "LUCAIRN_LICENSE_GRACE_DAYS must be a non-negative integer" "$TMPDIR/doctor-badgrace.out"

ENV_GOODGRACE="$TMPDIR/customer-entitlement-goodgrace.env"
copy_profiled_env "$ENV_FILE" "$ENV_GOODGRACE"
printf 'LUCAIRN_LICENSE_GRACE_DAYS=14\n' >> "$ENV_GOODGRACE"
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_GOODGRACE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-goodgrace.out"
grep -q "doctor: ok" "$TMPDIR/doctor-goodgrace.out"

# (d) Gap 3: production + both entitlement vars set -> the pubkey-match reminder
# WARN appears (informational only; doctor still passes — kit-side doctor can't
# see the baked pin). The dev ENV_ENT case above must NOT emit it.
ENV_PROD_ENT="$TMPDIR/customer-entitlement-prod.env"
copy_profiled_env "$ENV_ENT" "$ENV_PROD_ENT"
printf 'DSA_ENV=production\n' >> "$ENV_PROD_ENT"
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_PROD_ENT" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-prod-ent.out" 2> "$TMPDIR/doctor-prod-ent.err" || true
grep -q "warn: entitlement: ensure LUCAIRN_LICENSE_PUBLIC_KEY matches" "$TMPDIR/doctor-prod-ent.err"
# The dev both-set run earlier must NOT carry the prod reminder.
if grep -q "ensure LUCAIRN_LICENSE_PUBLIC_KEY matches" "$TMPDIR/doctor-ent.out"; then
  echo "prod pubkey-match reminder leaked into a non-production doctor run" >&2
  exit 1
fi

echo "lucairn entitlement doctor tests: ok"

# --- A9: lucairn-init writes the entitlement vars from the bundle ------------

# Production bundle carrying the entitlement fields -> customer.env gets them.
INIT_BUNDLE="$TMPDIR/a9-bundle.json"
printf '{"license_key":"lic_x","signing_key":"sk_x","entitlement_token":"tok_dummy","entitlement_public_key":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"}' > "$INIT_BUNDLE"
INIT_OUT="$TMPDIR/a9-customer.env"
"$ROOT/bin/lucairn-init" --production --license "$INIT_BUNDLE" --runtime-mode local-runtime --local-runtime llama-cpp --output "$INIT_OUT" --skip-doctor >/dev/null 2>&1
grep -q '^LUCAIRN_LICENSE_KEY=tok_dummy$' "$INIT_OUT"
grep -q '^LUCAIRN_LICENSE_PUBLIC_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff$' "$INIT_OUT"
grep -q '^DSA_LICENSE_KEY=lic_x$' "$INIT_OUT"

# Backward-compat: a bundle WITHOUT entitlement fields still parses; the
# entitlement vars are written empty (unregistered/INERT).
INIT_BUNDLE_NOENT="$TMPDIR/a9-bundle-noent.json"
printf '{"license_key":"lic_y","signing_key":"sk_y"}' > "$INIT_BUNDLE_NOENT"
INIT_OUT_NOENT="$TMPDIR/a9-customer-noent.env"
"$ROOT/bin/lucairn-init" --production --license "$INIT_BUNDLE_NOENT" --runtime-mode local-runtime --local-runtime llama-cpp --output "$INIT_OUT_NOENT" --skip-doctor >/dev/null 2>&1
grep -q '^LUCAIRN_LICENSE_KEY=$' "$INIT_OUT_NOENT"
grep -q '^LUCAIRN_LICENSE_PUBLIC_KEY=$' "$INIT_OUT_NOENT"

# --dev: entitlement vars present but empty (grace defaults to 14).
INIT_OUT_DEV="$TMPDIR/a9-customer-dev.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp --output "$INIT_OUT_DEV" --skip-doctor >/dev/null 2>&1
grep -q '^LUCAIRN_LICENSE_KEY=$' "$INIT_OUT_DEV"
grep -q '^LUCAIRN_LICENSE_PUBLIC_KEY=$' "$INIT_OUT_DEV"
grep -q '^LUCAIRN_LICENSE_GRACE_DAYS=14$' "$INIT_OUT_DEV"

echo "lucairn-init entitlement wiring tests: ok"

# --- A9: customer_id persistence + license-issue auto-fill -------------------

# Stub the license-sign runner with a script that echoes its args so we can
# observe what --customer-id the wrapper injected.
STUB_BIN="$TMPDIR/stub-license-sign"
cat > "$STUB_BIN" <<'STUB'
#!/usr/bin/env bash
printf 'STUBARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
STUB
chmod +x "$STUB_BIN"

# No persisted customer_id and no explicit flag -> license issue must fail with
# the actionable pointer (it must NOT silently shell out without a customer_id).
rm -f "$ROOT/.lucairn-customer-id"
set +e
LUCAIRN_LICENSE_SIGN_BIN="$STUB_BIN" "$ROOT/bin/lucairn" license issue \
  --license-id lic_x --customer-name "Bhatia" --valid-until 2027-01-01 \
  --signing-key-hex deadbeef > "$TMPDIR/issue-noid.out" 2>&1
ISSUE_NOID_STATUS=$?
set -e
if [ "$ISSUE_NOID_STATUS" -eq 0 ]; then
  echo "license issue with no customer_id should fail" >&2
  exit 1
fi
grep -q "no persisted customer_id" "$TMPDIR/issue-noid.out"

# Persist a customer_id (simulate a successful mint) and confirm auto-fill.
printf 'bhatia_test\n' > "$ROOT/.lucairn-customer-id"
chmod 0600 "$ROOT/.lucairn-customer-id"
LUCAIRN_LICENSE_SIGN_BIN="$STUB_BIN" "$ROOT/bin/lucairn" license issue \
  --license-id lic_x --customer-name "Bhatia" --valid-until 2027-01-01 \
  --signing-key-hex deadbeef > "$TMPDIR/issue-autofill.out" 2>&1
grep -q "STUBARGS: issue --customer-id bhatia_test --license-id lic_x" "$TMPDIR/issue-autofill.out"

# Explicit --customer-id wins over the persisted value (never overridden).
LUCAIRN_LICENSE_SIGN_BIN="$STUB_BIN" "$ROOT/bin/lucairn" license issue \
  --customer-id explicit_override --license-id lic_x --customer-name "Bhatia" \
  --valid-until 2027-01-01 --signing-key-hex deadbeef > "$TMPDIR/issue-explicit.out" 2>&1
grep -q "STUBARGS: issue --customer-id explicit_override --license-id lic_x" "$TMPDIR/issue-explicit.out"
if grep -q "bhatia_test" "$TMPDIR/issue-explicit.out"; then
  echo "explicit --customer-id must not be overridden by the persisted value" >&2
  exit 1
fi

rm -f "$ROOT/.lucairn-customer-id"
echo "lucairn license auto-fill tests: ok"

# --- M1 fixup: clean exit 1 (not 127) when no signer is configured ----------
#
# Regression guard for the `exec $(license_sign_runner) …` bug: when the runner
# could not be resolved (no LUCAIRN_LICENSE_SIGN_BIN, no `license-sign` on PATH,
# no DSA_REPO) the inner `fail`/exit 1 only exited the $(...) SUBSHELL, leaving
# `exec  issue …` → `exec: issue: not found` (EXIT 127) AFTER the actionable
# message. Run `license issue` with NO signer available and assert: exit 1 (not
# 127), the actionable "license-sign tool not found" message IS printed, and the
# spurious `exec: issue: not found` line is NOT.
NOSIGN_BIN="$TMPDIR/nosign-bin"
mkdir -p "$NOSIGN_BIN"
# A minimal PATH with the coreutils bin/lucairn needs early but WITHOUT
# license-sign or go, so license_sign_runner exhausts all three discovery paths.
for t in bash cat dirname pwd head tr printf grep sed env cut awk; do
  src="$(command -v "$t" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$NOSIGN_BIN/$t"
done
rm -f "$ROOT/.lucairn-customer-id"
set +e
env -i PATH="$NOSIGN_BIN" HOME="$TMPDIR" "$ROOT/bin/lucairn" license issue \
  --license-id lic_x --customer-id cust_x --customer-name "Bhatia" \
  --valid-until 2027-01-01 --signing-key-hex deadbeef \
  > "$TMPDIR/issue-nosigner.out" 2> "$TMPDIR/issue-nosigner.err"
ISSUE_NOSIGNER_STATUS=$?
set -e
if [ "$ISSUE_NOSIGNER_STATUS" -ne 1 ]; then
  echo "license issue with no signer must exit 1, got $ISSUE_NOSIGNER_STATUS" >&2
  cat "$TMPDIR/issue-nosigner.out" "$TMPDIR/issue-nosigner.err" >&2
  exit 1
fi
grep -q "license-sign tool not found" "$TMPDIR/issue-nosigner.err"
if grep -q "exec: issue: not found" "$TMPDIR/issue-nosigner.out" "$TMPDIR/issue-nosigner.err"; then
  echo "license issue emitted the spurious 'exec: issue: not found' bash error" >&2
  exit 1
fi

# Companion: with a stubbed signer present (LUCAIRN_LICENSE_SIGN_BIN=/bin/echo)
# the A9 auto-fill still injects --customer-id and execs the signer. Use the
# persisted-id path so we exercise the auto-fill branch end-to-end.
printf 'm1_fixup_cid\n' > "$ROOT/.lucairn-customer-id"
chmod 0600 "$ROOT/.lucairn-customer-id"
LUCAIRN_LICENSE_SIGN_BIN=/bin/echo "$ROOT/bin/lucairn" license issue \
  --license-id lic_x --customer-name "Bhatia" --valid-until 2027-01-01 \
  --signing-key-hex deadbeef > "$TMPDIR/issue-stub-echo.out" 2>&1
grep -q "issue --customer-id m1_fixup_cid --license-id lic_x" "$TMPDIR/issue-stub-echo.out"
rm -f "$ROOT/.lucairn-customer-id"
echo "lucairn license no-signer exit-code tests: ok"

FAKEBIN="$TMPDIR/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/docker" <<'DOCKER'
#!/usr/bin/env bash
if [ "$1" = "manifest" ] && [ "$2" = "inspect" ]; then
  echo 'unauthorized: authentication required' >&2
  exit 1
fi
if [ "$1" = "--version" ]; then
  echo "Docker version test"
  exit 0
fi
exit 0
DOCKER
chmod +x "$FAKEBIN/docker"

set +e
PATH="$FAKEBIN:$PATH" "$ROOT/bin/lucairn" doctor \
  --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline \
  --check-images > "$TMPDIR/image-check.out" 2>&1
IMAGE_CHECK_STATUS=$?
set -e

if [ "$IMAGE_CHECK_STATUS" -eq 0 ]; then
  echo "image check should fail when registry auth is missing" >&2
  exit 1
fi

grep -q "container images: failed" "$TMPDIR/image-check.out"
grep -q "dsa-gateway:${KIT_IMAGE_TAG}" "$TMPDIR/image-check.out"

echo "lucairn image-check test: ok"

MODEL_DIR="$TMPDIR/models"
mkdir -p "$MODEL_DIR"
printf 'fake gguf model bytes\n' > "$MODEL_DIR/acme-support-q4.gguf"

if command -v sha256sum >/dev/null 2>&1; then
  MODEL_SHA="$(sha256sum "$MODEL_DIR/acme-support-q4.gguf" | awk '{print $1}')"
else
  MODEL_SHA="$(shasum -a 256 "$MODEL_DIR/acme-support-q4.gguf" | awk '{print $1}')"
fi

MODEL_MANIFEST="$TMPDIR/model-manifest.yaml"
cat > "$MODEL_MANIFEST" <<YAML
model:
  name: acme-support-llm
  format: gguf
  runtime: llama-cpp
  files:
    - path: acme-support-q4.gguf
      sha256: $MODEL_SHA
  context_window: 8192
  gpu_required: false
  min_vram_gb: 0
  license: customer-owned
  checksum_policy: sha256-required
YAML

IMAGE_TAR="$TMPDIR/lucairn-images.tar"
printf 'fake image archive\n' > "$IMAGE_TAR"

# The model-manifest parser is a strict S1 contract, not a first-match YAML
# accessor.  Exercise the same hostile vocabulary through bundle create and
# bundle prepare before either can create output.
write_bad_model_manifest() {
  local case_name="$1" target="$2"
  cp "$MODEL_MANIFEST" "$target"
  case "$case_name" in
    yaml-meta) sed 's/^  name:.*/  name: model\&name/' "$target" > "$target.tmp" && mv "$target.tmp" "$target" ;;
    duplicate-name) printf '  name: duplicate-model\n' >> "$target" ;;
    duplicate-runtime) printf '  runtime: llama-cpp\n' >> "$target" ;;
    duplicate-provenance) printf '  provenance: operator-declared\n  provenance: operator-declared\n' >> "$target" ;;
    duplicate-file)
      awk -v sha="$MODEL_SHA" '
        /^  context_window:/ { print "    - path: acme-support-q4.gguf"; print "      sha256: " sha }
        { print }
      ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
      ;;
    unknown) printf '  unexpected_structure: rejected\n' >> "$target" ;;
    absolute) sed 's|    - path: .*|    - path: /outside.gguf|' "$target" > "$target.tmp" && mv "$target.tmp" "$target" ;;
    traversal) sed 's|    - path: .*|    - path: ../outside.gguf|' "$target" > "$target.tmp" && mv "$target.tmp" "$target" ;;
    symlink) sed 's|    - path: .*|    - path: linked.gguf|' "$target" > "$target.tmp" && mv "$target.tmp" "$target" ;;
  esac
}

for manifest_negative in yaml-meta duplicate-name duplicate-runtime duplicate-provenance duplicate-file unknown absolute traversal symlink; do
  BAD_MANIFEST="$TMPDIR/bad-model-${manifest_negative}.yaml"
  write_bad_model_manifest "$manifest_negative" "$BAD_MANIFEST"
  if [ "$manifest_negative" = "symlink" ]; then
    ln -s "$MODEL_DIR/acme-support-q4.gguf" "$MODEL_DIR/linked.gguf"
  fi
  set +e
  "$ROOT/bin/lucairn" bundle create --customer-slug "bad-${manifest_negative}" --models-dir "$MODEL_DIR" --model-manifest "$BAD_MANIFEST" --env "$ENV_FILE" --image-tar "$IMAGE_TAR" --output "$TMPDIR/bad-create-${manifest_negative}" > "$TMPDIR/bad-create-${manifest_negative}.out" 2>&1
  BAD_CREATE_STATUS=$?
  set -e
  [ "$BAD_CREATE_STATUS" -ne 0 ] || { echo "bundle create accepted invalid model manifest: $manifest_negative" >&2; exit 1; }
  test ! -e "$TMPDIR/bad-create-${manifest_negative}"

  BAD_STAGE="$TMPDIR/bad-prepare-${manifest_negative}"
  mkdir -p "$BAD_STAGE/models"
  cp "$ENV_FILE" "$BAD_STAGE/customer.env"
  cp "$ENV_FILE.runtime-profile.yaml" "$BAD_STAGE/customer.env.runtime-profile.yaml"
  cp "$ENV_FILE.image-manifest.yaml" "$BAD_STAGE/customer.env.image-manifest.yaml"
  cp "$BAD_MANIFEST" "$BAD_STAGE/models/model-manifest.yaml"
  cp "$MODEL_DIR/acme-support-q4.gguf" "$BAD_STAGE/models/acme-support-q4.gguf"
  if [ "$manifest_negative" = "symlink" ]; then
    ln -s acme-support-q4.gguf "$BAD_STAGE/models/linked.gguf"
  fi
  set +e
  "$ROOT/bin/lucairn" bundle prepare --customer-slug "bad-${manifest_negative}" --staging-dir "$BAD_STAGE" --output "$TMPDIR/bad-prepare-out-${manifest_negative}" > "$TMPDIR/bad-prepare-${manifest_negative}.out" 2>&1
  BAD_PREPARE_STATUS=$?
  set -e
  [ "$BAD_PREPARE_STATUS" -ne 0 ] || { echo "bundle prepare accepted invalid model manifest: $manifest_negative" >&2; exit 1; }
  test ! -e "$TMPDIR/bad-prepare-out-${manifest_negative}"
  if [ "$manifest_negative" = "symlink" ]; then
    rm -f "$MODEL_DIR/linked.gguf"
  fi
done

BUNDLE_OUT="$TMPDIR/customer-bundles"
"$ROOT/bin/lucairn" bundle create \
  --customer-slug acme \
  --models-dir "$MODEL_DIR" \
  --model-manifest "$MODEL_MANIFEST" \
  --env "$ENV_FILE" \
  --image-tar "$IMAGE_TAR" \
  --output "$BUNDLE_OUT" > "$TMPDIR/bundle-create.out"

CUSTOMER_BUNDLE="$(find "$BUNDLE_OUT" -name 'lucairn-customer-bundle-acme-*.tar.gz' -print -quit)"
test -n "$CUSTOMER_BUNDLE"

"$ROOT/bin/lucairn" bundle verify --bundle "$CUSTOMER_BUNDLE" > "$TMPDIR/bundle-verify.out"
grep -q "bundle verify: ok" "$TMPDIR/bundle-verify.out"

BUNDLE_EXTRACT="$TMPDIR/customer-bundle-extract"
mkdir -p "$BUNDLE_EXTRACT"
tar -xzf "$CUSTOMER_BUNDLE" -C "$BUNDLE_EXTRACT"
BASE_DIR="$(find "$BUNDLE_EXTRACT" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -f "$BASE_DIR/install/docker-compose.customer.yml"
test -f "$BASE_DIR/install/docker-compose.self-hosted.yml"
test ! -e "$BASE_DIR/install/docker-compose.self-hosted-byok.yml"
test -f "$BASE_DIR/install/customer.env"
test -f "$BASE_DIR/image-manifest.yaml"
test -f "$BASE_DIR/VERSION"
test -f "$BASE_DIR/RELEASE_DATE"
test -x "$BASE_DIR/scripts/derive-veil-pubkey.sh"
test -f "$BASE_DIR/models/acme-support-q4.gguf"
test -f "$BASE_DIR/models/model-manifest.yaml"
test -f "$BASE_DIR/images/lucairn-images.tar"
test -f "$BASE_DIR/checksums/SHA256SUMS"
grep -Fq 'bin/lucairn up --env install/customer.env --compose install/docker-compose.customer.yml' "$BASE_DIR/INSTALL-CUSTOMER.md"
ARCHIVE_NOTE="$BASE_DIR/INSTALL-CUSTOMER.md"
grep -Fqx 'docker load -i images/lucairn-images.tar' "$ARCHIVE_NOTE"
grep -Fq 'S1 provides integrity' "$ARCHIVE_NOTE"
grep -Fq 'checks, not completed publisher authentication.' "$ARCHIVE_NOTE"
archive_verify_line="$(grep -n -F 'bin/lucairn bundle verify --bundle .' "$ARCHIVE_NOTE" | cut -d: -f1)"
archive_load_line="$(grep -n -F 'docker load -i images/lucairn-images.tar' "$ARCHIVE_NOTE" | cut -d: -f1)"
[ "${archive_verify_line#*$'\n'}" = "$archive_verify_line" ]
[ "${archive_load_line#*$'\n'}" = "$archive_load_line" ]
[ "$archive_verify_line" -lt "$archive_load_line" ]

refresh_bundle_sums() {
  local bundle_root="$1"
  (
    cd "$bundle_root"
    find . -type f ! -path './checksums/SHA256SUMS' | sort | while IFS= read -r file; do
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk -v p="${file#./}" '{print $1 "  " p}'
      else
        shasum -a 256 "$file" | awk -v p="${file#./}" '{print $1 "  " p}'
      fi
    done > checksums/SHA256SUMS
  )
}

# S1 bundle payload requirements are structural, not merely checksum coverage:
# an attacker who deletes a required payload and re-hashes the directory must
# still be rejected by the trusted verifier.
for required_payload in VERSION RELEASE_DATE scripts/derive-veil-pubkey.sh; do
  MISSING_S1_PAYLOAD_DIR="$TMPDIR/customer-bundle-missing-${required_payload//\//-}"
  cp -R "$BASE_DIR" "$MISSING_S1_PAYLOAD_DIR"
  rm -f "$MISSING_S1_PAYLOAD_DIR/$required_payload"
  refresh_bundle_sums "$MISSING_S1_PAYLOAD_DIR"
  set +e
  "$ROOT/bin/lucairn" bundle verify --bundle "$MISSING_S1_PAYLOAD_DIR" > "$TMPDIR/missing-s1-${required_payload//\//-}.out" 2>&1
  MISSING_S1_PAYLOAD_STATUS=$?
  set -e
  [ "$MISSING_S1_PAYLOAD_STATUS" -ne 0 ] || { echo "bundle verify accepted S1 bundle missing $required_payload after re-hash" >&2; exit 1; }
  grep -q "bundle .*${required_payload##*/}" "$TMPDIR/missing-s1-${required_payload//\//-}.out"
done

# Bundle MODEL_PATH is intentionally narrower than the direct-install grammar:
# the delivered models/ tree always mounts at /models, so both vLLM and TGI
# must record `.` and reject an otherwise-safe missing directory before output.
exercise_canonical_bundle_model_path() {
  local runtime="$1" env models manifest sha out archive extract drift_env drift_stage
  env="$TMPDIR/${runtime}-bundle.env"
  models="$TMPDIR/${runtime}-bundle-models"
  manifest="$TMPDIR/${runtime}-bundle-model-manifest.yaml"
  mkdir "$models"
  printf '%s model bytes\n' "$runtime" > "$models/${runtime}-model.safetensors"
  if command -v sha256sum >/dev/null 2>&1; then sha="$(sha256sum "$models/${runtime}-model.safetensors" | awk '{print $1}')"; else sha="$(shasum -a 256 "$models/${runtime}-model.safetensors" | awk '{print $1}')"; fi
  cat > "$manifest" <<YAML
model:
  name: ${runtime}-model
  format: safetensors
  runtime: $runtime
  checksum_policy: sha256-required
  files:
    - path: ${runtime}-model.safetensors
      sha256: $sha
YAML
  "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime "$runtime" \
    --model-name "${runtime}-model" --model-file "${runtime}-model.safetensors" --model-path . \
    --output "$env" --skip-doctor >/dev/null 2>&1
  out="$TMPDIR/${runtime}-bundle-output"
  "$ROOT/bin/lucairn" bundle create --customer-slug "${runtime}-path" --models-dir "$models" --model-manifest "$manifest" --env "$env" --output "$out" >/dev/null
  archive="$(find "$out" -name '*.tar.gz' -print -quit)"
  "$ROOT/bin/lucairn" bundle verify --bundle "$archive" >/dev/null

  drift_env="$TMPDIR/${runtime}-bundle-drift.env"
  cp "$env" "$drift_env"
  cp "$env.runtime-profile.yaml" "$drift_env.runtime-profile.yaml"
  cp "$env.image-manifest.yaml" "$drift_env.image-manifest.yaml"
  sed 's|^MODEL_PATH=.*|MODEL_PATH=missing-dir|' "$drift_env" > "$drift_env.tmp" && mv "$drift_env.tmp" "$drift_env"
  sed 's|^  model_path: .*|  model_path: missing-dir|' "$drift_env.runtime-profile.yaml" > "$drift_env.tmp" && mv "$drift_env.tmp" "$drift_env.runtime-profile.yaml"
  set +e
  "$ROOT/bin/lucairn" bundle create --customer-slug "${runtime}-drift" --models-dir "$models" --model-manifest "$manifest" --env "$drift_env" --output "$TMPDIR/${runtime}-drift-output" > "$TMPDIR/${runtime}-drift-create.out" 2>&1
  local drift_status=$?
  set -e
  [ "$drift_status" -ne 0 ]
  test ! -e "$TMPDIR/${runtime}-drift-output"
  grep -q "MODEL_PATH must be '.'" "$TMPDIR/${runtime}-drift-create.out"

  drift_stage="$TMPDIR/${runtime}-drift-stage"
  mkdir -p "$drift_stage/models"
  cp "$drift_env" "$drift_stage/customer.env"
  cp "$drift_env.runtime-profile.yaml" "$drift_stage/customer.env.runtime-profile.yaml"
  cp "$drift_env.image-manifest.yaml" "$drift_stage/customer.env.image-manifest.yaml"
  cp "$manifest" "$drift_stage/models/model-manifest.yaml"
  cp "$models/${runtime}-model.safetensors" "$drift_stage/models/${runtime}-model.safetensors"
  set +e
  "$ROOT/bin/lucairn" bundle prepare --customer-slug "${runtime}-drift" --staging-dir "$drift_stage" --output "$TMPDIR/${runtime}-drift-prepare-output" > "$TMPDIR/${runtime}-drift-prepare.out" 2>&1
  drift_status=$?
  set -e
  [ "$drift_status" -ne 0 ]
  test ! -e "$TMPDIR/${runtime}-drift-prepare-output"
  grep -q "MODEL_PATH must be '.'" "$TMPDIR/${runtime}-drift-prepare.out"

  extract="$TMPDIR/${runtime}-bundle-extract"
  mkdir "$extract"
  tar -xzf "$archive" -C "$extract"
  extract="$(find "$extract" -maxdepth 1 -type d -name 'lucairn-customer-bundle-*' -print -quit)"
  sed 's|^MODEL_PATH=.*|MODEL_PATH=missing-dir|' "$extract/install/customer.env" > "$extract/env.tmp" && mv "$extract/env.tmp" "$extract/install/customer.env"
  sed 's|^  model_path: .*|  model_path: missing-dir|' "$extract/install/customer.env.runtime-profile.yaml" > "$extract/profile.tmp" && mv "$extract/profile.tmp" "$extract/install/customer.env.runtime-profile.yaml"
  refresh_bundle_sums "$extract"
  set +e
  "$ROOT/bin/lucairn" bundle verify --bundle "$extract" > "$TMPDIR/${runtime}-drift-verify.out" 2>&1
  drift_status=$?
  set -e
  [ "$drift_status" -ne 0 ]
  grep -q "MODEL_PATH must be '.'" "$TMPDIR/${runtime}-drift-verify.out"
}
exercise_canonical_bundle_model_path vllm
exercise_canonical_bundle_model_path tgi

# Every source tree and received bundle uses an exact regular-file payload
# set. An undeclared source symlink fails before output creation, an unchecked
# extra file fails directory verification, and a symlink archive member is
# rejected before extraction.
ln -s acme-support-q4.gguf "$MODEL_DIR/undeclared-link.gguf"
set +e
"$ROOT/bin/lucairn" bundle create --customer-slug unsafe-source --models-dir "$MODEL_DIR" --model-manifest "$MODEL_MANIFEST" --env "$ENV_FILE" --output "$TMPDIR/unsafe-source-output" > "$TMPDIR/unsafe-source.out" 2>&1
UNSAFE_SOURCE_STATUS=$?
set -e
[ "$UNSAFE_SOURCE_STATUS" -ne 0 ]
test ! -e "$TMPDIR/unsafe-source-output"
grep -q 'symlink or special object' "$TMPDIR/unsafe-source.out"
rm -f "$MODEL_DIR/undeclared-link.gguf"

UNSAFE_STAGE="$TMPDIR/unsafe-source-stage"
mkdir -p "$UNSAFE_STAGE/models"
cp "$ENV_FILE" "$UNSAFE_STAGE/customer.env"
cp "$ENV_FILE.runtime-profile.yaml" "$UNSAFE_STAGE/customer.env.runtime-profile.yaml"
cp "$ENV_FILE.image-manifest.yaml" "$UNSAFE_STAGE/customer.env.image-manifest.yaml"
cp "$MODEL_MANIFEST" "$UNSAFE_STAGE/models/model-manifest.yaml"
cp "$MODEL_DIR/acme-support-q4.gguf" "$UNSAFE_STAGE/models/acme-support-q4.gguf"
ln -s acme-support-q4.gguf "$UNSAFE_STAGE/models/undeclared-link.gguf"
set +e
"$ROOT/bin/lucairn" bundle prepare --customer-slug unsafe-source --staging-dir "$UNSAFE_STAGE" --output "$TMPDIR/unsafe-source-prepare-output" > "$TMPDIR/unsafe-source-prepare.out" 2>&1
UNSAFE_SOURCE_STATUS=$?
set -e
[ "$UNSAFE_SOURCE_STATUS" -ne 0 ]
test ! -e "$TMPDIR/unsafe-source-prepare-output"
grep -q 'symlink or special object' "$TMPDIR/unsafe-source-prepare.out"

UNCHECKED_DIR="$TMPDIR/customer-bundle-unchecked-extra"
cp -R "$BASE_DIR" "$UNCHECKED_DIR"
printf 'not listed\n' > "$UNCHECKED_DIR/extra.txt"
set +e
"$ROOT/bin/lucairn" bundle verify --bundle "$UNCHECKED_DIR" > "$TMPDIR/unchecked-extra.out" 2>&1
UNCHECKED_STATUS=$?
set -e
[ "$UNCHECKED_STATUS" -ne 0 ]
grep -q 'unchecked bundle file extra.txt' "$TMPDIR/unchecked-extra.out"

UNSAFE_ARCHIVE="$TMPDIR/unsafe-member.tar.gz"
python3 - "$UNSAFE_ARCHIVE" <<'PY'
import tarfile, sys
with tarfile.open(sys.argv[1], 'w:gz') as archive:
    root = tarfile.TarInfo('lucairn-customer-bundle-unsafe-20260715T000000Z')
    root.type = tarfile.DIRTYPE
    archive.addfile(root)
    link = tarfile.TarInfo('lucairn-customer-bundle-unsafe-20260715T000000Z/models/link')
    link.type = tarfile.SYMTYPE
    link.linkname = '../../outside'
    archive.addfile(link)
PY
set +e
"$ROOT/bin/lucairn" bundle verify --bundle "$UNSAFE_ARCHIVE" > "$TMPDIR/unsafe-archive.out" 2>&1
UNSAFE_ARCHIVE_STATUS=$?
set -e
[ "$UNSAFE_ARCHIVE_STATUS" -ne 0 ]
grep -q 'non-regular archive member' "$TMPDIR/unsafe-archive.out"

# Receiver-side verification must independently reject the same unambiguous
# manifest/path contract, even if an attacker re-hashes the whole directory.
for verify_negative in yaml-meta duplicate-name duplicate-runtime duplicate-provenance duplicate-file unknown absolute traversal symlink; do
  VERIFY_NEG_DIR="$TMPDIR/verify-negative-${verify_negative}"
  cp -R "$BASE_DIR" "$VERIFY_NEG_DIR"
  write_bad_model_manifest "$verify_negative" "$VERIFY_NEG_DIR/models/model-manifest.yaml"
  if [ "$verify_negative" = "symlink" ]; then
    ln -s acme-support-q4.gguf "$VERIFY_NEG_DIR/models/linked.gguf"
  fi
  refresh_bundle_sums "$VERIFY_NEG_DIR"
  set +e
  "$ROOT/bin/lucairn" bundle verify --bundle "$VERIFY_NEG_DIR" > "$TMPDIR/verify-negative-${verify_negative}.out" 2>&1
  VERIFY_NEG_STATUS=$?
  set -e
  [ "$VERIFY_NEG_STATUS" -ne 0 ] || { echo "bundle verify accepted invalid model manifest: $verify_negative" >&2; exit 1; }
done

MODEL_VERIFY_DRIFT="$TMPDIR/customer-bundle-model-verify-drift"
cp -R "$BASE_DIR" "$MODEL_VERIFY_DRIFT"
sed 's/^MODEL_NAME=.*/MODEL_NAME=wrong-name/' "$MODEL_VERIFY_DRIFT/install/customer.env" > "$MODEL_VERIFY_DRIFT/env.tmp" && mv "$MODEL_VERIFY_DRIFT/env.tmp" "$MODEL_VERIFY_DRIFT/install/customer.env"
sed 's/^  model_name:.*/  model_name: wrong-name/' "$MODEL_VERIFY_DRIFT/install/customer.env.runtime-profile.yaml" > "$MODEL_VERIFY_DRIFT/profile.tmp" && mv "$MODEL_VERIFY_DRIFT/profile.tmp" "$MODEL_VERIFY_DRIFT/install/customer.env.runtime-profile.yaml"
set +e
"$ROOT/bin/lucairn" bundle verify --bundle "$MODEL_VERIFY_DRIFT" > "$TMPDIR/bundle-model-verify-drift.out" 2>&1
MODEL_VERIFY_DRIFT_STATUS=$?
set -e
[ "$MODEL_VERIFY_DRIFT_STATUS" -ne 0 ] || { echo "bundle verify accepted model inventory drift" >&2; exit 1; }
grep -q 'bundle local runtime profile and model manifest disagree' "$TMPDIR/bundle-model-verify-drift.out"

# Local runtime bundle contracts bind the saved profile inventory to the
# supplied manifest before accepting either staging or a verified bundle.
for model_drift in name runtime file; do
  DRIFT_OUT="$TMPDIR/model-drift-$model_drift"
  DRIFT_ENV="$TMPDIR/model-drift-$model_drift.env"
  cp "$ENV_FILE" "$DRIFT_ENV"
  cp "$ENV_FILE.runtime-profile.yaml" "$DRIFT_ENV.runtime-profile.yaml"
  cp "$ENV_FILE.image-manifest.yaml" "$DRIFT_ENV.image-manifest.yaml"
  case "$model_drift" in
    name)
      sed 's/^MODEL_NAME=.*/MODEL_NAME=wrong-name/' "$DRIFT_ENV" > "$DRIFT_ENV.tmp" && mv "$DRIFT_ENV.tmp" "$DRIFT_ENV"
      sed 's/^  model_name:.*/  model_name: wrong-name/' "$DRIFT_ENV.runtime-profile.yaml" > "$DRIFT_ENV.tmp"
      ;;
    runtime)
      sed 's/^MODEL_RUNTIME_PROFILE=.*/MODEL_RUNTIME_PROFILE=vllm/' "$DRIFT_ENV" > "$DRIFT_ENV.tmp" && mv "$DRIFT_ENV.tmp" "$DRIFT_ENV"
      sed -e 's/^local_runtime:.*/local_runtime: vllm/' -e 's/^  runtime:.*/  runtime: vllm/' "$DRIFT_ENV.runtime-profile.yaml" > "$DRIFT_ENV.tmp"
      ;;
    file)
      sed 's/^MODEL_FILE=.*/MODEL_FILE=wrong-model.gguf/' "$DRIFT_ENV" > "$DRIFT_ENV.tmp" && mv "$DRIFT_ENV.tmp" "$DRIFT_ENV"
      sed 's/^  model_file:.*/  model_file: wrong-model.gguf/' "$DRIFT_ENV.runtime-profile.yaml" > "$DRIFT_ENV.tmp"
      ;;
  esac
  mv "$DRIFT_ENV.tmp" "$DRIFT_ENV.runtime-profile.yaml"
  set +e
  "$ROOT/bin/lucairn" bundle create --customer-slug "drift-$model_drift" --models-dir "$MODEL_DIR" --model-manifest "$MODEL_MANIFEST" --env "$DRIFT_ENV" --image-tar "$IMAGE_TAR" --output "$DRIFT_OUT" > "$TMPDIR/model-drift-$model_drift.out" 2>&1
  DRIFT_STATUS=$?
  set -e
  [ "$DRIFT_STATUS" -ne 0 ] || { echo "bundle create accepted $model_drift model inventory drift" >&2; exit 1; }
  test ! -e "$DRIFT_OUT"
  grep -q 'local runtime profile and model manifest disagree' "$TMPDIR/model-drift-$model_drift.out"
done

# Re-hashing a duplicated profile must not turn ambiguity into valid bundle
# state: verification validates the env/profile pair before trusting checksums.
PROFILE_TAMPER_DIR="$TMPDIR/customer-bundle-profile-tamper"
cp -R "$BASE_DIR" "$PROFILE_TAMPER_DIR"
printf 'runtime_mode: split-remote\n' >> "$PROFILE_TAMPER_DIR/install/customer.env.runtime-profile.yaml"
(
  cd "$PROFILE_TAMPER_DIR"
  find . -type f ! -path './checksums/SHA256SUMS' | sort | while IFS= read -r file; do
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file" | awk -v p="${file#./}" '{print $1 "  " p}';
    else shasum -a 256 "$file" | awk -v p="${file#./}" '{print $1 "  " p}'; fi
  done > checksums/SHA256SUMS
)
set +e
"$ROOT/bin/lucairn" bundle verify --bundle "$PROFILE_TAMPER_DIR" > "$TMPDIR/bundle-profile-tamper.out" 2>&1
PROFILE_TAMPER_STATUS=$?
set -e
[ "$PROFILE_TAMPER_STATUS" -ne 0 ] || { echo "bundle verify should reject a duplicated profile" >&2; exit 1; }
grep -q 'runtime profile: failed' "$TMPDIR/bundle-profile-tamper.out"

printf 'tamper\n' >> "$BASE_DIR/models/acme-support-q4.gguf"
set +e
"$ROOT/bin/lucairn" bundle verify --bundle "$BASE_DIR" > "$TMPDIR/bundle-tamper.out" 2>&1
TAMPER_STATUS=$?
set -e
if [ "$TAMPER_STATUS" -eq 0 ]; then
  echo "bundle verify should fail after model tampering" >&2
  exit 1
fi
grep -Eq "(checksum verification failed|sha256 mismatch for)" "$TMPDIR/bundle-tamper.out"

# Install instructions follow the validated canonical topology, rather than a
# fixed self-hosted command.
SPLIT_ENV="$TMPDIR/split-bundle.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode split-remote --remote-endpoint https://inference.example.test --remote-credentials "$REMOTE_CREDENTIALS" --output "$SPLIT_ENV" --skip-doctor >/dev/null 2>&1
SPLIT_OUT="$TMPDIR/split-bundles"
"$ROOT/bin/lucairn" bundle create --customer-slug split --models-dir "$MODEL_DIR" --model-manifest "$MODEL_MANIFEST" --env "$SPLIT_ENV" --image-tar "$IMAGE_TAR" --output "$SPLIT_OUT" >/dev/null
SPLIT_DIR="$TMPDIR/split-extract"
mkdir "$SPLIT_DIR"
tar -xzf "$(find "$SPLIT_OUT" -name '*.tar.gz' -print -quit)" -C "$SPLIT_DIR"
SPLIT_NOTE="$(find "$SPLIT_DIR" -name INSTALL-CUSTOMER.md -print -quit)"
grep -Fq 'bin/lucairn up --env install/customer.env --compose install/docker-compose.customer.yml' "$SPLIT_NOTE"
grep -Fq 'Lucairn-issued remote credential file' "$SPLIT_NOTE"
SPLIT_BASE_DIR="$(dirname "$SPLIT_NOTE")"
test ! -e "$SPLIT_BASE_DIR/install/docker-compose.self-hosted.yml"
test ! -e "$SPLIT_BASE_DIR/install/docker-compose.self-hosted-byok.yml"
test -f "$SPLIT_BASE_DIR/image-manifest.yaml"

BYOK_ENV="$TMPDIR/byok-bundle.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$BYOK_ENV" --skip-doctor >/dev/null 2>&1
BYOK_OUT="$TMPDIR/byok-bundles"
"$ROOT/bin/lucairn" bundle create --customer-slug byok --models-dir "$MODEL_DIR" --model-manifest "$MODEL_MANIFEST" --env "$BYOK_ENV" --image-tar "$IMAGE_TAR" --output "$BYOK_OUT" >/dev/null
BYOK_DIR="$TMPDIR/byok-extract"
mkdir "$BYOK_DIR"
tar -xzf "$(find "$BYOK_OUT" -name '*.tar.gz' -print -quit)" -C "$BYOK_DIR"
BYOK_NOTE="$(find "$BYOK_DIR" -name INSTALL-CUSTOMER.md -print -quit)"
grep -Fq 'bin/lucairn up --env install/customer.env --compose install/docker-compose.customer.yml' "$BYOK_NOTE"
BYOK_BASE_DIR="$(dirname "$BYOK_NOTE")"
test -f "$BYOK_BASE_DIR/install/docker-compose.self-hosted.yml"
test -f "$BYOK_BASE_DIR/install/docker-compose.self-hosted-byok.yml"

# Bundled provenance is required before checksum verification; a symlinked or
# missing manifest cannot be substituted after bundle creation.
rm -f "$SPLIT_BASE_DIR/image-manifest.yaml"
ln -s "$ROOT/image-manifest.yaml" "$SPLIT_BASE_DIR/image-manifest.yaml"
set +e
"$ROOT/bin/lucairn" bundle verify --bundle "$SPLIT_BASE_DIR" > "$TMPDIR/symlink-bundle-manifest.out" 2>&1
SYMLINK_MANIFEST_STATUS=$?
set -e
[ "$SYMLINK_MANIFEST_STATUS" -ne 0 ] || { echo "bundle verify accepted symlinked image manifest" >&2; exit 1; }
rm -f "$SPLIT_BASE_DIR/image-manifest.yaml"
set +e
"$ROOT/bin/lucairn" bundle verify --bundle "$SPLIT_BASE_DIR" > "$TMPDIR/missing-bundle-manifest.out" 2>&1
MISSING_MANIFEST_STATUS=$?
set -e
[ "$MISSING_MANIFEST_STATUS" -ne 0 ] || { echo "bundle verify accepted missing image manifest" >&2; exit 1; }

# A genuine pre-S1 archive contains only the historical bundle requirements:
# no S1 marker, profile sidecar, helper, image-manifest copy, or newer profile
# metadata. It must still verify through the legacy branch.
HISTORICAL_ROOT="$TMPDIR/lucairn-customer-bundle-historical-20200101T000000Z"
mkdir -p "$HISTORICAL_ROOT/bin" "$HISTORICAL_ROOT/install" "$HISTORICAL_ROOT/models" "$HISTORICAL_ROOT/checksums"
printf '#!/usr/bin/env bash\n# historical bundle CLI placeholder\n' > "$HISTORICAL_ROOT/bin/lucairn"
chmod +x "$HISTORICAL_ROOT/bin/lucairn"
cp "$ROOT/docker-compose.customer.yml" "$HISTORICAL_ROOT/install/docker-compose.customer.yml"
cp "$ROOT/docker-compose.self-hosted.yml" "$HISTORICAL_ROOT/install/docker-compose.self-hosted.yml"
printf 'DSA_ENV=test\n' > "$HISTORICAL_ROOT/install/customer.env"
printf 'historical model bytes\n' > "$HISTORICAL_ROOT/models/historical.gguf"
if command -v sha256sum >/dev/null 2>&1; then HISTORICAL_SHA="$(sha256sum "$HISTORICAL_ROOT/models/historical.gguf" | awk '{print $1}')"; else HISTORICAL_SHA="$(shasum -a 256 "$HISTORICAL_ROOT/models/historical.gguf" | awk '{print $1}')"; fi
cat > "$HISTORICAL_ROOT/models/model-manifest.yaml" <<YAML
model:
  name: historical-model
  format: gguf
  runtime: llama-cpp
  checksum_policy: sha256-required
  files:
    - path: historical.gguf
      sha256: $HISTORICAL_SHA
YAML
refresh_bundle_sums "$HISTORICAL_ROOT"
HISTORICAL_ARCHIVE="$TMPDIR/historical-pre-s1.tar.gz"
COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=true \
  tar -czf "$HISTORICAL_ARCHIVE" -C "$TMPDIR" "$(basename "$HISTORICAL_ROOT")"
"$ROOT/bin/lucairn" bundle verify --bundle "$HISTORICAL_ARCHIVE" > "$TMPDIR/historical-pre-s1.out"
grep -q 'runtime profile: legacy install' "$TMPDIR/historical-pre-s1.out"
grep -q 'bundle verify: ok' "$TMPDIR/historical-pre-s1.out"
test ! -e "$HISTORICAL_ROOT/bin/runtime-profile-lib.sh"
test ! -e "$HISTORICAL_ROOT/image-manifest.yaml"

# Directory inputs do not need an extraction temp. An invalid marker state
# therefore reports the profile reason even if mktemp is unavailable.
INVALID_DIRECTORY_BUNDLE="$TMPDIR/lucairn-customer-bundle-invalid-s1-20200101T000000Z"
mkdir -p "$INVALID_DIRECTORY_BUNDLE/install" "$TMPDIR/no-mktemp-bin"
printf 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1\n' > "$INVALID_DIRECTORY_BUNDLE/install/customer.env"
mkdir -p "$INVALID_DIRECTORY_BUNDLE/bin"
cp "$ROOT/bin/runtime-profile-lib.sh" "$INVALID_DIRECTORY_BUNDLE/bin/runtime-profile-lib.sh"
printf '#!/usr/bin/env bash\nexit 77\n' > "$TMPDIR/no-mktemp-bin/mktemp"
chmod +x "$TMPDIR/no-mktemp-bin/mktemp"
set +e
PATH="$TMPDIR/no-mktemp-bin:$PATH" "$ROOT/bin/lucairn" bundle verify --bundle "$INVALID_DIRECTORY_BUNDLE" > "$TMPDIR/invalid-directory-bundle.out" 2>&1
INVALID_DIRECTORY_STATUS=$?
set -e
[ "$INVALID_DIRECTORY_STATUS" -ne 0 ] || { echo "invalid directory S1 state should fail" >&2; exit 1; }
[ "$INVALID_DIRECTORY_STATUS" -ne 77 ] || { echo "directory validation attempted mktemp before profile validation" >&2; exit 1; }
grep -q 'LUCAIRN_RUNTIME_PROFILE_REQUIRED=1 requires' "$TMPDIR/invalid-directory-bundle.out"

echo "lucairn bundle tests: ok"

AGENT_STAGE="$TMPDIR/agent-staging/acme"
mkdir -p "$AGENT_STAGE/models" "$AGENT_STAGE/images" "$AGENT_STAGE/demo-data"
cp "$ENV_FILE" "$AGENT_STAGE/customer.env"
cp "$ENV_FILE.runtime-profile.yaml" "$AGENT_STAGE/customer.env.runtime-profile.yaml"
cp "$ENV_FILE.image-manifest.yaml" "$AGENT_STAGE/customer.env.image-manifest.yaml"
cp "$MODEL_MANIFEST" "$AGENT_STAGE/models/model-manifest.yaml"
cp "$MODEL_DIR/acme-support-q4.gguf" "$AGENT_STAGE/models/acme-support-q4.gguf"
cp "$IMAGE_TAR" "$AGENT_STAGE/images/lucairn-images.tar"
printf 'study_id,endpoint\nACME-001,spirometry\n' > "$AGENT_STAGE/demo-data/endpoint-demo.csv"

AGENT_OUT="$TMPDIR/agent-output"
"$ROOT/bin/lucairn" bundle prepare \
  --customer-slug acme \
  --staging-dir "$AGENT_STAGE" \
  --output "$AGENT_OUT" > "$TMPDIR/agent-prepare.out"

AGENT_BUNDLE="$(find "$AGENT_OUT" -name 'lucairn-customer-bundle-acme-*.tar.gz' -print -quit)"
test -n "$AGENT_BUNDLE"
test -f "$AGENT_OUT/lucairn-customer-bundle-acme-report.txt"
grep -q "bundle_verify=ok" "$AGENT_OUT/lucairn-customer-bundle-acme-report.txt"
grep -q "model_runtime=llama-cpp" "$AGENT_OUT/lucairn-customer-bundle-acme-report.txt"
grep -q "image_delivery=archive" "$AGENT_OUT/lucairn-customer-bundle-acme-report.txt"
grep -q "customer_env=present" "$AGENT_OUT/lucairn-customer-bundle-acme-report.txt"
grep -q "customer_data=present" "$AGENT_OUT/lucairn-customer-bundle-acme-report.txt"
if grep -q "lcr_enterprise_test_secret\\|sk-test-sandbox-b-secret" "$AGENT_OUT/lucairn-customer-bundle-acme-report.txt"; then
  echo "agent packaging report leaked a secret" >&2
  exit 1
fi

AGENT_EXTRACT="$TMPDIR/agent-extract"
mkdir -p "$AGENT_EXTRACT"
tar -xzf "$AGENT_BUNDLE" -C "$AGENT_EXTRACT"
AGENT_BASE_DIR="$(find "$AGENT_EXTRACT" -maxdepth 1 -type d -name 'lucairn-customer-bundle-acme-*' -print -quit)"
test -f "$AGENT_BASE_DIR/customer-data/endpoint-demo.csv"

BAD_AGENT_STAGE="$TMPDIR/agent-staging/model-mismatch"
cp -R "$AGENT_STAGE" "$BAD_AGENT_STAGE"
sed 's/^MODEL_FILE=.*/MODEL_FILE=wrong-model.gguf/' "$BAD_AGENT_STAGE/customer.env" > "$BAD_AGENT_STAGE/env.tmp" && mv "$BAD_AGENT_STAGE/env.tmp" "$BAD_AGENT_STAGE/customer.env"
sed 's/^  model_file:.*/  model_file: wrong-model.gguf/' "$BAD_AGENT_STAGE/customer.env.runtime-profile.yaml" > "$BAD_AGENT_STAGE/profile.tmp" && mv "$BAD_AGENT_STAGE/profile.tmp" "$BAD_AGENT_STAGE/customer.env.runtime-profile.yaml"
set +e
"$ROOT/bin/lucairn" bundle prepare --customer-slug model-mismatch --staging-dir "$BAD_AGENT_STAGE" --output "$TMPDIR/model-mismatch-output" > "$TMPDIR/model-mismatch-prepare.out" 2>&1
MODEL_PREPARE_DRIFT_STATUS=$?
set -e
[ "$MODEL_PREPARE_DRIFT_STATUS" -ne 0 ] || { echo "bundle prepare accepted model inventory drift" >&2; exit 1; }
test ! -e "$TMPDIR/model-mismatch-output"
grep -q 'local runtime profile and model manifest disagree' "$TMPDIR/model-mismatch-prepare.out"

MAKE_AGENT_OUT="$TMPDIR/make-agent-output"
make -C "$ROOT" customer-bundle \
  CUSTOMER_SLUG=acme \
  STAGING_DIR="$AGENT_STAGE" \
  OUTPUT_DIR="$MAKE_AGENT_OUT" > "$TMPDIR/make-agent-prepare.out"

MAKE_AGENT_BUNDLE="$(find "$MAKE_AGENT_OUT" -name 'lucairn-customer-bundle-acme-*.tar.gz' -print -quit)"
test -n "$MAKE_AGENT_BUNDLE"
grep -q "bundle_verify=ok" "$MAKE_AGENT_OUT/lucairn-customer-bundle-acme-report.txt"

REGISTRY_STAGE="$TMPDIR/agent-staging/registry-only"
mkdir -p "$REGISTRY_STAGE/models" "$REGISTRY_STAGE/images"
cp "$SPLIT_ENV" "$REGISTRY_STAGE/customer.env"
cp "$SPLIT_ENV.runtime-profile.yaml" "$REGISTRY_STAGE/customer.env.runtime-profile.yaml"
cp "$SPLIT_ENV.image-manifest.yaml" "$REGISTRY_STAGE/customer.env.image-manifest.yaml"
cat > "$REGISTRY_STAGE/models/model-manifest.yaml" <<'YAML'
model:
  name: qwen2.5:7b
  format: openai-compatible
  runtime: external-openai-compatible
  endpoint: http://model-runtime.example/v1
  context_window: 8192
  gpu_required: false
  min_vram_gb: 0
  license: local-test-model
  checksum_policy: external-runtime-no-model-file
YAML
printf 'No image archive included. Use registry access.\n' > "$REGISTRY_STAGE/images/README.txt"

REGISTRY_OUT="$TMPDIR/registry-only-output"
"$ROOT/bin/lucairn" bundle prepare \
  --customer-slug registry-only \
  --staging-dir "$REGISTRY_STAGE" \
  --output "$REGISTRY_OUT" > "$TMPDIR/registry-only-prepare.out"

grep -q "image_delivery=registry" "$REGISTRY_OUT/lucairn-customer-bundle-registry-only-report.txt"
REGISTRY_BUNDLE="$(find "$REGISTRY_OUT" -name 'lucairn-customer-bundle-registry-only-*.tar.gz' -print -quit)"
test -n "$REGISTRY_BUNDLE"
REGISTRY_EXTRACT="$TMPDIR/registry-only-extract"
mkdir "$REGISTRY_EXTRACT"
tar -xzf "$REGISTRY_BUNDLE" -C "$REGISTRY_EXTRACT"
REGISTRY_NOTE="$(find "$REGISTRY_EXTRACT" -name INSTALL-CUSTOMER.md -print -quit)"
test -n "$REGISTRY_NOTE"
grep -Fq 'This handoff uses registry delivery.' "$REGISTRY_NOTE"
! grep -Fqx 'docker load -i images/lucairn-images.tar' "$REGISTRY_NOTE"
! grep -Fq 'images/lucairn-images.tar' "$REGISTRY_NOTE"
registry_verify_line="$(grep -n -F 'bin/lucairn bundle verify --bundle .' "$REGISTRY_NOTE" | cut -d: -f1)"
registry_doctor_line="$(grep -n -F 'bin/lucairn doctor --env install/customer.env' "$REGISTRY_NOTE" | cut -d: -f1)"
[ "${registry_verify_line#*$'\n'}" = "$registry_verify_line" ]
[ "${registry_doctor_line#*$'\n'}" = "$registry_doctor_line" ]
[ "$registry_verify_line" -lt "$registry_doctor_line" ]

echo "lucairn agent prepare tests: ok"

# Multi-source ambiguity guard (audit 2026-05-15 F4): bundle prepare must fail
# loudly if more than one of customer-data/, demo-data/, data/ is non-empty.
AMBIG_STAGE="$TMPDIR/agent-staging/ambig"
mkdir -p "$AMBIG_STAGE/models" "$AMBIG_STAGE/customer-data" "$AMBIG_STAGE/demo-data"
cp "$ENV_FILE" "$AMBIG_STAGE/customer.env"
cp "$ENV_FILE.runtime-profile.yaml" "$AMBIG_STAGE/customer.env.runtime-profile.yaml"
cp "$ENV_FILE.image-manifest.yaml" "$AMBIG_STAGE/customer.env.image-manifest.yaml"
cp "$MODEL_MANIFEST" "$AMBIG_STAGE/models/model-manifest.yaml"
cp "$MODEL_DIR/acme-support-q4.gguf" "$AMBIG_STAGE/models/acme-support-q4.gguf"
printf 'real\n' > "$AMBIG_STAGE/customer-data/real.csv"
printf 'demo\n' > "$AMBIG_STAGE/demo-data/demo.csv"

set +e
"$ROOT/bin/lucairn" bundle prepare \
  --customer-slug ambig \
  --staging-dir "$AMBIG_STAGE" \
  --output "$TMPDIR/ambig-out" > "$TMPDIR/ambig.out" 2>&1
AMBIG_STATUS=$?
set -e
if [ "$AMBIG_STATUS" -eq 0 ]; then
  echo "expected bundle prepare to fail on ambiguous data dirs" >&2
  cat "$TMPDIR/ambig.out" >&2
  exit 1
fi
grep -q "ambiguous data staging" "$TMPDIR/ambig.out"
grep -q "customer-data" "$TMPDIR/ambig.out"
grep -q "demo-data" "$TMPDIR/ambig.out"

# Sanity: a clean single-source staging still announces the selection.
SINGLE_STAGE="$TMPDIR/agent-staging/single"
mkdir -p "$SINGLE_STAGE/models" "$SINGLE_STAGE/customer-data"
cp "$ENV_FILE" "$SINGLE_STAGE/customer.env"
cp "$ENV_FILE.runtime-profile.yaml" "$SINGLE_STAGE/customer.env.runtime-profile.yaml"
cp "$ENV_FILE.image-manifest.yaml" "$SINGLE_STAGE/customer.env.image-manifest.yaml"
cp "$MODEL_MANIFEST" "$SINGLE_STAGE/models/model-manifest.yaml"
cp "$MODEL_DIR/acme-support-q4.gguf" "$SINGLE_STAGE/models/acme-support-q4.gguf"
printf 'real\n' > "$SINGLE_STAGE/customer-data/real.csv"

"$ROOT/bin/lucairn" bundle prepare \
  --customer-slug single \
  --staging-dir "$SINGLE_STAGE" \
  --output "$TMPDIR/single-out" > "$TMPDIR/single.out"
grep -q "selected staging dir:" "$TMPDIR/single.out"
grep -q "/customer-data" "$TMPDIR/single.out"

echo "lucairn data-staging ambiguity tests: ok"

# ---------------------------------------------------------------------------
# WS-2 / HA-01 — compliance-DB backup / restore CLI guards.
#
# The full backup -> S3 -> restore round-trip needs age + aws + docker and a
# live S3 bucket — that is the LIVE-VERIFY-on-Vast gate (PRD § LIVE-VERIFY).
# These tests cover the arg-parsing + fail-fast guards that do NOT need those
# tools: missing --env, missing bucket, missing age recipient (backup), and
# missing --stamp (restore). Each must error before any pg_dump / S3 call.
# ---------------------------------------------------------------------------

# backup with no --env errors.
set +e
"$ROOT/bin/lucairn" backup > "$TMPDIR/bk.out" 2>&1
BK_STATUS=$?
set -e
[ "$BK_STATUS" -ne 0 ] || { echo "backup without --env should have failed" >&2; exit 1; }
grep -q -- "--env customer.env is required" "$TMPDIR/bk.out"

# help advertises both new commands.
"$ROOT/bin/lucairn" --help > "$TMPDIR/help.out"
grep -q "lucairn backup --env" "$TMPDIR/help.out"
grep -q "lucairn restore --env" "$TMPDIR/help.out"

# A backup env file missing the bucket fails fast. If age/aws are absent the
# tool-presence guard fires first — also an acceptable fail-fast. Assert backup
# does NOT succeed and never reaches a pg_dump invocation.
BK_ENV="$TMPDIR/backup-nobucket.env"
cat > "$BK_ENV" <<'ENV'
LUCAIRN_BACKUP_AGE_RECIPIENT=age1exampleexampleexampleexampleexampleexampleexampleexample
ENV
set +e
"$ROOT/bin/lucairn" backup --env "$BK_ENV" > "$TMPDIR/bk2.out" 2>&1
BK2_STATUS=$?
set -e
[ "$BK2_STATUS" -ne 0 ] || { echo "backup with no bucket should have failed" >&2; exit 1; }
if grep -q "pg_dump" "$TMPDIR/bk2.out"; then
  echo "backup reached pg_dump despite missing config" >&2; exit 1
fi

# restore with no --stamp fails fast.
set +e
"$ROOT/bin/lucairn" restore --env "$BK_ENV" > "$TMPDIR/rs.out" 2>&1
RS_STATUS=$?
set -e
[ "$RS_STATUS" -ne 0 ] || { echo "restore without --stamp should have failed" >&2; exit 1; }
grep -q -- "--stamp" "$TMPDIR/rs.out"

# Regression guard (HA-01): the plaintext-upload check must read >= the full
# age v1 magic ("age-encryption.org/v1", 21 bytes). `head -c 16` truncates the
# 18-char needle and can NEVER match, aborting every valid backup. Assert the
# source uses head -c 64 and the broken 16-byte read is gone.
grep -q 'head -c 64 "$enc" | grep -q "age-encryption.org"' "$ROOT/bin/lucairn" \
  || { echo "backup plaintext guard must read >= 64 bytes" >&2; exit 1; }
if grep -q 'head -c 16 "$enc"' "$ROOT/bin/lucairn"; then
  echo "backup plaintext guard still uses head -c 16 (truncated needle)" >&2; exit 1
fi

# Runtime round-trip of the guard logic itself, when age is available: an
# age-encrypted file MUST pass `head -c 64 | grep age-encryption.org`, and a
# raw pg_dump (PGDMP magic) MUST fail it. This exercises the actual byte math
# without needing docker / S3.
if command -v age >/dev/null 2>&1; then
  AGEKEY="$TMPDIR/guard.key"
  age-keygen -o "$AGEKEY" 2>"$TMPDIR/guard.pub"
  REC="$(grep 'public key:' "$TMPDIR/guard.pub" | awk '{print $NF}')"
  printf 'PGDMP raw custom-format dump content that must be rejected' > "$TMPDIR/guard.dump"
  age -r "$REC" -o "$TMPDIR/guard.enc" "$TMPDIR/guard.dump"
  head -c 64 "$TMPDIR/guard.enc" | grep -q "age-encryption.org" \
    || { echo "guard FALSE-NEGATIVE: encrypted file failed the head -c 64 check" >&2; exit 1; }
  if head -c 64 "$TMPDIR/guard.dump" | grep -q "age-encryption.org"; then
    echo "guard FALSE-POSITIVE: raw PGDMP dump passed the encryption check" >&2; exit 1
  fi
  # Prove the old broken read would have wrongly rejected the encrypted file.
  if head -c 16 "$TMPDIR/guard.enc" | grep -q "age-encryption.org"; then
    echo "unexpected: head -c 16 matched (age header changed?)" >&2; exit 1
  fi
  echo "lucairn backup plaintext-guard byte-math test: ok (encrypted passes, raw rejected, 16-byte read proven broken)"
else
  echo "lucairn backup plaintext-guard byte-math test: skipped (age not installed)"
fi

echo "lucairn backup/restore CLI guard tests: ok"
