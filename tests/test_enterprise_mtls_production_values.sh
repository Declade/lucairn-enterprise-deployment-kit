#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
VALUES="$CHART/values-prod.yaml"
SITE_VALUES="$CHART/values-prod-site.example.yaml"
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
  abort "production Vault mount path drifted" unless global.dig("secrets", "vault", "mountPath") == "dsa"
  expected_paths = {
    "gateway" => "gateway", "audit" => "postgres-audit", "id-bridge" => "bridge",
    "sandbox-a" => "sandbox-a", "sandbox-b" => "sandbox-b", "veil-witness" => "veil-witness"
  }
  %w[admin observability ingest].each do |child|
    service = values.fetch(child)
    abort "production #{child} must be explicitly disabled" unless service["enabled"] == false
    abort "production #{child} carries inline application values" if service.dig("secrets", "values")
  end
  %w[gateway audit id-bridge sandbox-a sandbox-b veil-witness].each do |child|
    secrets = values.fetch(child).fetch("secrets")
    abort "#{child} relies on global backend inference" unless secrets["backend"] == "vault"
    path = secrets.dig("vault", "path")
    abort "#{child} Vault remote path drifted" unless path == expected_paths.fetch(child)
    abort "#{child} carries inline application values" if secrets.key?("values")
  end
' "$VALUES"

# The checked-in production profile deliberately has no site endpoint. It is
# unusable until a names-and-paths-only site overlay supplies one.
if helm template lucairn "$CHART" -f "$VALUES" >"$TMPDIR/no-site.yaml" 2>"$TMPDIR/no-site.err"; then
  echo "production values rendered without a required site provider overlay" >&2
  exit 1
fi
grep -Fq 'global.secrets.vault.endpoint must be a non-empty HTTPS URL with a host' "$TMPDIR/no-site.err" \
  || { echo "empty production Vault endpoint was not rejected" >&2; exit 1; }

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
helm template lucairn "$CHART" -f "$VALUES" -f "$SITE_VALUES" --namespace lucairn > "$RENDER"
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
  store = documents.find { |document| document.is_a?(Hash) && document["kind"] == "ClusterSecretStore" && document.dig("metadata", "name") == "dsa-secret-store" }
  abort "production render misses dsa-secret-store" unless store
  abort "ClusterSecretStore Vault KV v2 mount drifted" unless store.dig("spec", "provider", "vault", "path") == "dsa"
  expected_keys = {
    "gateway-credentials" => "gateway", "audit-credentials" => "postgres-audit",
    "id-bridge-credentials" => "bridge", "sandbox-a-credentials" => "sandbox-a",
    "sandbox-b-credentials" => "sandbox-b", "veil-witness-credentials" => "veil-witness"
  }
  documents.select { |document| document.is_a?(Hash) && document["kind"] == "ExternalSecret" }.each do |document|
    name = document.dig("metadata", "name")
    next unless expected_keys.key?(name)
    keys = document.fetch("spec").fetch("data").map { |item| item.dig("remoteRef", "key") }.uniq
    abort "#{name} Vault key drifted: #{keys.inspect}" unless keys == [expected_keys.fetch(name)]
  end

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

if "$ROOT/bin/lucairn" doctor --values "$VALUES" --offline >"$TMPDIR/doctor-no-site.out" 2>&1; then
  echo "doctor accepted production values without a site provider overlay" >&2
  exit 1
fi
grep -Fq 'global.secrets.vault.endpoint must be a non-empty HTTPS URL with a host' "$TMPDIR/doctor-no-site.out" \
  || { echo "doctor did not expose the missing site endpoint" >&2; exit 1; }

"$ROOT/bin/lucairn" doctor --values "$VALUES" --values "$SITE_VALUES" --offline > "$TMPDIR/doctor.out"
grep -Fq 'enterprise mTLS (Helm): production render contract: ok' "$TMPDIR/doctor.out" \
  || { echo "doctor did not accept the production External Secrets contract" >&2; exit 1; }

assert_render_rejected() {
  local name="$1"
  local expected="$2"
  shift 2
  if helm template lucairn "$CHART" -f "$VALUES" -f "$SITE_VALUES" "$@" >"$TMPDIR/$name.yaml" 2>"$TMPDIR/$name.err"; then
    echo "production render accepted invalid provider configuration: $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$TMPDIR/$name.err" \
    || { echo "production $name rejection was not actionable" >&2; cat "$TMPDIR/$name.err" >&2; exit 1; }
}

assert_render_rejected malformed-vault-endpoint \
  'global.secrets.vault.endpoint must be a non-empty HTTPS URL with a host' \
  --set-string global.secrets.vault.endpoint=http://vault.example.internal
assert_render_rejected empty-vault-endpoint \
  'global.secrets.vault.endpoint must be a non-empty HTTPS URL with a host' \
  --set-string global.secrets.vault.endpoint=
assert_render_rejected invalid-global-backend \
  'global.secrets.backend must be exactly vault, aws, or azure' \
  --set-string global.secrets.backend=unsupported
assert_render_rejected mixed-child-backend \
  'audit.secrets.backend must equal global.secrets.backend (vault)' \
  --set-string audit.secrets.backend=aws
assert_render_rejected missing-selected-remote-reference \
  'gateway.secrets.vault.path must be a non-empty string' \
  --set-string gateway.secrets.vault.path=

# Provider-specific global configuration is validated only after every child
# selects that one provider, mirroring the single dsa-secret-store render.
provider_children=(
  --set global.secrets.backend=aws
  --set gateway.secrets.backend=aws --set audit.secrets.backend=aws
  --set id-bridge.secrets.backend=aws --set sandbox-a.secrets.backend=aws
  --set sandbox-b.secrets.backend=aws --set veil-witness.secrets.backend=aws
)
assert_render_rejected empty-aws-region \
  'global.secrets.aws.region must be a non-empty string' \
  "${provider_children[@]}" --set-string global.secrets.aws.region=
assert_render_rejected missing-aws-remote-reference \
  'gateway.secrets.aws.name must be a non-empty string' \
  "${provider_children[@]}" --set-string gateway.secrets.aws.name=
provider_children[1]=global.secrets.backend=azure
for index in 3 5 7 9 11 13; do
  provider_children[$index]="${provider_children[$index]%=aws}=azure"
done
assert_render_rejected empty-azure-key-vault \
  'global.secrets.azure.keyVaultName must be a non-empty string' \
  "${provider_children[@]}" --set-string global.secrets.azure.keyVaultName=
assert_render_rejected empty-azure-tenant \
  'global.secrets.azure.tenantId must be a non-empty string' \
  "${provider_children[@]}" --set-string global.secrets.azure.keyVaultName=customer-vault --set-string global.secrets.azure.tenantId=

for required in 'External Secrets' 'global.skipPullSecretGuard=true' 'global.imagePullSecrets' \
  'node-level registry auth' 'workload identity' 'release history' \
  'every** enabled child’s `secrets.backend`'; do
  grep -Fq "$required" "$ROOT/INSTALL.md" \
    || { echo "production registry/ESO documentation omits: $required" >&2; exit 1; }
done

# Mandatory workloads select chart-specific ServiceAccounts, so a pull Secret
# attached to default cannot authenticate them. Guidance must instead describe
# the two valid modes: a names-only PodSpec reference, or genuinely external
# node-level/workload-identity registry authentication.
ruby -e '
  root = ARGV.fetch(0)
  guidance = %w[
    charts/lucairn/values-prod.yaml
    docs/CUSTOMER_HELM_RUNBOOK.md
    INSTALL.md
  ]
  guidance.each do |path|
    content = File.read(File.join(root, path))
    content = content.gsub(/^\s*#\s?/, "")
    abort "#{path} still claims default-ServiceAccount registry auth" if content.match?(/(?:node\/)?default[- ]serviceaccount/i)
    abort "#{path} must describe pre-created names-only imagePullSecrets" unless content.match?(/pre-created pull Secret/i) && content.match?(/name(?:s)?[- ]only/i) && content.include?("global.imagePullSecrets")
    abort "#{path} must describe PodSpec pull-Secret attachment" unless content.match?(/chart-specific\s+workload\s+PodSpecs/im)
    abort "#{path} must limit empty imagePullSecrets to external registry auth" unless content.match?(/(?:leave|leaves).*imagePullSecrets.*empty.*only.*node-level.*workload identity.*outside Helm/im)
  end
' "$ROOT"

for document in "$ROOT/INSTALL.md" "$ROOT/OPS.md" "$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md"; do
  grep -Fq 'SITE_OVERLAY=/secure/operator/lucairn-production-site.yaml' "$document" \
    || { echo "production documentation omits the site overlay variable: $document" >&2; exit 1; }
  grep -Fq -- '--values "$SITE_OVERLAY"' "$document" \
    || { echo "production doctor documentation omits the ordered site overlay: $document" >&2; exit 1; }
  grep -Fq -- '-f "$SITE_OVERLAY"' "$document" \
    || { echo "production Helm documentation omits the ordered site overlay: $document" >&2; exit 1; }
done

# The first-customer flow must keep the provider key out of Helm values and
# curl argv. These are structural assertions over the narrow code block rather
# than an attempt to execute a Markdown shell program.
RUNBOOK="$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md"
if rg -n '\$OVERLAY' "$RUNBOOK"; then
  echo "production runbook still references the undefined OVERLAY variable" >&2
  exit 1
fi
for required in 'PROVIDER_KEY_FILE=/secure/operator/anthropic-provider-key' \
  'provider key file must be mode 0600' \
  'jq -n --rawfile provider_key "$PROVIDER_KEY_FILE"' \
  '--data-binary @-'; do
  grep -Fq -- "$required" "$RUNBOOK" \
    || { echo "production runbook omits protected provider-key flow: $required" >&2; exit 1; }
done
if rg -n -- '-d .*provider_key|--data .*provider_key|echo .*PROVIDER_KEY|echo .*ANTHROPIC' "$RUNBOOK"; then
  echo "production runbook may expose a provider key through curl argv or output" >&2
  exit 1
fi

echo "enterprise mTLS production values: ESO-only names/paths contract and required-key coverage verified"
