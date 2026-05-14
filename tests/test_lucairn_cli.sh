#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ENV_FILE="$TMPDIR/customer.env"
cat > "$ENV_FILE" <<'ENV'
LUCAIRN_IMAGE_REGISTRY=ghcr.io/declade
LUCAIRN_IMAGE_TAG=1.0.0
DSA_ENV=production
DSA_LICENSE_KEY=lcr_enterprise_test_secret
DSA_LICENSE_SIGNING_KEY=test-license-signing-secret
SANDBOX_B_REMOTE_ENDPOINT=https://inference.customer.example
SANDBOX_B_API_KEY=sk-test-sandbox-b-secret
DSA_SERVICE_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DSA_BRIDGE_ENCRYPTION_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SANDBOX_A_ENCRYPTION_KEY=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
BRIDGE_MASTER_KEY=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
DSA_ADMIN_KEY=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
GATEWAY_KEYSTORE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
GATEWAY_BASE_URL=https://lucairn.customer.example
VEIL_AUDIT_SIGNING_KEY=1111111111111111111111111111111111111111111111111111111111111111
VEIL_BRIDGE_SIGNING_KEY=2222222222222222222222222222222222222222222222222222222222222222
VEIL_SANITIZER_SIGNING_KEY=3333333333333333333333333333333333333333333333333333333333333333
VEIL_WITNESS_SIGNING_KEY=4444444444444444444444444444444444444444444444444444444444444444
VEIL_GATEWAY_SIGNING_KEY=5555555555555555555555555555555555555555555555555555555555555555
VEIL_MANIFEST_SIGNING_KEY=6666666666666666666666666666666666666666666666666666666666666666
VEIL_WITNESS_PUBLIC_KEY=7777777777777777777777777777777777777777777777777777777777777777
VEIL_BRIDGE_PUBLIC_KEY=8888888888888888888888888888888888888888888888888888888888888888
VEIL_SANITIZER_PUBLIC_KEY=9999999999999999999999999999999999999999999999999999999999999999
VEIL_AUDIT_PUBLIC_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
VEIL_SANDBOX_B_PUBLIC_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
POSTGRES_AUDIT_PASSWORD=postgres-audit-secret
POSTGRES_BRIDGE_PASSWORD=postgres-bridge-secret
POSTGRES_SANDBOX_A_PASSWORD=postgres-sandbox-a-secret
POSTGRES_VEIL_PASSWORD=postgres-veil-secret
BUILD_AUTH_TOKEN=build-token-secret
CUSTOMER_KEY_ID=customer-key-id-secret
PORTAL_API_KEY=portal-api-key-secret
ENV

"$ROOT/bin/lucairn" doctor \
  --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/doctor.out"

grep -q "doctor: ok" "$TMPDIR/doctor.out"
grep -q "required secrets: ok" "$TMPDIR/doctor.out"
grep -q "compose file: ok" "$TMPDIR/doctor.out"

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
grep -q "dsa-gateway:1.0.0" "$TMPDIR/image-check.out"

echo "lucairn image-check test: ok"

MODEL_DIR="$TMPDIR/models"
mkdir -p "$MODEL_DIR"
printf 'fake gguf model bytes\n' > "$MODEL_DIR/acme-support-q4.gguf"

MODEL_MANIFEST="$TMPDIR/model-manifest.yaml"
cat > "$MODEL_MANIFEST" <<'YAML'
model:
  name: acme-support-llm
  format: gguf
  runtime: llama-cpp
  files:
    - acme-support-q4.gguf
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
grep -q "checksum verification failed" "$TMPDIR/bundle-tamper.out"

echo "lucairn bundle tests: ok"
