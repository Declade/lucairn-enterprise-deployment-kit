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

# Resolve and validate the parent before generating any credentials.  A
# customer directory is never chmodded: it is either already a private,
# effective-user-owned directory or it is unsafe for secret material.
OUTPUT_NAME="$(basename "$OUTPUT")"
OUTPUT_DIR_INPUT="$(dirname "$OUTPUT")"
if ! OUTPUT_DIR="$(ruby -e '
  directory = File.realpath(ARGV.fetch(0))
  stat = File.lstat(directory)
  abort "not a real directory" unless stat.directory?
  abort "not owned by the effective user" unless stat.uid == Process.euid
  abort "group/world writable" unless (stat.mode & 0o022).zero?
  print directory
' "$OUTPUT_DIR_INPUT")"; then
  echo "error: output directory must be a real, effective-user-owned directory that is not group/world writable: $OUTPUT_DIR_INPUT" >&2
  exit 1
fi
OUTPUT="$OUTPUT_DIR/$OUTPUT_NAME"

# This overlay contains freshly generated credentials. Refuse an occupied
# destination before generating them so an ordinary upgrade cannot silently
# rotate credentials, and include -L so dangling symlinks are refused too.
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  echo "error: refusing to overwrite existing output path: $OUTPUT" >&2
  echo "choose a new path for a deliberate, coordinated credential rotation" >&2
  exit 1
fi

TMP_VALUES=""
STAGED_VALUES=""
cleanup() {
  rm -f -- "$TMP_VALUES" "$STAGED_VALUES"
}
trap cleanup EXIT

# Both files hold generated credentials. Stage the final serialized document
# beside its destination so publication can use an atomic, non-replacing hard
# link on the same filesystem. The validated directory is private to the
# effective user, which is the trust boundary for the pathname-based link
# below; mktemp creates the initial 0600 staging inode under that boundary.
TMP_VALUES="$(mktemp "${TMPDIR:-/tmp}/lucairn-production-values.XXXXXX")"
STAGED_VALUES="$(mktemp "$OUTPUT_DIR/.lucairn-production-values.XXXXXX")"

if [ ! -x "$RENDER_VALUES" ]; then
  echo "error: render-values.sh not found or not executable at $RENDER_VALUES" >&2
  exit 1
fi

# Keep the cryptographic generation in the one canonical renderer. Do not
# duplicate its paired-key or shared-token logic here.
bash "$RENDER_VALUES" "$TMP_VALUES" >/dev/null

STAGED_ID="$(ruby -ryaml -e '
  values = YAML.load_file(ARGV.fetch(0))
  global = values.fetch("global")
  allowed_global_keys = %w[dsaServiceToken dsaLicenseKey lucairnLicenseKey lucairnLicensePublicKey imageRegistry imageTag imagePullSecrets imagePullDockerConfigJson]
  values["global"] = global.select { |key, _| allowed_global_keys.include?(key) }
  values.delete("demo")

  staged = ARGV.fetch(1)
  abort "runtime lacks File::NOFOLLOW for secure staging" unless File.const_defined?(:NOFOLLOW)
  serialized = YAML.dump(values)
  flags = File::WRONLY | File::TRUNC | File::NOFOLLOW
  File.open(staged, flags) do |file|
    file.chmod(0o600)
    written = file.write(serialized)
    abort "short write while staging production overlay" unless written == serialized.bytesize
    file.flush
    file.fsync if file.respond_to?(:fsync)
  end

  flags = File::RDONLY | File::NOFOLLOW
  File.open(staged, flags) do |file|
    stat = file.stat
    abort "staged production overlay is not a regular file" unless stat.file?
    abort "staged production overlay is not owned by the effective user" unless stat.uid == Process.euid
    abort "staged production overlay mode is not 0600" unless (stat.mode & 0o7777) == 0o600
    content = file.read
    abort "staged production overlay bytes changed after write" unless content == serialized
    parsed = YAML.load(content)
    abort "staged production overlay does not equal the complete source object" unless parsed == values
    print "#{stat.dev}:#{stat.ino}"
  end
' "$TMP_VALUES" "$STAGED_VALUES")"

# File.link calls link(2) directly: publication is atomic, does not replace or
# follow an output path that appeared after the early refusal. The parent was
# checked as private to this effective user above; still assert immediately
# before link that the staging pathname has not changed from the validated
# inode. This preserves the same-directory, non-replacing publication rule.
ruby -e '
  staged, output, expected_dev, expected_ino = ARGV
  stat = File.lstat(staged)
  abort "staging path changed before publication" unless stat.file? && stat.dev == expected_dev.to_i && stat.ino == expected_ino.to_i
  abort "staging path is not owned by the effective user" unless stat.uid == Process.euid
  abort "staging path mode is not 0600" unless (stat.mode & 0o7777) == 0o600
  File.link(staged, output)
' "$STAGED_VALUES" "$OUTPUT" "${STAGED_ID%%:*}" "${STAGED_ID##*:}"
rm -f -- "$STAGED_VALUES"
STAGED_VALUES=""

echo "render-production-values.sh: $OUTPUT ready (mode 600; keep it out of Git)."
