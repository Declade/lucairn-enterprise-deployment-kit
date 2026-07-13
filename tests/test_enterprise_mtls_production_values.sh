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
if grep -R -n -E 'render-production-values\.sh|customer-production-values\.yaml' \
  "$ROOT/INSTALL.md" "$ROOT/OPS.md" "$ROOT/TROUBLESHOOTING.md" \
  "$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md" "$ROOT/Makefile" "$ROOT/scripts"; then
  echo "production path still refers to a generated secret-bearing values file" >&2
  exit 1
fi

# Production values are a names-and-paths-only External Secrets overlay. The
# default topology must never fall back to k8s-native secret values or a global
# backend inference, and registry config is never a Helm value.
ruby -ryaml -e '
  values = (begin; YAML.load_file(ARGV.fetch(0), aliases: true); rescue ArgumentError; YAML.load_file(ARGV.fetch(0)); end)
  global = values.fetch("global")
  abort "production pull-secret guard must fail closed by default" unless global["skipPullSecretGuard"] == false
  abort "production imagePullSecrets must default to an empty list" unless global["imagePullSecrets"] == []
  abort "production values carry Docker registry credentials" if global.key?("imagePullDockerConfigJson")
  abort "production global External Secrets backend is not Vault" unless global.dig("secrets", "backend") == "vault"
  abort "production generic Cilium DNS restriction must be disabled" unless global["dnsRestriction"] == false
  abort "production generic node isolation must be disabled" unless global["nodeIsolation"] == false
  abort "production generic Cilium WireGuard must remain an opt-in" unless global["wireguardEncryption"] == false
  abort "production serviceToken custody placeholder must be an empty string" unless global["serviceToken"] == ""
  abort "production Vault mount path drifted" unless global.dig("secrets", "vault", "mountPath") == "dsa"
  expected_paths = {
    "gateway" => "gateway", "audit" => "postgres-audit", "id-bridge" => "bridge",
    "sandbox-a" => "sandbox-a", "sandbox-b" => "sandbox-b", "veil-witness" => "veil-witness"
  }
  %w[admin observability ingest].each do |child|
    service = values.fetch(child)
    abort "production #{child} must be explicitly disabled" unless service["enabled"] == false
    abort "production #{child} carries inline application values" unless service.dig("secrets", "values").nil?
  end
  %w[gateway audit id-bridge sandbox-a sandbox-b veil-witness].each do |child|
    secrets = values.fetch(child).fetch("secrets")
    abort "#{child} relies on global backend inference" unless secrets["backend"] == "vault"
    path = secrets.dig("vault", "path")
    abort "#{child} Vault remote path drifted" unless path == expected_paths.fetch(child)
  end
  expected_empty_values = {
    "audit" => %w[postgresPassword auditAppPassword],
    "id-bridge" => %w[postgresPassword],
    "sandbox-a" => %w[postgresPassword],
    "veil-witness" => %w[postgresPassword veilAppPassword signingKey keyId],
  }
  expected_empty_values.each do |child, fields|
    inline = values.fetch(child).fetch("secrets").fetch("values")
    abort "#{child} production values must keep a mapping" unless inline.is_a?(Hash)
    abort "#{child} production values must override only development placeholders" unless inline.keys.sort == fields.sort && inline.values.all? { |value| value == "" }
  end
  %w[gateway sandbox-b].each do |child|
    abort "#{child} production overlay must rely on its all-empty chart-default values map" if values.fetch(child).fetch("secrets").key?("values")
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

# The production base has a private registry and therefore also needs an
# explicit site decision: names-only pull-Secret references, or the narrowly
# scoped external-registry-auth escape hatch.
cat >"$TMPDIR/endpoint-only-site.yaml" <<'YAML'
global:
  secrets:
    vault:
      endpoint: "https://vault.example.internal"
YAML
if helm template lucairn "$CHART" -f "$VALUES" -f "$TMPDIR/endpoint-only-site.yaml" >"$TMPDIR/endpoint-only-site.yaml.rendered" 2>"$TMPDIR/endpoint-only-site.err"; then
  echo "production rendered with an endpoint-only site overlay and no registry auth decision" >&2
  exit 1
fi
grep -Fq 'global.imageRegistry="ghcr.io/declade" is a PRIVATE registry but global.imagePullSecrets is empty' "$TMPDIR/endpoint-only-site.err" \
  || { echo "endpoint-only production overlay did not expose the private-registry guard" >&2; cat "$TMPDIR/endpoint-only-site.err" >&2; exit 1; }

cat >"$TMPDIR/external-registry-auth-site.yaml" <<'YAML'
global:
  secrets:
    vault:
      endpoint: "https://vault.example.internal"
  imagePullSecrets: []
  skipPullSecretGuard: true
YAML
helm template lucairn "$CHART" -f "$VALUES" -f "$TMPDIR/external-registry-auth-site.yaml" >"$TMPDIR/external-registry-auth-site.yaml.rendered"

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
  identities = documents.group_by do |document|
    metadata = document.fetch("metadata", {})
    [document["apiVersion"], document["kind"], metadata.fetch("namespace", ""), metadata.fetch("name", "")]
  end
  duplicates = identities.select { |_identity, resources| resources.length > 1 }.keys
  abort "production render has duplicate Kubernetes identities: #{duplicates.inspect}" unless duplicates.empty?
  gateway = documents.find { |document| document.is_a?(Hash) && document["kind"] == "Deployment" && document.dig("metadata", "name") == "gateway" } || abort("production render misses gateway deployment")
  pull_secrets = gateway.dig("spec", "template", "spec", "imagePullSecrets")
  abort "checked-in production site example must attach its names-only pull Secret reference" unless pull_secrets == [{ "name" => "lucairn-registry" }]
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

  redis = documents.find { |document| document.is_a?(Hash) && document["kind"] == "StatefulSet" && document.dig("metadata", "name") == "sandbox-b-redis" } || abort("production render misses sandbox-b Redis StatefulSet")
  container = redis.dig("spec", "template", "spec", "containers")&.find { |item| item["name"] == "redis" } || abort("production Redis container missing")
  abort "external-backend Redis must require its Secret password" unless container.fetch("args").each_cons(2).any? { |pair| pair == ["--requirepass", "$(REDIS_PASSWORD)"] }
  password_env = container.fetch("env").find { |item| item["name"] == "REDIS_PASSWORD" }
  abort "external-backend Redis must reference REDIS_PASSWORD from its credentials Secret" unless password_env&.dig("valueFrom", "secretKeyRef") == { "name" => "sandbox-b-credentials", "key" => "REDIS_PASSWORD" }
  %w[livenessProbe readinessProbe].each do |probe|
    command = container.dig(probe, "exec", "command")
    abort "external-backend Redis #{probe} must authenticate with the runtime password variable" unless command == ["sh", "-c", "redis-cli -a $REDIS_PASSWORD --no-auth-warning ping"]
  end

  secrets = documents.map do |document|
    if document.is_a?(Hash) && document["kind"] == "Secret"
      metadata = document.fetch("metadata", {})
      "#{metadata.fetch("namespace", release_namespace)}/#{metadata.fetch("name", "<unnamed>")}"
    end
  end.compact
  abort "production render contains Helm-owned Secret objects: #{secrets.join(", ")}" unless secrets.empty?
  abort "generic production render contains CiliumNetworkPolicy resources" unless documents.none? { |document| document.is_a?(Hash) && document["kind"] == "CiliumNetworkPolicy" }
  %w[sandbox-a sandbox-b].each do |name|
    deployment = documents.find { |document| document.is_a?(Hash) && document["kind"] == "Deployment" && document.dig("metadata", "name") == name }
    abort "generic production render misses #{name} deployment" unless deployment
    abort "generic production render requires dsa.io/zone scheduling for #{name}" if deployment.dig("spec", "template", "spec").to_yaml.include?("dsa.io/zone")
  end
' "$RENDER"

# Cilium WireGuard remains a site-overlay opt-in. It annotates the canonical
# Namespace objects without creating a second object identity for any of the
# ten DSA namespaces.
WIREGUARD_RENDER="$TMPDIR/wireguard-rendered.yaml"
helm template lucairn "$CHART" -f "$VALUES" -f "$SITE_VALUES" \
  --set global.wireguardEncryption=true --namespace lucairn > "$WIREGUARD_RENDER"
ruby -ryaml -e '
  documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  identities = documents.group_by do |document|
    metadata = document.fetch("metadata", {})
    [document["apiVersion"], document["kind"], metadata.fetch("namespace", ""), metadata.fetch("name", "")]
  end
  duplicates = identities.select { |_identity, resources| resources.length > 1 }.keys
  abort "WireGuard render has duplicate Kubernetes identities: #{duplicates.inspect}" unless duplicates.empty?
  namespaces = documents.select { |document| document["apiVersion"] == "v1" && document["kind"] == "Namespace" }
  expected = %w[dsa-edge dsa-identity dsa-bridge dsa-ai dsa-audit dsa-observability dsa-ingest dsa-admin dsa-witness dsa-demo]
  abort "WireGuard render Namespace roster drifted" unless namespaces.map { |document| document.dig("metadata", "name") }.sort == expected.sort
  namespaces.each do |document|
    annotations = document.dig("metadata", "annotations")
    abort "WireGuard annotation missing from canonical Namespace #{document.dig("metadata", "name")}" unless annotations == {
      "helm.sh/resource-policy" => "keep", "io.cilium.network.wg-encryption" => "true"
    }
  end
' "$WIREGUARD_RENDER"
if grep -n -E 'dockerconfigjson|imagePullDockerConfigJson' "$RENDER"; then
  echo "production render contains a Helm-owned registry credential" >&2
  exit 1
fi

DEV_REDIS_RENDER="$TMPDIR/development-redis-no-password.yaml"
helm template lucairn "$CHART" \
  --set global.dsaEnv=development \
  --set global.skipPullSecretGuard=true \
  --set infrastructure.enabled=false \
  --set-string sandbox-b.redis.password= \
  --set sandbox-b.secrets.backend=k8s-native \
  --set veil-witness.secrets.values.signingKey=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  >"$DEV_REDIS_RENDER"
ruby -ryaml -e '
  documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  redis = documents.find { |document| document.is_a?(Hash) && document["kind"] == "StatefulSet" && document.dig("metadata", "name") == "sandbox-b-redis" } || abort("development render misses sandbox-b Redis StatefulSet")
  container = redis.dig("spec", "template", "spec", "containers")&.find { |item| item["name"] == "redis" } || abort("development Redis container missing")
  abort "k8s-native no-password Redis unexpectedly requires authentication" if container.fetch("args").include?("--requirepass")
  abort "k8s-native no-password Redis unexpectedly injects REDIS_PASSWORD" if container.fetch("env", []).any? { |item| item["name"] == "REDIS_PASSWORD" }
  %w[livenessProbe readinessProbe].each do |probe|
    command = container.dig(probe, "exec", "command")
    abort "k8s-native no-password Redis #{probe} must remain unauthenticated" unless command == ["sh", "-c", "redis-cli ping"]
  end
' "$DEV_REDIS_RENDER"

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
assert_render_rejected disabled-infrastructure \
  'infrastructure.enabled must be true when global.dsaEnv=production; it is mandatory for the verified default production mTLS topology.' \
  --set infrastructure.enabled=false

# Production retains real child values maps, then rejects every nonempty leaf
# so Helm never stores a credential in release history even though ESO owns
# the resulting Kubernetes Secret.
for child_field in \
  gateway.dsaServiceToken \
  audit.postgresPassword \
  id-bridge.postgresPassword \
  sandbox-a.postgresPassword \
  sandbox-b.anthropicApiKey \
  veil-witness.signingKey; do
  child="${child_field%.*}"
  field="${child_field##*.}"
  assert_render_rejected "inline-${child}-credential" \
    "${child}.secrets.values.${field} must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history" \
    --set-string "${child}.secrets.values.${field}=review-sentinel-not-a-secret"
done
assert_render_rejected inline-global-service-token \
  'global.dsaServiceToken must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' \
  --set-string global.dsaServiceToken=review-sentinel-not-a-secret
assert_render_rejected inline-sandbox-b-redis-password \
  'sandbox-b.redis.password must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' \
  --set-string sandbox-b.redis.password=review-sentinel-not-a-secret
assert_render_rejected typed-falsy-gateway-service-token \
  'gateway.secrets.values.dsaServiceToken must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' \
  --set gateway.secrets.values.dsaServiceToken=0
assert_render_rejected typed-falsy-audit-postgres-password \
  'audit.secrets.values.postgresPassword must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' \
  --set audit.secrets.values.postgresPassword=false
assert_render_rejected typed-falsy-global-dsa-service-token \
  'global.dsaServiceToken must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' \
  --set global.dsaServiceToken=0
assert_render_rejected typed-falsy-global-service-token \
  'global.serviceToken must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' \
  --set global.serviceToken=false
assert_render_rejected typed-falsy-sandbox-b-redis-password \
  'sandbox-b.redis.password must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' \
  --set sandbox-b.redis.password=false

# String-empty placeholders are the supported production custody values.
helm template lucairn "$CHART" -f "$VALUES" -f "$SITE_VALUES" \
  --set-string gateway.secrets.values.dsaServiceToken= \
  --set-string audit.secrets.values.postgresPassword= \
  --set-string global.dsaServiceToken= \
  --set-string global.serviceToken= \
  --set-string sandbox-b.redis.password= \
  >"$TMPDIR/string-empty-custody.yaml"

# Overlay files have exactly the same custody boundary as --set: Helm stores
# both in release values, so a sentinel in an operator overlay must fail.
cat >"$TMPDIR/inline-custody-override.yaml" <<'YAML'
gateway:
  secrets:
    values:
      dsaServiceToken: review-sentinel-not-a-secret
YAML
if helm template lucairn "$CHART" -f "$VALUES" -f "$SITE_VALUES" -f "$TMPDIR/inline-custody-override.yaml" >"$TMPDIR/inline-overlay.yaml" 2>"$TMPDIR/inline-overlay.err"; then
  echo "production render accepted an inline credential in an overlay file" >&2
  exit 1
fi
grep -Fq 'gateway.secrets.values.dsaServiceToken must be exactly the empty string when global.dsaEnv=production and External Secrets owns credentials. Helm persists supplied credential bytes in release history' "$TMPDIR/inline-overlay.err" \
  || { echo "production overlay credential rejection was not actionable" >&2; cat "$TMPDIR/inline-overlay.err" >&2; exit 1; }

helm template lucairn "$CHART" \
  --set global.dsaEnv=development \
  --set global.skipPullSecretGuard=true \
  --set infrastructure.enabled=false \
  --set veil-witness.secrets.values.signingKey=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  > "$TMPDIR/development-infrastructure-disabled.yaml"

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
assert_render_rejected missing-aws-service-account-name \
  'global.secrets.aws.serviceAccount.name must be a non-empty string' \
  "${provider_children[@]}" --set-string global.secrets.aws.serviceAccount.name=
assert_render_rejected missing-aws-service-account-namespace \
  'global.secrets.aws.serviceAccount.namespace must be a non-empty string' \
  "${provider_children[@]}" --set-string global.secrets.aws.serviceAccount.namespace=

AWS_RENDER="$TMPDIR/aws-rendered.yaml"
helm template lucairn "$CHART" -f "$VALUES" -f "$SITE_VALUES" --namespace lucairn \
  "${provider_children[@]}" > "$AWS_RENDER"
ruby -ryaml -e '
  documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  store = documents.find { |document| document.is_a?(Hash) && document["kind"] == "ClusterSecretStore" }
  abort "AWS production render must contain exactly one ClusterSecretStore" unless documents.count { |document| document.is_a?(Hash) && document["kind"] == "ClusterSecretStore" } == 1
  aws = store.dig("spec", "provider", "aws")
  abort "AWS store service drifted" unless aws["service"] == "SecretsManager"
  abort "AWS store region drifted" unless aws["region"] == "eu-central-1"
  ref = aws.dig("auth", "jwt", "serviceAccountRef")
  abort "AWS store ServiceAccount name drifted" unless ref["name"] == "eso-service-account"
  abort "AWS store ServiceAccount namespace drifted" unless ref["namespace"] == "external-secrets"
  abort "AWS production render must contain exactly six ExternalSecrets" unless documents.count { |document| document.is_a?(Hash) && document["kind"] == "ExternalSecret" } == 6
  abort "AWS production render contains Helm-owned Secrets" unless documents.none? { |document| document.is_a?(Hash) && document["kind"] == "Secret" }
' "$AWS_RENDER"
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
    charts/lucairn/values-prod-site.example.yaml
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
    obsolete_bypass_claims = [
      /skipPullSecretGuard\s*=\s*true\s*\(already in the production profile\)/i,
      /values-prod\.yaml\s+(?:sets|defaults? to)\s+`?global\.skipPullSecretGuard\s*(?:=|:)\s*true/i,
    ]
    abort "#{path} must not claim the registry escape hatch is already/defaulted in production" if obsolete_bypass_claims.any? { |claim| content.match?(claim) }
  end
' "$ROOT"

ruby -e '
  source = File.read(File.join(ARGV.fetch(0), "charts/lucairn/charts/gateway/templates/externalsecret.yaml"))
  required = {
    "LCR_GATEWAY_SIGNING_KEY" => "veilGatewaySigningKey",
    "LCR_GATEWAY_PUBLIC_KEY" => "veilGatewayPublicKey",
    "LCR_GATEWAY_MANIFEST_PUBLIC_KEY" => "veilGatewayManifestPublicKey",
    "LCR_WITNESS_MANIFEST_PUBLIC_KEY" => "veilWitnessManifestPublicKey",
  }
  required.each do |key, property|
    mapping = source[/^    - secretKey: #{Regexp.escape(key)}$(.*?)(?=^    - secretKey:|\z)/m]
    abort "gateway ExternalSecret lacks complete #{key} mapping" unless mapping&.include?("property: #{property}")
  end

  ops = File.read(File.join(ARGV.fetch(0), "OPS.md"))
  obsolete = [
    "Supported full-restore path is the bundled `k8s-native` values-overlay",
    "does **NOT** map four of the gateway-roster keys",
    "kubectl patch secret gateway-credentials",
    "Flip the gateway subchart to `k8s-native`",
  ]
  obsolete.each { |claim| abort "OPS retains obsolete ESO restore claim: #{claim}" if ops.include?(claim) }
  normalized_ops = ops.gsub(/^>\s?/, "").gsub(/\s+/, " ")
  ["The External Secrets path is the supported production restore path", "restore **every mapped property**", "let ESO own every materialized Secret", "Neither Helm nor ESO derives public keys", "ExternalSecret readiness", "well-known key-id checks"].each do |claim|
    abort "OPS omits supported ESO restore guidance: #{claim}" unless normalized_ops.include?(claim)
  end
' "$ROOT"

ruby -e '
  content = File.read(ARGV.fetch(0))
  abort "chart validator still claims default-ServiceAccount registry auth" if content.match?(/(?:node\/)?default[- ]serviceaccount/i)
  abort "chart validator still claims generic ServiceAccount-level pull-secret auth" if content.match?(/serviceaccount-level/i)
  abort "chart validator omits names-only pre-created pull-Secret guidance" unless content.match?(/names-only\s+global\.imagePullSecrets.*pre-created\s+pull\s+Secret/im)
  abort "chart validator omits external registry-auth guidance" unless content.match?(/true\s+node-level\s+registry\s+auth.*registry\s+workload\s+identity\s+outside\s+Helm/im)
' "$ROOT/charts/lucairn/templates/_validators.tpl"

for document in "$ROOT/INSTALL.md" "$ROOT/OPS.md" "$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md" "$ROOT/TROUBLESHOOTING.md"; do
  grep -Fq 'SITE_OVERLAY=/secure/operator/lucairn-production-site.yaml' "$document" \
    || { echo "production documentation omits the site overlay variable: $document" >&2; exit 1; }
  grep -Fq -- '--values "$SITE_OVERLAY"' "$document" \
    || { echo "production doctor documentation omits the ordered site overlay: $document" >&2; exit 1; }
  grep -Fq -- '-f "$SITE_OVERLAY"' "$document" \
    || { echo "production Helm documentation omits the ordered site overlay: $document" >&2; exit 1; }
done

# Troubleshooting's production recovery examples are executable shell blocks:
# every doctor/template/install invocation must define and order the mandatory
# site overlay after values-prod.yaml, including the certificate-error doctor.
ruby -e '
  content = File.read(ARGV.fetch(0))
  normalized = content.gsub(/\\\n/, " ")
  patterns = [
    /SITE_OVERLAY=\/secure\/operator\/lucairn-production-site\.yaml\s+bin\/lucairn doctor\s+--values charts\/lucairn\/values-prod\.yaml\s+--values "\$SITE_OVERLAY"\s+--offline/m,
    /helm template lucairn charts\/lucairn\s+-f charts\/lucairn\/values-prod\.yaml\s+-f "\$SITE_OVERLAY" >\/dev\/null/m,
    /helm upgrade --install lucairn charts\/lucairn\s+-f charts\/lucairn\/values-prod\.yaml\s+-f "\$SITE_OVERLAY"/m,
    /Production Helm uses the names-and-paths-only External Secrets profile\.\s+SITE_OVERLAY=\/secure\/operator\/lucairn-production-site\.yaml\s+bin\/lucairn doctor\s+--values charts\/lucairn\/values-prod\.yaml\s+--values "\$SITE_OVERLAY"\s+--offline/m
  ]
  patterns.each { |pattern| abort "TROUBLESHOOTING.md production command omits or misorders SITE_OVERLAY" unless normalized.match?(pattern) }
' "$ROOT/TROUBLESHOOTING.md"

# The first-customer flow must keep the provider key out of Helm values and
# curl argv. These are structural assertions over the narrow code block rather
# than an attempt to execute a Markdown shell program.
RUNBOOK="$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md"
if grep -n -E '\$OVERLAY' "$RUNBOOK"; then
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
for required in 'Cilium-only opt-in' 'ciliumnetworkpolicies.cilium.io' \
  'dsa.io/zone=identity' 'dsa.io/zone=ai' \
  'single-node pilot: the hardened topology requires' \
  'dsa.io/zone=identity:NoSchedule' 'dsa.io/zone=ai:NoSchedule'; do
  grep -Fq -- "$required" "$RUNBOOK" \
    || { echo "production runbook omits Cilium/node-isolation opt-in guidance: $required" >&2; exit 1; }
done
if grep -n -E -- '-d .*provider_key|--data .*provider_key|echo .*PROVIDER_KEY|echo .*ANTHROPIC' "$RUNBOOK"; then
  echo "production runbook may expose a provider key through curl argv or output" >&2
  exit 1
fi
ruby -e '
  content = File.read(ARGV.fetch(0))
  block = content[/## Step 8 — Mint your first customer.*?(?=\n---)/m]
  abort "first-customer runbook block missing" unless block
  abort "first-customer flow must frame the admin key through stdin" unless block.include?("IFS= read -r admin_key") && block.include?("printf")
  abort "first-customer flow must use stdin JSON body" unless block.include?("--data-binary @-")
  abort "first-customer flow interpolates ADMIN_KEY into kubectl/POD argv" if block.match?(/\$\{?ADMIN_KEY\}?/)
  admin_header = block[/x-admin-key:\s*[^\"\n]*/]
  abort "first-customer flow must construct its admin header only from the runtime stdin variable" unless admin_header == "x-admin-key: ${admin_key}"
  pinned = "curlimages/curl:8.10.1@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b"
  abort "first-customer flow must use exactly the reviewed pinned curl helper" unless block.scan(pinned).length == 1
  abort "first-customer flow must not use curlimages/curl:latest" if block.include?("curlimages/curl:latest")
  abort "first-customer flow must describe the helper as a fixed reviewed identity" unless block.include?("fixed, reviewed multi-architecture image identity")
' "$RUNBOOK"

echo "enterprise mTLS production values: ESO-only names/paths contract and required-key coverage verified"
