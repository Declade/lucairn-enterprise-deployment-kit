#!/usr/bin/env bash
set -euo pipefail

# Regression for the documented production order. A development/pilot
# customer-values.yaml contains parent controls and must never be the second
# file after values-prod.yaml.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
OVERLAY="$TMPDIR/customer-production-values.yaml"
RENDER="$TMPDIR/rendered.yaml"

if ! command -v helm >/dev/null 2>&1; then
  echo "enterprise mTLS production overlay: ERROR — Helm CLI is required; install Helm and rerun make test." >&2
  exit 2
fi

bash "$ROOT/scripts/render-production-values.sh" "$OVERLAY" >/dev/null

if MODE="$(stat -f '%Lp' "$OVERLAY" 2>/dev/null)"; then :; else MODE="$(stat -c '%a' "$OVERLAY")"; fi
[ "$MODE" = "600" ] || { echo "production overlay mode is $MODE, expected 600" >&2; exit 1; }

# A production overlay holds generated DB credentials, signing keys, and
# service tokens. Every pre-existing output type must fail without changing
# the existing object or following a symlink. These failures happen before
# secret generation; the succeeding overlay below remains the exact pair used
# by the Helm and doctor contract checks.
assert_existing_output_refused() {
  local path="$1"
  if bash "$ROOT/scripts/render-production-values.sh" "$path" >/dev/null 2>&1; then
    echo "production renderer accepted existing output path: $path" >&2
    exit 1
  fi
}

REGULAR_SENTINEL="$TMPDIR/existing-values.yaml"
printf '%s\n' 'regular-file-sentinel' > "$REGULAR_SENTINEL"
assert_existing_output_refused "$REGULAR_SENTINEL"
[ "$(<"$REGULAR_SENTINEL")" = 'regular-file-sentinel' ] \
  || { echo "production renderer changed regular-file sentinel" >&2; exit 1; }

SYMLINK_TARGET="$TMPDIR/symlink-target.yaml"
SYMLINK_SENTINEL="$TMPDIR/existing-values-symlink.yaml"
printf '%s\n' 'symlink-target-sentinel' > "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_SENTINEL"
assert_existing_output_refused "$SYMLINK_SENTINEL"
[ "$(<"$SYMLINK_TARGET")" = 'symlink-target-sentinel' ] \
  || { echo "production renderer changed symlink target sentinel" >&2; exit 1; }

DANGLING_SYMLINK="$TMPDIR/dangling-values-symlink.yaml"
ln -s "$TMPDIR/does-not-exist.yaml" "$DANGLING_SYMLINK"
assert_existing_output_refused "$DANGLING_SYMLINK"

EXISTING_DIRECTORY="$TMPDIR/existing-values-directory"
mkdir "$EXISTING_DIRECTORY"
assert_existing_output_refused "$EXISTING_DIRECTORY"

assert_no_staged_overlay() {
  local directory="$1"
  if find "$directory" -maxdepth 1 -name '.lucairn-production-values.*' -print -quit | grep -q .; then
    echo "production renderer left a secret-bearing staged overlay in $directory" >&2
    exit 1
  fi
}

assert_no_source_overlay() {
  local directory="$1"
  if find "$directory" -maxdepth 1 -name '.lucairn-production-values-source.*' -print -quit | grep -q .; then
    echo "production renderer left a secret-bearing source overlay in $directory" >&2
    exit 1
  fi
}

assert_no_source_overlay "$TMPDIR"
assert_no_staged_overlay "$TMPDIR"

# TMPDIR is caller-controlled and can be non-sticky. A mktemp shim replaces
# any source created there with valid-looking attacker input; the renderer must
# neither create that source nor consume it, and must publish its own overlay
# through the validated output directory.
UNSAFE_TMPDIR="$TMPDIR/caller-controlled-tmp"
SOURCE_TRAP_BIN="$TMPDIR/source-trap-bin"
SOURCE_TRAP_LOG="$TMPDIR/source-trap.log"
SOURCE_TRAP_CALL_LOG="$TMPDIR/source-trap-calls.log"
SOURCE_TRAP_OUTPUT="$TMPDIR/source-trap-values.yaml"
SOURCE_TRAP_OUTPUT_DIR="$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$(dirname "$SOURCE_TRAP_OUTPUT")")"
REAL_MKTEMP="$(command -v mktemp)"
mkdir "$UNSAFE_TMPDIR" "$SOURCE_TRAP_BIN"
chmod 777 "$UNSAFE_TMPDIR"
cat > "$SOURCE_TRAP_BIN/mktemp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
path="\$("$REAL_MKTEMP" "\$@")"
if mode="\$(stat -f '%Lp' "\$path" 2>/dev/null)"; then :; else mode="\$(stat -c '%a' "\$path")"; fi
printf '%s|%s\\n' "\${1:-}" "\$mode" >> "$SOURCE_TRAP_CALL_LOG"
case "\${1:-}" in
  "$UNSAFE_TMPDIR"/lucairn-production-values.XXXXXX)
    printf '%s\\n' "\$path" >> "$SOURCE_TRAP_LOG"
    cat > "\$path" <<'YAML'
---
global:
  dsaServiceToken: attacker-substituted-token
YAML
    ;;
esac
printf '%s\\n' "\$path"
EOF
chmod 700 "$SOURCE_TRAP_BIN/mktemp"
TMPDIR="$UNSAFE_TMPDIR" PATH="$SOURCE_TRAP_BIN:$PATH" bash "$ROOT/scripts/render-production-values.sh" "$SOURCE_TRAP_OUTPUT" >/dev/null
[ -f "$SOURCE_TRAP_OUTPUT" ] && [ ! -L "$SOURCE_TRAP_OUTPUT" ] \
  || { echo "production renderer did not publish through the validated destination" >&2; exit 1; }
if MODE="$(stat -f '%Lp' "$SOURCE_TRAP_OUTPUT" 2>/dev/null)"; then :; else MODE="$(stat -c '%a' "$SOURCE_TRAP_OUTPUT")"; fi
[ "$MODE" = "600" ] || { echo "source-trap output mode is $MODE, expected 600" >&2; exit 1; }
[ ! -s "$SOURCE_TRAP_LOG" ] \
  || { echo "production renderer created a source overlay under caller-controlled TMPDIR" >&2; exit 1; }
grep -Fqx "$SOURCE_TRAP_OUTPUT_DIR/.lucairn-production-values-source.XXXXXX|600" "$SOURCE_TRAP_CALL_LOG" \
  || { echo "production renderer did not create its hidden 0600 source under the validated output directory" >&2; exit 1; }
grep -Fqx "$SOURCE_TRAP_OUTPUT_DIR/.lucairn-production-values.XXXXXX|600" "$SOURCE_TRAP_CALL_LOG" \
  || { echo "production renderer did not create its hidden 0600 stage under the validated output directory" >&2; exit 1; }
assert_no_source_overlay "$UNSAFE_TMPDIR"
assert_no_staged_overlay "$UNSAFE_TMPDIR"
ruby -ryaml -e '
  values = YAML.load_file(ARGV.fetch(0))
  abort "source replacement reached the published overlay" if values.dig("global", "dsaServiceToken") == "attacker-substituted-token"
  abort "published overlay lacks canonical generated credentials" unless values.dig("global", "dsaServiceToken").is_a?(String) && !values.dig("global", "dsaServiceToken").empty?
' "$SOURCE_TRAP_OUTPUT"
assert_no_source_overlay "$TMPDIR"
assert_no_staged_overlay "$TMPDIR"

# A syntactically valid but short stage write must not publish. RUBYOPT scopes
# the fault to the staging inode and makes File#write return the short byte
# count it actually wrote, without adding a production-only renderer switch.
SHORT_WRITE_PATCH="$TMPDIR/short-stage-write.rb"
cat > "$SHORT_WRITE_PATCH" <<'RUBY'
class File
  alias_method :production_overlay_original_write, :write

  def write(data, *args)
    if ENV["PRODUCTION_OVERLAY_SHORT_STAGE_WRITE"] == "1" && path.include?(".lucairn-production-values.")
      return production_overlay_original_write("---\nglobal: {}\n", *args)
    end
    production_overlay_original_write(data, *args)
  end
end
RUBY
SHORT_WRITE_OUTPUT="$TMPDIR/short-write-values.yaml"
SHORT_WRITE_TMPDIR="$TMPDIR/short-write-tmp"
mkdir "$SHORT_WRITE_TMPDIR"
if TMPDIR="$SHORT_WRITE_TMPDIR" PRODUCTION_OVERLAY_SHORT_STAGE_WRITE=1 RUBYOPT="-r$SHORT_WRITE_PATCH" bash "$ROOT/scripts/render-production-values.sh" "$SHORT_WRITE_OUTPUT" >/dev/null 2>&1; then
  echo "production renderer accepted a syntactically valid short stage write" >&2
  exit 1
fi
[ ! -e "$SHORT_WRITE_OUTPUT" ] && [ ! -L "$SHORT_WRITE_OUTPUT" ] \
  || { echo "production renderer published output after a short stage write" >&2; exit 1; }
assert_no_staged_overlay "$TMPDIR"
assert_no_source_overlay "$TMPDIR"
assert_no_source_overlay "$SHORT_WRITE_TMPDIR"
assert_no_staged_overlay "$SHORT_WRITE_TMPDIR"

# Replacing the mktemp-created stage with a symlink must fail at the NOFOLLOW
# open, leave the replacement target untouched, and publish nothing.
STAGE_REPLACEMENT_TARGET="$TMPDIR/stage-replacement-sentinel.yaml"
printf '%s\n' 'stage-replacement-sentinel' > "$STAGE_REPLACEMENT_TARGET"
STAGE_REPLACE_SHIM_DIR="$TMPDIR/stage-replace-bin"
REAL_MKTEMP="$(command -v mktemp)"
mkdir "$STAGE_REPLACE_SHIM_DIR"
cat > "$STAGE_REPLACE_SHIM_DIR/mktemp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
path="\$("$REAL_MKTEMP" "\$@")"
case "\${1:-}" in
  */.lucairn-production-values.XXXXXX)
    rm -f -- "\$path"
    ln -s "\$STAGE_REPLACEMENT_TARGET" "\$path"
    ;;
esac
printf '%s\\n' "\$path"
EOF
chmod 700 "$STAGE_REPLACE_SHIM_DIR/mktemp"
STAGE_REPLACEMENT_OUTPUT="$TMPDIR/stage-replacement-values.yaml"
STAGE_REPLACEMENT_TMPDIR="$TMPDIR/stage-replacement-tmp"
mkdir "$STAGE_REPLACEMENT_TMPDIR"
if TMPDIR="$STAGE_REPLACEMENT_TMPDIR" PATH="$STAGE_REPLACE_SHIM_DIR:$PATH" bash "$ROOT/scripts/render-production-values.sh" "$STAGE_REPLACEMENT_OUTPUT" >/dev/null 2>&1; then
  echo "production renderer accepted a replaced staging path" >&2
  exit 1
fi
[ "$(<"$STAGE_REPLACEMENT_TARGET")" = 'stage-replacement-sentinel' ] \
  || { echo "production renderer wrote secrets through a replaced staging path" >&2; exit 1; }
[ ! -e "$STAGE_REPLACEMENT_OUTPUT" ] && [ ! -L "$STAGE_REPLACEMENT_OUTPUT" ] \
  || { echo "production renderer published output after staging-path replacement" >&2; exit 1; }
assert_no_staged_overlay "$TMPDIR"
assert_no_source_overlay "$TMPDIR"
assert_no_source_overlay "$STAGE_REPLACEMENT_TMPDIR"
assert_no_staged_overlay "$STAGE_REPLACEMENT_TMPDIR"

# The renderer refuses customer-controlled group/world-writable parents before
# it calls the canonical secret generator, and leaves no temporary material.
OPENSSL_SHIM_DIR="$TMPDIR/unsafe-directory-bin"
OPENSSL_CALL_LOG="$TMPDIR/unsafe-directory-openssl-called"
mkdir "$OPENSSL_SHIM_DIR"
cat > "$OPENSSL_SHIM_DIR/openssl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' called > "$OPENSSL_CALL_LOG"
exit 99
EOF
chmod 700 "$OPENSSL_SHIM_DIR/openssl"
for unsafe_mode in 770 707; do
  UNSAFE_DIR="$TMPDIR/unsafe-output-$unsafe_mode"
  mkdir "$UNSAFE_DIR"
  chmod "$unsafe_mode" "$UNSAFE_DIR"
  if OPENSSL_CALL_LOG="$OPENSSL_CALL_LOG" PATH="$OPENSSL_SHIM_DIR:$PATH" bash "$ROOT/scripts/render-production-values.sh" "$UNSAFE_DIR/values.yaml" >/dev/null 2>&1; then
    echo "production renderer accepted unsafe output directory mode $unsafe_mode" >&2
    exit 1
  fi
  [ ! -e "$OPENSSL_CALL_LOG" ] \
    || { echo "production renderer generated secrets before rejecting unsafe directory mode $unsafe_mode" >&2; exit 1; }
  assert_no_staged_overlay "$UNSAFE_DIR"
  assert_no_source_overlay "$UNSAFE_DIR"
done

# File.link is the non-replacing publication primitive. Simulate a destination
# racing into existence just before that call; it must stay untouched and the
# now-unpublished staging file must still be cleaned.
PUBLISH_SHIM_DIR="$TMPDIR/publish-race-bin"
mkdir "$PUBLISH_SHIM_DIR"
REAL_RUBY="$(command -v ruby)"
cat > "$PUBLISH_SHIM_DIR/ruby" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-e" ] && [ "\$#" -eq 6 ]; then
  printf '%s\\n' 'raced-destination-sentinel' > "\$4"
  exit 1
fi
exec "$REAL_RUBY" "\$@"
EOF
chmod 700 "$PUBLISH_SHIM_DIR/ruby"
RACED_OUTPUT="$TMPDIR/raced-values.yaml"
PUBLISH_RACE_TMPDIR="$TMPDIR/publish-race-tmp"
mkdir "$PUBLISH_RACE_TMPDIR"
if TMPDIR="$PUBLISH_RACE_TMPDIR" PATH="$PUBLISH_SHIM_DIR:$PATH" bash "$ROOT/scripts/render-production-values.sh" "$RACED_OUTPUT" >/dev/null 2>&1; then
  echo "production renderer unexpectedly survived publication race" >&2
  exit 1
fi
[ "$(<"$RACED_OUTPUT")" = 'raced-destination-sentinel' ] \
  || { echo "production renderer changed raced destination sentinel" >&2; exit 1; }
assert_no_staged_overlay "$TMPDIR"
assert_no_source_overlay "$TMPDIR"
assert_no_source_overlay "$PUBLISH_RACE_TMPDIR"
assert_no_staged_overlay "$PUBLISH_RACE_TMPDIR"

# The application overlay is a strict allowlist at global scope. It must not
# carry parent-owned production controls even if the development template gains
# new controls later.
ruby -ryaml -e '
  overlay = YAML.load_file(ARGV.fetch(0))
  global = overlay.fetch("global")
  allowed = %w[
    dsaServiceToken dsaLicenseKey lucairnLicenseKey lucairnLicensePublicKey
    imageRegistry imageTag imagePullSecrets imagePullDockerConfigJson
  ].sort
  abort "production overlay contains parent-owned global keys: #{(global.keys.sort - allowed).join(", ")}" unless global.keys.sort == allowed
  abort "production overlay must not restate the parent demo topology" if overlay.key?("demo")
  %w[dsaEnv mtls dnsRestriction nodeIsolation postgresqlSslmode wireguardEncryption secrets].each do |key|
    abort "production overlay contains parent-owned global.#{key}" if global.key?(key)
  end
' "$OVERLAY"

# Model Helm's ordered value merge to prove the production security posture is
# retained before checking the concrete rendered runtime contract below.
ruby -ryaml -e '
  merge = lambda do |left, right|
    left.merge(right) do |_key, old, new|
      old.is_a?(Hash) && new.is_a?(Hash) ? merge.call(old, new) : new
    end
  end
  defaults, production, overlay = ARGV.map { |path| YAML.load_file(path) }
  effective = merge.call(merge.call(defaults, production), overlay).fetch("global")
  expected = {
    "dsaEnv" => "production",
    "dnsRestriction" => true,
    "nodeIsolation" => true,
    "postgresqlSslmode" => "require",
    "wireguardEncryption" => true,
  }
  expected.each { |key, value| abort "effective global.#{key} lost its production posture" unless effective[key] == value }
  abort "effective global.mtls.enabled is not true" unless effective.dig("mtls", "enabled") == true
' "$CHART/values.yaml" "$CHART/values-prod.yaml" "$OVERLAY"

# The exact documented pair is production first, application-only overlay
# second. skipPullSecretGuard is test-only; the documented command supplies
# the registry config with --set-file instead.
helm template lucairn "$CHART" \
  -f "$CHART/values-prod.yaml" \
  -f "$OVERLAY" \
  --set global.skipPullSecretGuard=true > "$RENDER"

# Preserve the doctor regression for the same ordered pair operators use.
"$ROOT/bin/lucairn" doctor \
  --values "$CHART/values-prod.yaml" \
  --values "$OVERLAY" \
  --offline > "$TMPDIR/doctor.out"
grep -Fq 'enterprise mTLS (Helm): production render contract: ok' "$TMPDIR/doctor.out" \
  || { echo "doctor did not accept the documented production values pair" >&2; exit 1; }

for config in gateway audit id-bridge sandbox-a sandbox-b; do
  block="$(awk -v name="$config-config" '
    /^kind: ConfigMap$/{in_block=1; block=""}
    in_block{block=block $0 "\n"}
    in_block && $0 == "  name: " name {matched=1}
    /^---$/{if (matched) {print block; exit} in_block=0; matched=0}
    END{if (matched) print block}
  ' "$RENDER")"
  [ -n "$block" ] || { echo "production render misses $config ConfigMap" >&2; exit 1; }
  grep -Fq 'DSA_ENV: "production"' <<<"$block" \
    || { echo "$config is not rendered with DSA_ENV=production" >&2; exit 1; }
  grep -Fq 'DSA_MTLS_CA_BUNDLE_PATH: "/var/run/lucairn/mtls/ca.crt"' <<<"$block" \
    || { echo "$config lacks the production mTLS CA path" >&2; exit 1; }
done

for key in \
  DSA_MTLS_CA_BUNDLE_PATH \
  DSA_MTLS_SERVER_CERT_PATH \
  DSA_MTLS_SERVER_KEY_PATH \
  DSA_MTLS_CLIENT_CERT_PATH \
  DSA_MTLS_CLIENT_KEY_PATH; do
  grep -Fq "$key" "$RENDER" \
    || { echo "production render lacks $key" >&2; exit 1; }
done

echo "enterprise mTLS production overlay: documented ordered render and doctor contract are production and mTLS-on"
