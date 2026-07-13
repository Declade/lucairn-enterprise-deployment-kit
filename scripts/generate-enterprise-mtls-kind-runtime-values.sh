#!/usr/bin/env bash
set -euo pipefail

# Generate the two custody domains for the disposable Enterprise mTLS Kind
# harness. The public overlay is safe for doctor and Helm; the six env files
# are private operator inputs for pre-created application Secrets. Do not add
# xtrace: this script deliberately holds fresh credentials in shell variables.

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <public-overlay.yaml-path> <application-secrets-directory>" >&2
  exit 2
fi

PUBLIC_OVERLAY="$1"
APPLICATION_SECRETS_DIR="$2"
OVERLAY_DIR="$(dirname "$PUBLIC_OVERLAY")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVE_PUBKEY="$ROOT/scripts/derive-veil-pubkey.sh"
FIXTURE="$ROOT/charts/lucairn/tests/fixtures/enterprise-mtls-accepted.yaml"

[ -d "$OVERLAY_DIR" ] || { echo "public overlay parent directory does not exist: $OVERLAY_DIR" >&2; exit 2; }
[ ! -e "$PUBLIC_OVERLAY" ] || { echo "refusing to overwrite existing public overlay: $PUBLIC_OVERLAY" >&2; exit 2; }
[ ! -e "$APPLICATION_SECRETS_DIR" ] || { echo "refusing to overwrite existing application secrets directory: $APPLICATION_SECRETS_DIR" >&2; exit 2; }
[ -x "$DERIVE_PUBKEY" ] || { echo "missing executable Ed25519 public-key derivation helper: $DERIVE_PUBKEY" >&2; exit 2; }
[ -r "$FIXTURE" ] || { echo "missing readable non-secret enterprise mTLS fixture: $FIXTURE" >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required to generate the disposable runtime fixture" >&2; exit 2; }
command -v ruby >/dev/null 2>&1 || { echo "ruby is required to generate the disposable runtime fixture" >&2; exit 2; }

umask 077
mkdir "$APPLICATION_SECRETS_DIR"
chmod 0700 "$APPLICATION_SECRETS_DIR"

random_hex() { openssl rand -hex 32; }
random_base64_32() { openssl rand -base64 32 | tr -d '\n'; }
derive_public() { printf '%s' "$1" | "$DERIVE_PUBKEY"; }

# Seven coherent Ed25519 seeds: six workload claim emitters and the Gateway's
# separate signed-manifest key. Only the derived verifier values enter the
# public overlay.
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

service_token="$(random_hex)"
admin_key="$(random_hex)"
canary_hmac_key="$(random_hex)"
sandbox_b_api_key="$(random_hex)"
gateway_keystore_key="$(random_base64_32)"

# The ExternalSecret target-key rosters are explicit below. Preserve every
# cross-service equality in the source files because Helm never sees them:
# service token, admin key, API key, canary key, signing keys, verifier roster,
# bundled database credentials, and the Redis URL/password all remain coherent.
write_env() {
  local name="$1"
  shift
  local output="$APPLICATION_SECRETS_DIR/$name.env"
  ( umask 077; printf '%s\n' "$@" > "$output" )
  chmod 0600 "$output"
}

audit_postgres_password="$(random_hex)"
audit_app_password="$(random_hex)"
bridge_postgres_password="$(random_hex)"
sandbox_a_postgres_password="$(random_hex)"
witness_postgres_password="$(random_hex)"
witness_app_password="$(random_hex)"
sandbox_b_redis_password="$(random_hex)"

# The platform-tier token and the deployment entitlement are issuer-signed
# formats, not random 64-hex values. Keep the complete external-Secret target
# roster empty in Kind so Gateway takes its supported unregistered path; a
# non-empty random value makes the pinned binary fail before the battery can
# exercise the mTLS topology.
write_env gateway \
  "DSA_LICENSE_KEY=" \
  "DSA_LICENSE_SIGNING_KEY=" \
  "LUCAIRN_LICENSE_KEY=" \
  "LUCAIRN_LICENSE_PUBLIC_KEY=" \
  "DSA_ADMIN_KEY=$admin_key" \
  "SANDBOX_B_API_KEY=$sandbox_b_api_key" \
  "LCR_MANIFEST_SIGNING_KEY=$gateway_manifest_seed" \
  "LCR_GATEWAY_SIGNING_KEY=$gateway_seed" \
  "LCR_GATEWAY_PUBLIC_KEY=$gateway_public" \
  "LCR_GATEWAY_MANIFEST_PUBLIC_KEY=$gateway_manifest_public" \
  "LCR_WITNESS_MANIFEST_PUBLIC_KEY=$witness_public" \
  "LCR_WITNESS_PUBLIC_KEY=$witness_public" \
  "LCR_BRIDGE_PUBLIC_KEY=$bridge_public" \
  "LCR_SANITIZER_PUBLIC_KEY=$sanitizer_public" \
  "LCR_SANDBOX_B_PUBLIC_KEY=$sandbox_b_public" \
  "LCR_AUDIT_PUBLIC_KEY=$audit_public" \
  "LCR_AI_SIGNING_KEY=$sandbox_b_seed" \
  "DSA_SERVICE_TOKEN=$service_token" \
  "GATEWAY_KEYSTORE_KEY=$gateway_keystore_key" \
  "CANARY_HMAC_KEY=$canary_hmac_key"

write_env audit \
  "DATABASE_URL=postgres://dsa:$audit_postgres_password@audit-postgresql:5432/audit?sslmode=disable" \
  "DATABASE_URL_APP=postgres://audit_app:$audit_app_password@audit-postgresql:5432/audit?sslmode=disable" \
  "POSTGRES_PASSWORD=$audit_postgres_password" \
  "AUDIT_APP_PASSWORD=$audit_app_password" \
  "LCR_SIGNING_KEY=$audit_seed" \
  "DSA_SERVICE_TOKEN=$service_token"

write_env id-bridge \
  "DATABASE_URL=postgres://dsa:$bridge_postgres_password@id-bridge-postgresql:5432/bridge?sslmode=disable" \
  "POSTGRES_PASSWORD=$bridge_postgres_password" \
  "MASTER_KEY=$(random_hex)" \
  "LCR_SIGNING_KEY=$bridge_seed" \
  "DSA_BRIDGE_ENCRYPTION_KEY=$(random_hex)" \
  "DSA_SERVICE_TOKEN=$service_token"

write_env sandbox-a \
  "DATABASE_URL=postgres://dsa:$sandbox_a_postgres_password@sandbox-a-postgresql:5432/sandbox_a?sslmode=disable" \
  "POSTGRES_PASSWORD=$sandbox_a_postgres_password" \
  "ENCRYPTION_KEY=$(random_hex)" \
  "DSA_ADMIN_KEY=$admin_key" \
  "LCR_SIGNING_KEY=$sanitizer_seed" \
  "DSA_SERVICE_TOKEN=$service_token" \
  "CANARY_HMAC_KEY=$canary_hmac_key" \
  "MODEL_AUTH_SECRET=$(random_hex)"

write_env sandbox-b \
  "SANDBOX_B_REDIS_URL=redis://:$sandbox_b_redis_password@sandbox-b-redis:6379" \
  "REDIS_PASSWORD=$sandbox_b_redis_password" \
  "ANTHROPIC_API_KEY=$(random_hex)" \
  "MISTRAL_API_KEY=$(random_hex)" \
  "OPENAI_API_KEY=$(random_hex)" \
  "GEMINI_API_KEY=$(random_hex)" \
  "LCR_SIGNING_KEY=$sandbox_b_seed" \
  "SANDBOX_B_API_KEYS=$sandbox_b_api_key" \
  "DSA_ADMIN_KEY=$admin_key" \
  "DSA_MANAGED_AI_KEY=$(random_hex)" \
  "DSA_SERVICE_TOKEN=$service_token" \
  "DSA_LICENSE_KEY="

write_env veil-witness \
  "DATABASE_URL=postgres://veil:$witness_postgres_password@veil-witness-postgresql:5432/veil?sslmode=disable" \
  "DATABASE_URL_APP=postgres://veil_app:$witness_app_password@veil-witness-postgresql:5432/veil?sslmode=disable" \
  "POSTGRES_PASSWORD=$witness_postgres_password" \
  "VEIL_APP_PASSWORD=$witness_app_password" \
  "LCR_WITNESS_SIGNING_KEY=$witness_seed" \
  "LCR_WITNESS_KEY_ID=kind-ephemeral-witness-v1"

# Preserve the checked-in names/path topology, add Kind-only non-secret CNI
# exceptions, and publish verifier values in a neutral public map. No
# `secrets.values`, password, signing seed, token, API key, or registry byte is
# present in this overlay.
PUBLIC_OVERLAY="$PUBLIC_OVERLAY" FIXTURE="$FIXTURE" \
  AUDIT_PUBLIC="$audit_public" BRIDGE_PUBLIC="$bridge_public" \
  SANITIZER_PUBLIC="$sanitizer_public" SANDBOX_B_PUBLIC="$sandbox_b_public" \
  WITNESS_PUBLIC="$witness_public" GATEWAY_PUBLIC="$gateway_public" \
  GATEWAY_MANIFEST_PUBLIC="$gateway_manifest_public" \
  ruby -ryaml -e '
    def deep_merge(left, right)
      left.merge(right) { |_key, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b }
    end
    fixture = YAML.safe_load(File.read(ENV.fetch("FIXTURE")), aliases: true)
    kind = {
      "global" => {
        "skipPullSecretGuard" => true,
        "dnsRestriction" => false,
        "wireguardEncryption" => false,
        "postgresqlSslmode" => "disable",
        # Kind deliberately installs no ESO controller. This disposable,
        # non-secret HTTPS endpoint only satisfies the production render
        # contract; the harness pre-creates target Secrets and never claims
        # ExternalSecret reconciliation.
        "secrets" => { "vault" => { "endpoint" => "https://vault.kind.invalid" } }
      },
      "kindPublicKeys" => {
        "veilAuditPublicKey" => ENV.fetch("AUDIT_PUBLIC"),
        "veilBridgePublicKey" => ENV.fetch("BRIDGE_PUBLIC"),
        "veilSanitizerPublicKey" => ENV.fetch("SANITIZER_PUBLIC"),
        "veilSandboxBPublicKey" => ENV.fetch("SANDBOX_B_PUBLIC"),
        "veilWitnessPublicKey" => ENV.fetch("WITNESS_PUBLIC"),
        "veilGatewayPublicKey" => ENV.fetch("GATEWAY_PUBLIC"),
        "veilGatewayManifestPublicKey" => ENV.fetch("GATEWAY_MANIFEST_PUBLIC")
      },
      # These four verifier values are public configuration, not operator
      # credentials. Veil Witness reads them from its ConfigMap, so mirror the
      # public roster into the child value path while all private keys stay in
      # the pre-created application Secrets.
      "veil-witness" => {
        "config" => {
          "bridgePublicKey" => ENV.fetch("BRIDGE_PUBLIC"),
          "sanitizerPublicKey" => ENV.fetch("SANITIZER_PUBLIC"),
          "sandboxBPublicKey" => ENV.fetch("SANDBOX_B_PUBLIC"),
          "auditPublicKey" => ENV.fetch("AUDIT_PUBLIC")
        }
      }
    }
    output = deep_merge(fixture, kind)
    File.open(ENV.fetch("PUBLIC_OVERLAY"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(YAML.dump(output)) }
  '
chmod 0600 "$PUBLIC_OVERLAY"
