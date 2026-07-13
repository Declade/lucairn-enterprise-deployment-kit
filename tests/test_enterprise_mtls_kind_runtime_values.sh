#!/usr/bin/env bash
set -euo pipefail

# Static/render contract for the disposable Kind customer-values document. It
# never starts Kind or contacts a registry, and it keeps all generated material
# in a temporary directory outside the repository.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
FIXTURE="$CHART/tests/fixtures/enterprise-mtls-accepted.yaml"
GENERATOR="$ROOT/scripts/generate-enterprise-mtls-kind-runtime-values.sh"
SIGN_MANIFEST="$ROOT/scripts/generate-enterprise-mtls-kind-signed-manifest.sh"
TMPDIR="$(mktemp -d)"
RUNTIME_VALUES="$TMPDIR/runtime-values.yaml"
trap 'rm -rf "$TMPDIR"' EXIT

"$GENERATOR" "$RUNTIME_VALUES" >"$TMPDIR/generator.stdout" 2>"$TMPDIR/generator.stderr"
[ ! -s "$TMPDIR/generator.stdout" ] || {
  echo "Kind runtime-value generator must not print generated values" >&2
  exit 1
}
[ ! -s "$TMPDIR/generator.stderr" ] || {
  echo "Kind runtime-value generator emitted unexpected output" >&2
  exit 1
}
[ -f "$RUNTIME_VALUES" ] || {
  echo "Kind runtime values were not created inside the caller state directory" >&2
  exit 1
}

if MODE="$(stat -f '%Lp' "$RUNTIME_VALUES" 2>/dev/null)"; then :; else MODE="$(stat -c '%a' "$RUNTIME_VALUES")"; fi
[ "$MODE" = "600" ] || {
  echo "Kind runtime values file mode is $MODE, expected 600" >&2
  exit 1
}

# Exercise the signed-manifest generator with a local Docker double. This
# keeps the static test offline while proving that the exact pinned ceremony
# command receives a valid seven-entry roster derived from the generated
# coherent keys, produces no output, cleans its temporary keys.json, and does
# not write any generated artifact into the tracked worktree.
[ -x "$SIGN_MANIFEST" ] || {
  echo "missing executable Kind signed-manifest generator: $SIGN_MANIFEST" >&2
  exit 1
}
FAKE_BIN="$TMPDIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = "run" ] || exit 91
shift
args=("$@")
mount=""
seed=""
keys_arg=""
issuer=""
key_id=""
image_seen=0
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --entrypoint)
      [ "${args[$((i + 1))]:-}" = "sign-manifest" ] || exit 92
      ;;
    -v)
      mount="${args[$((i + 1))]:-}"
      ;;
    ghcr.io/declade/dsa-veil-witness:0.5.4)
      image_seen=1
      ;;
    --keys-json)
      keys_arg="${args[$((i + 1))]:-}"
      ;;
    --issuer)
      issuer="${args[$((i + 1))]:-}"
      ;;
    --witness-signing-key-hex)
      seed="${args[$((i + 1))]:-}"
      ;;
    --witness-key-id)
      key_id="${args[$((i + 1))]:-}"
      ;;
  esac
done
[ "$image_seen" -eq 1 ] || exit 93
[ "$keys_arg" = "/keys.json" ] || exit 94
[ "$key_id" = "witness_manifest_v1" ] || exit 95
[ "$issuer" = "Lucairn Veil Witness" ] || exit 96
[[ "$seed" =~ ^[0-9a-fA-F]{64}$ ]] || exit 97
case "$mount" in
  *:/keys.json:ro) keys_json="${mount%:/keys.json:ro}" ;;
  *) exit 98 ;;
esac
[ -f "$keys_json" ] || exit 99

RUNTIME_VALUES="$RUNTIME_VALUES" ruby -rjson -ryaml -e '
  values = YAML.load_file(ENV.fetch("RUNTIME_VALUES"))
  gateway = values.fetch("gateway").fetch("secrets").fetch("values")
  expected = [
    ["dsa-witness", "witness_v1", "veilWitnessPublicKey", "Certificate signing"],
    ["dsa-bridge", "bridge_v1", "veilBridgePublicKey", "Bridge claim signing"],
    ["dsa-sanitizer", "sanitizer_v1", "veilSanitizerPublicKey", "Sanitizer claim signing"],
    ["dsa-ai", "sandbox_b_v1", "veilSandboxBPublicKey", "Inference claim signing"],
    ["dsa-audit", "audit_v1", "veilAuditPublicKey", "Audit claim signing"],
    ["dsa-gateway", "gateway_manifest_v1", "veilGatewayManifestPublicKey", "Manifest signing"],
    ["dsa-witness", "witness_manifest_v1", "veilWitnessManifestPublicKey", "Manifest signing"]
  ]
  keys = JSON.parse(File.read(ARGV.fetch(0)))
  abort "wrong keys.json roster size" unless keys.length == expected.length
  expected.zip(keys).each do |(service, key_id, source, purpose), key|
    abort "wrong keys.json schema" unless key.keys.sort == %w[algorithm key_id key_state public_key purpose service_id]
    abort "wrong keys.json entry" unless key == { "service_id" => service, "key_id" => key_id, "public_key" => gateway.fetch(source), "purpose" => purpose, "algorithm" => "Ed25519", "key_state" => "active" }
  end
' "$keys_json"
printf '%s\n' '{"mock":"witness-signed-manifest"}'
DOCKER
chmod 0700 "$FAKE_BIN/docker"
SIGNED_MANIFEST="$TMPDIR/witness-signed-manifest.json"
RUNTIME_VALUES="$RUNTIME_VALUES" PATH="$FAKE_BIN:$PATH" "$SIGN_MANIFEST" "$RUNTIME_VALUES" "$SIGNED_MANIFEST" \
  >"$TMPDIR/sign-manifest.stdout" 2>"$TMPDIR/sign-manifest.stderr"
[ ! -s "$TMPDIR/sign-manifest.stdout" ] || {
  echo "Kind signed-manifest generator must not print generated material" >&2
  exit 1
}
[ ! -s "$TMPDIR/sign-manifest.stderr" ] || {
  echo "Kind signed-manifest generator emitted unexpected output" >&2
  exit 1
}
[ -s "$SIGNED_MANIFEST" ] || {
  echo "Kind signed-manifest generator did not create its output" >&2
  exit 1
}
if MODE="$(stat -f '%Lp' "$SIGNED_MANIFEST" 2>/dev/null)"; then :; else MODE="$(stat -c '%a' "$SIGNED_MANIFEST")"; fi
[ "$MODE" = "600" ] || {
  echo "Kind signed-manifest file mode is $MODE, expected 600" >&2
  exit 1
}
if find "$TMPDIR" -maxdepth 1 -type d -name '.enterprise-mtls-manifest.*' | grep -q .; then
  echo "Kind signed-manifest generator left its disposable keys.json workspace behind" >&2
  exit 1
fi
if git -C "$ROOT" ls-files --error-unmatch "${SIGNED_MANIFEST#$ROOT/}" >/dev/null 2>&1; then
  echo "generated Kind signed manifest must not be tracked" >&2
  exit 1
fi

# The output path is caller-selected. The real harness must select its own
# STATE_DIR, then give the generated complete document to both doctor and Helm.
KIND_GATE="$ROOT/scripts/test-enterprise-mtls-kind.sh"
PRELOAD="$ROOT/scripts/preload-enterprise-mtls-kind-images.sh"
grep -Fq 'RUNTIME_VALUES="$STATE_DIR/runtime-values.yaml"' "$KIND_GATE" \
  || { echo "Kind harness does not place runtime values under STATE_DIR" >&2; exit 1; }
grep -Fq 'generate-enterprise-mtls-kind-runtime-values.sh" "$RUNTIME_VALUES"' "$KIND_GATE" \
  || { echo "Kind harness does not generate its runtime values at install time" >&2; exit 1; }
grep -Fq 'generate-enterprise-mtls-kind-signed-manifest.sh"' "$KIND_GATE" \
  || { echo "Kind harness does not invoke the signed-manifest ceremony tool" >&2; exit 1; }
grep -Fq 'create secret generic lucairn-witness-signed-manifest' "$KIND_GATE" \
  || { echo "Kind harness does not create the witness-signed manifest Secret" >&2; exit 1; }
if grep -Fq 'enterprise-mtls-accepted.yaml' "$KIND_GATE"; then
  echo "Kind harness must not layer the incomplete non-secret fixture separately" >&2
  exit 1
fi
grep -Fq -- '--values "$RUNTIME_VALUES"' "$KIND_GATE" \
  || { echo "Kind harness does not doctor the complete runtime values" >&2; exit 1; }
grep -Fq -- '-f "$RUNTIME_VALUES"' "$KIND_GATE" \
  || { echo "Kind harness does not feed the runtime values to Helm" >&2; exit 1; }
grep -Fq 'RENDERED_MANIFEST="$STATE_DIR/rendered-topology.yaml"' "$KIND_GATE" \
  || { echo "Kind harness does not keep its rendered topology in STATE_DIR" >&2; exit 1; }
grep -Fq 'PRELOAD_ARCHIVE_DIR="$STATE_DIR/preload-archives"' "$KIND_GATE" \
  || { echo "Kind harness does not keep preload archives in STATE_DIR" >&2; exit 1; }
grep -Fq 'helm template lucairn' "$KIND_GATE" \
  || { echo "Kind harness does not render the install topology before preload" >&2; exit 1; }
grep -Fq 'preload-enterprise-mtls-kind-images.sh' "$KIND_GATE" \
  || { echo "Kind harness does not preload its rendered topology images" >&2; exit 1; }
grep -Fq -- '--archive-dir "$PRELOAD_ARCHIVE_DIR"' "$KIND_GATE" \
  || { echo "Kind harness does not give preload archives a private state path" >&2; exit 1; }
grep -Fq -- '--wait-for-jobs' "$KIND_GATE" \
  || { echo "Kind harness does not wait for migration Jobs" >&2; exit 1; }
[ -x "$PRELOAD" ] || {
  echo "missing executable Kind topology image preloader" >&2
  exit 1
}

# The dsa-edge probe is acceptance evidence for the chart's actual
# witness-ingress policy, not a harness-specific allow rule. Keep both locked
# witness ports in the probe battery and reject any NetworkPolicy manipulation
# in the harness that could mask a chart regression.
for witness_port in 50057 50058; do
  grep -Fq "positive_handshake veil-witness.dsa-witness.svc.cluster.local:${witness_port} dsa-veil-witness" "$KIND_GATE" \
    || { echo "Kind harness does not probe the dsa-edge to witness :${witness_port} mTLS path" >&2; exit 1; }
done
if grep -Eqi '(^|[^[:alpha:]])networkpolicy([^[:alpha:]]|$)' "$KIND_GATE"; then
  echo "Kind harness must not install or bypass a NetworkPolicy for the dsa-edge witness probe" >&2
  exit 1
fi

# SNI selects a virtual server but does not prove that the returned certificate
# identifies it. Every positive edge must therefore use the shared helper's
# exact hostname verification, and the wrong-SAN negative must deliberately
# request a different verification hostname while retaining normal audit SNI.
ruby -e '
  source = File.read(ARGV.fetch(0))
  helper = source[/^positive_handshake\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses positive_handshake helper")
  abort "positive_handshake omits exact hostname verification" unless helper.include?("-verify_hostname '\''$san'\''")
  positive_paths = source.scan(/^positive_handshake\s+\S+\s+\S+$/)
  abort "Kind harness has no positive mTLS paths" if positive_paths.empty?
  wrong_san = source[/^negative_handshake wrong-san "(?<command>.*)"$/, :command] || abort("Kind harness misses wrong-SAN negative")
  servername = wrong_san[/\B-servername\s+(\S+)/, 1] || abort("wrong-SAN negative omits SNI")
  verify_hostname = wrong_san[/\B-verify_hostname\s+(\S+)/, 1] || abort("wrong-SAN negative omits hostname verification")
  abort "wrong-SAN negative must retain audit SNI" unless servername == "dsa-audit"
  abort "wrong-SAN negative must verify a mismatched hostname" if servername == verify_hostname
  %w[-verify_return_error -CAfile /certs/gateway/ca.crt -cert /certs/gateway/tls.crt -key /certs/gateway/tls.key].each do |argument|
    abort "wrong-SAN negative omits #{argument}" unless wrong_san.include?(argument)
  end
' "$KIND_GATE"

# Server-side client-auth negatives must wait for the server's TLS 1.3
# post-handshake client-certificate decision. A generic nonzero check is not
# enough: an early s_client success, or a deadline reached while the server
# keeps the connection open, both fail the acceptance battery.
ruby -e '
  source = File.read(ARGV.fetch(0))
  abort "expired-client probe must install GNU timeout support" unless source.include?("apk add --no-cache openssl coreutils")
  generic = source[/^negative_handshake\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses generic negative helper")
  abort "generic negative helper changed" unless generic.include?("if probe \"$command\"; then") && generic.include?("negative mTLS handshake unexpectedly passed")
  strict = source[/^strict_client_auth_rejection\(\) \{\n(?<body>.*?)^positive_handshake audit\.dsa-audit/m, :body] || abort("Kind harness misses shared strict client-auth helper")
  [
    "-connect \"$address\"",
    "-servername \"$san\"",
    "-verify_hostname \"$san\"",
    "-verify_return_error",
    "-CAfile \"$ca_file\"",
    "-quiet -ign_eof"
  ].each do |argument|
    abort "strict client-auth helper omits #{argument}" unless strict.include?(argument)
  end
  abort "strict client-auth helper must use a strict in-Pod deadline" unless strict.match?(/timeout\s+15\s+openssl\s+s_client/m)
  abort "strict client-auth helper does not capture the OpenSSL status" unless strict.include?("status=$?")
  abort "strict client-auth helper accepts a timeout" unless strict.match?(/if \[ "\$status" -eq 124 \]; then\n.*?exit 1\nfi/m) && strict.include?("timed out waiting for server rejection")
  abort "strict client-auth helper accepts an open connection" unless strict.match?(/if \[ "\$status" -eq 0 \]; then\n.*?exit 1\nfi/m) && strict.include?("remained accepted/open")
  abort "strict client-auth helper can mistake a timeout runner failure for OpenSSL rejection" unless strict.include?("[ \"$status\" -ge 125 ] && [ \"$status\" -le 127 ]")
  abort "strict client-auth helper does not require the server TLS alert" unless strict.include?("(tls|ssl).*alert|alert.*(tls|ssl)")
  abort "strict client-auth helper does not forward positional arguments to the probe shell" unless source.include?("sh -ec \"$1\" -- \"${@:2}\"")
  abort "missing-client negative still uses the generic helper" if source.match?(/^negative_handshake missing-client-cert /)
  abort "expired-client negative still uses the generic helper" if source.match?(/^negative_handshake expired-client-cert /)
  {
    "missing-client-cert" => "audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/gateway/ca.crt",
    "expired-client-cert" => "audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/expired/ca.crt /certs/expired/tls.crt /certs/expired/tls.key"
  }.each do |description, arguments|
    abort "#{description} does not use the shared strict client-auth helper" unless source.include?("strict_client_auth_rejection #{description} #{arguments}")
  end
' "$KIND_GATE"

# The probe installs OpenSSL at startup. Pod readiness must therefore remain
# false until the exact executable used by the handshake battery exists.
ruby -ryaml -e '
  source = File.read(ARGV.fetch(0))
  match = source.match(%r{(?<pod>apiVersion: v1\nkind: Pod\nmetadata:\n  name: enterprise-mtls-probe\n.*?^YAML$)}m) || abort("Kind harness misses enterprise mTLS probe manifest")
  pod = YAML.load(match[:pod].sub(/\nYAML\z/, "\n"))
  container = pod.fetch("spec").fetch("containers").find { |item| item["name"] == "openssl" } || abort("enterprise mTLS probe misses openssl container")
  expected = {
    "exec" => { "command" => ["test", "-x", "/usr/bin/openssl"] },
    "periodSeconds" => 1,
    "timeoutSeconds" => 1,
    "failureThreshold" => 60
  }
  abort "enterprise mTLS probe readiness must wait for executable OpenSSL" unless container["readinessProbe"] == expected
' "$KIND_GATE"

# The accepted fixture must itself remain free of application secret values and
# explicitly shrink the rendered topology to the locked default mesh.
ruby -ryaml -e '
  fixture = YAML.load_file(ARGV.fetch(0))
  runtime = YAML.load_file(ARGV.fetch(1))
  includes_fixture = lambda do |expected, actual|
    expected.all? do |key, value|
      value.is_a?(Hash) ? actual[key].is_a?(Hash) && includes_fixture.call(value, actual[key]) : actual[key] == value
    end
  end
  abort "accepted fixture carries global.dsaServiceToken" if fixture.fetch("global").key?("dsaServiceToken")
  abort "generated runtime values omit static non-secret contract" unless includes_fixture.call(fixture, runtime)
  expected_secrets = {
    "gateway" => "lucairn-mtls-gateway", "audit" => "lucairn-mtls-audit",
    "idBridge" => "lucairn-mtls-id-bridge", "sandboxA" => "lucairn-mtls-sandbox-a",
    "sanitizer" => "lucairn-mtls-sanitizer", "sandboxB" => "lucairn-mtls-sandbox-b",
    "veilWitness" => "lucairn-mtls-veil-witness"
  }
  abort "accepted fixture mTLS Secret names changed" unless fixture.dig("global", "mtls", "secrets") == expected_secrets
  %w[admin observability pii-ml postgres-gateway demo ingest certification dashboard].each do |name|
    component = fixture.fetch(name)
    abort "accepted fixture does not disable #{name}" unless component["enabled"] == false
  end
  abort "accepted fixture does not enable the Sandbox-B harness-only readiness adapter" unless fixture.dig("sandbox-b", "enableTestProvider") == "true"
  abort "generated runtime values omit the Sandbox-B harness-only readiness adapter" unless runtime.dig("sandbox-b", "enableTestProvider") == "true"
  abort "accepted fixture does not disable Sandbox-B Ollama" unless fixture.dig("sandbox-b", "ollama", "enabled") == false
  abort "generated runtime values enable Sandbox-B Ollama" unless runtime.dig("sandbox-b", "ollama", "enabled") == false
  chart_defaults = YAML.load_file(ARGV.fetch(2))
  production_defaults = YAML.load_file(ARGV.fetch(3))
  sandbox_b_defaults = YAML.load_file(ARGV.fetch(4))
  abort "parent default values must not enable the harness-only test provider" if chart_defaults.dig("sandbox-b", "enableTestProvider")
  abort "production values must not enable the harness-only test provider" if production_defaults.dig("sandbox-b", "enableTestProvider")
  abort "Sandbox-B chart default test provider changed" unless sandbox_b_defaults.fetch("enableTestProvider") == "false"
' "$FIXTURE" "$RUNTIME_VALUES" "$CHART/values.yaml" "$CHART/values-prod.yaml" "$CHART/charts/sandbox-b/values.yaml"

value() {
  ruby -ryaml -e '
    value = ARGV.fetch(1).split(".").reduce(YAML.load_file(ARGV.fetch(0))) { |node, key| node.fetch(key) }
    print value
  ' "$RUNTIME_VALUES" "$1"
}

require_nonempty() {
  local path
  for path in "$@"; do
    [ -n "$(value "$path")" ] || {
      echo "Kind runtime values omit required field: $path" >&2
      exit 1
    }
  done
}

derive_public() {
  printf '%s' "$1" | "$ROOT/scripts/derive-veil-pubkey.sh"
}

# Every non-mTLS startup field observed in the current 0.5.4 chart templates
# is set here. The separate mTLS identities remain operator-owned Secrets.
require_nonempty \
  global.dsaServiceToken \
  audit.secrets.values.postgresPassword \
  audit.secrets.values.auditAppPassword \
  audit.secrets.values.veilSigningKey \
  id-bridge.secrets.values.postgresPassword \
  id-bridge.secrets.values.masterKey \
  id-bridge.secrets.values.veilSigningKey \
  id-bridge.secrets.values.bridgeEncryptionKey \
  sandbox-a.secrets.values.postgresPassword \
  sandbox-a.secrets.values.encryptionKey \
  sandbox-a.secrets.values.adminKey \
  sandbox-a.secrets.values.veilSigningKey \
  sandbox-a.secrets.values.canaryHmacKey \
  sandbox-b.redis.password \
  sandbox-b.secrets.values.veilSigningKey \
  sandbox-b.secrets.values.sandboxBApiKeys \
  sandbox-b.secrets.values.adminKey \
  gateway.secrets.values.veilManifestSigningKey \
  gateway.secrets.values.veilGatewaySigningKey \
  gateway.secrets.values.gatewayKeystoreKey \
  gateway.secrets.values.canaryHmacKey \
  veil-witness.secrets.values.postgresPassword \
  veil-witness.secrets.values.veilAppPassword \
  veil-witness.secrets.values.signingKey \
  veil-witness.secrets.values.keyId

# All verifier keys must be derived from the signing seed actually injected
# into the matching emitter. The same comparison proves AI-signing coherence.
[ "$(derive_public "$(value audit.secrets.values.veilSigningKey)")" = "$(value gateway.secrets.values.veilAuditPublicKey)" ]
[ "$(derive_public "$(value id-bridge.secrets.values.veilSigningKey)")" = "$(value gateway.secrets.values.veilBridgePublicKey)" ]
[ "$(derive_public "$(value sandbox-a.secrets.values.veilSigningKey)")" = "$(value gateway.secrets.values.veilSanitizerPublicKey)" ]
[ "$(derive_public "$(value sandbox-b.secrets.values.veilSigningKey)")" = "$(value gateway.secrets.values.veilSandboxBPublicKey)" ]
[ "$(derive_public "$(value veil-witness.secrets.values.signingKey)")" = "$(value gateway.secrets.values.veilWitnessPublicKey)" ]
[ "$(derive_public "$(value gateway.secrets.values.veilGatewaySigningKey)")" = "$(value gateway.secrets.values.veilGatewayPublicKey)" ]
[ "$(derive_public "$(value gateway.secrets.values.veilManifestSigningKey)")" = "$(value gateway.secrets.values.veilGatewayManifestPublicKey)" ]
[ "$(value gateway.secrets.values.veilWitnessManifestPublicKey)" = "$(value gateway.secrets.values.veilWitnessPublicKey)" ]
[ "$(value sandbox-b.secrets.values.veilSigningKey)" = "$(value gateway.secrets.values.veilAISigningKey)" ]
[ "$(value sandbox-a.secrets.values.canaryHmacKey)" = "$(value gateway.secrets.values.canaryHmacKey)" ]
[ "$(value sandbox-a.secrets.values.adminKey)" = "$(value sandbox-b.secrets.values.adminKey)" ]
[ "$(value sandbox-b.secrets.values.adminKey)" = "$(value gateway.secrets.values.adminKey)" ]
[ "$(value sandbox-b.secrets.values.sandboxBApiKeys)" = "$(value gateway.secrets.values.sandboxBApiKey)" ]
[ "$(value veil-witness.config.bridgePublicKey)" = "$(value gateway.secrets.values.veilBridgePublicKey)" ]
[ "$(value veil-witness.config.sanitizerPublicKey)" = "$(value gateway.secrets.values.veilSanitizerPublicKey)" ]
[ "$(value veil-witness.config.sandboxBPublicKey)" = "$(value gateway.secrets.values.veilSandboxBPublicKey)" ]
[ "$(value veil-witness.config.auditPublicKey)" = "$(value gateway.secrets.values.veilAuditPublicKey)" ]

# Generated material stays outside version control. The generator is silent;
# this assertion catches a future change that redirects the generated overlay
# into a tracked worktree path.
if git -C "$ROOT" ls-files --error-unmatch "${RUNTIME_VALUES#$ROOT/}" >/dev/null 2>&1; then
  echo "generated Kind runtime values must not be tracked" >&2
  exit 1
fi

if command -v helm >/dev/null 2>&1; then
  RENDER="$TMPDIR/rendered.yaml"
  helm template lucairn "$CHART" \
    -f "$CHART/values-prod.yaml" \
    -f "$RUNTIME_VALUES" \
    --set global.skipPullSecretGuard=true \
    --set global.secrets.backend=k8s-native \
    --set global.dnsRestriction=false \
    --set global.wireguardEncryption=false \
    --set global.postgresqlSslmode=disable \
    >"$RENDER"

  ruby -ryaml -e '
    docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
    named = lambda do |kind, name|
      docs.find { |doc| doc["kind"] == kind && doc.dig("metadata", "name") == name } || abort("render misses #{kind}/#{name}")
    end
    secret = lambda do |name|
      named.call("Secret", name).fetch("stringData")
    end
    gateway = secret.call("gateway-credentials")
    audit = secret.call("audit-credentials")
    bridge = secret.call("id-bridge-credentials")
    sandbox_a = secret.call("sandbox-a-credentials")
    sandbox_b = secret.call("sandbox-b-credentials")
    witness = secret.call("veil-witness-credentials")
    token = gateway.fetch("DSA_SERVICE_TOKEN")
    [audit, bridge, sandbox_a, sandbox_b].each do |credentials|
      abort "rendered service token drift" unless credentials.fetch("DSA_SERVICE_TOKEN") == token
    end
    abort "rendered canary key drift" unless gateway.fetch("CANARY_HMAC_KEY") == sandbox_a.fetch("CANARY_HMAC_KEY")
    abort "rendered AI signing key drift" unless gateway.fetch("LCR_AI_SIGNING_KEY") == sandbox_b.fetch("LCR_SIGNING_KEY")
    abort "rendered Sandbox-B API key drift" unless gateway.fetch("SANDBOX_B_API_KEY") == sandbox_b.fetch("SANDBOX_B_API_KEYS")
    abort "rendered admin key drift" unless [gateway, sandbox_a, sandbox_b].map { |credentials| credentials.fetch("DSA_ADMIN_KEY") }.uniq.one?
    config = named.call("ConfigMap", "veil-witness-config").fetch("data")
    {
      "LCR_BRIDGE_PUBLIC_KEY" => gateway.fetch("LCR_BRIDGE_PUBLIC_KEY"),
      "LCR_SANITIZER_PUBLIC_KEY" => gateway.fetch("LCR_SANITIZER_PUBLIC_KEY"),
      "LCR_SANDBOX_B_PUBLIC_KEY" => gateway.fetch("LCR_SANDBOX_B_PUBLIC_KEY"),
      "LCR_AUDIT_PUBLIC_KEY" => gateway.fetch("LCR_AUDIT_PUBLIC_KEY")
    }.each do |key, expected|
      abort "rendered witness verifier key drift: #{key}" unless config.fetch(key) == expected
    end
    abort "rendered witness signing seed is blank" if witness.fetch("LCR_WITNESS_SIGNING_KEY").empty?
    sandbox_b = named.call("Deployment", "sandbox-b")
    container = sandbox_b.dig("spec", "template", "spec", "containers").find { |item| item["name"] == "sandbox-b" } || abort("render misses Sandbox-B container")
    test_provider = container.fetch("env").find { |item| item["name"] == "ENABLE_TEST_PROVIDER" }
    abort "rendered Sandbox-B does not enable the harness-only readiness adapter" unless test_provider == { "name" => "ENABLE_TEST_PROVIDER", "value" => "true" }
    names = docs.map { |doc| doc.dig("metadata", "name") }
    %w[sandbox-b-ollama sandbox-b-ollama-pull sandbox-b-ollama-data].each do |name|
      abort "rendered Kind fixture includes disabled Ollama resource: #{name}" if names.include?(name)
    end
    sandbox_b_config = named.call("ConfigMap", "sandbox-b-config").fetch("data")
    abort "rendered Sandbox-B config retains an Ollama endpoint" if sandbox_b_config.key?("OLLAMA_URL")
  ' "$RENDER"

  # Feed the actual production-profile render to the preloader through local
  # Docker/Kind doubles. This proves a newly rendered mandatory workload image
  # becomes part of the preload set without Docker, Kind, or registry access.
  PRELOAD_FAKE_BIN="$TMPDIR/preload-fake-bin"
  PRELOAD_CALLS="$TMPDIR/preload-calls"
  PRELOAD_IMAGES="$TMPDIR/preload-images.txt"
  PRELOAD_ARCHIVE_DIR="$TMPDIR/preload-archives"
  export PRELOAD_ARCHIVE_DIR
  mkdir -p "$PRELOAD_FAKE_BIN"
  cat > "$PRELOAD_FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  inspect:--format)
    [ "$#" -eq 4 ] && [ "$3" = '{{.Image}}' ] && [ "$4" = 'runtime-render-control-plane' ] || exit 81
    printf '%s\n' 'sha256:runtime-render-node'
    ;;
  image:inspect)
    [ "$#" -eq 5 ] && [ "$3" = '--format' ] && [ "$4" = '{{.Os}}/{{.Architecture}}' ] && [ "$5" = 'sha256:runtime-render-node' ] || exit 82
    printf '%s\n' 'linux/arm64'
    ;;
  pull:*)
    [ "$#" -eq 2 ] || exit 83
    printf 'pull %s\n' "$2" >> "$PRELOAD_CALLS"
    ;;
  image:save)
    [ "$#" -eq 7 ] && [ "$3" = '--platform' ] && [ "$4" = 'linux/arm64' ] && [ "$5" = '--output' ] || exit 84
    case "$6" in "$PRELOAD_ARCHIVE_DIR"/image-[0-9]*.tar) ;; *) exit 85 ;; esac
    [ ! -e "$6" ] || exit 86
    if find "$PRELOAD_ARCHIVE_DIR" -type f -print -quit | grep -q .; then exit 87; fi
    printf '%s' archive > "$6"
    printf 'save %s %s\n' "$4" "$7" >> "$PRELOAD_CALLS"
    ;;
  *) exit 88 ;;
esac
DOCKER
  cat > "$PRELOAD_FAKE_BIN/kind" <<'KIND'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  get:nodes)
    [ "${3:-}" = "--name" ] && [ "${4:-}" = "runtime-render" ] || exit 82
    printf '%s\n' runtime-render-control-plane runtime-render-worker runtime-render-worker2
    ;;
  load:image-archive)
    [ "${3:-}" = "--name" ] && [ "${4:-}" = "runtime-render" ] && [ "$#" -eq 5 ] && [ -s "$5" ] || exit 89
    case "$5" in "$PRELOAD_ARCHIVE_DIR"/image-[0-9]*.tar) ;; *) exit 90 ;; esac
    printf 'load %s\n' "$5" >> "$PRELOAD_CALLS"
    ;;
  *) exit 91 ;;
esac
KIND
  chmod 0700 "$PRELOAD_FAKE_BIN/docker" "$PRELOAD_FAKE_BIN/kind"
  PATH="$PRELOAD_FAKE_BIN:$PATH" PRELOAD_CALLS="$PRELOAD_CALLS" "$PRELOAD" \
    --cluster runtime-render \
    --rendered-manifest "$RENDER" \
    --image-list "$PRELOAD_IMAGES" \
    --archive-dir "$PRELOAD_ARCHIVE_DIR" \
    >"$TMPDIR/preload.stdout" 2>"$TMPDIR/preload.stderr"
  ruby -ryaml -e '
    expected = []
    collect_document = nil
    collect_document = lambda do |doc|
      next unless doc.is_a?(Hash)
      if doc["kind"] == "List"
        Array(doc["items"]).each { |item| collect_document.call(item) }
        next
      end
      hooks = (doc.dig("metadata", "annotations") || {}).fetch("helm.sh/hook", "").split(",").map(&:strip).reject(&:empty?)
      next if !hooks.empty? && hooks.all? { |hook| hook.start_with?("test") }
      pod_specs = [doc.dig("spec", "template", "spec"), doc.dig("spec", "jobTemplate", "spec", "template", "spec")]
      pod_specs << doc["spec"] if doc["kind"] == "Pod"
      pod_specs.each do |pod_spec|
        next unless pod_spec.is_a?(Hash)
        %w[initContainers containers].each do |field|
          Array(pod_spec[field]).each { |container| expected << container.fetch("image") }
        end
      end
    end
    YAML.load_stream(File.read(ARGV.fetch(0))).compact.each { |doc| collect_document.call(doc) }
    actual = File.readlines(ARGV.fetch(1), chomp: true)
    abort "preload list drifted from the actual Helm PodSpecs" unless actual == expected.uniq.sort
    abort "rendered migrate image omitted from preload" unless actual.include?("migrate/migrate:v4.17.0")
    abort "rendered sanitizer image omitted from preload" unless actual.include?("ghcr.io/declade/dsa-sanitizer:0.5.4")
  ' "$RENDER" "$PRELOAD_IMAGES"
  while IFS= read -r image; do
    grep -Fxq "pull $image" "$PRELOAD_CALLS" \
      || { echo "rendered image was not pulled before install: $image" >&2; exit 1; }
    grep -Fxq "save linux/arm64 $image" "$PRELOAD_CALLS" \
      || { echo "rendered image was not saved for the Kind node platform: $image" >&2; exit 1; }
  done < "$PRELOAD_IMAGES"
  [ ! -e "$PRELOAD_ARCHIVE_DIR" ] \
    || { echo "runtime render preload left image archives behind" >&2; exit 1; }

  for forbidden in 'name: admin' 'name: grafana' 'name: loki' 'name: tempo' 'name: sandbox-b-ollama' 'name: sandbox-b-ollama-pull'; do
    if grep -Fq "$forbidden" "$RENDER"; then
      echo "Kind runtime render includes optional/non-contract workload: $forbidden" >&2
      exit 1
    fi
  done
fi

echo "enterprise mTLS Kind runtime-values contract: ok"
