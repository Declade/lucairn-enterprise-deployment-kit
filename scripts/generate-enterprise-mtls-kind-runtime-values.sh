#!/usr/bin/env bash
set -euo pipefail

# Generate the complete customer-values document for the disposable Enterprise
# mTLS Kind harness. It merges the static, non-secret production/mTLS contract
# with fresh application values so it is safe to give this one file to doctor
# and to Helm. This is deliberately not a production ceremony: all generated
# material is fresh per invocation, written only to the caller's already-owned
# state directory, and never printed. Operator-owned mTLS CA/leaf Secrets are
# created independently by enterprise-mtls-fixture-certs.sh.

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <runtime-values.yaml-path>" >&2
  exit 2
fi

OUTPUT="$1"
OUTPUT_DIR="$(dirname "$OUTPUT")"
if [ ! -d "$OUTPUT_DIR" ]; then
  echo "runtime values parent directory does not exist: $OUTPUT_DIR" >&2
  exit 2
fi
if [ -e "$OUTPUT" ]; then
  echo "refusing to overwrite existing runtime values file: $OUTPUT" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVE_PUBKEY="$ROOT/scripts/derive-veil-pubkey.sh"
FIXTURE="$ROOT/charts/lucairn/tests/fixtures/enterprise-mtls-accepted.yaml"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required to generate the disposable runtime fixture" >&2
  exit 2
}
command -v ruby >/dev/null 2>&1 || {
  echo "ruby is required to merge the disposable runtime fixture" >&2
  exit 2
}
[ -x "$DERIVE_PUBKEY" ] || {
  echo "missing executable Ed25519 public-key derivation helper: $DERIVE_PUBKEY" >&2
  exit 2
}
[ -r "$FIXTURE" ] || {
  echo "missing readable non-secret enterprise mTLS fixture: $FIXTURE" >&2
  exit 2
}

# The file contains private material, so establish restrictive permissions
# before opening it. Do not add xtrace to this script: command output is safe,
# but tracing assignments would disclose the generated values.
umask 077

random_hex() {
  openssl rand -hex 32
}

random_base64_32() {
  openssl rand -base64 32 | tr -d '\n'
}

derive_public() {
  # stdin keeps the Ed25519 seed out of the child process argument list.
  printf '%s' "$1" | "$DERIVE_PUBKEY"
}

# Seven Ed25519 seeds are required by the pinned 0.5.4 Veil startup contract:
# six claim emitters plus the gateway's separate manifest signer. Public keys
# are derived from their corresponding seeds; they are never independently
# randomized.
audit_seed="$(random_hex)"
bridge_seed="$(random_hex)"
sanitizer_seed="$(random_hex)"
sandbox_b_seed="$(random_hex)"
witness_seed="$(random_hex)"
gateway_seed="$(random_hex)"
gateway_manifest_seed="$(random_hex)"

audit_public="$(derive_public "$audit_seed")"
bridge_public="$(derive_public "$bridge_seed")"
sanitizer_public="$(derive_public "$sanitizer_seed")"
sandbox_b_public="$(derive_public "$sandbox_b_seed")"
witness_public="$(derive_public "$witness_seed")"
gateway_public="$(derive_public "$gateway_seed")"
gateway_manifest_public="$(derive_public "$gateway_manifest_seed")"

# Shared values are generated once and reused verbatim by every consumer.
service_token="$(random_hex)"
admin_key="$(random_hex)"
canary_hmac_key="$(random_hex)"
sandbox_b_api_key="$(random_hex)"
gateway_keystore_key="$(random_base64_32)"

# Keep the generated material on stdin rather than in a shell argument or
# temporary file. Ruby deep-merges it with the static fixture so nested maps
# such as global and sandbox-b retain both their non-secret and secret fields.
ruby -ryaml -e '
  def deep_merge(static, generated)
    static.merge(generated) do |_key, left, right|
      left.is_a?(Hash) && right.is_a?(Hash) ? deep_merge(left, right) : right
    end
  end

  static = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  generated = YAML.safe_load(STDIN.read, aliases: true)
  merged = deep_merge(static, generated)
  File.open(ARGV.fetch(1), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(YAML.dump(merged))
  end
' "$FIXTURE" "$OUTPUT" <<YAML
# Ephemeral Kind-only application values. These are merged with the static
# non-secret fixture above; never commit this file or use it for production.
global:
  dsaServiceToken: "$service_token"

audit:
  secrets:
    values:
      postgresPassword: "$(random_hex)"
      auditAppPassword: "$(random_hex)"
      veilSigningKey: "$audit_seed"

id-bridge:
  secrets:
    values:
      postgresPassword: "$(random_hex)"
      masterKey: "$(random_hex)"
      veilSigningKey: "$bridge_seed"
      bridgeEncryptionKey: "$(random_hex)"

sandbox-a:
  secrets:
    values:
      postgresPassword: "$(random_hex)"
      encryptionKey: "$(random_hex)"
      adminKey: "$admin_key"
      veilSigningKey: "$sanitizer_seed"
      canaryHmacKey: "$canary_hmac_key"

sandbox-b:
  redis:
    password: "$(random_hex)"
  secrets:
    values:
      veilSigningKey: "$sandbox_b_seed"
      sandboxBApiKeys: "$sandbox_b_api_key"
      adminKey: "$admin_key"

gateway:
  secrets:
    values:
      adminKey: "$admin_key"
      sandboxBApiKey: "$sandbox_b_api_key"
      veilManifestSigningKey: "$gateway_manifest_seed"
      veilGatewaySigningKey: "$gateway_seed"
      veilGatewayPublicKey: "$gateway_public"
      veilGatewayManifestPublicKey: "$gateway_manifest_public"
      veilWitnessManifestPublicKey: "$witness_public"
      veilWitnessPublicKey: "$witness_public"
      veilBridgePublicKey: "$bridge_public"
      veilSanitizerPublicKey: "$sanitizer_public"
      veilSandboxBPublicKey: "$sandbox_b_public"
      veilAuditPublicKey: "$audit_public"
      # Sensitive-mode AI signing must be the same seed Sandbox B uses.
      veilAISigningKey: "$sandbox_b_seed"
      gatewayKeystoreKey: "$gateway_keystore_key"
      canaryHmacKey: "$canary_hmac_key"

veil-witness:
  config:
    bridgePublicKey: "$bridge_public"
    sanitizerPublicKey: "$sanitizer_public"
    sandboxBPublicKey: "$sandbox_b_public"
    auditPublicKey: "$audit_public"
  secrets:
    values:
      postgresPassword: "$(random_hex)"
      veilAppPassword: "$(random_hex)"
      signingKey: "$witness_seed"
      keyId: "kind-ephemeral-witness-v1"
YAML

chmod 0600 "$OUTPUT"
