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
