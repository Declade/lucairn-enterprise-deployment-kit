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
# coherent keys, keeps the witness seed out of the host Docker argv, produces
# no output, cleans its private temporary files on success and failure, and
# does not write any generated artifact into the tracked worktree.
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
keys_mount=""
seed_mount=""
image_index=-1
image_seen=0
expected_seed="$(ruby -ryaml -e 'print YAML.load_file(ENV.fetch("RUNTIME_VALUES")).fetch("veil-witness").fetch("secrets").fetch("values").fetch("signingKey")')"
[[ "${args[*]}" != *"$expected_seed"* ]] || exit 92
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --entrypoint)
      [ "${args[$((i + 1))]:-}" = "/bin/sh" ] || exit 93
      ;;
    -v)
      case "${args[$((i + 1))]:-}" in
        *:/keys.json:ro) keys_mount="${args[$((i + 1))]}" ;;
        *:/run/secrets/witness-signing-key-hex:ro) seed_mount="${args[$((i + 1))]}" ;;
        *) exit 94 ;;
      esac
      ;;
    ghcr.io/declade/dsa-veil-witness:0.5.4@sha256:edc110fd5f827604790cee2be4a963ad03ee7201cbfb1262d2b23ff95a500523)
      image_seen=1
      image_index="$i"
      ;;
  esac
done
[ "$image_seen" -eq 1 ] || exit 95
[ "$image_index" -ge 0 ] || exit 96
expected_command='exec sign-manifest --keys-json /keys.json --issuer "$1" --witness-signing-key-hex "$(cat /run/secrets/witness-signing-key-hex)" --witness-key-id witness_manifest_v1'
[ "${args[$((image_index + 1))]:-}" = "-ec" ] || exit 97
[ "${args[$((image_index + 2))]:-}" = "$expected_command" ] || exit 98
[ "${args[$((image_index + 3))]:-}" = "sign-manifest" ] || exit 99
[ "${args[$((image_index + 4))]:-}" = "Lucairn Veil Witness" ] || exit 100
[ "${#args[@]}" -eq "$((image_index + 5))" ] || exit 101
case "$keys_mount" in
  *:/keys.json:ro) keys_json="${keys_mount%:/keys.json:ro}" ;;
  *) exit 102 ;;
esac
case "$seed_mount" in
  *:/run/secrets/witness-signing-key-hex:ro) seed_file="${seed_mount%:/run/secrets/witness-signing-key-hex:ro}" ;;
  *) exit 103 ;;
esac
[ -f "$keys_json" ] || exit 104
[ -f "$seed_file" ] || exit 105
if MODE="$(stat -f '%Lp' "$seed_file" 2>/dev/null)"; then :; else MODE="$(stat -c '%a' "$seed_file")"; fi
[ "$MODE" = "600" ] || exit 106
[ "$(cat "$seed_file")" = "$expected_seed" ] || exit 107

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
if [ "${FAKE_DOCKER_FAIL:-}" = "1" ]; then
  exit 108
fi
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
  echo "Kind signed-manifest generator left its disposable signing workspace behind" >&2
  exit 1
fi
if git -C "$ROOT" ls-files --error-unmatch "${SIGNED_MANIFEST#$ROOT/}" >/dev/null 2>&1; then
  echo "generated Kind signed manifest must not be tracked" >&2
  exit 1
fi

# The workspace must be removed when the signing container fails too; the
# caller-selected output must remain unpublished and untouched.
FAILED_MANIFEST="$TMPDIR/witness-signed-manifest-failed.json"
if RUNTIME_VALUES="$RUNTIME_VALUES" FAKE_DOCKER_FAIL=1 PATH="$FAKE_BIN:$PATH" "$SIGN_MANIFEST" "$RUNTIME_VALUES" "$FAILED_MANIFEST" \
  >"$TMPDIR/sign-manifest-failure.stdout" 2>"$TMPDIR/sign-manifest-failure.stderr"; then
  echo "Kind signed-manifest generator unexpectedly succeeded after signer failure" >&2
  exit 1
fi
[ ! -e "$FAILED_MANIFEST" ] || {
  echo "Kind signed-manifest generator published output after signer failure" >&2
  exit 1
}
if find "$TMPDIR" -maxdepth 1 -type d -name '.enterprise-mtls-manifest.*' | grep -q .; then
  echo "Kind signed-manifest generator left its private seed workspace behind after signer failure" >&2
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

# The generic dsa-edge probe must not stand in for a real workload Pod. Stock
# Kind/kindnet does not enforce NetworkPolicy, so every Gateway-originated
# mandatory edge must use the resolved Gateway Pod and its projected leaf.
for witness_port in 50057 50058; do
  grep -Fq "veil-witness.dsa-witness.svc.cluster.local:${witness_port} dsa-veil-witness" "$KIND_GATE" \
    || { echo "Kind harness does not execute the actual gateway to witness :${witness_port} mTLS path" >&2; exit 1; }
  if grep -Fq "positive_handshake veil-witness.dsa-witness.svc.cluster.local:${witness_port} dsa-veil-witness" "$KIND_GATE"; then
    echo "Kind harness must not run a generic-probe witness handshake on :${witness_port}" >&2
    exit 1
  fi
done
grep -Fq 'This harness uses stock Kind/kindnet. kindnet does not enforce NetworkPolicy,' "$KIND_GATE" \
  || { echo "Kind harness does not disclose the stock kindnet NetworkPolicy limit" >&2; exit 1; }
if grep -Fq 'Pod/network-policy/secret identity' "$KIND_GATE"; then
  echo "Kind harness still claims projected-leaf evidence proves NetworkPolicy identity" >&2
  exit 1
fi

# SNI selects a virtual server but does not prove that the returned certificate
# identifies it. Every positive edge must therefore pass a distinct exact
# hostname verifier to the static helper, and the wrong-SAN negative must
# retain normal audit SNI while requesting a different verification hostname.
ruby -e '
  source = File.read(ARGV.fetch(0))
  helper = source[/^positive_handshake\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses positive_handshake helper")
  abort "positive_handshake omits exact hostname verification" unless helper.include?("probe_tls_handshake \"$address\" \"$san\" \"$san\"")
  abort "positive_handshake does not use the static local probe" unless helper.include?("/certs/gateway/ca.crt") && helper.include?("/certs/gateway/tls.key")
  abort "positive_handshake accepts a failed helper" unless helper.include?("positive mTLS handshake failed")
  positive_paths = source.scan(/^positive_handshake\s+\S+\s+\S+$/)
  expected_paths = [
    "positive_handshake audit.dsa-audit.svc.cluster.local:50051 dsa-audit",
    "positive_handshake id-bridge.dsa-bridge.svc.cluster.local:50052 dsa-id-bridge",
    "positive_handshake sandbox-a.dsa-identity.svc.cluster.local:50053 dsa-sandbox-a",
    "positive_handshake sandbox-b.dsa-ai.svc.cluster.local:50054 dsa-sandbox-b",
    "positive_handshake sandbox-a.dsa-identity.svc.cluster.local:8086 dsa-sanitizer"
  ]
  abort "local positive mTLS path roster changed: #{positive_paths.inspect}" unless positive_paths.uniq == expected_paths
  abort "local positive mTLS paths may repeat only the post-rotation Audit proof" unless positive_paths.count(expected_paths.fetch(0)) == 2 && positive_paths.count == 6
  abort "local probe must not claim a witness handshake" if positive_paths.any? { |path| path.include?("veil-witness") }
  wrong_san = source[/^negative_handshake wrong-san\s+(?<body>.*?)(?=^strict_client_auth_rejection)/m, :body] || abort("Kind harness misses wrong-SAN negative")
  abort "wrong-SAN negative must retain audit SNI" unless wrong_san.include?("audit.dsa-audit.svc.cluster.local:50051 dsa-audit dsa-sandbox-a")
  %w[/certs/gateway/ca.crt /certs/gateway/tls.crt /certs/gateway/tls.key].each do |argument|
    abort "wrong-SAN negative omits #{argument}" unless wrong_san.include?(argument)
  end
' "$KIND_GATE"

# Three distinct projected client leaves must make narrow exact-SAN TLS calls
# from the real audit, ID Bridge, and smallest mandatory pipeline workload
# (Sandbox B) Pods. The helper can only execute after the runtime Pod mount is
# proven read-only and bound to that workload's own operator Secret; it must
# never receive the generic probe or gateway leaf.
ruby -e '
  source = File.read(ARGV.fetch(0))
  required = {
    "audit" => ["dsa-audit", "audit", "lucairn-mtls-audit"],
    "id-bridge" => ["dsa-bridge", "id-bridge", "lucairn-mtls-id-bridge"],
    "sandbox-b" => ["dsa-ai", "sandbox-b", "lucairn-mtls-sandbox-b"]
  }
  required.each do |identity, (namespace, container, secret)|
    call = [identity, namespace, container, secret].join(" ")
    abort "Kind gate misses projected #{identity} workload roster" unless source.include?(call)
    pass = %q(echo "PASS: projected workload identity $identity verified exact-SAN TLS to veil-witness:50057")
    abort "Kind gate misses the stable projected workload identity PASS line" unless source.include?(pass)
  end
  abort "Kind gate does not identify Sandbox B as the pipeline workload" unless source.include?("Sandbox B is\n# the smallest mandatory pipeline choice")
  abort "Kind gate misses the three :50057 exact-SAN projected workload calls" unless source.include?("veil-witness.dsa-witness.svc.cluster.local:50057 dsa-veil-witness")
  resolve = source[/^resolve_projected_identity_workload\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind gate misses projected workload resolver")
  [
    "expected exactly one $identity workload Pod",
    "expected exactly one $container container",
    "mountPath \\\"$WORKLOAD_MTLS_DIR\\\"",
    "mounted_read_only",
    "mounted_secret",
    "enterprise-mtls",
    "would not use its own read-only projected mTLS Secret",
    "get node \"$node\"",
    "exec \"$WORKLOAD_POD\" -c \"$container\" -- uname -m"
  ].each { |needle| abort "projected workload resolver misses: #{needle}" unless resolve.include?(needle) }
  runner = source[/^projected_identity_witness_handshake\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind gate misses projected workload handshake runner")
  [
    "resolve_projected_identity_workload \"$identity\" \"$namespace\" \"$container\" \"$expected_secret\"",
    "build_workload_witness_helper \"$WORKLOAD_NODE_ARCH\"",
    "install_projected_identity_helper",
    "\"$WORKLOAD_HELPER_PATH\" tls-handshake \"$address\" \"$san\"",
    "\"$WORKLOAD_MTLS_DIR/ca.crt\" \"$WORKLOAD_MTLS_DIR/tls.crt\" \"$WORKLOAD_MTLS_DIR/tls.key\"",
    "projected_identity_helper_cleanup"
  ].each { |needle| abort "projected workload handshake runner misses: #{needle}" unless runner.include?(needle) }
  abort "projected workload helper reuses the gateway leaf" if runner.include?("/certs/gateway") || resolve.include?("lucairn-mtls-gateway")
  installer = source[/^install_projected_identity_helper\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind gate misses projected workload helper installer")
  ["WORKLOAD_HELPER_DIR=\"/dev/shm\"", "test -d \"$1\" && test -w \"$1\"", "cat > \"$1/$2\"", "chmod 0700 \"$1/$2\""].each do |needle|
    abort "projected workload helper installer misses bounded safe execution: #{needle}" unless source.include?(needle)
  end
  abort "projected workload helper installer writes into a Secret path" if installer.include?("/var/run/lucairn/mtls")
  calls = source.index("for identity_call in") || abort("Kind gate does not execute projected workload calls")
  pass = source.index("ENTERPRISE_HELM_MTLS_KIND: PASS") || abort("Kind gate misses PASS terminator")
  abort "projected workload calls are outside the real Kind gate" unless calls < pass
' "$KIND_GATE"

# Every Gateway proof and the gateway-local application health evidence
# must originate inside the real gateway container and use only a temporary,
# static standard-library Go helper. Its node target, Pod/container identity,
# projected input files, writable non-secret PVC parent, execution, bounded
# loopback health mode, and deletion are all fail-closed static requirements.
ruby -ropen3 -e '
  source = File.read(ARGV.fetch(0))
  required = [
    "GATEWAY_POD=\"${gateway_pods[0]}\"",
    "GATEWAY_CONTAINER=\"gateway\"",
    "expected exactly one gateway Pod after rollout",
    "expected exactly one $GATEWAY_CONTAINER container",
    "GATEWAY_KEYSTORE_VOLUME=\"$(\"${K[@]}\" -n dsa-edge get pod \"$GATEWAY_POD\"",
    "does not mount the required writable keystore PVC parent $GATEWAY_HELPER_DIR",
    "is not a persistentVolumeClaim",
    "unsupported gateway Kind node architecture",
    "does not match node $GATEWAY_NODE architecture $GATEWAY_NODE_ARCH",
    "GATEWAY_NODE_ARCH=\"$(\"${K[@]}\" get node \"$GATEWAY_NODE\"",
    "GATEWAY_RUNTIME_MACHINE=\"$(\"${K[@]}\" -n dsa-edge exec \"$GATEWAY_POD\" -c \"$GATEWAY_CONTAINER\" -- uname -m)",
    "CGO_ENABLED=0 GOOS=linux GOARCH=\"$GATEWAY_NODE_ARCH\"",
    "gateway-tls-helper.go",
    "go build -trimpath",
    "-ldflags=",
    "-s -w",
    "GATEWAY_HELPER_DIR=\"/etc/dsa/keystore-dir\"",
    "GATEWAY_MTLS_DIR=\"/var/run/lucairn/mtls\"",
    "test -d \"$1\" && test -w \"$1\" && test ! -e \"$1/$2\"",
    "cat > \"$1/$2\"",
    "chmod 0700 \"$1/$2\"",
    "rm -f \"$1\"; test ! -e \"$1\"",
    "gateway_mtls_secret",
    "lucairn-mtls-gateway",
    "install_gateway_tls_helper",
    "gateway_workload_handshake audit.dsa-audit.svc.cluster.local:50051 dsa-audit || exit 1",
    "gateway_workload_handshake id-bridge.dsa-bridge.svc.cluster.local:50052 dsa-id-bridge || exit 1",
    "gateway_workload_handshake sandbox-a.dsa-identity.svc.cluster.local:50053 dsa-sandbox-a || exit 1",
    "gateway_workload_handshake sandbox-b.dsa-ai.svc.cluster.local:50054 dsa-sandbox-b || exit 1",
    "gateway_workload_handshake sandbox-a.dsa-identity.svc.cluster.local:8086 dsa-sanitizer || exit 1",
    "gateway_workload_handshake veil-witness.dsa-witness.svc.cluster.local:50057 dsa-veil-witness || exit 1",
    "gateway_workload_handshake veil-witness.dsa-witness.svc.cluster.local:50058 dsa-veil-witness || exit 1",
    "gateway evidence helper deleted after workload transport and local health battery",
    "supporting local-probe evidence only"
  ]
  required.each { |needle| abort "Gateway workload transport contract missing: #{needle}" unless source.include?(needle) }
  abort "generic witness probe call remains" if source.match?(/^positive_handshake veil-witness\./)
  helper = source[/^gateway_workload_handshake\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses Gateway workload helper runner")
  [
    "exec \"$GATEWAY_POD\" -c \"$GATEWAY_CONTAINER\" --",
    "\"$GATEWAY_HELPER_PATH\" tls-handshake \"$address\" \"$san\"",
    "\"$GATEWAY_MTLS_DIR/ca.crt\" \"$GATEWAY_MTLS_DIR/tls.crt\" \"$GATEWAY_MTLS_DIR/tls.key\""
  ].each { |needle| abort "Gateway workload helper runner misses: #{needle}" unless helper.include?(needle) }
  health = source[/^gateway_health_response\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses gateway-local health runner")
  [
    "exec \"$GATEWAY_POD\" -c \"$GATEWAY_CONTAINER\" --",
    "\"$GATEWAY_HELPER_PATH\" gateway-health",
    "mktemp -d \"${TMPDIR:-/tmp}/lucairn-gateway-health.XXXXXX\"",
    "umask 077",
    ">\"$stdout_file\" 2>\"$stderr_file\"",
    "GATEWAY_HEALTH_RESPONSE=\"$(<\"$stdout_file\")\"",
    "rm -f \"$stdout_file\" \"$stderr_file\"",
    "rmdir \"$capture_dir\""
  ].each { |needle| abort "gateway-local health runner misses: #{needle}" unless health.include?(needle) }
  abort "gateway-local health runner must not use the generic probe" if health.match?(/\bprobe\b/)
  abort "gateway-local health runner still merges kubectl stderr into JSON stdout" if health.include?("2>&1")

  # Model a nonzero kubectl helper exit: kubectl adds transport text to stderr,
  # while helper JSON stdout remains the sole parser input. The same real
  # runner must reject malformed stdout (including a valid JSON prefix plus
  # suffix) and retain status zero for a successful helper response.
  structured = source[/^gateway_health_response_is_structured\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses structured gateway health validator")
  identity_failure = source[/^gateway_health_response_has_identity_failure\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses parsed identity-failure validator")
  healthy = source[/^gateway_health_response_is_mtls_healthy\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses healthy gateway response validator")
  {
    object: [%q({"status":"unhealthy"}), true],
    prefix: ["transport diagnostic\\n{\"status\":\"unhealthy\"}", false],
    suffix: [%q({"status":"unhealthy"} trailing-data), false]
  }.each do |name, (fixture, expected)|
    _stdout, _stderr, result = Open3.capture3("bash", "-c", structured, stdin_data: fixture)
    abort "gateway structured validator #{name} fixture result changed" unless result.success? == expected
  end
  runner_fixture = <<~BASH
    mock_kubectl() {
      printf "%s" "$MOCK_STDOUT"
      printf "%s" "$MOCK_STDERR" >&2
      return "$MOCK_STATUS"
    }
    K=(mock_kubectl)
    GATEWAY_POD=gateway-fixture
    GATEWAY_CONTAINER=gateway
    GATEWAY_HELPER_PATH=gateway-helper
    gateway_health_response() {
    #{health}
    }
    gateway_health_response_is_structured() {
    #{structured}
    }
    gateway_health_response_has_identity_failure() {
    #{identity_failure}
    }
    gateway_health_response_is_mtls_healthy() {
    #{healthy}
    }
    gateway_health_response
    helper_status=$?
    if printf "%s" "$GATEWAY_HEALTH_RESPONSE" | gateway_health_response_has_identity_failure; then identity_status=0; else identity_status=$?; fi
    if printf "%s" "$GATEWAY_HEALTH_RESPONSE" | gateway_health_response_is_mtls_healthy; then healthy_status=0; else healthy_status=$?; fi
    printf "%s\\n%s\\n%s\\n" "$helper_status" "$identity_status" "$healthy_status"
    printf "%s" "$GATEWAY_HEALTH_RESPONSE"
  BASH
  fixtures = {
    nonzero_json: [
      %q({"status":"unhealthy","checks":{"identity":{"status":"fail"},"sanitizer":{"status":"fail"}}}),
      "command terminated with exit code 1; credential=top-secret; path=/private/private.key",
      [1, 0, 1]
    ],
    malformed: [
      %q({"status":"unhealthy","checks":{"identity":{"status":"fail"}}} trailing-data),
      "command terminated with exit code 1; credential=top-secret; path=/private/private.key",
      [1, 1, 1]
    ],
    success: [
      %q({"status":"healthy","checks":{"identity":{"status":"ok"},"sanitizer":{"status":"ok"},"sandbox_b":{"status":"ok"}}}),
      "", [0, 1, 0]
    ]
  }
  fixtures.each do |name, (stdout, stderr, expected_statuses)|
    output, diagnostics, process = Open3.capture3(
      { "MOCK_STDOUT" => stdout, "MOCK_STDERR" => stderr, "MOCK_STATUS" => expected_statuses.fetch(0).to_s },
      "bash", "-c", runner_fixture
    )
    abort "gateway health runner fixture #{name} did not complete" unless process.success?
    helper_status, identity_status, healthy_status, parser_input = output.split("\n", 4)
    actual_statuses = [helper_status, identity_status, healthy_status].map(&:to_i)
    abort "gateway health runner fixture #{name} changed status preservation" unless actual_statuses == expected_statuses
    abort "gateway health runner fixture #{name} mixed kubectl stderr into parser input" unless parser_input == stdout
    combined_output = output + diagnostics
    abort "gateway health runner fixture #{name} leaked transport diagnostics" if combined_output.include?("top-secret") || combined_output.include?("/private/private.key")
  end
  positive_health = source[/^gateway_health_mtls_healthy\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses bounded positive gateway health convergence")
  [
    "deadline=$((SECONDS + 40))",
    "while (( SECONDS < deadline )); do",
    "gateway_health_response_is_mtls_healthy",
    "gateway_health_response_is_structured",
    "[ \"$status\" -eq 0 ]",
    "sleep 2",
    "gateway_pod_re_resolve || true",
    "complete application-level healthy response within 40 seconds"
  ].each { |needle| abort "gateway positive health convergence misses: #{needle}" unless positive_health.include?(needle) }
  abort "gateway positive health convergence accepts a one-shot response" unless positive_health.match?(/while \(\( SECONDS < deadline \)\); do.*?gateway_health_response.*?sleep 2/m)
  healthy_response = source[/^gateway_health_response_is_mtls_healthy\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses complete gateway health JSON validator")
  [
    "response[\"status\"] == \"healthy\"",
    "%w[identity sanitizer sandbox_b]",
    "checks = response[\"checks\"]",
    "checks.is_a?(Hash)",
    "checks[dependency].is_a?(Hash)",
    "checks[dependency][\"status\"] == \"ok\""
  ].each { |needle| abort "gateway health validator misses required same-response status: #{needle}" unless healthy_response.include?(needle) }
  abort "gateway health validator does not require a JSON object" unless healthy_response.include?("response.is_a?(Hash)")
  {
    positive: [%q({"status":"healthy","checks":{"identity":{"status":"ok"},"sanitizer":{"status":"ok"},"sandbox_b":{"status":"ok"}}}), true],
    partial: [%q({"status":"healthy","checks":{"identity":{"status":"ok"},"sanitizer":{"status":"ok"}}}), false],
    malformed: [%q({"status":"healthy","checks":), false]
  }.each do |name, (fixture, expected)|
    _stdout, _stderr, status = Open3.capture3("bash", "-c", healthy_response, stdin_data: fixture)
    abort "gateway health validator #{name} nested-checks fixture result changed" unless status.success? == expected
  end
  rejection = source[/^gateway_identity_server_material_rejected\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses bounded gateway server-material rejection evidence")
  [
    "deadline=$((SECONDS + 40))",
    "while (( SECONDS < deadline )); do",
    "if [ \"$status\" -ne 0 ] && gateway_health_response_has_identity_failure <<<\"$response\"; then",
    "if gateway_health_response_is_structured <<<\"$response\"; then",
    "sleep 2",
    "gateway_pod_re_resolve",
    "server material left the real gateway identity client healthy through the 40s convergence window"
  ].each { |needle| abort "gateway server-material rejection lacks bounded convergence: #{needle}" unless rejection.include?(needle) }
  abort "gateway server-material rejection can print unstructured helper stdout" if rejection.match?(/printf .*"\$response"/)
  abort "gateway server-material rejection lacks a bounded terminal diagnostic" unless rejection.match?(/printf .*"\$diagnostic"/)
  abort "gateway server-material rejection accepts one-shot health evidence" unless rejection.match?(/while \(\( SECONDS < deadline \)\); do.*?gateway_health_response.*?sleep 2.*?continue/m)
  proof = rejection.index("if [ \"$status\" -ne 0 ] && gateway_health_response_has_identity_failure <<<\"$response\"; then") || abort("gateway server-material rejection does not require a nonzero helper result plus parsed identity failure")
  structured_retry = rejection.index("if gateway_health_response_is_structured <<<\"$response\"; then") || abort("gateway server-material rejection does not retry structured intermediate responses")
  turnover = rejection.index("if [ \"$status\" -ne 0 ] && gateway_pod_re_resolve; then") || abort("gateway server-material rejection lost safe Pod-turnover recovery")
  terminal = rejection.index("echo \"FAIL: $description gateway /healthz did not produce non-2xx JSON identity status=fail\"") || abort("gateway server-material rejection misses fail-closed terminal failure")
  proof_return = rejection.index("return 0", proof) || abort("gateway server-material rejection does not return after identity-failure proof")
  abort "structured sanitizer-only failure can be terminal before identity convergence" unless proof < structured_retry && structured_retry < turnover && turnover < terminal
  abort "observed nonzero identity failure can reach a bounded terminal failure" unless proof < proof_return && proof_return < structured_retry
  abort "gateway server-material rejection retains loose identity text matching" if rejection.match?(/grep -Eq.*identity/)
  identity_failure = source[/^gateway_health_response_has_identity_failure\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses parsed identity-failure validator")
  [
    "response.is_a?(Hash)",
    "response[\"checks\"].is_a?(Hash)",
    "response[\"checks\"][\"identity\"].is_a?(Hash)",
    "response[\"checks\"][\"identity\"][\"status\"] == \"fail\""
  ].each { |needle| abort "identity-failure validator misses required structured check: #{needle}" unless identity_failure.include?(needle) }
  {
    identity_fail: [%q({"status":"unhealthy","checks":{"identity":{"status":"fail"},"sanitizer":{"status":"fail"}}}), true],
    sanitizer_only: [%q({"status":"unhealthy","checks":{"identity":{"status":"ok"},"sanitizer":{"status":"fail"}}}), false],
    overall_only: [%q({"status":"unhealthy","checks":{"identity":{"status":"ok"}}}), false],
    malformed: [%q({"status":"unhealthy","checks":), false],
    unstructured: ["gateway health request failed", false]
  }.each do |name, (fixture, expected)|
    _stdout, _stderr, status = Open3.capture3("bash", "-c", identity_failure, stdin_data: fixture)
    abort "identity-failure validator #{name} fixture result changed" unless status.success? == expected
  end
  re_resolve = source[/^gateway_pod_re_resolve\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness cannot safely re-resolve the gateway Pod")
  ["-l app.kubernetes.io/name=gateway", "could not safely re-resolve exactly one gateway Pod", "grep -Fxc \"$GATEWAY_CONTAINER\""].each do |needle|
    abort "gateway Pod re-resolution is not fail-closed: #{needle}" unless re_resolve.include?(needle)
  end
  ["gateway_pod_ips=", "GATEWAY_POD_IP=", "http://$1:8085/healthz", "curl --fail-with-body"].each do |forbidden|
    abort "Kind harness retains forbidden Pod-IP or generic-probe health evidence: #{forbidden}" if source.include?(forbidden)
  end

  gateway_transport = source.index("install_gateway_tls_helper") || abort("Gateway workload transport helper is missing")
  terminal_pass = source.index("echo \"PASS: coverage class=workload-originated transport handshake; origin=actual-gateway-pod") || abort("Gateway terminal workload-originated evidence is missing")
  [
    "audit.dsa-audit.svc.cluster.local:50051 dsa-audit",
    "id-bridge.dsa-bridge.svc.cluster.local:50052 dsa-id-bridge",
    "sandbox-a.dsa-identity.svc.cluster.local:50053 dsa-sandbox-a",
    "sandbox-b.dsa-ai.svc.cluster.local:50054 dsa-sandbox-b",
    "sandbox-a.dsa-identity.svc.cluster.local:8086 dsa-sanitizer"
  ].each do |edge|
    invocation = source.index("gateway_workload_handshake #{edge} || exit 1", gateway_transport) || abort("Gateway workload transport proof is missing: #{edge}")
    abort "Gateway workload transport proof must precede terminal PASS: #{edge}" unless invocation < terminal_pass
  end
  initial_health = source.index("\ngateway_health_mtls_healthy\n", gateway_transport) || abort("gateway initial local health proof is missing")
  server_battery = source.index("for server_material in wrong-ca wrong-san expired; do", initial_health) || abort("gateway server-material battery is missing")
  cleanup = source.index("\ngateway_tls_helper_cleanup\n", server_battery)
  partial_material = source.index("# Partial material must block Pod startup", server_battery)
  abort "gateway helper must remain installed through the initial local health proof" unless cleanup && cleanup > initial_health
  abort "gateway helper must remain installed through all server-material mutations and restores" unless cleanup > server_battery
  abort "gateway helper must be deleted before the next battery" unless partial_material && cleanup < partial_material

  source_start = source.index("package main") || abort("Kind harness misses generated Gateway Go source")
  source_end = source.index("\nGO\n", source_start) || abort("Kind harness does not terminate generated Gateway Go source")
  go_source = source[source_start...source_end]
  imports = go_source[/import \(\n(?<items>.*?)\n\)/m, :items] || abort("Gateway TLS Go helper misses import block")
  actual_imports = imports.scan(/"([^"]+)"/).flatten.sort
  expected_imports = %w[context crypto/sha256 crypto/tls crypto/x509 encoding/hex errors fmt io net net/http os strings time].sort
  abort "Gateway TLS Go helper is not standard-library-only: #{actual_imports.inspect}" unless actual_imports == expected_imports
  [
    "case \"tls-handshake\":",
    "case \"fingerprint\":",
    "case \"client-auth-rejection\":",
    "case \"serve\":",
    "case \"ready\":",
    "case \"gateway-health\":",
    "tls.LoadX509KeyPair(certPath, keyPath)",
    "roots.AppendCertsFromPEM(caPEM)",
    "tlsOperationTimeout    = 10 * time.Second",
    "MinVersion:         tls.VersionTLS13",
    "ServerName:         serverName",
    "RootCAs:            roots",
    "InsecureSkipVerify: false",
    "config.VerifyConnection = func(state tls.ConnectionState) error",
    "state.PeerCertificates[0].VerifyHostname(verifyHostname)",
    "verifiedServer = true",
    "if !verifiedServer {",
    "isRemoteTLSAlert(err)",
    "strings.HasPrefix(err.Error(), \"remote error: tls:\")",
    "func formatFingerprint(raw []byte) string",
    "sha256 Fingerprint=",
    "probeServeLifetime     = 45 * time.Minute",
    "func runProbeReady()",
    "verified TLS handshake failed",
    "healthURL              = \"http://127.0.0.1:8085/healthz\"",
    "context.WithTimeout(context.Background(), healthRequestTimeout)",
    "Timeout: healthRequestTimeout",
    "Proxy:                 nil",
    "ResponseHeaderTimeout: healthDialTimeout",
    "io.LimitReader(response.Body, maxHealthResponseBytes+1)",
    "http.StatusOK || response.StatusCode == http.StatusServiceUnavailable",
    "os.Stdout.Write(responseBody)",
    "response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices",
    "gateway health request failed"
  ].each { |needle| abort "Gateway TLS Go helper misses: #{needle}" unless go_source.include?(needle) }
  abort "Gateway TLS Go helper leaks errors that could contain sensitive paths or material" if go_source.match?(/fmt\.(?:Print|Printf|Fprintf).*err/)

  fingerprint = source[/^served_leaf_fingerprint\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses served leaf fingerprint helper")
  abort "fingerprint helper does not invoke the static probe directly" unless fingerprint.include?("/probe fingerprint \"$address\" \"$san\" \"$san\"")
  abort "fingerprint helper does not use the Gateway projected leaf" unless fingerprint.include?("/certs/gateway/ca.crt") && fingerprint.include?("/certs/gateway/tls.key")
  abort "fingerprint helper still executes OpenSSL" if fingerprint.include?("openssl") || fingerprint.include?("timeout")

  rotation = source[/^await_served_leaf_fingerprint\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses exact audit replacement fingerprint convergence")
  [
    "deadline=$((SECONDS + 40))",
    "while (( SECONDS < deadline )); do",
    "served_leaf_fingerprint \"$address\" \"$san\"",
    "[ \"$observed\" = \"$expected\" ]",
    "served fingerprint was unparseable",
    "verified TLS fingerprint handshake failed",
    "sleep_seconds=2",
    "audit replacement did not serve the exact expected fingerprint within 40s"
  ].each { |needle| abort "audit rotation convergence misses: #{needle}" unless rotation.include?(needle) }
  abort "audit rotation convergence lost the static-helper bounded retry deadline" unless rotation.include?("deadline=$((SECONDS + 40))")
  abort "audit rotation convergence accepts any changed fingerprint" if rotation.match?(/!=\s*\"\$expected\".*return 0/m)
  expected_fingerprint = source.index("AUDIT_FINGERPRINT_EXPECTED=\"$(openssl x509 -in \"$ROTATE/tls.crt\"") || abort("rotation does not compute the local replacement fingerprint")
  secret_apply = source.index("create secret generic lucairn-mtls-audit", expected_fingerprint) || abort("rotation does not apply the replacement Secret")
  abort "rotation validates the replacement fingerprint after mutating the Secret" unless expected_fingerprint < secret_apply
  [
    "generated audit replacement leaf has no valid SHA-256 fingerprint",
    "[ \"$AUDIT_FINGERPRINT_EXPECTED\" = \"$AUDIT_FINGERPRINT_BEFORE\" ]",
    "await_served_leaf_fingerprint audit.dsa-audit.svc.cluster.local:50051 dsa-audit \"$AUDIT_FINGERPRINT_EXPECTED\"",
    "rotation replacement: audit served the exact expected replacement fingerprint",
    "CA rotation or CRL/OCSP policy"
  ].each { |needle| abort "audit rotation exact-material contract misses: #{needle}" unless source.include?(needle) }

  run_rotation_fixture = lambda do |name, sequence, expected_success|
    sequence_items = sequence.map { |item| %Q(\"#{item}\") }.join(" ")
    fixture = <<~BASH
      set -euo pipefail
      await_served_leaf_fingerprint() {
      #{rotation}
      }
      SECONDS=0
      calls_file="$(mktemp)"
      sequence=(#{sequence_items})
      served_leaf_fingerprint() {
        calls=$(( $(wc -l <"$calls_file") ))
        last_index=$((${#sequence[@]} - 1))
        if (( calls > last_index )); then index="$last_index"; else index="$calls"; fi
        item="${sequence[$index]}"
        printf "\\n" >>"$calls_file"
        if [ "$item" = FAIL ]; then
          return 1
        fi
        printf "%s\\n" "$item"
      }
      sleep() { SECONDS=$((SECONDS + $1)); }
      result_file="$(mktemp)"
      if await_served_leaf_fingerprint audit:50051 dsa-audit "sha256 Fingerprint=AA:BB" >"$result_file"; then status=0; else status=$?; fi
      result="$(<"$result_file")"
      rm -f "$result_file"
      calls=$(( $(wc -l <"$calls_file") ))
      rm -f "$calls_file"
      printf "%s\\n%s\\n%s\\n" "$status" "$calls" "$result"
    BASH
    output, diagnostics, process = Open3.capture3("bash", "-c", fixture)
    abort "audit rotation fixture #{name} did not complete" unless process.success?
    status, calls, result = output.split("\n", 3)
    succeeded = status == "0"
    abort "audit rotation fixture #{name} success changed: #{output.inspect}" unless succeeded == expected_success
    [calls.to_i, result.rstrip, diagnostics]
  end

  expected = "sha256 Fingerprint=AA:BB"
  old = "sha256 Fingerprint=11:22"
  third = "sha256 Fingerprint=CC:DD"
  calls, result, diagnostics = run_rotation_fixture.call(:exact, [expected], true)
  abort "exact replacement fingerprint did not pass immediately: #{[calls, result, diagnostics].inspect}" unless calls == 1 && result == expected && diagnostics.empty?
  calls, result, diagnostics = run_rotation_fixture.call(:stale_old_then_expected, [old, expected], true)
  abort "stale old fingerprint was not retried before the expected replacement" unless calls == 2 && result == expected && diagnostics.empty?
  calls, result, diagnostics = run_rotation_fixture.call(:third_then_expected, [third, expected], true)
  abort "unexpected third fingerprint was accepted or not retried" unless calls == 2 && result == expected && diagnostics.empty?
  calls, result, diagnostics = run_rotation_fixture.call(:third_only, [third], false)
  abort "unexpected third fingerprint passed rotation convergence" if result == expected
  abort "unexpected third fingerprint did not fail within the bounded retry count: #{[calls, result, diagnostics].inspect}" unless calls == 20 && diagnostics.include?("exact expected fingerprint within 40s")
  calls, result, diagnostics = run_rotation_fixture.call(:timeout, ["FAIL"], false)
  abort "fingerprint timeout did not fail within the bounded retry count" unless calls == 20 && diagnostics.include?("handshake failed")
  calls, result, diagnostics = run_rotation_fixture.call(:unparseable, ["not-a-fingerprint"], false)
  abort "unparseable fingerprint did not fail closed" unless calls == 20 && diagnostics.include?("served fingerprint was unparseable")
' "$KIND_GATE"

# Compile the generated source for the target OS with CGO disabled. This stays
# offline and does not start Kind, but catches a helper syntax/import drift that
# grep-level contract checks cannot see.
command -v go >/dev/null 2>&1 || {
  echo "Go is required to validate the generated Gateway TLS helper" >&2
  exit 1
}
GATEWAY_TLS_HELPER_SOURCE="$TMPDIR/gateway-tls-helper.go"
GATEWAY_TLS_HELPER="$TMPDIR/gateway-tls-helper"
GATEWAY_TLS_HELPER_HOST="$TMPDIR/gateway-tls-helper-host"
ruby -e '
  source = File.read(ARGV.fetch(0))
  source_start = source.index("package main") || abort("Kind harness misses generated Gateway Go source")
  source_end = source.index("\nGO\n", source_start) || abort("Kind harness does not terminate generated Gateway Go source")
  File.write(ARGV.fetch(1), source[source_start...source_end])
' "$KIND_GATE" "$GATEWAY_TLS_HELPER_SOURCE"
CGO_ENABLED=0 go build -trimpath -o "$GATEWAY_TLS_HELPER_HOST" "$GATEWAY_TLS_HELPER_SOURCE"
[ -x "$GATEWAY_TLS_HELPER_HOST" ] || {
  echo "generated Gateway TLS helper did not compile for the host" >&2
  exit 1
}
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$GATEWAY_TLS_HELPER" "$GATEWAY_TLS_HELPER_SOURCE"
[ -x "$GATEWAY_TLS_HELPER" ] || {
  echo "generated Gateway TLS helper did not compile as a Linux executable" >&2
  exit 1
}

# Server-side client-auth negatives must verify the normal server chain/SAN and
# accept only a non-timeout remote TLS alert; a connection failure or accepted
# connection is not evidence.
ruby -e '
  source = File.read(ARGV.fetch(0))
  abort "Kind harness retains mutable probe package installation" if source.include?("apk add --no-cache")
  generic = source[/^negative_handshake\(\) \{\n(?<body>.*?)^\}$/m, :body] || abort("Kind harness misses generic negative helper")
  abort "generic negative helper changed" unless generic.include?("probe_tls_handshake") && generic.include?("negative mTLS handshake unexpectedly passed")
  strict = source[/^strict_client_auth_rejection\(\) \{\n(?<body>.*?)^positive_handshake audit\.dsa-audit/m, :body] || abort("Kind harness misses shared strict client-auth helper")
  [
    "/probe client-auth-rejection \"$address\" \"$san\" \"$san\" \"$ca_file\"",
    "command+=(\"$client_cert\" \"$client_key\")",
    "exec enterprise-mtls-probe -- \"${command[@]}\"",
    "actual remote TLS alert"
  ].each do |argument|
    abort "strict client-auth helper omits #{argument}" unless strict.include?(argument)
  end
  abort "strict client-auth helper retains an OpenSSL shell path" if strict.include?("openssl") || strict.include?("sh -ec")
  go_start = source.index("package main") || abort("Kind harness misses generated static helper")
  go_source = source[go_start...source.index("\nGO\n", go_start)]
  ["func runClientAuthRejection(args []string)", "func clientAuthRejectionError(address, serverName, verifyHostname, caPath, certPath, keyPath string, clientMaterial bool) error", "tlsConfig(caPath, certPath, keyPath, serverName, clientMaterial)", "verifiedServer := false", "config.VerifyConnection = func(state tls.ConnectionState) error", "state.PeerCertificates[0].VerifyHostname(verifyHostname)", "verifiedServer = true", "if !verifiedServer {", "conn.HandshakeContext(ctx)", "isTimeout(err)", "isRemoteTLSAlert(err)", "strings.HasPrefix(err.Error(), \"remote error: tls:\")"].each do |needle|
    abort "static client-auth helper misses #{needle}" unless go_source.include?(needle)
  end
  abort "static client-auth verification flag must be set only by VerifyConnection" unless go_source.scan("verifiedServer = true").length == 1
  abort "missing-client negative still uses the generic helper" if source.match?(/^negative_handshake missing-client-cert /)
  abort "expired-client negative still uses the generic helper" if source.match?(/^negative_handshake expired-client-cert /)
  {
    "missing-client-cert" => "audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/gateway/ca.crt",
    "expired-client-cert" => "audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/expired/ca.crt /certs/expired/tls.crt /certs/expired/tls.key"
  }.each do |description, arguments|
    abort "#{description} does not use the shared strict client-auth helper" unless source.include?("strict_client_auth_rejection #{description} #{arguments}")
  end
' "$KIND_GATE"

# The probe is a locally built static scratch image. Pod readiness and serving
# must invoke /probe directly, with only the three read-only cert/config mounts.
ruby -ryaml -e '
  source = File.read(ARGV.fetch(0))
  match = source.match(%r{(?<pod>apiVersion: v1\nkind: Pod\nmetadata:\n  name: enterprise-mtls-probe\n.*?^YAML$)}m) || abort("Kind harness misses enterprise mTLS probe manifest")
  pod = YAML.load(match[:pod].sub(/\nYAML\z/, "\n"))
  container = pod.fetch("spec").fetch("containers").find { |item| item["name"] == "probe" } || abort("enterprise mTLS probe misses static helper container")
  expected = {
    "exec" => { "command" => ["/probe", "ready"] },
    "periodSeconds" => 1,
    "timeoutSeconds" => 1,
    "failureThreshold" => 60
  }
  abort "enterprise mTLS probe readiness must use the static helper" unless container["readinessProbe"] == expected
  abort "enterprise mTLS probe must invoke /probe directly" unless container["command"] == ["/probe", "serve"]
  abort "enterprise mTLS probe must never pull the local image" unless container["imagePullPolicy"] == "Never"
  expected_pod_security_context = {
    "runAsNonRoot" => true,
    "runAsUser" => 65532,
    "runAsGroup" => 65532,
    "seccompProfile" => { "type" => "RuntimeDefault" }
  }
  abort "enterprise mTLS probe must not mount a service-account token" unless pod.dig("spec", "automountServiceAccountToken") == false
  abort "enterprise mTLS probe pod security posture changed" unless pod.dig("spec", "securityContext") == expected_pod_security_context
  expected_container_security_context = {
    "allowPrivilegeEscalation" => false,
    "readOnlyRootFilesystem" => true,
    "capabilities" => { "drop" => ["ALL"] }
  }
  abort "enterprise mTLS probe container security posture changed" unless container["securityContext"] == expected_container_security_context
  mounts = container.fetch("volumeMounts")
  expected_mounts = [["gateway", "/certs/gateway"], ["expired", "/certs/expired"], ["wrong-ca", "/certs/wrong-ca"]]
  abort "enterprise mTLS probe mount roster changed" unless mounts.map { |item| [item["name"], item["mountPath"]] } == expected_mounts
  abort "enterprise mTLS probe has a writable certificate/config mount" unless mounts.all? { |item| item["readOnly"] == true }
  abort "enterprise mTLS probe has a non-harness image tag" unless container["image"] == "${PROBE_IMAGE}"
' "$KIND_GATE"

ruby -e '
  source = File.read(ARGV.fetch(0))
  dockerfile = source[/cat > "\$PROBE_DOCKERFILE" <<\x27DOCKERFILE\x27\n(?<body>.*?)^DOCKERFILE$/m, :body] || abort("Kind harness misses local probe Dockerfile")
  abort "local probe Dockerfile must use scratch only" unless dockerfile == "FROM scratch\nCOPY probe /probe\n"
  ["PROBE_IMAGE=\"lucairn-enterprise-mtls-probe:kind-$$\"", "docker build --network=none --pull=false --platform \"linux/$GATEWAY_NODE_ARCH\" --tag \"$PROBE_IMAGE\"", "PROBE_IMAGE_ID=\"$(docker image inspect --format", "[[ \"$PROBE_IMAGE_ID\" =~ ^sha256:[0-9a-f]{64}$ ]]", "docker image save --output \"$PROBE_ARCHIVE\" \"$PROBE_IMAGE_ID\" \"$PROBE_IMAGE\"", "require_probe_archive_tag_binding \"$PROBE_ARCHIVE\" \"$PROBE_IMAGE\" \"$PROBE_IMAGE_ID\"", "archive must contain exactly one manifest entry", "kind load image-archive --name \"$CLUSTER\" \"$PROBE_ARCHIVE\"", "docker image rm -f \"$PROBE_IMAGE\""].each do |needle|
    abort "local probe supply-chain control missing: #{needle}" unless source.include?(needle)
  end
  ["alpine:3.20", "apk add", "openssl s_client", "probe() {"].each do |forbidden|
    abort "Kind harness retains remote/mutable probe residue: #{forbidden}" if source.include?(forbidden)
  end
' "$KIND_GATE"

# Extract and execute only the scratch-probe build/inspect/save/load sequence
# with local doubles. The Docker double retags the mutable probe name as soon
# as the script captures .Id; save must receive that captured ID and tag. A
# valid selected-platform config differs from the captured index digest, while
# a retargeted tag yields two manifest entries and must not reach Kind.
PROBE_PRELOAD="$TMPDIR/probe-preload.sh"
ruby -e '
  source = File.read(ARGV.fetch(0))
  start = source.index("PROBE_IMAGE=\"lucairn-enterprise-mtls-probe:kind-$$\"") || abort("Kind harness misses local probe preload")
  finish = source.index("\n\n\"${K[@]}\" -n dsa-edge create configmap enterprise-mtls-negative-ca", start) || abort("Kind harness misses local probe preload boundary")
  File.write(ARGV.fetch(1), source[start...finish])
' "$KIND_GATE" "$PROBE_PRELOAD"
PROBE_FAKE_BIN="$TMPDIR/probe-fake-bin"
PROBE_STATE="$TMPDIR/probe-state"
mkdir -p "$PROBE_FAKE_BIN" "$PROBE_STATE"
printf '%s\n' helper > "$PROBE_STATE/gateway-tls-helper"
chmod 0700 "$PROBE_STATE/gateway-tls-helper"
cat > "$PROBE_FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${2:-}" in
  build:--network=none)
    [ "${3:-}" = "--pull=false" ] && [ "${4:-}" = "--platform" ] && [ "${5:-}" = "linux/amd64" ] || exit 91
    ;;
  image:inspect)
    [ "$#" -eq 5 ] && [ "$3" = "--format" ] && [ "$4" = "{{.Id}}" ] || exit 92
    # The mutable tag is substituted immediately after validation returns.
    : > "$PROBE_TAG_SUBSTITUTED"
    printf '%s\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ;;
  image:save)
    [ "$#" -eq 6 ] && [ "$3" = "--output" ] && [ -e "$PROBE_TAG_SUBSTITUTED" ] || exit 93
    [ "$5" = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ] || exit 94
    case "$6" in lucairn-enterprise-mtls-probe:kind-[0-9]*) ;; *) exit 95 ;; esac
    ARCHIVE="$4" RUNTIME_TAG="$6" PROBE_ARCHIVE_TAG_RETARGETED="${PROBE_ARCHIVE_TAG_RETARGETED:-}" ruby -rjson -rrubygems/package -e '
      entry = {
        "Config" => "blobs/sha256/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "RepoTags" => [ENV.fetch("RUNTIME_TAG")],
        "Layers" => []
      }
      manifest = JSON.generate(
        if ENV.fetch("PROBE_ARCHIVE_TAG_RETARGETED", "") == "1"
          [entry.merge("RepoTags" => nil), entry.merge("Config" => "blobs/sha256/#{"c" * 64}")]
        else
          [entry]
        end
      )
      File.open(ENV.fetch("ARCHIVE"), "wb") do |file|
        Gem::Package::TarWriter.new(file) do |tar|
          tar.add_file_simple("manifest.json", 0o644, manifest.bytesize) { |entry| entry.write(manifest) }
        end
      end
    '
    printf '%s %s\n' "$5" "$6" > "$PROBE_SAVE_ARGUMENT"
    ;;
  *) exit 96 ;;
esac
DOCKER
cat > "$PROBE_FAKE_BIN/kind" <<'KIND'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = "load" ] && [ "${2:-}" = "image-archive" ] && [ "${3:-}" = "--name" ] \
  && [ "${4:-}" = "probe-preload-test" ] && [ -s "${5:-}" ] || exit 96
[ -z "${PROBE_KIND_LOAD:-}" ] || : > "$PROBE_KIND_LOAD"
KIND
chmod 0700 "$PROBE_FAKE_BIN/docker" "$PROBE_FAKE_BIN/kind"
PROBE_TAG_SUBSTITUTED="$TMPDIR/probe-tag-substituted"
PROBE_SAVE_ARGUMENT="$TMPDIR/probe-save-argument"
if ! PATH="$PROBE_FAKE_BIN:$PATH" STATE_DIR="$PROBE_STATE" \
  GATEWAY_TLS_HELPER="$PROBE_STATE/gateway-tls-helper" GATEWAY_NODE_ARCH=amd64 \
  PROBE_ARCHIVE="$PROBE_STATE/enterprise-mtls-probe.tar" CLUSTER=probe-preload-test \
  PROBE_TAG_SUBSTITUTED="$PROBE_TAG_SUBSTITUTED" PROBE_SAVE_ARGUMENT="$PROBE_SAVE_ARGUMENT" \
  bash -e "$PROBE_PRELOAD"; then
  echo "Kind scratch-probe preload did not save its validated immutable ID" >&2
  exit 1
fi
[ -e "$PROBE_TAG_SUBSTITUTED" ] && grep -Eq '^sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa lucairn-enterprise-mtls-probe:kind-[0-9]+$' "$PROBE_SAVE_ARGUMENT" || {
  echo "Kind scratch-probe preload saved a mutable tag after substitution" >&2
  exit 1
}
PROBE_RETARGETED_KIND_LOAD="$TMPDIR/probe-retargeted-kind-load"
if PATH="$PROBE_FAKE_BIN:$PATH" STATE_DIR="$PROBE_STATE" \
  GATEWAY_TLS_HELPER="$PROBE_STATE/gateway-tls-helper" GATEWAY_NODE_ARCH=amd64 \
  PROBE_ARCHIVE="$PROBE_STATE/enterprise-mtls-probe-retargeted.tar" CLUSTER=probe-preload-test \
  PROBE_TAG_SUBSTITUTED="$PROBE_TAG_SUBSTITUTED" PROBE_SAVE_ARGUMENT="$PROBE_SAVE_ARGUMENT" \
  PROBE_ARCHIVE_TAG_RETARGETED=1 PROBE_KIND_LOAD="$PROBE_RETARGETED_KIND_LOAD" \
  bash -e "$PROBE_PRELOAD" >"$TMPDIR/probe-retargeted.stdout" 2>"$TMPDIR/probe-retargeted.stderr"; then
  echo "Kind scratch-probe preload accepted a retargeted multi-entry archive" >&2
  exit 1
fi
grep -Fq 'archive must contain exactly one manifest entry' "$TMPDIR/probe-retargeted.stderr" \
  || { cat "$TMPDIR/probe-retargeted.stderr" >&2; echo "Kind scratch-probe preload did not reject the retargeted manifest" >&2; exit 1; }
[ ! -e "$PROBE_RETARGETED_KIND_LOAD" ] \
  || { echo "Kind scratch-probe preload loaded a retargeted archive before rejection" >&2; exit 1; }

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
  abort "accepted fixture does not enable Veil Witness" unless fixture.dig("veil-witness", "enabled") == true
  abort "generated runtime values do not enable Veil Witness" unless runtime.dig("veil-witness", "enabled") == true
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
    if [ "$#" -eq 5 ] && [ "$3" = '--format' ] && [ "$4" = '{{.Os}}/{{.Architecture}}' ] && [ "$5" = 'sha256:runtime-render-node' ]; then
      printf '%s\n' 'linux/arm64'
    elif [ "$#" -eq 5 ] && [ "$3" = '--format' ] && [ "$4" = '{{range .RepoDigests}}{{println .}}{{end}}' ]; then
      case "$5" in
        ghcr.io/declade/dsa-audit:0.5.4) digest='sha256:52fb366d5b425618a14f15d9a9a5e9abf6d1bf51cfcdc4c56e655884f53b0404' ;;
        ghcr.io/declade/dsa-gateway:0.5.4) digest='sha256:f73e55e0a3d3445d3242d2a73aff7086427da50cbcd2e47e3c8cd4f0fad2bece' ;;
        ghcr.io/declade/dsa-id-bridge:0.5.4) digest='sha256:3aaee7958071e95fae29847679537e949b0876c6b423a3653ae9ed4fb4baf746' ;;
        ghcr.io/declade/dsa-sandbox-a:0.5.4) digest='sha256:8b75837e5b123e6f0c4c89a26ae72b6c73627cfb508a73b1c01f713f6be36b84' ;;
        ghcr.io/declade/dsa-sandbox-b:0.5.4) digest='sha256:8aad459fc04a03de849cb2cc6ae812146b46d89bc023e171e232cf7ee7d09aef' ;;
        ghcr.io/declade/dsa-sanitizer:0.5.4) digest='sha256:5204d30b1cd4ae12ec2faf47eaf7a4f9fdfaf5137c37cb625752f96452eea9df' ;;
        ghcr.io/declade/dsa-veil-witness:0.5.4) digest='sha256:edc110fd5f827604790cee2be4a963ad03ee7201cbfb1262d2b23ff95a500523' ;;
        migrate/migrate:v4.17.0) digest='sha256:4d017c6fb5997127093648cab09e63d377997125c3d3dcca18e5d1c847da49fa' ;;
        postgres:16-alpine) digest='sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777' ;;
        redis:7-alpine) digest='sha256:6ab0b6e7381779332f97b8ca76193e45b0756f38d4c0dcda72dbb3c32061ab99' ;;
        *) exit 82 ;;
      esac
      printf '%s@%s\n' "${5%%:*}" "$digest"
    elif [ "$#" -eq 5 ] && [ "$3" = '--format' ] && [ "$4" = '{{.Id}}' ]; then
      printf '%s\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    else
      exit 82
    fi
    ;;
  pull:*)
    [ "$#" -eq 4 ] && [ "$2" = '--platform' ] && [ "$3" = 'linux/arm64' ] || exit 83
    printf 'pull %s %s\n' "$3" "$4" >> "$PRELOAD_CALLS"
    ;;
  image:save)
    [ "$#" -eq 8 ] && [ "$3" = '--platform' ] && [ "$4" = 'linux/arm64' ] && [ "$5" = '--output' ] || exit 84
    case "$6" in "$PRELOAD_ARCHIVE_DIR"/image-[0-9]*.tar) ;; *) exit 85 ;; esac
    [ ! -e "$6" ] || exit 86
    if find "$PRELOAD_ARCHIVE_DIR" -type f -print -quit | grep -q .; then exit 87; fi
    [ "$7" = 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ] || exit 88
    case "$8" in ghcr.io/declade/*:0.5.4|migrate/migrate:v4.17.0|postgres:16-alpine|redis:7-alpine) ;; *) exit 89 ;; esac
    ARCHIVE="$6" RUNTIME_TAG="$8" ruby -rjson -rrubygems/package -e '
      manifest = JSON.generate([{
        "Config" => "blobs/sha256/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "RepoTags" => [ENV.fetch("RUNTIME_TAG")],
        "Layers" => []
      }])
      File.open(ENV.fetch("ARCHIVE"), "wb") do |file|
        Gem::Package::TarWriter.new(file) do |tar|
          tar.add_file_simple("manifest.json", 0o644, manifest.bytesize) { |entry| entry.write(manifest) }
        end
      end
    '
    printf 'save %s %s %s\n' "$4" "$7" "$8" >> "$PRELOAD_CALLS"
    ;;
  *) exit 90 ;;
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
    grep -Fxq "pull linux/arm64 $image" "$PRELOAD_CALLS" \
      || { echo "rendered image was not pulled before install: $image" >&2; exit 1; }
  done < "$PRELOAD_IMAGES"
  while IFS= read -r image; do
    grep -Fxq "save linux/arm64 sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa $image" "$PRELOAD_CALLS" \
      || { echo "rendered image was not saved with its captured immutable ID and runtime tag for the Kind node platform: $image" >&2; exit 1; }
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

# The real-cluster battery must prove workload behavior, not only probe-Pod
# handshakes. Keep the gateway-local health call, its tlsutil mechanism-class
# citation, sanitizer HTTPS/wire evidence, and the bounded representative
# server-material mutations from regressing back to an OpenSSL-only claim.
for required in \
  '-l app.kubernetes.io/name=gateway' \
  'http://127.0.0.1:8085/healthz' \
  '"$GATEWAY_HELPER_PATH" gateway-health' \
  'gateway health request failed' \
  'gateway /healthz did not produce non-2xx JSON identity status=fail' \
  'tlsutil.ClientCredentialsForPeer(tlsutil.SANSandboxA)' \
  'gateway_health_mtls_healthy' \
  'gateway_identity_server_material_rejected' \
  'gateway evidence helper deleted after workload transport and local health battery' \
  'SANITIZER_URL="$("${K[@]}" -n dsa-edge get configmap gateway-config' \
  'https://sandbox-a.dsa-identity.svc:8086' \
  'actual client response plus verified mTLS wire fingerprint' \
  'for server_material in wrong-ca wrong-san expired' \
  'restore_sandbox_a_server_material' \
  'AUDIT_FINGERPRINT_BEFORE="$(served_leaf_fingerprint' \
  'AUDIT_FINGERPRINT_EXPECTED="$(openssl x509 -in "$ROTATE/tls.crt"' \
  'await_served_leaf_fingerprint audit.dsa-audit.svc.cluster.local:50051 dsa-audit "$AUDIT_FINGERPRINT_EXPECTED"' \
  'audit replacement did not serve the exact expected fingerprint within 40s' \
  'CA rotation or CRL/OCSP policy'; do
  grep -Fq -- "$required" "$KIND_GATE" \
    || { echo "Kind harness misses required workload-mTLS evidence: $required" >&2; exit 1; }
done
for forbidden in \
  'gateway_pod_ips=' \
  'GATEWAY_POD_IP=' \
  'http://$1:8085/healthz' \
  'curl --fail-with-body'; do
  if grep -Fq -- "$forbidden" "$KIND_GATE"; then
    echo "Kind harness retains forbidden Pod-IP or generic-probe health evidence: $forbidden" >&2
    exit 1
  fi
done

# Customer-facing evidence must retain the transport/application boundary.
# Stable terminal PASS lines and the adjacent install ledger must never relabel
# a TLS-only proof as an application call or promise exhaustive application
# coverage without a separately scoped runtime workstream.
ruby -e '
  harness = File.read(ARGV.fetch(0))
  ledger = File.read(ARGV.fetch(1))
  ledger_normalized = ledger.gsub(/\s+/, " ")
  pass_lines = [
    "PASS: coverage class=workload-originated transport handshake; origin=actual-gateway-pod; projected-leaf=gateway; edges=gateway-to-audit,gateway-to-id-bridge,gateway-to-sandbox-a,gateway-to-sandbox-b,gateway-to-sanitizer,gateway-to-witness-50057,gateway-to-witness-50058; server-SANs=dsa-audit,dsa-id-bridge,dsa-sandbox-a,dsa-sandbox-b,dsa-sanitizer,dsa-veil-witness",
    "PASS: coverage class=workload-originated transport handshake; projected-leaves=audit,id-bridge,sandbox-b; edges=audit-to-witness,id-bridge-to-witness,sandbox-b-to-witness; server-SAN=dsa-veil-witness",
    "PASS: coverage class=application-layer call; gateway gRPC identity; expected-server-SAN=dsa-sandbox-a",
    "PASS: coverage class=application-layer call; gateway-to-sanitizer HTTPS; expected-server-SAN=dsa-sanitizer"
  ]
  pass_lines.each { |line| abort "Kind terminal evidence line drifted: #{line}" unless harness.include?(%Q(echo "#{line}")) }
  required_ledger_terms = [
    "### Kind acceptance evidence ledger",
    "supporting local-probe evidence",
    "workload-originated transport handshake",
    "Actual Gateway Pod / Gateway",
    "representative application-layer gateway gRPC identity",
    "representative application-layer gateway→sanitizer HTTPS",
    "Residual risk: a non-representative application client could be misconfigured despite transport success.",
    "Exhaustive per-edge application verification is deferred to a separately grilled and locked runtime workstream"
  ]
  required_ledger_terms.each { |term| abort "Kind evidence ledger omits #{term.inspect}" unless ledger_normalized.include?(term) }
  abort "Kind evidence ledger presents generic probe as the Gateway acceptance mechanism" if ledger_normalized.include?("| Gateway →") && ledger_normalized.include?("Transport handshake (harness probe)")
  witness_rows = ledger.lines.grep(/^\| .*Veil Witness/)
  abort "Kind evidence ledger wrongly calls Witness transport an application RPC" if witness_rows.any? { |row| row.match?(/\bapplication\b/i) }
' "$KIND_GATE" "$ROOT/INSTALL.md"

echo "enterprise mTLS Kind runtime-values contract: ok"
