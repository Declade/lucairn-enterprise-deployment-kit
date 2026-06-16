#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
# Also remove the kit-local customer_id state file the A9 auto-fill sub-tests
# write into $ROOT (it is gitignored, but clean it up on every exit path so a
# mid-run abort never leaves it behind).
trap 'rm -rf "$TMPDIR"; rm -f "$ROOT/.lucairn-customer-id"' EXIT

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
"$ROOT/bin/lucairn-init" --dev --output "$ENV_FILE" --skip-doctor >/dev/null 2>&1
KIT_IMAGE_TAG="$(grep -E '^LUCAIRN_IMAGE_TAG=' "$ENV_FILE" | tail -1 | sed 's/^[^=]*=//')"

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

# --- A9: deployment-entitlement doctor coverage ------------------------------

# Both entitlement vars set -> doctor reports "configured" and still passes.
ENV_ENT="$TMPDIR/customer-entitlement.env"
cp "$ENV_FILE" "$ENV_ENT"
{
  printf 'LUCAIRN_LICENSE_KEY=ent_token_dummy\n'
  printf 'LUCAIRN_LICENSE_PUBLIC_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\n'
  printf 'LUCAIRN_LICENSE_GRACE_DAYS=14\n'
} >> "$ENV_ENT"
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_ENT" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-ent.out"
grep -q "doctor: ok" "$TMPDIR/doctor-ent.out"
grep -q "entitlement: LUCAIRN_LICENSE_KEY + LUCAIRN_LICENSE_PUBLIC_KEY set" "$TMPDIR/doctor-ent.out"

# Exactly one entitlement var set -> doctor WARNs (to stderr) but does NOT fail
# (an incomplete entitlement is a config smell, not an install blocker).
ENV_ENT_HALF="$TMPDIR/customer-entitlement-half.env"
cp "$ENV_FILE" "$ENV_ENT_HALF"
printf 'LUCAIRN_LICENSE_KEY=ent_token_dummy_only\n' >> "$ENV_ENT_HALF"
"$ROOT/bin/lucairn" doctor \
  --env "$ENV_ENT_HALF" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor-ent-half.out" 2> "$TMPDIR/doctor-ent-half.err"
grep -q "doctor: ok" "$TMPDIR/doctor-ent-half.out"
grep -q "warn: entitlement:" "$TMPDIR/doctor-ent-half.err"

# --- A9 fixup: CRASHLOOP-class format/range guards + prod reminder -----------

# (a) Gap 1: a malformed LUCAIRN_LICENSE_PUBLIC_KEY (not 64-hex) -> doctor FAILS.
# The gateway's LoadPublicKeyHex log.Fatals on a non-64-hex pubkey on a pinned
# boot, so doctor must ERROR here instead of going green-then-crashloop. Both a
# non-hex token AND a too-short (32-char) hex string must be rejected.
for BAD_PUB in "not-hex" "0011223344556677889900112233aabb"; do
  ENV_BADPUB="$TMPDIR/customer-entitlement-badpub.env"
  cp "$ENV_FILE" "$ENV_BADPUB"
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
cp "$ENV_FILE" "$ENV_GOODPUB"
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
cp "$ENV_FILE" "$ENV_BADGRACE"
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
cp "$ENV_FILE" "$ENV_GOODGRACE"
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
cp "$ENV_ENT" "$ENV_PROD_ENT"
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
"$ROOT/bin/lucairn-init" --production --license "$INIT_BUNDLE" --output "$INIT_OUT" --skip-doctor >/dev/null 2>&1
grep -q '^LUCAIRN_LICENSE_KEY=tok_dummy$' "$INIT_OUT"
grep -q '^LUCAIRN_LICENSE_PUBLIC_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff$' "$INIT_OUT"
grep -q '^DSA_LICENSE_KEY=lic_x$' "$INIT_OUT"

# Backward-compat: a bundle WITHOUT entitlement fields still parses; the
# entitlement vars are written empty (unregistered/INERT).
INIT_BUNDLE_NOENT="$TMPDIR/a9-bundle-noent.json"
printf '{"license_key":"lic_y","signing_key":"sk_y"}' > "$INIT_BUNDLE_NOENT"
INIT_OUT_NOENT="$TMPDIR/a9-customer-noent.env"
"$ROOT/bin/lucairn-init" --production --license "$INIT_BUNDLE_NOENT" --output "$INIT_OUT_NOENT" --skip-doctor >/dev/null 2>&1
grep -q '^LUCAIRN_LICENSE_KEY=$' "$INIT_OUT_NOENT"
grep -q '^LUCAIRN_LICENSE_PUBLIC_KEY=$' "$INIT_OUT_NOENT"

# --dev: entitlement vars present but empty (grace defaults to 14).
INIT_OUT_DEV="$TMPDIR/a9-customer-dev.env"
"$ROOT/bin/lucairn-init" --dev --output "$INIT_OUT_DEV" --skip-doctor >/dev/null 2>&1
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
test -f "$BASE_DIR/install/customer.env"
test -f "$BASE_DIR/models/acme-support-q4.gguf"
test -f "$BASE_DIR/models/model-manifest.yaml"
test -f "$BASE_DIR/images/lucairn-images.tar"
test -f "$BASE_DIR/checksums/SHA256SUMS"

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

echo "lucairn bundle tests: ok"

AGENT_STAGE="$TMPDIR/agent-staging/acme"
mkdir -p "$AGENT_STAGE/models" "$AGENT_STAGE/images" "$AGENT_STAGE/demo-data"
cp "$ENV_FILE" "$AGENT_STAGE/customer.env"
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
cp "$ENV_FILE" "$REGISTRY_STAGE/customer.env"
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

echo "lucairn agent prepare tests: ok"

# Multi-source ambiguity guard (audit 2026-05-15 F4): bundle prepare must fail
# loudly if more than one of customer-data/, demo-data/, data/ is non-empty.
AMBIG_STAGE="$TMPDIR/agent-staging/ambig"
mkdir -p "$AMBIG_STAGE/models" "$AMBIG_STAGE/customer-data" "$AMBIG_STAGE/demo-data"
cp "$ENV_FILE" "$AMBIG_STAGE/customer.env"
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
