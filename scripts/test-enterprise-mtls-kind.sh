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

make_server_leaf() {
  local output_dir="$1" signing_ca="$2" signing_key="$3" san="$4"
  mkdir -p "$output_dir"
  openssl req -newkey rsa:2048 -nodes -sha256 -subj "/CN=$san" \
    -keyout "$output_dir/tls.key" -out "$output_dir/request.csr" >/dev/null 2>&1
  printf '%s\n' "subjectAltName=DNS:$san" 'extendedKeyUsage=serverAuth,clientAuth' > "$output_dir/extensions.cnf"
  openssl x509 -req -sha256 -days 2 -in "$output_dir/request.csr" \
    -CA "$signing_ca" -CAkey "$signing_key" -CAcreateserial \
    -extfile "$output_dir/extensions.cnf" -out "$output_dir/tls.crt" >/dev/null 2>&1
  rm -f "$output_dir/request.csr" "$output_dir/extensions.cnf"
}

create_leaf_secret dsa-edge lucairn-mtls-gateway gateway
create_leaf_secret dsa-audit lucairn-mtls-audit audit
create_leaf_secret dsa-bridge lucairn-mtls-id-bridge id-bridge
create_leaf_secret dsa-identity lucairn-mtls-sandbox-a sandbox-a
create_leaf_secret dsa-identity lucairn-mtls-sanitizer sanitizer
create_leaf_secret dsa-ai lucairn-mtls-sandbox-b sandbox-b
create_leaf_secret dsa-witness lucairn-mtls-veil-witness veil-witness

# The representative server-material negatives all target the same actual
# gateway→Sandbox-A workload edge. Keep the gateway trust bundle unchanged so
# each failure has one cause: wrong issuer, wrong server identity, or expiry.
INVALID_SERVER_DIR="$STATE_DIR/invalid-sandbox-a-server"
make_server_leaf "$INVALID_SERVER_DIR/wrong-ca" \
  "$STATE_DIR/certs/wrong-ca.crt" "$STATE_DIR/certs/wrong-ca.key" dsa-sandbox-a
make_server_leaf "$INVALID_SERVER_DIR/wrong-san" \
  "$STATE_DIR/certs/ca.crt" "$STATE_DIR/certs/ca.key" dsa-not-sandbox-a
mkdir -p "$INVALID_SERVER_DIR/expired"
cp "$STATE_DIR/certs/expired-sandbox-a/tls.crt" "$INVALID_SERVER_DIR/expired/tls.crt"
cp "$STATE_DIR/certs/expired-sandbox-a/tls.key" "$INVALID_SERVER_DIR/expired/tls.key"
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

# The witness NetworkPolicies select the real gateway workload identity, not
# the generic dsa-edge probe. Resolve that exact Pod and container before
# building the short-lived in-container proof helper. A label or architecture
# ambiguity is evidence failure, not a reason to fall back to the probe Pod.
gateway_pods=()
while IFS= read -r gateway_pod; do
  [ -n "$gateway_pod" ] && gateway_pods+=("$gateway_pod")
done < <("${K[@]}" -n dsa-edge get pods -l app.kubernetes.io/name=gateway \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [ "${#gateway_pods[@]}" -ne 1 ]; then
  echo "FAIL: expected exactly one gateway Pod after rollout, found ${#gateway_pods[@]}" >&2
  printf 'gateway Pods: %s\n' "${gateway_pods[*]:-(none)}" >&2
  exit 1
fi
GATEWAY_POD="${gateway_pods[0]}"
GATEWAY_CONTAINER="gateway"
gateway_container_count="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -Fxc "$GATEWAY_CONTAINER" || true)"
if [ "$gateway_container_count" -ne 1 ]; then
  echo "FAIL: expected exactly one $GATEWAY_CONTAINER container in gateway Pod $GATEWAY_POD" >&2
  exit 1
fi
GATEWAY_HELPER_DIR="/etc/dsa/keystore-dir"
GATEWAY_KEYSTORE_VOLUME="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
  -o go-template='{{range .spec.containers}}{{if eq .name "gateway"}}{{range .volumeMounts}}{{if eq .mountPath "/etc/dsa/keystore-dir"}}{{.name}}{{end}}{{end}}{{end}}{{end}}')"
if [ -z "$GATEWAY_KEYSTORE_VOLUME" ]; then
  echo "FAIL: gateway container does not mount the required writable keystore PVC parent $GATEWAY_HELPER_DIR" >&2
  exit 1
fi
GATEWAY_KEYSTORE_CLAIM="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
  -o go-template="{{range .spec.volumes}}{{if eq .name \"$GATEWAY_KEYSTORE_VOLUME\"}}{{with .persistentVolumeClaim}}{{.claimName}}{{end}}{{end}}{{end}}")"
if [ -z "$GATEWAY_KEYSTORE_CLAIM" ]; then
  echo "FAIL: gateway helper mount $GATEWAY_HELPER_DIR is not a persistentVolumeClaim" >&2
  exit 1
fi
GATEWAY_NODE="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" -o jsonpath='{.spec.nodeName}')"
if [ -z "$GATEWAY_NODE" ]; then
  echo "FAIL: gateway Pod $GATEWAY_POD has no scheduled node" >&2
  exit 1
fi
GATEWAY_NODE_ARCH="$("${K[@]}" get node "$GATEWAY_NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')"
case "$GATEWAY_NODE_ARCH" in
  amd64) GATEWAY_NODE_MACHINES='x86_64 amd64' ;;
  arm64) GATEWAY_NODE_MACHINES='aarch64 arm64' ;;
  *)
    echo "FAIL: unsupported gateway Kind node architecture: ${GATEWAY_NODE_ARCH:-(missing)}" >&2
    exit 1
    ;;
esac
GATEWAY_RUNTIME_MACHINE="$("${K[@]}" -n dsa-edge exec "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- uname -m)"
case " $GATEWAY_NODE_MACHINES " in
  *" $GATEWAY_RUNTIME_MACHINE "*) ;;
  *)
    echo "FAIL: gateway container architecture $GATEWAY_RUNTIME_MACHINE does not match node $GATEWAY_NODE architecture $GATEWAY_NODE_ARCH" >&2
    exit 1
    ;;
esac

GATEWAY_WITNESS_HELPER_SOURCE="$STATE_DIR/gateway-witness-tls-helper.go"
GATEWAY_WITNESS_HELPER="$STATE_DIR/gateway-witness-tls-helper"
cat > "$GATEWAY_WITNESS_HELPER_SOURCE" <<'GO'
// gateway-witness-tls-helper is generated only in the disposable harness
// state. It performs either one verified mutual-TLS handshake or a bounded
// loopback gateway health request and prints no secret material, even on
// failure.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

const (
	healthURL              = "http://127.0.0.1:8085/healthz"
	healthRequestTimeout   = 10 * time.Second
	healthDialTimeout      = 5 * time.Second
	maxHealthResponseBytes = 64 * 1024
)

func failTLS() {
	fmt.Fprintln(os.Stderr, "verified TLS handshake failed")
	os.Exit(1)
}

func failGatewayHealth() {
	fmt.Fprintln(os.Stderr, "gateway health request failed")
	os.Exit(1)
}

func runTLSHandshake(args []string) {
	if len(args) != 5 {
		failTLS()
	}
	address, serverName := args[0], args[1]
	caPath, certPath, keyPath := args[2], args[3], args[4]
	if address == "" || serverName == "" || caPath == "" || certPath == "" || keyPath == "" {
		failTLS()
	}

	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		failTLS()
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		failTLS()
	}
	clientCertificate, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		failTLS()
	}

	dialer := &net.Dialer{Timeout: 10 * time.Second}
	conn, err := tls.DialWithDialer(dialer, "tcp", address, &tls.Config{
		MinVersion:         tls.VersionTLS13,
		ServerName:         serverName,
		RootCAs:            roots,
		Certificates:       []tls.Certificate{clientCertificate},
		InsecureSkipVerify: false,
	})
	if err != nil {
		failTLS()
	}
	defer conn.Close()
	if err := conn.VerifyHostname(serverName); err != nil {
		failTLS()
	}
}

func runGatewayHealth() {
	ctx, cancel := context.WithTimeout(context.Background(), healthRequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, healthURL, nil)
	if err != nil {
		failGatewayHealth()
	}
	dialer := &net.Dialer{Timeout: healthDialTimeout}
	client := &http.Client{
		Timeout: healthRequestTimeout,
		Transport: &http.Transport{
			Proxy:                 nil,
			DialContext:           dialer.DialContext,
			ResponseHeaderTimeout: healthDialTimeout,
		},
	}
	response, err := client.Do(request)
	if err != nil {
		failGatewayHealth()
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxHealthResponseBytes+1))
	if err != nil || len(responseBody) > maxHealthResponseBytes {
		failGatewayHealth()
	}
	if response.StatusCode == http.StatusOK || response.StatusCode == http.StatusServiceUnavailable {
		if _, err := os.Stdout.Write(responseBody); err != nil {
			failGatewayHealth()
		}
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		os.Exit(1)
	}
}

func main() {
	if len(os.Args) < 2 {
		failTLS()
	}
	switch os.Args[1] {
	case "tls-handshake":
		runTLSHandshake(os.Args[2:])
	case "gateway-health":
		if len(os.Args) != 2 {
			failGatewayHealth()
		}
		runGatewayHealth()
	default:
		failTLS()
	}
}
GO
if ! command -v go >/dev/null 2>&1; then
  echo "BLOCKED: Go is required to build the disposable gateway witness TLS helper." >&2
  exit 2
fi
if ! CGO_ENABLED=0 GOOS=linux GOARCH="$GATEWAY_NODE_ARCH" \
  go build -trimpath -ldflags='-s -w' -o "$GATEWAY_WITNESS_HELPER" "$GATEWAY_WITNESS_HELPER_SOURCE"; then
  echo "FAIL: could not cross-compile the gateway witness TLS helper for linux/$GATEWAY_NODE_ARCH" >&2
  exit 1
fi
[ -x "$GATEWAY_WITNESS_HELPER" ] || {
  echo "FAIL: gateway witness TLS helper was not built as an executable" >&2
  exit 1
}

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

# Gateway /healthz is an application-level call executed in the actual gateway
# container through its loopback listener. In particular,
# gateway/internal/clients/identity.go builds
# its gRPC client with
# tlsutil.ClientCredentialsForPeer(tlsutil.SANSandboxA), and Ping performs the
# GetIdentity RPC. A healthy identity check below is therefore one real
# representative call for the shared tlsutil gRPC mechanism class. The five
# non-witness exact-SAN checks use the generic probe; the two witness checks
# below execute the helper's exact-SAN TLS mode inside the real gateway Pod.
# The same health response invokes SanitizerClient.Ping, which performs the
# gateway's real /readyz request through SanitizerHTTPClientConfig + ForceHTTPS
# when the DSA_MTLS_* client triple is projected.
gateway_health_response() {
  local capture_dir stdout_file stderr_file status previous_umask
  GATEWAY_HEALTH_RESPONSE=""
  GATEWAY_HEALTH_DIAGNOSTIC="gateway health helper did not return a structured response"

  # Keep the helper's stdout as the only candidate structured response. kubectl
  # appends its nonzero-exit message on stderr, which must not be mixed into
  # that JSON body. The private directory is removed on every return path and
  # neither its path nor the raw transport output is reported.
  previous_umask="$(umask)"
  umask 077
  if ! capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/lucairn-gateway-health.XXXXXX" 2>/dev/null)"; then
    umask "$previous_umask"
    GATEWAY_HEALTH_DIAGNOSTIC="gateway health capture was unavailable"
    return 1
  fi
  umask "$previous_umask"
  stdout_file="$capture_dir/stdout"
  stderr_file="$capture_dir/stderr"
  if ! : >"$stdout_file" || ! : >"$stderr_file"; then
    rm -f "$stdout_file" "$stderr_file"
    rmdir "$capture_dir" 2>/dev/null || true
    GATEWAY_HEALTH_DIAGNOSTIC="gateway health capture was unavailable"
    return 1
  fi

  if "${K[@]}" -n dsa-edge exec "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- \
    "$GATEWAY_HELPER_PATH" gateway-health >"$stdout_file" 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  GATEWAY_HEALTH_RESPONSE="$(<"$stdout_file")"
  if [ -s "$stderr_file" ]; then
    GATEWAY_HEALTH_DIAGNOSTIC="kubectl exec transport diagnostics were suppressed"
  elif [ "$status" -ne 0 ]; then
    GATEWAY_HEALTH_DIAGNOSTIC="kubectl exec returned a nonzero status"
  fi
  rm -f "$stdout_file" "$stderr_file"
  rmdir "$capture_dir" 2>/dev/null || true
  return "$status"
}

gateway_health_response_is_structured() {
  ruby -rjson -e '
    begin
      exit(JSON.parse(STDIN.read).is_a?(Hash) ? 0 : 1)
    rescue JSON::ParserError
      exit 1
    end
  '
}

gateway_health_response_is_mtls_healthy() {
  ruby -rjson -e '
    begin
      response = JSON.parse(STDIN.read)
    rescue JSON::ParserError
      exit 1
    end
    dependencies = %w[identity sanitizer sandbox_b]
    checks = response["checks"]
    exit(
      response.is_a?(Hash) &&
      response["status"] == "healthy" &&
      checks.is_a?(Hash) &&
      dependencies.all? { |dependency| checks[dependency].is_a?(Hash) && checks[dependency]["status"] == "ok" } ? 0 : 1
    )
  '
}

gateway_health_response_has_identity_failure() {
  ruby -rjson -e '
    begin
      response = JSON.parse(STDIN.read)
    rescue JSON::ParserError
      exit 1
    end
    exit(
      response.is_a?(Hash) &&
      response["checks"].is_a?(Hash) &&
      response["checks"]["identity"].is_a?(Hash) &&
      response["checks"]["identity"]["status"] == "fail" ? 0 : 1
    )
  '
}

gateway_health_mtls_healthy() {
  local response status diagnostic last_diagnostic="" deadline=$((SECONDS + 40))
  while (( SECONDS < deadline )); do
    if gateway_health_response; then
      status=0
    else
      status=$?
    fi
    response="$GATEWAY_HEALTH_RESPONSE"
    diagnostic="$GATEWAY_HEALTH_DIAGNOSTIC"
    last_diagnostic="$diagnostic"

    # A single JSON response must prove the overall state and every actual
    # workload client together; a partial or generic response is never healthy.
    if [ "$status" -eq 0 ] && gateway_health_response_is_mtls_healthy <<<"$response"; then
      echo "gateway health: application-level gRPC and sanitizer mTLS clients reported healthy"
      return 0
    fi

    # The restored server can take a short time to reconnect. Retry every
    # structured unhealthy response, including the helper's non-2xx JSON body.
    if gateway_health_response_is_structured <<<"$response"; then
      sleep 2
      continue
    fi

    # An unstructured nonzero result can be a gateway Pod exec turnover. Only
    # continue after attempting the existing fail-closed single-Pod resolution.
    if [ "$status" -ne 0 ]; then
      gateway_pod_re_resolve || true
    fi
    sleep 2
  done
  echo "FAIL: gateway /healthz did not converge to a complete application-level healthy response within 40 seconds" >&2
  printf '%s\n' "$last_diagnostic" >&2
  exit 1
}

gateway_pod_re_resolve() {
  local -a gateway_pods=()
  local gateway_pod gateway_container_count
  while IFS= read -r gateway_pod; do
    [ -n "$gateway_pod" ] && gateway_pods+=("$gateway_pod")
  done < <("${K[@]}" -n dsa-edge get pods -l app.kubernetes.io/name=gateway \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [ "${#gateway_pods[@]}" -ne 1 ]; then
    echo "FAIL: could not safely re-resolve exactly one gateway Pod after gateway health execution failure (found ${#gateway_pods[@]})" >&2
    printf 'gateway Pods: %s\n' "${gateway_pods[*]:-(none)}" >&2
    return 1
  fi
  GATEWAY_POD="${gateway_pods[0]}"
  gateway_container_count="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -Fxc "$GATEWAY_CONTAINER" || true)"
  if [ "$gateway_container_count" -ne 1 ]; then
    echo "FAIL: re-resolved gateway Pod $GATEWAY_POD does not have exactly one $GATEWAY_CONTAINER container" >&2
    return 1
  fi
}

gateway_identity_server_material_rejected() {
  local description="$1" response status diagnostic last_diagnostic="" deadline=$((SECONDS + 40))
  while (( SECONDS < deadline )); do
    if gateway_health_response; then
      status=0
    else
      status=$?
    fi
    response="$GATEWAY_HEALTH_RESPONSE"
    diagnostic="$GATEWAY_HEALTH_DIAGNOSTIC"
    last_diagnostic="$diagnostic"
    if [ "$status" -ne 0 ] && gateway_health_response_has_identity_failure <<<"$response"; then
      echo "negative actual workload client rejected: $description"
      return 0
    fi

    # A changed server identity can fail the sanitizer before the long-lived
    # identity gRPC client reconnects. Every well-formed response is therefore
    # intermediate until the required identity failure above is observed.
    if gateway_health_response_is_structured <<<"$response"; then
      sleep 2
      continue
    fi

    # An unstructured nonzero result can be a gateway Pod exec turnover. Only
    # continue after the existing fail-closed single-Pod re-resolution.
    if [ "$status" -ne 0 ] && gateway_pod_re_resolve; then
      sleep 2
      continue
    fi
    echo "FAIL: $description gateway /healthz did not produce non-2xx JSON identity status=fail" >&2
    printf '%s\n' "$diagnostic" >&2
    exit 1
  done
  echo "FAIL: $description server material left the real gateway identity client healthy through the 40s convergence window" >&2
  printf '%s\n' "$last_diagnostic" >&2
  exit 1
}

served_leaf_fingerprint() {
  local address="$1" san="$2" timeout_seconds="${3:-15}"
  if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || [ "$timeout_seconds" -gt 15 ]; then
    echo "FAIL: invalid TLS fingerprint probe timeout" >&2
    return 1
  fi
  probe '
set +e
result=$(mktemp)
timeout "$3" openssl s_client \
  -connect "$1" \
  -servername "$2" \
  -verify_hostname "$2" \
  -verify_return_error \
  -CAfile /certs/gateway/ca.crt \
  -cert /certs/gateway/tls.crt \
  -key /certs/gateway/tls.key \
  </dev/null >"$result" 2>/dev/null
status=$?
set -e
if [ "$status" -ne 0 ]; then
  rm -f "$result"
  if [ "$status" -eq 124 ]; then
    echo "FAIL: positive TLS fingerprint handshake timed out" >&2
  else
    echo "FAIL: positive TLS fingerprint handshake failed" >&2
  fi
  exit 1
fi
openssl x509 -in "$result" -noout -fingerprint -sha256
rm -f "$result"
' "$address" "$san" "$timeout_seconds"
}

await_served_leaf_fingerprint() {
  local address="$1" san="$2" expected="$3"
  local observed="" last_diagnostic="no verified TLS fingerprint was observed"
  local deadline=$((SECONDS + 40)) remaining probe_timeout sleep_seconds

  while (( SECONDS < deadline )); do
    remaining=$((deadline - SECONDS))
    probe_timeout=5
    if (( remaining < probe_timeout )); then
      probe_timeout="$remaining"
    fi
    if observed="$(served_leaf_fingerprint "$address" "$san" "$probe_timeout")"; then
      if ! grep -Eq '^sha256 Fingerprint=[0-9A-F:]+$' <<<"$observed"; then
        last_diagnostic="served fingerprint was unparseable"
      elif [ "$observed" = "$expected" ]; then
        printf '%s\n' "$observed"
        return 0
      else
        last_diagnostic="served fingerprint did not match the expected replacement"
      fi
    else
      last_diagnostic="verified TLS fingerprint handshake failed or timed out"
    fi

    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || break
    sleep_seconds=2
    if (( remaining < sleep_seconds )); then
      sleep_seconds="$remaining"
    fi
    sleep "$sleep_seconds"
  done

  echo "FAIL: audit replacement did not serve the exact expected fingerprint within 40s" >&2
  echo "last observation: $last_diagnostic" >&2
  return 1
}

replace_sandbox_a_server_material() {
  local material_dir="$1"
  # Preserve the trusted CA projection while replacing only the server leaf.
  # This distinguishes wrong-CA leaf, wrong-SAN leaf, and expired leaf from a
  # client-side trust-store mutation.
  "${K[@]}" -n dsa-identity create secret generic lucairn-mtls-sandbox-a \
    --from-file=ca.crt="$STATE_DIR/certs/ca.crt" \
    --from-file=tls.crt="$material_dir/tls.crt" \
    --from-file=tls.key="$material_dir/tls.key" \
    --dry-run=client -o yaml | "${K[@]}" apply -f -
  "${K[@]}" -n dsa-identity rollout restart deployment/sandbox-a
  "${K[@]}" -n dsa-identity rollout status deployment/sandbox-a --timeout=6m
}

restore_sandbox_a_server_material() {
  create_leaf_secret dsa-identity lucairn-mtls-sandbox-a sandbox-a
  "${K[@]}" -n dsa-identity rollout restart deployment/sandbox-a
  "${K[@]}" -n dsa-identity rollout status deployment/sandbox-a --timeout=6m
  gateway_health_mtls_healthy
}

positive_handshake() {
  local address="$1" san="$2"
  if ! probe "timeout 15 openssl s_client -connect '$address' -servername '$san' -verify_hostname '$san' -verify_return_error -CAfile /certs/gateway/ca.crt -cert /certs/gateway/tls.crt -key /certs/gateway/tls.key </dev/null >/dev/null"; then
    echo "FAIL: positive mTLS handshake failed or timed out: $address ($san)" >&2
    exit 1
  fi
  echo "positive mTLS handshake verified: $address ($san)"
}

GATEWAY_HELPER_NAME=".enterprise-mtls-witness-tls-helper"
GATEWAY_HELPER_PATH="$GATEWAY_HELPER_DIR/$GATEWAY_HELPER_NAME"
GATEWAY_MTLS_DIR="/var/run/lucairn/mtls"

gateway_witness_helper_cleanup() {
  if ! "${K[@]}" -n dsa-edge exec "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- \
    sh -ec 'rm -f "$1"; test ! -e "$1"' -- "$GATEWAY_HELPER_PATH"; then
    echo "FAIL: could not delete temporary gateway witness TLS helper" >&2
    return 1
  fi
}

install_gateway_witness_helper() {
  # The root filesystem and projected mTLS Secret remain read-only. The
  # keystore PVC parent is the chart's existing writable, non-secret volume.
  if ! "${K[@]}" -n dsa-edge exec "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- \
    sh -ec 'test -d "$1" && test -w "$1" && test ! -e "$1/$2"' -- \
    "$GATEWAY_HELPER_DIR" "$GATEWAY_HELPER_NAME"; then
    echo "FAIL: gateway keystore PVC parent is not an empty writable helper location" >&2
    exit 1
  fi
  if ! "${K[@]}" -n dsa-edge exec -i "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- \
    sh -ec 'umask 077; cat > "$1/$2"; chmod 0700 "$1/$2"; test -s "$1/$2" && test -x "$1/$2"' -- \
    "$GATEWAY_HELPER_DIR" "$GATEWAY_HELPER_NAME" < "$GATEWAY_WITNESS_HELPER"; then
    gateway_witness_helper_cleanup || true
    echo "FAIL: could not stream the gateway witness TLS helper into the keystore PVC" >&2
    exit 1
  fi
}

gateway_witness_handshake() {
  local address="$1" san="$2"
  if ! "${K[@]}" -n dsa-edge exec "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- \
    "$GATEWAY_HELPER_PATH" tls-handshake "$address" "$san" \
    "$GATEWAY_MTLS_DIR/ca.crt" "$GATEWAY_MTLS_DIR/tls.crt" "$GATEWAY_MTLS_DIR/tls.key"; then
    echo "FAIL: actual gateway-Pod witness TLS handshake failed: $address ($san)" >&2
    return 1
  fi
  echo "gateway witness TLS handshake verified from actual gateway Pod: $address ($san)"
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

# The chart's least-privilege witness rules authorize only the actual gateway
# Pod. Stream a static, standard-library-only TLS client into the gateway's
# existing non-secret writable keystore PVC, execute both witness handshakes
# with the projected gateway identity, then retain it for the bounded local
# /healthz evidence below. The witness checks are transport proofs from the
# workload's Pod/network-policy/secret identity; they do not claim to invoke
# either gateway application's witness RPC method.
install_gateway_witness_helper
if ! gateway_witness_handshake veil-witness.dsa-witness.svc.cluster.local:50057 dsa-veil-witness; then
  exit 1
fi
if ! gateway_witness_handshake veil-witness.dsa-witness.svc.cluster.local:50058 dsa-veil-witness; then
  exit 1
fi

# Runtime + wire evidence for the gateway→sanitizer HTTP path. The rendered
# ConfigMap must expose HTTPS, the direct transcript verifies the mTLS server
# identity with the gateway leaf, and /healthz then makes the actual gateway
# SanitizerClient report an application-level healthy response. The direct
# transcript is supporting wire evidence only; the health call is the proof
# that the real workload client reached the sanitizer.
SANITIZER_URL="$("${K[@]}" -n dsa-edge get configmap gateway-config -o jsonpath='{.data.SANITIZER_URL}')"
if [ "$SANITIZER_URL" != "https://sandbox-a.dsa-identity.svc:8086" ]; then
  echo "FAIL: gateway runtime ConfigMap did not project the production HTTPS sanitizer URL (got: $SANITIZER_URL)" >&2
  exit 1
fi
SANITIZER_FINGERPRINT="$(served_leaf_fingerprint sandbox-a.dsa-identity.svc.cluster.local:8086 dsa-sanitizer)"
if ! grep -Eq '^sha256 Fingerprint=[0-9A-F:]+$' <<<"$SANITIZER_FINGERPRINT"; then
  echo "FAIL: could not capture a CA/SAN-verified sanitizer TLS fingerprint" >&2
  printf '%s\n' "$SANITIZER_FINGERPRINT" >&2
  exit 1
fi
gateway_health_mtls_healthy
echo "gateway sanitizer: actual client response plus verified mTLS wire fingerprint=$SANITIZER_FINGERPRINT"

negative_handshake wrong-ca "openssl s_client -connect audit.dsa-audit.svc.cluster.local:50051 -servername dsa-audit -verify_return_error -CAfile /certs/wrong-ca/wrong-ca.crt -cert /certs/gateway/tls.crt -key /certs/gateway/tls.key </dev/null >/dev/null"
negative_handshake wrong-san "openssl s_client -connect audit.dsa-audit.svc.cluster.local:50051 -servername dsa-audit -verify_hostname dsa-sandbox-a -verify_return_error -CAfile /certs/gateway/ca.crt -cert /certs/gateway/tls.crt -key /certs/gateway/tls.key </dev/null >/dev/null"
strict_client_auth_rejection missing-client-cert audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/gateway/ca.crt
strict_client_auth_rejection expired-client-cert audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/expired/ca.crt /certs/expired/tls.crt /certs/expired/tls.key

# Representative invalid SERVER material, deliberately one edge rather than a
# mutation×edge cross-product. The gateway health endpoint exercises its real
# IdentityClient (grpc.NewClient + tlsutil.ClientCredentialsForPeer), so each
# failure proves the workload refuses the server leaf without plaintext or
# insecure fallback. Restore the coherent Secret and readiness after every
# mutation before moving to the next mechanism.
for server_material in wrong-ca wrong-san expired; do
  replace_sandbox_a_server_material "$INVALID_SERVER_DIR/$server_material"
  gateway_identity_server_material_rejected "Sandbox A $server_material server leaf"
  restore_sandbox_a_server_material
done
gateway_witness_helper_cleanup
echo "gateway evidence helper deleted after witness and local health battery"

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

# Rotation/replacement proof: capture the served audit leaf before replacement,
# replace it, restart only audit, and require the exact locally generated
# replacement fingerprint before the final positive handshake. This is honest replacement evidence,
# not revocation: a same-CA, unexpired old leaf remains CA-valid until an
# operator PKI CA rotation or CRL/OCSP policy invalidates it. The separate
# expiry/invalid-material negatives above cover the fail-closed mechanisms this
# harness can truthfully demonstrate.
AUDIT_FINGERPRINT_BEFORE="$(served_leaf_fingerprint audit.dsa-audit.svc.cluster.local:50051 dsa-audit)"
if ! grep -Eq '^sha256 Fingerprint=[0-9A-F:]+$' <<<"$AUDIT_FINGERPRINT_BEFORE"; then
  echo "FAIL: could not capture the served audit leaf fingerprint before replacement" >&2
  printf '%s\n' "$AUDIT_FINGERPRINT_BEFORE" >&2
  exit 1
fi
ROTATE="$STATE_DIR/rotate-audit"
mkdir -p "$ROTATE"
openssl req -newkey rsa:2048 -nodes -sha256 -subj '/CN=dsa-audit' \
  -keyout "$ROTATE/tls.key" -out "$ROTATE/request.csr" >/dev/null 2>&1
printf '%s\n' 'subjectAltName=DNS:dsa-audit' 'extendedKeyUsage=serverAuth,clientAuth' > "$ROTATE/extensions.cnf"
openssl x509 -req -sha256 -days 2 -in "$ROTATE/request.csr" \
  -CA "$STATE_DIR/certs/ca.crt" -CAkey "$STATE_DIR/certs/ca.key" -CAcreateserial \
  -extfile "$ROTATE/extensions.cnf" -out "$ROTATE/tls.crt" >/dev/null 2>&1
if ! AUDIT_FINGERPRINT_EXPECTED="$(openssl x509 -in "$ROTATE/tls.crt" -noout -fingerprint -sha256 2>/dev/null)" \
  || ! grep -Eq '^sha256 Fingerprint=[0-9A-F:]+$' <<<"$AUDIT_FINGERPRINT_EXPECTED"; then
  echo "FAIL: generated audit replacement leaf has no valid SHA-256 fingerprint" >&2
  exit 1
fi
if [ "$AUDIT_FINGERPRINT_EXPECTED" = "$AUDIT_FINGERPRINT_BEFORE" ]; then
  echo "FAIL: generated audit replacement leaf fingerprint unexpectedly matches the current served leaf" >&2
  exit 1
fi
"${K[@]}" -n dsa-audit create secret generic lucairn-mtls-audit \
  --from-file=ca.crt="$STATE_DIR/certs/ca.crt" \
  --from-file=tls.crt="$ROTATE/tls.crt" \
  --from-file=tls.key="$ROTATE/tls.key" --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" -n dsa-audit rollout restart deployment/audit
"${K[@]}" -n dsa-audit rollout status deployment/audit --timeout=6m
if ! AUDIT_FINGERPRINT_AFTER="$(await_served_leaf_fingerprint audit.dsa-audit.svc.cluster.local:50051 dsa-audit "$AUDIT_FINGERPRINT_EXPECTED")"; then
  exit 1
fi
positive_handshake audit.dsa-audit.svc.cluster.local:50051 dsa-audit
echo "rotation replacement: audit served the exact expected replacement fingerprint"

echo "ENTERPRISE_HELM_MTLS_KIND: PASS"
