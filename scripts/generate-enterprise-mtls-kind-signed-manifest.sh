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

# Both the runtime values and the output are secret-adjacent ceremony artifacts.
# Apply restrictive permissions before opening either path. Do not add xtrace:
# the witness seed is passed to the tool using its documented flag interface.
umask 077
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.enterprise-mtls-manifest.XXXXXX")"
KEYS_JSON="$WORK_DIR/keys.json"
SIGNED_TMP="$WORK_DIR/witness-signed-manifest.json"
trap 'rm -rf "$WORK_DIR"' EXIT

# The schema and roster deliberately mirror docs/KEY_CEREMONY_RUNBOOK.md §6.1.
# It includes every non-empty LCR public key injected into the gateway, so the
# gateway's verifyEnvKeysMatchBlobActive startup check can match it byte-for-byte.
# The Ruby process writes public keys to KEYS_JSON and returns only the witness
# seed to this shell; neither is printed.
witness_seed="$(ruby -ryaml -rjson - "$RUNTIME_VALUES" "$KEYS_JSON" <<'RUBY'
values = YAML.load_file(ARGV.fetch(0))
output = ARGV.fetch(1)
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
STDOUT.write(witness_seed)
RUBY
)"

issuer="$(ruby -ryaml -e 'print YAML.load_file(ARGV.fetch(0)).fetch("gateway").fetch("veilIssuer")' "$RUNTIME_VALUES")"
[ -n "$issuer" ] || {
  echo "runtime values omit gateway.veilIssuer" >&2
  exit 2
}

# Exact supported interface from docs/KEY_CEREMONY_RUNBOOK.md §6.2. The seed
# enters the disposable signing container only through sign-manifest's required
# --witness-signing-key-hex flag; the only persisted result is the signed blob.
docker run --rm \
  --entrypoint sign-manifest \
  -v "$KEYS_JSON:/keys.json:ro" \
  ghcr.io/declade/dsa-veil-witness:0.5.4 \
  --keys-json /keys.json \
  --issuer "$issuer" \
  --witness-signing-key-hex "$witness_seed" \
  --witness-key-id witness_manifest_v1 \
  > "$SIGNED_TMP"

[ -s "$SIGNED_TMP" ] || {
  echo "sign-manifest produced an empty signed manifest" >&2
  exit 1
}
chmod 0600 "$SIGNED_TMP"
mv "$SIGNED_TMP" "$OUTPUT"
chmod 0600 "$OUTPUT"
