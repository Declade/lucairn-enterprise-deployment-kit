#!/usr/bin/env bash
set -euo pipefail

# Verify that Helm release state did not retain an exact private value from the
# six out-of-band application Secret sources. This reports only the source key
# and output class, never a sensitive byte.

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <application-secrets-directory> <helm-values-output> <helm-manifest-output> <helm-all-output>" >&2
  exit 2
fi

APPLICATION_SECRETS_DIR="$1"
shift
[ -d "$APPLICATION_SECRETS_DIR" ] || { echo "release-state custody check: application secrets directory is missing" >&2; exit 2; }
for output in "$@"; do
  [ -r "$output" ] || { echo "release-state custody check: release output is missing" >&2; exit 2; }
done

ruby - "$APPLICATION_SECRETS_DIR" "$@" <<'RUBY'
directory, values, manifest, all = ARGV
public_keys = %w[
  LCR_GATEWAY_PUBLIC_KEY LCR_GATEWAY_MANIFEST_PUBLIC_KEY
  LCR_WITNESS_MANIFEST_PUBLIC_KEY LCR_WITNESS_PUBLIC_KEY
  LCR_BRIDGE_PUBLIC_KEY LCR_SANITIZER_PUBLIC_KEY
  LCR_SANDBOX_B_PUBLIC_KEY LCR_AUDIT_PUBLIC_KEY
]
private_items = []
Dir.children(directory).sort.grep(/\.env\z/).each do |name|
  File.foreach(File.join(directory, name), chomp: true) do |line|
    key, value = line.split("=", 2)
    next if value.nil? || public_keys.include?(key)
    abort "release-state custody check: empty or short private source item #{name}/#{key}" if value.empty? || value.length < 16
    private_items << [name, key, value]
  end
end
abort "release-state custody check: no private source items found" if private_items.empty?
{ "values" => values, "manifest" => manifest, "all" => all }.each do |class_name, path|
  content = File.binread(path)
  private_items.each do |source, key, value|
    abort "release-state custody failure: private item #{source}/#{key} occurs in Helm #{class_name} output" if content.include?(value)
  end
end
RUBY
