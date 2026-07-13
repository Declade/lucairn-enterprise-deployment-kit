#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
VALUES="$CHART/values-prod.yaml"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if ! command -v helm >/dev/null 2>&1; then
  echo "enterprise mTLS production values: ERROR — Helm CLI is required; install Helm and rerun make test." >&2
  exit 2
fi

[ ! -e "$ROOT/scripts/render-production-values.sh" ] \
  || { echo "production secret renderer must be deleted" >&2; exit 1; }
if rg -n 'render-production-values\.sh|customer-production-values\.yaml' \
  "$ROOT/INSTALL.md" "$ROOT/OPS.md" "$ROOT/TROUBLESHOOTING.md" \
  "$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md" "$ROOT/Makefile" "$ROOT/scripts"; then
  echo "production path still refers to a generated secret-bearing values file" >&2
  exit 1
fi

# Production values are a names-and-paths-only External Secrets overlay. The
# default topology must never fall back to k8s-native secret values or a global
# backend inference, and registry config is never a Helm value.
ruby -ryaml -e '
  values = YAML.load_file(ARGV.fetch(0))
  global = values.fetch("global")
  abort "production pull-secret guard must be explicitly bypassed for out-of-band auth" unless global["skipPullSecretGuard"] == true
  abort "production imagePullSecrets must default to an empty out-of-band list" unless global["imagePullSecrets"] == []
  abort "production values carry Docker registry credentials" if global.key?("imagePullDockerConfigJson")
  abort "production global External Secrets backend is not Vault" unless global.dig("secrets", "backend") == "vault"
  %w[admin observability ingest].each do |child|
    service = values.fetch(child)
    abort "production #{child} must be explicitly disabled" unless service["enabled"] == false
    abort "production #{child} carries inline application values" if service.dig("secrets", "values")
  end
  %w[gateway audit id-bridge sandbox-a sandbox-b veil-witness].each do |child|
    secrets = values.fetch(child).fetch("secrets")
    abort "#{child} relies on global backend inference" unless secrets["backend"] == "vault"
    path = secrets.dig("vault", "path")
    abort "#{child} has no explicit Vault remote path" unless path.is_a?(String) && !path.empty?
    abort "#{child} carries inline application values" if secrets.key?("values")
  end
' "$VALUES"

# Every generated ExternalSecret must cover the credential keys consumed by its
# default-topology Pods or mandatory Jobs. The list is deliberately explicit:
# adding a new required secretKeyRef must update this test and the ESO mapping.
ruby -e '
  root = ARGV.fetch(0)
  required = {
    "gateway" => %w[DSA_LICENSE_KEY DSA_LICENSE_SIGNING_KEY LUCAIRN_LICENSE_KEY LUCAIRN_LICENSE_PUBLIC_KEY DSA_ADMIN_KEY SANDBOX_B_API_KEY LCR_MANIFEST_SIGNING_KEY LCR_GATEWAY_SIGNING_KEY LCR_GATEWAY_PUBLIC_KEY LCR_GATEWAY_MANIFEST_PUBLIC_KEY LCR_WITNESS_MANIFEST_PUBLIC_KEY LCR_WITNESS_PUBLIC_KEY LCR_BRIDGE_PUBLIC_KEY LCR_SANITIZER_PUBLIC_KEY LCR_SANDBOX_B_PUBLIC_KEY LCR_AUDIT_PUBLIC_KEY LCR_AI_SIGNING_KEY DSA_SERVICE_TOKEN GATEWAY_KEYSTORE_KEY CANARY_HMAC_KEY],
    "audit" => %w[DATABASE_URL DATABASE_URL_APP POSTGRES_PASSWORD AUDIT_APP_PASSWORD LCR_SIGNING_KEY DSA_SERVICE_TOKEN],
    "id-bridge" => %w[DATABASE_URL POSTGRES_PASSWORD MASTER_KEY LCR_SIGNING_KEY DSA_BRIDGE_ENCRYPTION_KEY DSA_SERVICE_TOKEN],
    "sandbox-a" => %w[DATABASE_URL POSTGRES_PASSWORD ENCRYPTION_KEY DSA_ADMIN_KEY LCR_SIGNING_KEY DSA_SERVICE_TOKEN CANARY_HMAC_KEY MODEL_AUTH_SECRET],
    "sandbox-b" => %w[SANDBOX_B_REDIS_URL REDIS_PASSWORD ANTHROPIC_API_KEY MISTRAL_API_KEY OPENAI_API_KEY GEMINI_API_KEY LCR_SIGNING_KEY SANDBOX_B_API_KEYS DSA_ADMIN_KEY DSA_MANAGED_AI_KEY DSA_SERVICE_TOKEN DSA_LICENSE_KEY],
    "veil-witness" => %w[DATABASE_URL DATABASE_URL_APP POSTGRES_PASSWORD VEIL_APP_PASSWORD LCR_WITNESS_SIGNING_KEY LCR_WITNESS_KEY_ID],
  }
  required.each do |child, keys|
    source = File.read(File.join(root, "charts/lucairn/charts/#{child}/templates/externalsecret.yaml"))
    actual = source.scan(/^\s*- secretKey: ([A-Z0-9_]+)$/).flatten
    missing = keys - actual
    abort "#{child} ExternalSecret misses required keys: #{missing.join(", ")}" unless missing.empty?
    abort "#{child} ExternalSecret has no remoteRef mappings" unless source.include?("remoteRef:")
  end
' "$ROOT"

RENDER="$TMPDIR/rendered.yaml"
helm template lucairn "$CHART" -f "$VALUES" --namespace lucairn > "$RENDER"
ruby -ryaml -e '
  release_namespace = "lucairn"
  required = %w[
    gateway-credentials audit-credentials id-bridge-credentials
    sandbox-a-credentials sandbox-b-credentials veil-witness-credentials
  ].sort
  documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  external_secrets = documents.map do |document|
    document.dig("metadata", "name") if document.is_a?(Hash) && document["kind"] == "ExternalSecret"
  end.compact.sort
  missing = required - external_secrets
  abort "production render misses mandatory ExternalSecrets: #{missing.join(", ")}" unless missing.empty?
  abort "production render must contain exactly six mandatory ExternalSecrets; got: #{external_secrets.join(", ")}" unless external_secrets == required

  secrets = documents.map do |document|
    if document.is_a?(Hash) && document["kind"] == "Secret"
      metadata = document.fetch("metadata", {})
      "#{metadata.fetch("namespace", release_namespace)}/#{metadata.fetch("name", "<unnamed>")}"
    end
  end.compact
  abort "production render contains Helm-owned Secret objects: #{secrets.join(", ")}" unless secrets.empty?
' "$RENDER"
if rg -n 'dockerconfigjson|imagePullDockerConfigJson' "$RENDER"; then
  echo "production render contains a Helm-owned registry credential" >&2
  exit 1
fi

"$ROOT/bin/lucairn" doctor --values "$VALUES" --offline > "$TMPDIR/doctor.out"
grep -Fq 'enterprise mTLS (Helm): production render contract: ok' "$TMPDIR/doctor.out" \
  || { echo "doctor did not accept the production External Secrets contract" >&2; exit 1; }

for required in 'External Secrets' 'global.skipPullSecretGuard=true' 'global.imagePullSecrets' \
  'node/default-ServiceAccount' 'workload identity' 'release history' \
  'every** enabled child’s `secrets.backend`'; do
  grep -Fq "$required" "$ROOT/INSTALL.md" \
    || { echo "production registry/ESO documentation omits: $required" >&2; exit 1; }
done

echo "enterprise mTLS production values: ESO-only names/paths contract and required-key coverage verified"
