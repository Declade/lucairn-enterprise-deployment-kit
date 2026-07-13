#!/usr/bin/env bash
set -euo pipefail

# Disposable real-cluster acceptance for the Enterprise default mTLS topology.
# All state is created under a unique /tmp directory and the Kind cluster name
# is unique to this invocation. No production context, trust store, or existing
# Kubernetes object is changed.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    -h|--help)
      echo "usage: $0 [--keep]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

umask 077
STATE_DIR="$(mktemp -d /tmp/lucairn-enterprise-mtls-kind.XXXXXX)"
CLUSTER="lucairn-enterprise-mtls-${USER:-local}-$$"
KUBECONFIG="$STATE_DIR/kubeconfig"
KIND_CONFIG="$STATE_DIR/kind.yaml"
RUNTIME_VALUES="$STATE_DIR/runtime-values.yaml"
WITNESS_SIGNED_MANIFEST="$STATE_DIR/witness-signed-manifest.json"
RENDERED_MANIFEST="$STATE_DIR/rendered-topology.yaml"
PRELOAD_IMAGES="$STATE_DIR/rendered-topology-images.txt"
PRELOAD_ARCHIVE_DIR="$STATE_DIR/preload-archives"
KUBECTL_BIN="${KUBECTL:-}"

cleanup() {
  local rc=$?
  if [ "$KEEP" -eq 1 ]; then
    echo "enterprise mTLS Kind state retained: cluster=$CLUSTER state=$STATE_DIR kubeconfig=$KUBECONFIG" >&2
  else
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT

if ! command -v kind >/dev/null 2>&1; then
  echo "BLOCKED: Kind is not installed; cannot run the real-cluster mTLS gate." >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "BLOCKED: docker/container runtime is not installed; Kind cannot create the isolated cluster." >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "BLOCKED: docker is installed but unavailable; Kind cannot create the isolated cluster." >&2
  docker info 2>&1 | sed -n '1,80p' >&2 || true
  exit 2
fi

if [ -z "$KUBECTL_BIN" ]; then
  KUBECTL_BIN="$(command -v kubectl || true)"
fi
if [ -z "$KUBECTL_BIN" ]; then
  # Isolated tool provision: never writes a system path. Pin may be overridden
  # by the caller if their Kind/Kubernetes skew policy requires it.
  KUBECTL_VERSION="${KUBECTL_VERSION:-v1.33.4}"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) echo "BLOCKED: unsupported host architecture for isolated kubectl provision: $(uname -m)" >&2; exit 2 ;;
  esac
  mkdir -p "$STATE_DIR/bin"
  KUBECTL_BIN="$STATE_DIR/bin/kubectl"
  if ! curl --fail --location --retry 1 --connect-timeout 15 \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl" \
    -o "$KUBECTL_BIN"; then
    echo "BLOCKED: could not provision isolated kubectl ${KUBECTL_VERSION}." >&2
    exit 2
  fi
  chmod 0700 "$KUBECTL_BIN"
fi

DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
if [ ! -r "$DOCKER_CONFIG_FILE" ]; then
  echo "BLOCKED: authenticated GHCR Docker config not readable at $DOCKER_CONFIG_FILE." >&2
  echo "Set DOCKER_CONFIG to an existing authenticated directory; no credentials are copied into this harness state." >&2
  exit 2
fi

cat > "$KIND_CONFIG" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
YAML

kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG" --kubeconfig "$KUBECONFIG" --wait 180s
K=("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG")

# values-prod pins Sandbox A and B to separate zones. Label the two isolated
# workers only; no cluster outside this harness is touched.
workers=()
while IFS= read -r node; do
  case "$node" in
    *-control-plane) ;;
    *-worker*) workers+=("$node") ;;
    *)
      echo "FAIL: unexpected non-worker Kind node: $node" >&2
      exit 1
      ;;
  esac
done < <(kind get nodes --name "$CLUSTER")
if [ "${#workers[@]}" -ne 2 ]; then
  echo "FAIL: expected exactly two Kind worker nodes, found ${#workers[@]}" >&2
  exit 1
fi
identity_node="${workers[0]}"
ai_node="${workers[1]}"
"${K[@]}" label node "$identity_node" dsa.io/zone=identity --overwrite
"${K[@]}" label node "$ai_node" dsa.io/zone=ai --overwrite

for namespace in dsa-edge dsa-audit dsa-bridge dsa-identity dsa-ai dsa-witness; do
  "${K[@]}" create namespace "$namespace" --dry-run=client -o yaml | "${K[@]}" apply -f -
  "${K[@]}" label namespace "$namespace" app.kubernetes.io/managed-by=Helm --overwrite
  "${K[@]}" annotate namespace "$namespace" \
    meta.helm.sh/release-name=lucairn \
    meta.helm.sh/release-namespace=lucairn --overwrite
done

bash "$ROOT/scripts/enterprise-mtls-fixture-certs.sh" "$STATE_DIR/certs"
# Generate the complete disposable customer-values document in the
# harness-owned STATE_DIR; it includes the static non-secret mTLS/topology
# contract plus fresh application values and is deliberately silent.
bash "$ROOT/scripts/generate-enterprise-mtls-kind-runtime-values.sh" "$RUNTIME_VALUES"
# The production gateway verifies this blob before opening its listeners. Build
# the signed output from the same coherent disposable key set, then project it
# through a dedicated operator-style Secret before Helm is invoked.
bash "$ROOT/scripts/generate-enterprise-mtls-kind-signed-manifest.sh" \
  "$RUNTIME_VALUES" "$WITNESS_SIGNED_MANIFEST"
"$ROOT/bin/lucairn" doctor \
  --values "$RUNTIME_VALUES" \
  --offline

# Render with the exact values passed to the subsequent install. The manifest
# remains harness-private because it contains the chart-managed pull Secret;
# the image list is then derived only from workload PodSpecs and loaded into
# every node before Helm creates any workload.
HELM_RUNTIME_ARGS=(
  -f "$ROOT/charts/lucairn/values-prod.yaml"
  -f "$RUNTIME_VALUES"
  --set global.skipPullSecretGuard=false
  --set 'global.imagePullSecrets[0].name=lucairn-registry'
  --set global.secrets.backend=k8s-native
  --set global.dnsRestriction=false
  --set global.wireguardEncryption=false
  --set global.postgresqlSslmode=disable
  --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG_FILE"
  --namespace lucairn
)
helm template lucairn "$ROOT/charts/lucairn" "${HELM_RUNTIME_ARGS[@]}" > "$RENDERED_MANIFEST"
bash "$ROOT/scripts/preload-enterprise-mtls-kind-images.sh" \
  --cluster "$CLUSTER" \
  --rendered-manifest "$RENDERED_MANIFEST" \
  --image-list "$PRELOAD_IMAGES" \
  --archive-dir "$PRELOAD_ARCHIVE_DIR"

create_leaf_secret() {
  local namespace="$1" name="$2" identity="$3"
  "${K[@]}" -n "$namespace" create secret generic "$name" \
    --from-file=ca.crt="$STATE_DIR/certs/$identity/ca.crt" \
    --from-file=tls.crt="$STATE_DIR/certs/$identity/tls.crt" \
    --from-file=tls.key="$STATE_DIR/certs/$identity/tls.key" \
    --dry-run=client -o yaml | "${K[@]}" apply -f -
}

create_leaf_secret dsa-edge lucairn-mtls-gateway gateway
create_leaf_secret dsa-audit lucairn-mtls-audit audit
create_leaf_secret dsa-bridge lucairn-mtls-id-bridge id-bridge
create_leaf_secret dsa-identity lucairn-mtls-sandbox-a sandbox-a
create_leaf_secret dsa-identity lucairn-mtls-sanitizer sanitizer
create_leaf_secret dsa-ai lucairn-mtls-sandbox-b sandbox-b
create_leaf_secret dsa-witness lucairn-mtls-veil-witness veil-witness
"${K[@]}" -n dsa-edge create secret generic lucairn-witness-signed-manifest \
  --from-file=witness-signed-manifest.json="$WITNESS_SIGNED_MANIFEST" \
  --dry-run=client -o yaml | "${K[@]}" apply -f -

# The Kind harness uses production values with these explicit test-environment
# exceptions: stock Kind has neither Cilium (DNS restriction and WireGuard) nor
# the bundled-Postgres TLS setup, and it has no External Secrets Operator CRDs.
# Therefore non-PKI application secrets use k8s-native here. The seven mTLS
# identity Secrets remain pre-created by this harness and operator/PKI-owned.
# The generated document also carries the static suppression of non-contract
# Admin, observability, optional profile, and Sandbox-B Ollama/model-pull
# workloads. Bundled service databases and caches remain enabled because the
# mandatory services need them.
# The private-registry guard remains fail-closed and is satisfied with the
# caller's authenticated Docker config.
helm upgrade --install lucairn "$ROOT/charts/lucairn" \
  "${HELM_RUNTIME_ARGS[@]}" \
  --create-namespace --kubeconfig "$KUBECONFIG" \
  --wait --wait-for-jobs --timeout 12m

for deployment in \
  dsa-edge/gateway dsa-audit/audit dsa-bridge/id-bridge \
  dsa-identity/sandbox-a dsa-ai/sandbox-b dsa-witness/veil-witness; do
  "${K[@]}" -n "${deployment%/*}" rollout status "deployment/${deployment#*/}" --timeout=8m
done

"${K[@]}" -n dsa-edge create configmap enterprise-mtls-negative-ca \
  --from-file=wrong-ca.crt="$STATE_DIR/certs/wrong-ca.crt" --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" -n dsa-edge create secret generic enterprise-mtls-expired-gateway \
  --from-file=ca.crt="$STATE_DIR/certs/expired-gateway/ca.crt" \
  --from-file=tls.crt="$STATE_DIR/certs/expired-gateway/tls.crt" \
  --from-file=tls.key="$STATE_DIR/certs/expired-gateway/tls.key" \
  --dry-run=client -o yaml | "${K[@]}" apply -f -

cat <<'YAML' | "${K[@]}" -n dsa-edge apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: enterprise-mtls-probe
spec:
  restartPolicy: Never
  containers:
    - name: openssl
      image: alpine:3.20
      command: ["sh", "-ec", "apk add --no-cache openssl coreutils >/dev/null && sleep 3600"]
      readinessProbe:
        exec:
          command: ["test", "-x", "/usr/bin/openssl"]
        periodSeconds: 1
        timeoutSeconds: 1
        failureThreshold: 60
      volumeMounts:
        - name: gateway
          mountPath: /certs/gateway
          readOnly: true
        - name: expired
          mountPath: /certs/expired
          readOnly: true
        - name: wrong-ca
          mountPath: /certs/wrong-ca
          readOnly: true
  volumes:
    - name: gateway
      secret:
        secretName: lucairn-mtls-gateway
    - name: expired
      secret:
        secretName: enterprise-mtls-expired-gateway
    - name: wrong-ca
      configMap:
        name: enterprise-mtls-negative-ca
YAML
"${K[@]}" -n dsa-edge wait --for=condition=Ready pod/enterprise-mtls-probe --timeout=4m

probe() {
  "${K[@]}" -n dsa-edge exec enterprise-mtls-probe -- sh -ec "$1" -- "${@:2}"
}
positive_handshake() {
  local address="$1" san="$2"
  probe "openssl s_client -connect '$address' -servername '$san' -verify_hostname '$san' -verify_return_error -CAfile /certs/gateway/ca.crt -cert /certs/gateway/tls.crt -key /certs/gateway/tls.key </dev/null >/dev/null"
}
negative_handshake() {
  local description="$1" command="$2"
  if probe "$command"; then
    echo "FAIL: negative mTLS handshake unexpectedly passed: $description" >&2
    exit 1
  fi
  echo "negative mTLS handshake rejected: $description"
}
strict_client_auth_rejection() {
  local description="$1" address="$2" san="$3" ca_file="$4"
  local client_cert="${5:-}" client_key="${6:-}"

  if [ -n "$client_cert" ] && [ -z "$client_key" ]; then
    echo "FAIL: $description strict client-auth check has a certificate without a key" >&2
    exit 1
  fi
  if [ -z "$client_cert" ] && [ -n "$client_key" ]; then
    echo "FAIL: $description strict client-auth check has a key without a certificate" >&2
    exit 1
  fi

  # TLS 1.3 can finish the client side of the handshake before the server
  # validates the client certificate. Keep stdin open to s_client and give the
  # server a bounded window to deliver its fatal alert. GNU timeout returns
  # 124 on an accepted/still-open connection; only a non-timeout OpenSSL error
  # accompanied by a server TLS alert proves rejection.
  if ! probe '
set +e
description=$1
address=$2
san=$3
ca_file=$4
client_cert=$5
client_key=$6

run_s_client() {
  timeout 15 openssl s_client \
    -connect "$address" \
    -servername "$san" \
    -verify_hostname "$san" \
    -verify_return_error \
    -CAfile "$ca_file" \
    "$@" \
    -quiet -ign_eof
}

result=$(mktemp)
if [ -n "$client_cert" ]; then
  run_s_client -cert "$client_cert" -key "$client_key" </dev/null >"$result" 2>&1
else
  run_s_client </dev/null >"$result" 2>&1
fi
status=$?
cat "$result" >&2
if [ "$status" -eq 124 ]; then
  echo "FAIL: $description handshake timed out waiting for server rejection" >&2
  rm -f "$result"
  exit 1
fi
if [ "$status" -eq 0 ]; then
  echo "FAIL: $description handshake remained accepted/open" >&2
  rm -f "$result"
  exit 1
fi
if [ "$status" -ge 125 ] && [ "$status" -le 127 ]; then
  echo "FAIL: $description handshake could not run OpenSSL under timeout" >&2
  rm -f "$result"
  exit 1
fi
if ! grep -Eiq "(tls|ssl).*alert|alert.*(tls|ssl)" "$result"; then
  echo "FAIL: $description handshake failed without a server TLS alert" >&2
  rm -f "$result"
  exit 1
fi
rm -f "$result"
exit 0
' "$description" "$address" "$san" "$ca_file" "$client_cert" "$client_key"; then
    echo "FAIL: $description mTLS client authentication was not rejected by the server" >&2
    exit 1
  fi
  echo "negative mTLS handshake rejected: $description"
}

positive_handshake audit.dsa-audit.svc.cluster.local:50051 dsa-audit
positive_handshake id-bridge.dsa-bridge.svc.cluster.local:50052 dsa-id-bridge
positive_handshake sandbox-a.dsa-identity.svc.cluster.local:50053 dsa-sandbox-a
positive_handshake sandbox-b.dsa-ai.svc.cluster.local:50054 dsa-sandbox-b
positive_handshake sandbox-a.dsa-identity.svc.cluster.local:8086 dsa-sanitizer
positive_handshake veil-witness.dsa-witness.svc.cluster.local:50057 dsa-veil-witness
positive_handshake veil-witness.dsa-witness.svc.cluster.local:50058 dsa-veil-witness

negative_handshake wrong-ca "openssl s_client -connect audit.dsa-audit.svc.cluster.local:50051 -servername dsa-audit -verify_return_error -CAfile /certs/wrong-ca/wrong-ca.crt -cert /certs/gateway/tls.crt -key /certs/gateway/tls.key </dev/null >/dev/null"
negative_handshake wrong-san "openssl s_client -connect audit.dsa-audit.svc.cluster.local:50051 -servername dsa-audit -verify_hostname dsa-sandbox-a -verify_return_error -CAfile /certs/gateway/ca.crt -cert /certs/gateway/tls.crt -key /certs/gateway/tls.key </dev/null >/dev/null"
strict_client_auth_rejection missing-client-cert audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/gateway/ca.crt
strict_client_auth_rejection expired-client-cert audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/expired/ca.crt /certs/expired/tls.crt /certs/expired/tls.key

# Partial material must block Pod startup before a plaintext listener exists.
"${K[@]}" -n dsa-ai delete secret lucairn-mtls-sandbox-b
"${K[@]}" -n dsa-ai rollout restart deployment/sandbox-b
if "${K[@]}" -n dsa-ai rollout status deployment/sandbox-b --timeout=75s; then
  echo "FAIL: missing mTLS Secret let sandbox-b become Ready" >&2
  exit 1
fi
"${K[@]}" -n dsa-ai create secret generic lucairn-mtls-sandbox-b \
  --from-file=ca.crt="$STATE_DIR/certs/sandbox-b/ca.crt" \
  --from-file=tls.crt="$STATE_DIR/certs/sandbox-b/tls.crt"
"${K[@]}" -n dsa-ai rollout restart deployment/sandbox-b
if "${K[@]}" -n dsa-ai rollout status deployment/sandbox-b --timeout=75s; then
  echo "FAIL: partial mTLS Secret let sandbox-b become Ready" >&2
  exit 1
fi
create_leaf_secret dsa-ai lucairn-mtls-sandbox-b sandbox-b
"${K[@]}" -n dsa-ai rollout restart deployment/sandbox-b
"${K[@]}" -n dsa-ai rollout status deployment/sandbox-b --timeout=6m

# Rotation proof: replacing the audit leaf and restarting only audit restores
# healthy handshakes. A same-CA old leaf is not a revocation mechanism; the
# separate expired-leaf negative above covers invalidation at certificate expiry.
ROTATE="$STATE_DIR/rotate-audit"
mkdir -p "$ROTATE"
openssl req -newkey rsa:2048 -nodes -sha256 -subj '/CN=dsa-audit' \
  -keyout "$ROTATE/tls.key" -out "$ROTATE/request.csr" >/dev/null 2>&1
printf '%s\n' 'subjectAltName=DNS:dsa-audit' 'extendedKeyUsage=serverAuth,clientAuth' > "$ROTATE/extensions.cnf"
openssl x509 -req -sha256 -days 2 -in "$ROTATE/request.csr" \
  -CA "$STATE_DIR/certs/ca.crt" -CAkey "$STATE_DIR/certs/ca.key" -CAcreateserial \
  -extfile "$ROTATE/extensions.cnf" -out "$ROTATE/tls.crt" >/dev/null 2>&1
"${K[@]}" -n dsa-audit create secret generic lucairn-mtls-audit \
  --from-file=ca.crt="$STATE_DIR/certs/ca.crt" \
  --from-file=tls.crt="$ROTATE/tls.crt" \
  --from-file=tls.key="$ROTATE/tls.key" --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" -n dsa-audit rollout restart deployment/audit
"${K[@]}" -n dsa-audit rollout status deployment/audit --timeout=6m
positive_handshake audit.dsa-audit.svc.cluster.local:50051 dsa-audit

echo "ENTERPRISE_HELM_MTLS_KIND: PASS"
