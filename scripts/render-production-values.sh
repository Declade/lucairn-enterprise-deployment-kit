#!/usr/bin/env bash
#
# render-production-values.sh — render the customer/application half of the
# production Helm values pair. The parent production controls always come
# first from charts/lucairn/values-prod.yaml; this script deliberately does
# not copy them from the development/pilot template.

set -euo pipefail
umask 077

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <output-path>" >&2
  echo "Example: $0 customer-production-values.yaml" >&2
  exit 2
fi

OUTPUT="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_VALUES="$SCRIPT_DIR/render-values.sh"

# This overlay contains freshly generated credentials. Refuse an occupied
# destination before generating them so an ordinary upgrade cannot silently
# rotate credentials, and include -L so dangling symlinks are refused too.
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  echo "error: refusing to overwrite existing output path: $OUTPUT" >&2
  echo "choose a new path for a deliberate, coordinated credential rotation" >&2
  exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT")"
TMP_VALUES=""
STAGED_VALUES=""
cleanup() {
  rm -f -- "$TMP_VALUES" "$STAGED_VALUES"
}
trap cleanup EXIT

# Both files hold generated credentials. Stage the final serialized document
# beside its destination so publication can use an atomic, non-replacing hard
# link on the same filesystem. mktemp honours the 077 umask; chmod makes the
# required mode explicit even on a platform with different defaults.
TMP_VALUES="$(mktemp "${TMPDIR:-/tmp}/lucairn-production-values.XXXXXX")"
STAGED_VALUES="$(mktemp "$OUTPUT_DIR/.lucairn-production-values.XXXXXX")"
chmod 600 "$STAGED_VALUES"

if [ ! -x "$RENDER_VALUES" ]; then
  echo "error: render-values.sh not found or not executable at $RENDER_VALUES" >&2
  exit 1
fi

# Keep the cryptographic generation in the one canonical renderer. Do not
# duplicate its paired-key or shared-token logic here.
bash "$RENDER_VALUES" "$TMP_VALUES" >/dev/null

ruby -ryaml -e '
  values = YAML.load_file(ARGV.fetch(0))
  global = values.fetch("global")

  # This explicit allowlist is the production boundary. Every other global
  # value in customer-values.yaml.example is a parent-owned environment,
  # transport, network, or security control and must remain solely in
  # charts/lucairn/values-prod.yaml.
  allowed_global_keys = %w[
    dsaServiceToken
    dsaLicenseKey
    lucairnLicenseKey
    lucairnLicensePublicKey
    imageRegistry
    imageTag
    imagePullSecrets
    imagePullDockerConfigJson
  ]
  values["global"] = global.select { |key, _| allowed_global_keys.include?(key) }
  # The production profile owns the optional-profile switch as well. Keep the
  # customer inputs for disabled optional charts, but never let this overlay
  # restate the parent production topology.
  values.delete("demo")

  staged = ARGV.fetch(1)
  File.open(staged, File::WRONLY | File::TRUNC, 0600) do |file|
    file.write(YAML.dump(values))
    file.flush
    file.fsync if file.respond_to?(:fsync)
  end
  validated = YAML.load_file(staged)
  abort "staged production overlay is not a YAML mapping" unless validated.is_a?(Hash)
  abort "staged production overlay lacks global values" unless validated.fetch("global").is_a?(Hash)
' "$TMP_VALUES" "$STAGED_VALUES"

# File.link calls link(2) directly: publication is atomic, does not replace or
# follow an output path that appeared after the early refusal, and also refuses
# a raced directory (unlike a command-line ln destination operand).
ruby -e 'File.link(ARGV.fetch(0), ARGV.fetch(1))' "$STAGED_VALUES" "$OUTPUT"
rm -f -- "$STAGED_VALUES"
STAGED_VALUES=""

echo "render-production-values.sh: $OUTPUT ready (mode 600; keep it out of Git)."
