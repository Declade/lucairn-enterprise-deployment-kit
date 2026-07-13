#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
RUNTIME_VALUES="$TMPDIR/runtime-values.yaml"

if ! command -v helm >/dev/null 2>&1; then
  echo "enterprise mTLS Helm contract: SKIPPED — helm not installed"
  exit 0
fi

bash "$ROOT/scripts/generate-enterprise-mtls-kind-runtime-values.sh" "$RUNTIME_VALUES"

render() {
  helm template lucairn "$CHART" \
    -f "$CHART/values-prod.yaml" \
    -f "$RUNTIME_VALUES" \
    "$@"
}

RENDER="$TMPDIR/accepted.yaml"
render > "$RENDER"

# The accepted production values are layered over values.yaml. Every mandatory
# dependency must therefore resolve to the literal boolean true, and the
# production overlay must declare the witness explicitly: Helm otherwise
# treats an absent dependency condition as enabled, which is too ambiguous for
# the supported production topology. Keep the removal/false checks here so a
# future edit cannot silently rely on that Helm fallback.
ruby -ryaml -e '
  defaults = YAML.load_file(ARGV.fetch(0))
  production = YAML.load_file(ARGV.fetch(1))
  mandatory = %w[gateway audit id-bridge sandbox-a sandbox-b veil-witness]
  mandatory.each do |name|
    value = production.fetch(name, {}).fetch("enabled", defaults.fetch(name, {}).fetch("enabled", nil))
    abort "accepted production topology does not enable #{name}" unless value == true
  end
  witness = production.fetch("veil-witness", {})
  abort "accepted production overlay must explicitly set veil-witness.enabled=true" unless witness["enabled"] == true
' "$CHART/values.yaml" "$CHART/values-prod.yaml"

# An explicit false or an absent (null) witness condition must fail before
# Helm can use its legacy dependency-condition fallback.
for witness_value in false null; do
  witness_error="$TMPDIR/witness-enabled-${witness_value}.out"
  if render --set-json "veil-witness.enabled=${witness_value}" >"$witness_error" 2>&1; then
    echo "production render accepted veil-witness.enabled=${witness_value}" >&2
    exit 1
  fi
  grep -q 'veil-witness.enabled must be true when global.dsaEnv=production; it is mandatory for the verified default production mTLS topology.' "$witness_error" \
    || { echo "veil-witness.enabled=${witness_value} did not produce the mandatory-topology error" >&2; exit 1; }
done

# Kubelet HTTP probes cannot authenticate to the sanitizer's mTLS listener.
# Under production mTLS the sidecar must therefore run the read-only Python
# helper with the exact server SAN, CA, and client-leaf contract. Assert the
# rendered argv rather than matching loose YAML fragments. Assert the exact
# Python CRLF escape sequences before compiling the exact rendered helper:
# compilation alone accepts a helper that sends literal backslashes.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  named = lambda do |kind, name|
    docs.find { |doc| doc["kind"] == kind && doc.dig("metadata", "name") == name } || abort("render misses #{kind}/#{name}")
  end
  pod = named.call("Deployment", "sandbox-a").fetch("spec").fetch("template").fetch("spec")
  sanitizer = pod.fetch("containers").find { |item| item["name"] == "sanitizer" } || abort("sanitizer container missing")
  abort "sanitizer mTLS probe weakens its read-only root filesystem" unless sanitizer.dig("securityContext", "readOnlyRootFilesystem") == true
  expected = {
    "startupProbe" => ["python3", "/opt/lucairn/probes/sanitizer-mtls-probe.py", "/healthz"],
    "livenessProbe" => ["python3", "/opt/lucairn/probes/sanitizer-mtls-probe.py", "/healthz"],
    "readinessProbe" => ["python3", "/opt/lucairn/probes/sanitizer-mtls-probe.py", "/readyz"],
  }
  expected.each do |probe, command|
    value = sanitizer.fetch(probe)
    abort "sanitizer #{probe} renders plaintext httpGet under mTLS" if value.key?("httpGet")
    abort "sanitizer #{probe} argv mismatch" unless value.dig("exec", "command") == command
    abort "sanitizer #{probe} timeout must be bounded" unless value["timeoutSeconds"] == 5
  end
  mount = sanitizer.fetch("volumeMounts").find { |item| item["name"] == "sanitizer-mtls-probe" }
  abort "sanitizer mTLS probe mount is not read-only" unless mount == { "name" => "sanitizer-mtls-probe", "mountPath" => "/opt/lucairn/probes", "readOnly" => true }
  volume = pod.fetch("volumes").find { |item| item["name"] == "sanitizer-mtls-probe" }
  abort "sanitizer mTLS probe ConfigMap is not read-only" unless volume == { "name" => "sanitizer-mtls-probe", "configMap" => { "name" => "sanitizer-mtls-probe", "defaultMode" => 292 } }
  helper = named.call("ConfigMap", "sanitizer-mtls-probe").fetch("data").fetch("sanitizer-mtls-probe.py")
  %w[DSA_MTLS_CA_BUNDLE_PATH DSA_MTLS_CLIENT_CERT_PATH DSA_MTLS_CLIENT_KEY_PATH dsa-sanitizer /healthz /readyz].each do |required|
    abort "sanitizer mTLS helper lacks #{required}" unless helper.include?(required)
  end
  abort "sanitizer mTLS helper does not load the client leaf" unless helper.include?("load_cert_chain")
  abort "sanitizer mTLS helper does not require server verification" unless helper.include?("ssl.CERT_REQUIRED")
  abort "sanitizer mTLS helper does not verify the exact server SAN" unless helper.include?("server_hostname=\"dsa-sanitizer\"")
  abort "sanitizer mTLS helper accepts a non-2xx response" unless helper.include?("200 <= status < 300")
  ["\"GET {} HTTP/1.1\\r\\n\"", "\"Host: dsa-sanitizer\\r\\n\"", "\"Connection: close\\r\\n\\r\\n\"", "b\"\\r\\n\""].each do |framing|
    abort "sanitizer mTLS helper lacks single-escaped HTTP CRLF framing" unless helper.include?(framing)
  end
  abort "sanitizer mTLS helper has doubled HTTP CRLF escapes" if helper.include?("\\\\r")
  File.write(ARGV.fetch(1), helper)
' "$RENDER" "$TMPDIR/sanitizer-mtls-probe.py"
python3 - "$TMPDIR/sanitizer-mtls-probe.py" <<'PY'
import pathlib
import sys

compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")
PY

# The default (non-mTLS) manifest is a compatibility contract: all sanitizer
# probes remain the original plaintext HTTP endpoints and no mTLS probe helper
# or mount is rendered.
PLAIN_RENDER="$TMPDIR/plain.yaml"
helm template lucairn "$CHART" \
  --set global.skipPullSecretGuard=true \
  --set veil-witness.secrets.values.signingKey=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  > "$PLAIN_RENDER"
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  pod = docs.find { |doc| doc["kind"] == "Deployment" && doc.dig("metadata", "name") == "sandbox-a" }.fetch("spec").fetch("template").fetch("spec")
  sanitizer = pod.fetch("containers").find { |item| item["name"] == "sanitizer" } || abort("plaintext sanitizer container missing")
  expected = {
    "startupProbe" => ["/healthz", "sanitizer"],
    "livenessProbe" => ["/healthz", "sanitizer"],
    "readinessProbe" => ["/readyz", "sanitizer"],
  }
  expected.each do |probe, (path, port)|
    value = sanitizer.fetch(probe)
    abort "plaintext sanitizer #{probe} changed from httpGet" unless value["httpGet"] == { "path" => path, "port" => port }
    abort "plaintext sanitizer #{probe} unexpectedly has exec" if value.key?("exec")
  end
  abort "plaintext render unexpectedly contains sanitizer mTLS helper" if docs.any? { |doc| doc["kind"] == "ConfigMap" && doc.dig("metadata", "name") == "sanitizer-mtls-probe" }
  abort "plaintext sanitizer unexpectedly mounts mTLS probe" if sanitizer.fetch("volumeMounts").any? { |item| item["name"] == "sanitizer-mtls-probe" }
' "$PLAIN_RENDER"

# Veil's production boot gate reads one witness-signed manifest file. The
# dedicated Secret is not a readiness bundle and must project exactly one key
# at the exact ConfigMap path the gateway receives.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  named = lambda do |kind, name|
    docs.find { |doc| doc["kind"] == kind && doc.dig("metadata", "name") == name } || abort("render misses #{kind}/#{name}")
  end
  gateway = named.call("Deployment", "gateway")
  pod = gateway.fetch("spec").fetch("template").fetch("spec")
  volume = pod.fetch("volumes").find { |item| item["name"] == "witness-signed-manifest" } || abort("gateway misses witness-signed-manifest volume")
  expected_item = { "key" => "witness-signed-manifest.json", "path" => "witness-signed-manifest.json" }
  abort "wrong witness-signed manifest Secret" unless volume.dig("secret", "secretName") == "lucairn-witness-signed-manifest"
  abort "witness-signed manifest must project exactly one key" unless volume.dig("secret", "items") == [expected_item]
  container = pod.fetch("containers").find { |item| item["name"] == "gateway" } || abort("gateway container missing")
  mount = container.fetch("volumeMounts").find { |item| item["name"] == "witness-signed-manifest" } || abort("gateway misses witness-signed-manifest mount")
  abort "wrong witness-signed manifest mount" unless mount == { "name" => "witness-signed-manifest", "mountPath" => "/certs", "readOnly" => true }
  config = named.call("ConfigMap", "gateway-config").fetch("data")
  abort "gateway manifest runtime path is not the projected file" unless config.fetch("LCR_WITNESS_SIGNED_MANIFEST_PATH") == "/certs/witness-signed-manifest.json"
' "$RENDER"

# The production profile must use the verified DSA transport. The legacy child
# defaults remain only for non-production compatibility and must not win here.
for config in gateway audit id-bridge sandbox-a sandbox-b; do
  block="$(awk -v name="$config-config" '
    /^kind: ConfigMap$/{in_block=1; block=""}
    in_block{block=block $0 "\n"}
    in_block && $0 == "  name: " name {matched=1}
    /^---$/{if (matched) {print block; exit} in_block=0; matched=0}
    END{if (matched) print block}
  ' "$RENDER")"
  [ -n "$block" ] || { echo "missing $config ConfigMap" >&2; exit 1; }
  grep -q 'GRPC_TLS_ENABLED: "true"' <<<"$block" \
    || { echo "$config emits a non-mTLS legacy TLS posture" >&2; exit 1; }
  grep -q 'DSA_MTLS_CA_BUNDLE_PATH: "/var/run/lucairn/mtls/ca.crt"' <<<"$block" \
    || { echo "$config lacks the DSA mTLS CA path" >&2; exit 1; }
done

# The gateway's sanitizer client is HTTP-based rather than gRPC. In the
# production mTLS profile the rendered operator contract must still name HTTPS
# explicitly; tlsutil.ForceHTTPS repeats the upgrade in the pinned runtime as
# defense in depth. An http:// value here would be an ambiguous customer
# surface even if the runtime happens to repair it.
gateway_block="$(awk -v name="gateway-config" '
  /^kind: ConfigMap$/{in_block=1; block=""}
  in_block{block=block $0 "\n"}
  in_block && $0 == "  name: " name {matched=1}
  /^---$/{if (matched) {print block; exit} in_block=0; matched=0}
  END{if (matched) print block}
' "$RENDER")"
grep -q 'SANITIZER_URL: "https://sandbox-a.dsa-identity.svc:8086"' <<<"$gateway_block" \
  || { echo "production gateway ConfigMap does not expose an HTTPS sanitizer endpoint" >&2; exit 1; }

# Seven runtime identities are required: the six core services plus the
# sanitizer sidecar. Each container may mount its own leaf Secret only.
for secret in \
  lucairn-mtls-gateway \
  lucairn-mtls-audit \
  lucairn-mtls-id-bridge \
  lucairn-mtls-sandbox-a \
  lucairn-mtls-sanitizer \
  lucairn-mtls-sandbox-b \
  lucairn-mtls-veil-witness; do
  grep -q "secretName: $secret" "$RENDER" \
    || { echo "operator Secret $secret was not mounted" >&2; exit 1; }
done

for key in \
  DSA_MTLS_CA_BUNDLE_PATH \
  DSA_MTLS_SERVER_CERT_PATH \
  DSA_MTLS_SERVER_KEY_PATH \
  DSA_MTLS_CLIENT_CERT_PATH \
  DSA_MTLS_CLIENT_KEY_PATH; do
  grep -q "$key" "$RENDER" \
    || { echo "render lacks $key" >&2; exit 1; }
done

# :50058 is deliberately not governed by DSA_MTLS_*; it has its separate
# witness contract, fed from the same gateway/witness operator Secrets.
for key in \
  WITNESS_MTLS_CA_BUNDLE_PATH \
  WITNESS_MTLS_SERVER_CERT_PATH \
  WITNESS_MTLS_SERVER_KEY_PATH \
  WITNESS_MTLS_CLIENT_CERT_PATH \
  WITNESS_MTLS_CLIENT_KEY_PATH; do
  grep -q "$key" "$RENDER" \
    || { echo "render lacks $key for the :50058 witness link" >&2; exit 1; }
done

# The edge↔witness path needs claim emission on :50057 and certificate
# retrieval on :50058, while pipeline claim sources retain their :50057-only
# rules. Parse the rendered NetworkPolicies so a future formatting change
# cannot hide a widened namespace, selector, or port list.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  general = docs.find { |doc| doc["kind"] == "NetworkPolicy" && doc.dig("metadata", "name") == "edge-egress" } || abort("render misses NetworkPolicy/edge-egress")
  abort "edge-egress namespace changed" unless general.dig("metadata", "namespace") == "dsa-edge"
  abort "edge-egress changed its non-witness namespace posture" unless general.dig("spec", "podSelector") == {}
  abort "edge-egress must not retain a namespace-wide witness allowance" if general.fetch("spec").fetch("egress").any? { |rule| rule.fetch("to", []).any? { |target| target.dig("namespaceSelector", "matchLabels", "dsa.io/namespace") == "witness" } }
  policy = docs.find { |doc| doc["kind"] == "NetworkPolicy" && doc.dig("metadata", "name") == "edge-witness-egress" } || abort("render misses NetworkPolicy/edge-witness-egress")
  abort "edge-witness-egress namespace changed" unless policy.dig("metadata", "namespace") == "dsa-edge"
  abort "edge-witness-egress must select only the gateway Pod" unless policy.dig("spec", "podSelector") == { "matchLabels" => { "app.kubernetes.io/name" => "gateway" } }
  witness = policy.fetch("spec").fetch("egress").select do |rule|
    rule.fetch("to") == [{
      "namespaceSelector" => { "matchLabels" => { "dsa.io/namespace" => "witness" } },
      "podSelector" => { "matchLabels" => { "app.kubernetes.io/name" => "veil-witness" } }
    }]
  end
  abort "edge-witness-egress witness rule missing or duplicated" unless witness.length == 1
  ports = witness.fetch(0).fetch("ports").map { |entry| [entry.fetch("port"), entry.fetch("protocol")] }.sort
  abort "edge-witness-egress witness ports widened or incomplete: #{ports.inspect}" unless ports == [[50057, "TCP"], [50058, "TCP"]]
' "$RENDER"

ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  policy = docs.find { |doc| doc["kind"] == "NetworkPolicy" && doc.dig("metadata", "name") == "witness-ingress" } || abort("render misses NetworkPolicy/witness-ingress")
  abort "witness-ingress namespace changed" unless policy.dig("metadata", "namespace") == "dsa-witness"
  ingress = policy.fetch("spec").fetch("ingress")
  selector = lambda do |rule, source|
    rule.fetch("from") == [source]
  end
  ports = lambda do |rule|
    rule.fetch("ports").map { |entry| [entry.fetch("port"), entry.fetch("protocol")] }.sort
  end
  exact_rule = lambda do |source, expected_ports, description|
    matches = ingress.select { |rule| selector.call(rule, source) }
    abort "witness-ingress #{description} rule missing or duplicated" unless matches.length == 1
    actual = ports.call(matches.fetch(0))
    abort "witness-ingress #{description} ports widened or incomplete: #{actual.inspect}" unless actual == expected_ports
  end

  exact_rule.call({
    "namespaceSelector" => { "matchLabels" => { "dsa.io/namespace" => "edge" } },
    "podSelector" => { "matchLabels" => { "app.kubernetes.io/name" => "gateway" } }
  }, [[50057, "TCP"], [50058, "TCP"]], "gateway edge")
  {
    "bridge" => "ID Bridge",
    "identity" => "Sanitizer",
    "ai" => "Sandbox B",
    "audit" => "Audit Service"
  }.each do |namespace, description|
    exact_rule.call({ "namespaceSelector" => { "matchLabels" => { "dsa.io/namespace" => namespace } } }, [[50057, "TCP"]], description)
  end
  exact_rule.call({ "namespaceSelector" => { "matchLabels" => { "dsa.io/namespace" => "observability" } } }, [[50059, "TCP"]], "observability")

  dashboard = ingress.select do |rule|
    rule.fetch("from") == [{
      "namespaceSelector" => { "matchLabels" => { "kubernetes.io/metadata.name" => "lucairn" } },
      "podSelector" => { "matchLabels" => {
        "app.kubernetes.io/name" => "lucairn-dashboard",
        "app.kubernetes.io/component" => "dashboard"
      } }
    }]
  end
  abort "witness-ingress dashboard rule missing or widened" unless dashboard.length == 1 && ports.call(dashboard.fetch(0)) == [[5432, "TCP"], [50058, "TCP"]]
  abort "witness-ingress intra-namespace rule changed" unless ingress.any? { |rule| rule["from"] == [{ "podSelector" => {} }] && !rule.key?("ports") }
' "$RENDER"

# `dsaEnv` is a security boundary, not a fuzzy intent label. The validator
# must reject aliases, case/whitespace variants, arbitrary strings, and YAML
# null/non-string shapes before any TLS-off ConfigMap can be rendered.
for invalid_env in prod Production ' production ' developmentx; do
  invalid_file="$TMPDIR/dsa-env-${invalid_env// /_}.out"
  if render --set-string "global.dsaEnv=$invalid_env" >"$invalid_file" 2>&1; then
    echo "production render accepted invalid global.dsaEnv=$invalid_env" >&2
    exit 1
  fi
  grep -q 'global.dsaEnv must be exactly "development" or "production"' "$invalid_file" \
    || { echo "invalid global.dsaEnv=$invalid_env did not produce the stable fail-closed error" >&2; exit 1; }
done
for shape in null object list; do
  case "$shape" in
    null) value='null' ;;
    object) value='{}' ;;
    list) value='[]' ;;
  esac
  cat > "$TMPDIR/dsa-env-$shape.yaml" <<YAML
global:
  dsaEnv: $value
YAML
  if render -f "$TMPDIR/dsa-env-$shape.yaml" >"$TMPDIR/dsa-env-$shape.out" 2>&1; then
    echo "production render accepted $shape global.dsaEnv" >&2
    exit 1
  fi
  grep -q 'global.dsaEnv must be exactly "development" or "production"' "$TMPDIR/dsa-env-$shape.out" \
    || { echo "$shape global.dsaEnv did not produce the stable fail-closed error" >&2; exit 1; }
done

# Keep the accepted development-off posture explicit: development may still
# disable the Veil path without the production mTLS contract, while production
# is the only supported verified transport profile.
DEV_RENDER="$TMPDIR/development.yaml"
helm template lucairn "$CHART" \
  --set global.skipPullSecretGuard=true \
  --set veil-witness.secrets.values.signingKey=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  --set global.dsaEnv=development \
  --set gateway.veilEnabled=false > "$DEV_RENDER"
grep -q 'DSA_ENV: "development"' "$DEV_RENDER" \
  || { echo "development render no longer emits the accepted development environment" >&2; exit 1; }

# Production is the locked default full-mesh topology, so no core dependency
# may be disabled through Chart.yaml's optional dependency conditions. Accept
# only the chart's literal true values; aliases, false, and absent values must
# fail before Helm can omit a mandatory workload.
for workload in gateway audit id-bridge sandbox-a sandbox-b veil-witness; do
  disabled_file="$TMPDIR/disabled-${workload}.out"
  if render --set "${workload}.enabled=false" >"$disabled_file" 2>&1; then
    echo "production render accepted ${workload}.enabled=false" >&2
    exit 1
  fi
  grep -q "${workload}.enabled must be true when global.dsaEnv=production; it is mandatory for the verified default production mTLS topology." "$disabled_file" \
    || { echo "${workload}.enabled=false did not produce the mandatory-topology error" >&2; exit 1; }
done

# The witness claim and certificate ports are part of the production topology;
# setting this legacy-compatible flag false must not bypass their validation.
if render --set gateway.veilEnabled=false >"$TMPDIR/veil-disabled.out" 2>&1; then
  echo "production render accepted gateway.veilEnabled=false" >&2
  exit 1
fi
grep -q 'gateway.veilEnabled must be true when global.dsaEnv=production; it is mandatory for the verified default production mTLS topology.' "$TMPDIR/veil-disabled.out" \
  || { echo "gateway.veilEnabled=false did not produce the mandatory-topology error" >&2; exit 1; }

# Keep the accepted true shapes exact: aliases and whitespace must not turn a
# production dependency or the production Veil path back on by accident.
for path in gateway.enabled gateway.veilEnabled; do
  for value in false TRUE ' true' 'true ' 1; do
    shape_file="$TMPDIR/${path//./-}-${value// /_}.out"
    if render --set-string "${path}=${value}" >"$shape_file" 2>&1; then
      echo "production render accepted ambiguous ${path}=${value}" >&2
      exit 1
    fi
    grep -q "${path} must be true when global.dsaEnv=production; it is mandatory for the verified default production mTLS topology." "$shape_file" \
      || { echo "ambiguous ${path}=${value} did not produce the mandatory-topology error" >&2; exit 1; }
  done
done

# Customer-facing instructions must not resurrect the removed child-chart TLS
# model. Production is parent-authoritative global.mtls with operator-owned
# Secrets, doctor/render inspection, readiness, and an acceptance battery.
for customer_file in \
  "$ROOT/customer-values.yaml.example" \
  "$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md" \
  "$ROOT/scripts/render-values.sh"; do
  if rg -n 'grpcTlsEnabled|global\.grpcTlsEnabled' "$customer_file"; then
    echo "customer-facing instruction revives unsupported child TLS guidance: $customer_file" >&2
    exit 1
  fi
done
for required_term in global.mtls operator/PKI doctor readiness acceptance; do
  if ! rg -q "$required_term" "$ROOT/docs/CUSTOMER_HELM_RUNBOOK.md"; then
    echo "customer Helm runbook omits required production mTLS guidance: $required_term" >&2
    exit 1
  fi
done

# A production profile cannot silently downgrade when an identity is omitted.
if render --set global.mtls.secrets.audit= >"$TMPDIR/missing-secret.out" 2>&1; then
  echo "production render accepted an empty audit mTLS Secret" >&2
  exit 1
fi
grep -q 'global.mtls.secrets.audit' "$TMPDIR/missing-secret.out" \
  || { echo "missing audit Secret failure was not actionable" >&2; exit 1; }

# A production gateway with Veil enabled cannot get as far as install unless
# every part of the operator-owned signed-manifest contract is present and the
# runtime path is exactly the projected file.
if render --set gateway.witnessSignedManifest.existingSecret= >"$TMPDIR/missing-manifest-secret.out" 2>&1; then
  echo "production render accepted a missing witness-signed manifest Secret" >&2
  exit 1
fi
grep -q 'gateway.witnessSignedManifest.existingSecret' "$TMPDIR/missing-manifest-secret.out" \
  || { echo "missing witness-signed manifest Secret failure was not actionable" >&2; exit 1; }

if render --set gateway.witnessSignedManifest.secretKey= >"$TMPDIR/partial-manifest.out" 2>&1; then
  echo "production render accepted a partial witness-signed manifest Secret contract" >&2
  exit 1
fi
grep -q 'gateway.witnessSignedManifest.secretKey' "$TMPDIR/partial-manifest.out" \
  || { echo "partial witness-signed manifest failure was not actionable" >&2; exit 1; }

if render --set gateway.veilWitnessSignedManifestPath=/certs/not-the-projected-manifest.json >"$TMPDIR/manifest-path-mismatch.out" 2>&1; then
  echo "production render accepted a witness-signed manifest path mismatch" >&2
  exit 1
fi
grep -q 'gateway.veilWitnessSignedManifestPath' "$TMPDIR/manifest-path-mismatch.out" \
  || { echo "witness-signed manifest path mismatch failure was not actionable" >&2; exit 1; }

# Optional gRPC profiles are explicitly outside this delivery and must not
# inherit an insecure or partial transport in the supported production profile.
if render --set ingest.enabled=true >"$TMPDIR/unsupported.out" 2>&1; then
  echo "production render accepted unsupported ingest mTLS wiring" >&2
  exit 1
fi
grep -q 'unsupported optional gRPC profile' "$TMPDIR/unsupported.out" \
  || { echo "unsupported profile failure was not actionable" >&2; exit 1; }

# The Helm-only doctor mode deliberately needs neither customer.env nor a
# Compose file. The complete generated document is the pre-install contract
# gate; the static fixture alone intentionally omits application secrets.
"$ROOT/bin/lucairn" doctor --values "$RUNTIME_VALUES" --offline > "$TMPDIR/doctor-ok.out"
grep -q 'enterprise mTLS (Helm): production render contract: ok' "$TMPDIR/doctor-ok.out" \
  || { echo "doctor did not report the accepted enterprise mTLS contract" >&2; exit 1; }
grep -q 'doctor: ok' "$TMPDIR/doctor-ok.out" \
  || { echo "doctor did not pass the complete generated enterprise mTLS values" >&2; exit 1; }

cat > "$TMPDIR/doctor-invalid.yaml" <<'YAML'
global:
  dsaEnv: production
  mtls:
    enabled: true
    mountPath: /var/run/lucairn/mtls
    caBundleKey: ca.crt
    certKey: tls.crt
    keyKey: tls.key
    secrets:
      gateway: lucairn-mtls-gateway
gateway:
  witnessSignedManifest:
    existingSecret: lucairn-witness-signed-manifest
    secretKey: witness-signed-manifest.json
    mountPath: /certs
    fileName: witness-signed-manifest.json
veil-witness:
  enabled: true
sandbox-b:
  redis:
    password: test-redis-password
  secrets:
    values:
      sandboxBApiKeys: test-api-key
YAML
if "$ROOT/bin/lucairn" doctor --values "$TMPDIR/doctor-invalid.yaml" --offline \
  > "$TMPDIR/doctor-invalid.out" 2>&1; then
  echo "doctor accepted an incomplete production mTLS values contract" >&2
  exit 1
fi
grep -q 'global.mtls.secrets.audit' "$TMPDIR/doctor-invalid.out" \
  || { echo "doctor did not expose the missing identity error" >&2; exit 1; }

# doctor --values inspects Helm's render, so it must surface the same mandatory
# topology failure rather than reporting a production contract as healthy.
cat > "$TMPDIR/doctor-disabled-workload.yaml" <<'YAML'
global:
  dsaEnv: production
  mtls:
    enabled: true
gateway:
  enabled: false
veil-witness:
  enabled: true
sandbox-b:
  redis:
    password: test-redis-password
  secrets:
    values:
      sandboxBApiKeys: test-api-key
YAML
if "$ROOT/bin/lucairn" doctor --values "$TMPDIR/doctor-disabled-workload.yaml" --offline \
  > "$TMPDIR/doctor-disabled-workload.out" 2>&1; then
  echo "doctor accepted gateway.enabled=false in production values" >&2
  exit 1
fi
grep -q 'gateway.enabled must be true when global.dsaEnv=production; it is mandatory for the verified default production mTLS topology.' "$TMPDIR/doctor-disabled-workload.out" \
  || { echo "doctor did not inherit the mandatory gateway topology error" >&2; exit 1; }

echo "enterprise mTLS Helm production contract: ok"
