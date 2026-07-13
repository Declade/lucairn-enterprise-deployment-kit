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

TMP_VALUES="$(mktemp "${TMPDIR:-/tmp}/lucairn-production-values.XXXXXX")"
trap 'rm -f "$TMP_VALUES"' EXIT

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

  # O_EXCL is the final TOCTOU guard: never follow, truncate, or replace an
  # output path that appeared after the early shell refusal check.
  File.open(ARGV.fetch(1), File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
    file.write(YAML.dump(values))
  end
' "$TMP_VALUES" "$OUTPUT"

echo "render-production-values.sh: $OUTPUT ready (mode 600; keep it out of Git)."
