#!/usr/bin/env bash
set -euo pipefail

# WP1 S4 / C3 / G3: Sandbox A's boot setting is a Helm string contract, not a
# service-default inference. This bounded suite keeps that contract explicit
# across direct child-chart use, every supported umbrella profile, production
# streaming policy, and the customer Compose surface.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
CHILD_CHART="$CHART/charts/sandbox-a"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
TEST_SIGNING_KEY="1111111111111111111111111111111111111111111111111111111111111111"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "WP1 S4 Helm boundary: ERROR — $1 is required" >&2
    exit 2
  }
}

require_command helm
require_command ruby

cat >"$TMPDIR/direct-valid.yaml" <<'YAML'
ephemeral: "true"
global:
  imageRegistry: ""
  imageTag: "0.5.4"
  imagePullSecrets: []
  postgresqlSslmode: disable
  dsaServiceToken: ""
  dsaEnv: development
  l3Required: false
  nodeIsolation: false
  mtls:
    enabled: false
YAML

# Profile overlays are intentionally independent Helm files, so Helm's normal
# coalescing cannot tell a missing selected-profile value from a base default.
# Assert the explicit checked-in declaration before rendering each profile.
ruby -ryaml -e '
  def load_yaml(path)
    YAML.load_file(path, aliases: true)
  rescue ArgumentError
    YAML.load_file(path)
  end

  expected = {
    "values.yaml" => "true",
    "values-dev.yaml" => "true",
    "values-test.yaml" => "true",
    "values-proof.yaml" => "true",
    "values-trainer.yaml" => "true",
    "values-prod.yaml" => "true"
  }
  root = ARGV.fetch(0)
  expected.each do |name, value|
    actual = load_yaml(File.join(root, name)).dig("sandbox-a", "ephemeral")
    abort "#{name} must explicitly set sandbox-a.ephemeral as the YAML string #{value.inspect}; got #{actual.inspect}" unless actual == value
  end
' "$CHART"

render_nonproduction_profile() {
  local name="$1"
  shift
  helm lint "$CHART" "$@" \
    --set global.skipPullSecretGuard=true \
    --set-string "veil-witness.secrets.values.signingKey=$TEST_SIGNING_KEY" \
    >"$TMPDIR/lint-$name.out"
  helm template lucairn "$CHART" "$@" \
    --set global.skipPullSecretGuard=true \
    --set-string "veil-witness.secrets.values.signingKey=$TEST_SIGNING_KEY" \
    >"$TMPDIR/render-$name.yaml"
}

render_nonproduction_profile base
render_nonproduction_profile development -f "$CHART/values-dev.yaml"
render_nonproduction_profile test -f "$CHART/values-test.yaml"
render_nonproduction_profile proof -f "$CHART/values-proof.yaml"
render_nonproduction_profile trainer -f "$CHART/values-trainer.yaml"

# The checked-in site example supplies only names-and-paths configuration, so
# it is the canonical non-secret fixture for the supported production render.
helm lint "$CHART" -f "$CHART/values-prod.yaml" -f "$CHART/values-prod-site.example.yaml" \
  >"$TMPDIR/lint-production.out"
helm template lucairn "$CHART" -f "$CHART/values-prod.yaml" -f "$CHART/values-prod-site.example.yaml" \
  >"$TMPDIR/render-production.yaml"

# Direct child-chart lint/template must also pass with an explicit value; the
# child intentionally has no implicit default for this required boot input.
helm lint "$CHILD_CHART" -f "$TMPDIR/direct-valid.yaml" >"$TMPDIR/lint-direct.out"
helm template sandbox-a "$CHILD_CHART" -f "$TMPDIR/direct-valid.yaml" >"$TMPDIR/render-direct.yaml"

# Verify the real sandbox-a container consumes the ConfigMap key, and preserve
# the startup/readiness contract that the Kind readiness gate will exercise.
ruby -ryaml -e '
  documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  named = lambda do |kind, name|
    documents.find { |document| document["kind"] == kind && document.dig("metadata", "name") == name } \
      || abort("production render misses #{kind}/#{name}")
  end
  config = named.call("ConfigMap", "sandbox-a-config").fetch("data")
  abort "Sandbox A ConfigMap must set SANDBOX_A_EPHEMERAL=\\\"true\\\"" unless config["SANDBOX_A_EPHEMERAL"] == "true"
  deployment = named.call("Deployment", "sandbox-a")
  container = deployment.dig("spec", "template", "spec", "containers").find { |item| item["name"] == "sandbox-a" } \
    || abort("production Sandbox A deployment misses the sandbox-a container")
  ephemeral = container.fetch("env").find { |item| item["name"] == "SANDBOX_A_EPHEMERAL" }
  expected_env = {
    "name" => "SANDBOX_A_EPHEMERAL",
    "valueFrom" => {
      "configMapKeyRef" => {
        "name" => "sandbox-a-config",
        "key" => "SANDBOX_A_EPHEMERAL"
      }
    }
  }
  abort "Sandbox A SANDBOX_A_EPHEMERAL must use the sandbox-a ConfigMap key" unless ephemeral == expected_env
  expected_probes = {
    "startupProbe" => { "path" => "/healthz", "initialDelaySeconds" => 5, "periodSeconds" => 5, "timeoutSeconds" => 5, "failureThreshold" => 30 },
    "readinessProbe" => { "path" => "/readyz", "initialDelaySeconds" => 10, "periodSeconds" => 10, "timeoutSeconds" => 5, "failureThreshold" => 3 }
  }
  expected_probes.each do |name, expected|
    probe = container.fetch(name)
    abort "Sandbox A #{name} must be an HTTP probe" unless probe.key?("httpGet")
    abort "Sandbox A #{name} endpoint drift" unless probe.fetch("httpGet") == { "path" => expected.fetch("path"), "port" => "health" }
    expected.reject { |key, _| key == "path" }.each do |key, value|
      abort "Sandbox A #{name} #{key} drift" unless probe[key] == value
    end
  end
' "$TMPDIR/render-production.yaml"

assert_rejected() {
  local name="$1"
  local expected="$2"
  shift 2
  if "$@" >"$TMPDIR/$name.out" 2>&1; then
    echo "WP1 S4 Helm boundary: accepted invalid $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$TMPDIR/$name.out" || {
    echo "WP1 S4 Helm boundary: $name did not produce the stable schema error: $expected" >&2
    cat "$TMPDIR/$name.out" >&2
    exit 1
  }
}

write_direct_invalid() {
  local value="$1"
  {
    [ "$value" = '__MISSING__' ] || printf 'ephemeral: %s\n' "$value"
    tail -n +2 "$TMPDIR/direct-valid.yaml"
  } >"$TMPDIR/direct-invalid.yaml"
}

write_direct_invalid '__MISSING__'
assert_rejected direct-missing "missing property 'ephemeral'" \
  helm template sandbox-a "$CHILD_CHART" -f "$TMPDIR/direct-invalid.yaml"

invalid_value() {
  case "$1" in
    boolean) printf 'true' ;;
    null) printf 'null' ;;
    typo) printf '"yes"' ;;
    number) printf '1' ;;
    list) printf '[]' ;;
    map) printf '{}' ;;
    *) echo "unknown invalid value shape: $1" >&2; exit 2 ;;
  esac
}

schema_error() {
  case "$1" in
    boolean) printf 'got boolean, want string' ;;
    null) printf 'got null, want string' ;;
    typo) printf "value must be one of 'true', 'false'" ;;
    number) printf 'got number, want string' ;;
    list) printf 'got array, want string' ;;
    map) printf 'got object, want string' ;;
    *) echo "unknown schema error shape: $1" >&2; exit 2 ;;
  esac
}

for shape in boolean null typo number list map; do
  write_direct_invalid "$(invalid_value "$shape")"
  assert_rejected "direct-$shape" "$(schema_error "$shape")" \
    helm template sandbox-a "$CHILD_CHART" -f "$TMPDIR/direct-invalid.yaml"
done

# The umbrella path must be equally fail-closed for every value that can
# override the explicit base. Missing is covered by the direct child schema;
# an omitted profile key is checked explicitly above because Helm merges it
# with the required base declaration before schema validation.
for shape in boolean null typo number list map; do
  cat >"$TMPDIR/umbrella-invalid.yaml" <<YAML
sandbox-a:
  ephemeral: $(invalid_value "$shape")
YAML
  assert_rejected "umbrella-$shape" "$(schema_error "$shape")" \
    helm template lucairn "$CHART" \
      -f "$CHART/values-prod.yaml" \
      -f "$CHART/values-prod-site.example.yaml" \
      -f "$TMPDIR/umbrella-invalid.yaml"
done

# Customer Compose is a static render boundary, not a runtime deployment. In
# constrained test environments Docker Compose can be unavailable; when it is
# present, use Compose itself (with STREAMING_ENABLED intentionally absent) and
# assert exact production parity with the accepted Helm production render.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  cat >"$TMPDIR/customer-compose.env" <<'ENV'
DSA_ENV=production
DSA_SERVICE_TOKEN=test-service-token
AUDIT_APP_PASSWORD=test-audit-app-password
BUILD_AUTH_TOKEN=test-build-auth-token
CANARY_HMAC_KEY=test-canary-hmac-key
CUSTOMER_KEY_ID=test-customer-key-id
DSA_BRIDGE_ENCRYPTION_KEY=test-bridge-encryption-key
GATEWAY_KEYSTORE_KEY=dGVzdC1rZXlzdG9yZS1rZXktMzItYnl0ZXMtbG9uZw==
PORTAL_API_KEY=test-portal-api-key
POSTGRES_AUDIT_PASSWORD=test-postgres-audit-password
POSTGRES_BRIDGE_PASSWORD=test-postgres-bridge-password
POSTGRES_SANDBOX_A_PASSWORD=test-postgres-sandbox-a-password
POSTGRES_VEIL_PASSWORD=test-postgres-veil-password
VEIL_APP_PASSWORD=test-veil-app-password
LCR_GATEWAY_SIGNING_KEY=test-gateway-signing-key
DSA_LICENSE_KEY=
DSA_LICENSE_SIGNING_KEY=
LUCAIRN_LICENSE_KEY=
LUCAIRN_LICENSE_PUBLIC_KEY=
ENV
  env -u STREAMING_ENABLED docker compose \
    --env-file "$TMPDIR/customer-compose.env" \
    -f "$ROOT/docker-compose.customer.yml" \
    config >"$TMPDIR/customer-compose.rendered.yaml"
  ruby -ryaml -e '
    compose = YAML.load_file(ARGV.fetch(0))
    gateway = compose.fetch("services").fetch("gateway").fetch("environment")
    abort "customer Compose Gateway must render STREAMING_ENABLED=false when unset" unless gateway.fetch("STREAMING_ENABLED") == "false"
    documents = YAML.load_stream(File.read(ARGV.fetch(1))).compact
    deployment = documents.find { |document| document["kind"] == "Deployment" && document.dig("metadata", "name") == "gateway" } \
      || abort("production Helm render misses Gateway deployment")
    container = deployment.dig("spec", "template", "spec", "containers").find { |item| item["name"] == "gateway" } \
      || abort("production Helm render misses Gateway container")
    helm_value = container.fetch("env").find { |item| item["name"] == "STREAMING_ENABLED" }.fetch("value")
    abort "production Helm Gateway must render STREAMING_ENABLED=false" unless helm_value == "false"
    abort "customer Compose and production Helm streaming policies diverge" unless gateway.fetch("STREAMING_ENABLED") == helm_value
  ' "$TMPDIR/customer-compose.rendered.yaml" "$TMPDIR/render-production.yaml"
else
  echo "WP1 S4 Helm boundary: SKIP customer Compose render (docker compose unavailable)" >&2
fi

echo "WP1 S4 Helm/Compose Sandbox A boundary: ok"
