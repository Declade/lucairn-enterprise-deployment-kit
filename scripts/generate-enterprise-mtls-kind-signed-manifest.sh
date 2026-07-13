#!/usr/bin/env bash
set -euo pipefail

# Sign the public verifier roster using only the witness seed in the private
# application-secret source directory. The host Docker argv and stdout receive
# paths/output only, never seed bytes or a secret-bearing Helm values file.

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <public-overlay.yaml-path> <application-secrets-directory> <witness-signed-manifest.json-path>" >&2
  exit 2
fi

PUBLIC_OVERLAY="$1"
APPLICATION_SECRETS_DIR="$2"
OUTPUT="$3"
OUTPUT_DIR="$(dirname "$OUTPUT")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_MANIFEST="$ROOT/image-manifest.yaml"
WITNESS_ENV="$APPLICATION_SECRETS_DIR/veil-witness.env"

[ -r "$PUBLIC_OVERLAY" ] || { echo "public overlay is not readable: $PUBLIC_OVERLAY" >&2; exit 2; }
[ -d "$APPLICATION_SECRETS_DIR" ] || { echo "application secrets directory is not readable: $APPLICATION_SECRETS_DIR" >&2; exit 2; }
[ -r "$WITNESS_ENV" ] || { echo "witness private source file is not readable: $WITNESS_ENV" >&2; exit 2; }
[ -d "$OUTPUT_DIR" ] || { echo "signed-manifest output parent directory does not exist: $OUTPUT_DIR" >&2; exit 2; }
[ ! -e "$OUTPUT" ] || { echo "refusing to overwrite existing signed-manifest output: $OUTPUT" >&2; exit 2; }
[ -r "$IMAGE_MANIFEST" ] || { echo "image manifest is not readable: $IMAGE_MANIFEST" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "docker is required to invoke the pinned sign-manifest ceremony tool" >&2; exit 2; }
command -v ruby >/dev/null 2>&1 || { echo "ruby is required to assemble the disposable keys.json roster" >&2; exit 2; }

WITNESS_IMAGE="$(ruby -ryaml -e '
  manifest = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  entry = manifest.fetch("image_digests").fetch("signed_artifacts").fetch("dsa-veil-witness")
  ref, digest = entry.fetch("ref"), entry.fetch("digest")
  abort "invalid witness image ref" unless ref == "ghcr.io/declade/dsa-veil-witness:0.5.4"
  abort "invalid witness image digest" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
  print "#{ref}@#{digest}"
' "$IMAGE_MANIFEST")"

umask 077
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.enterprise-mtls-manifest.XXXXXX")"
KEYS_JSON="$WORK_DIR/keys.json"
SIGNING_SEED_FILE="$WORK_DIR/witness-signing-key-hex"
SIGNED_TMP="$WORK_DIR/witness-signed-manifest.json"
trap 'rm -rf "$WORK_DIR"' EXIT

# The signer accepts only a public overlay and private source files. Ruby
# writes the seven-entry public roster and mounts a mode-0600 seed file into the
# short-lived ceremony container. The current signer CLI accepts
# --witness-signing-key-hex, so that seed is expanded only inside the container;
# the host Docker argv and stdout never receive it.
ruby -ryaml -rjson - "$PUBLIC_OVERLAY" "$WITNESS_ENV" "$KEYS_JSON" "$SIGNING_SEED_FILE" <<'RUBY'
values = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
private_env = File.readlines(ARGV.fetch(1), chomp: true).each_with_object({}) do |line, map|
  key, value = line.split("=", 2)
  map[key] = value if key && value
end
keys = values.fetch("kindPublicKeys")
public_key = lambda do |key|
  value = keys.fetch(key)
  abort "public overlay omits #{key}" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/i)
  value
end
roster = [
  ["dsa-witness", "witness_v1", "veilWitnessPublicKey", "Certificate signing"],
  ["dsa-bridge", "bridge_v1", "veilBridgePublicKey", "Bridge claim signing"],
  ["dsa-sanitizer", "sanitizer_v1", "veilSanitizerPublicKey", "Sanitizer claim signing"],
  ["dsa-ai", "sandbox_b_v1", "veilSandboxBPublicKey", "Inference claim signing"],
  ["dsa-audit", "audit_v1", "veilAuditPublicKey", "Audit claim signing"],
  ["dsa-gateway", "gateway_manifest_v1", "veilGatewayManifestPublicKey", "Manifest signing"],
  ["dsa-witness", "witness_manifest_v1", "veilWitnessPublicKey", "Manifest signing"]
]
payload = roster.map { |service, key_id, public, purpose| { "service_id" => service, "key_id" => key_id, "public_key" => public_key.call(public), "purpose" => purpose, "algorithm" => "Ed25519", "key_state" => "active" } }
File.open(ARGV.fetch(2), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(payload)) }
seed = private_env.fetch("LCR_WITNESS_SIGNING_KEY")
abort "private witness source omits a valid signing seed" unless seed.match?(/\A[0-9a-f]{64}\z/i)
File.open(ARGV.fetch(3), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(seed) }
RUBY

issuer="$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true).fetch("gateway").fetch("veilIssuer")' "$PUBLIC_OVERLAY")"
[ -n "$issuer" ] || { echo "public overlay omits gateway.veilIssuer" >&2; exit 2; }

docker run --rm \
  --entrypoint /bin/sh \
  -v "$KEYS_JSON:/keys.json:ro" \
  -v "$SIGNING_SEED_FILE:/run/secrets/witness-signing-key-hex:ro" \
  "$WITNESS_IMAGE" \
  -ec 'exec sign-manifest --keys-json /keys.json --issuer "$1" --witness-signing-key-hex "$(cat /run/secrets/witness-signing-key-hex)" --witness-key-id witness_manifest_v1' \
  sign-manifest "$issuer" \
  > "$SIGNED_TMP"

[ -s "$SIGNED_TMP" ] || { echo "sign-manifest produced an empty signed manifest" >&2; exit 1; }
chmod 0600 "$SIGNED_TMP"
mv "$SIGNED_TMP" "$OUTPUT"
chmod 0600 "$OUTPUT"
