#!/usr/bin/env bash
set -euo pipefail

# Generate the witness-signed public-key manifest used by the disposable
# Enterprise mTLS Kind harness. The input runtime values already contain one
# coherent set of generated signing seeds and derived public keys. This script
# derives the exact seven-entry keys.json roster required by the pinned 0.5.4
# sign-manifest tool, writes only the signed output requested by the caller,
# and never prints private material or the signed input.

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <runtime-values.yaml-path> <witness-signed-manifest.json-path>" >&2
  exit 2
fi

RUNTIME_VALUES="$1"
OUTPUT="$2"
OUTPUT_DIR="$(dirname "$OUTPUT")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_MANIFEST="$ROOT/image-manifest.yaml"

[ -r "$RUNTIME_VALUES" ] || {
  echo "runtime values are not readable: $RUNTIME_VALUES" >&2
  exit 2
}
[ -d "$OUTPUT_DIR" ] || {
  echo "signed-manifest output parent directory does not exist: $OUTPUT_DIR" >&2
  exit 2
}
[ ! -e "$OUTPUT" ] || {
  echo "refusing to overwrite existing signed-manifest output: $OUTPUT" >&2
  exit 2
}

command -v docker >/dev/null 2>&1 || {
  echo "docker is required to invoke the pinned sign-manifest ceremony tool" >&2
  exit 2
}
command -v ruby >/dev/null 2>&1 || {
  echo "ruby is required to assemble the disposable keys.json roster" >&2
  exit 2
}
[ -r "$IMAGE_MANIFEST" ] || {
  echo "image manifest is not readable: $IMAGE_MANIFEST" >&2
  exit 2
}

# Resolve the signing image from the release manifest rather than duplicating a
# mutable tag or a second digest literal here. The ceremony is deliberately
# bound to the exact witness artifact recorded for this repository release.
WITNESS_IMAGE="$(ruby -ryaml -e '
  manifest = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
  entry = manifest.fetch("image_digests").fetch("signed_artifacts").fetch("dsa-veil-witness")
  ref = entry.fetch("ref")
  digest = entry.fetch("digest")
  abort "invalid witness image ref" unless ref == "ghcr.io/declade/dsa-veil-witness:0.5.4"
  abort "invalid witness image digest" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
  print "#{ref}@#{digest}"
' "$IMAGE_MANIFEST")"

# Both the runtime values and the output are secret-adjacent ceremony artifacts.
# Apply restrictive permissions before opening either path. Do not add xtrace:
# the witness seed is passed to the tool using its documented flag interface.
umask 077
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.enterprise-mtls-manifest.XXXXXX")"
KEYS_JSON="$WORK_DIR/keys.json"
SIGNING_SEED_FILE="$WORK_DIR/witness-signing-key-hex"
SIGNED_TMP="$WORK_DIR/witness-signed-manifest.json"
trap 'rm -rf "$WORK_DIR"' EXIT

# The schema and roster deliberately mirror docs/KEY_CEREMONY_RUNBOOK.md §6.1.
# It includes every non-empty LCR public key injected into the gateway, so the
# gateway's verifyEnvKeysMatchBlobActive startup check can match it byte-for-byte.
# The Ruby process writes public keys and the witness seed directly into the
# private workspace; it never returns the seed to this shell or stdout.
ruby -ryaml -rjson - "$RUNTIME_VALUES" "$KEYS_JSON" "$SIGNING_SEED_FILE" <<'RUBY'
values = YAML.load_file(ARGV.fetch(0))
output = ARGV.fetch(1)
seed_output = ARGV.fetch(2)
gateway = values.fetch("gateway").fetch("secrets").fetch("values")

public_key = lambda do |key|
  value = gateway.fetch(key)
  abort "runtime values omit #{key}" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/i)
  value
end

keys = [
  { "service_id" => "dsa-witness", "key_id" => "witness_v1", "public_key" => public_key.call("veilWitnessPublicKey"), "purpose" => "Certificate signing", "algorithm" => "Ed25519", "key_state" => "active" },
  { "service_id" => "dsa-bridge", "key_id" => "bridge_v1", "public_key" => public_key.call("veilBridgePublicKey"), "purpose" => "Bridge claim signing", "algorithm" => "Ed25519", "key_state" => "active" },
  { "service_id" => "dsa-sanitizer", "key_id" => "sanitizer_v1", "public_key" => public_key.call("veilSanitizerPublicKey"), "purpose" => "Sanitizer claim signing", "algorithm" => "Ed25519", "key_state" => "active" },
  { "service_id" => "dsa-ai", "key_id" => "sandbox_b_v1", "public_key" => public_key.call("veilSandboxBPublicKey"), "purpose" => "Inference claim signing", "algorithm" => "Ed25519", "key_state" => "active" },
  { "service_id" => "dsa-audit", "key_id" => "audit_v1", "public_key" => public_key.call("veilAuditPublicKey"), "purpose" => "Audit claim signing", "algorithm" => "Ed25519", "key_state" => "active" },
  { "service_id" => "dsa-gateway", "key_id" => "gateway_manifest_v1", "public_key" => public_key.call("veilGatewayManifestPublicKey"), "purpose" => "Manifest signing", "algorithm" => "Ed25519", "key_state" => "active" },
  { "service_id" => "dsa-witness", "key_id" => "witness_manifest_v1", "public_key" => public_key.call("veilWitnessManifestPublicKey"), "purpose" => "Manifest signing", "algorithm" => "Ed25519", "key_state" => "active" }
]

File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(keys)) }
witness_seed = values.fetch("veil-witness").fetch("secrets").fetch("values").fetch("signingKey")
abort "runtime values omit a valid witness signing seed" unless witness_seed.is_a?(String) && witness_seed.match?(/\A[0-9a-f]{64}\z/i)
File.open(seed_output, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(witness_seed) }
RUBY

issuer="$(ruby -ryaml -e 'print YAML.load_file(ARGV.fetch(0)).fetch("gateway").fetch("veilIssuer")' "$RUNTIME_VALUES")"
[ -n "$issuer" ] || {
  echo "runtime values omit gateway.veilIssuer" >&2
  exit 2
}

# Exact supported interface from docs/KEY_CEREMONY_RUNBOOK.md §6.2. The seed
# enters the disposable signing container only through a private read-only
# mount. The literal in-container shell command reads it for sign-manifest's
# required flag; the host Docker argv never contains the secret bytes.
docker run --rm \
  --entrypoint /bin/sh \
  -v "$KEYS_JSON:/keys.json:ro" \
  -v "$SIGNING_SEED_FILE:/run/secrets/witness-signing-key-hex:ro" \
  "$WITNESS_IMAGE" \
  -ec 'exec sign-manifest --keys-json /keys.json --issuer "$1" --witness-signing-key-hex "$(cat /run/secrets/witness-signing-key-hex)" --witness-key-id witness_manifest_v1' \
  sign-manifest "$issuer" \
  > "$SIGNED_TMP"

[ -s "$SIGNED_TMP" ] || {
  echo "sign-manifest produced an empty signed manifest" >&2
  exit 1
}
chmod 0600 "$SIGNED_TMP"
mv "$SIGNED_TMP" "$OUTPUT"
chmod 0600 "$OUTPUT"
