#!/usr/bin/env bash
set -euo pipefail

# Disposable real-cluster acceptance for the Enterprise default mTLS topology.
# All state is created under a unique /tmp directory and the Kind cluster name
# is unique to this invocation. No production context, trust store, or existing
# Kubernetes object is changed.
#
# This harness uses stock Kind/kindnet. kindnet does not enforce NetworkPolicy,
# so this run does not claim NetworkPolicy identity or enforcement evidence.
# Its identity evidence is limited to executing the helper inside each resolved
# workload Pod with that container's own read-only projected mTLS leaf.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/enterprise-mtls-kind-cleanup.sh
source "$ROOT/scripts/lib/enterprise-mtls-kind-cleanup.sh"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      echo "usage: $0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Resolve the caller-owned kubectl before creating any harness state or
# invoking Kind/Docker. Resolver failure is intentionally a zero-action gate.
KUBECTL_BIN="$("$ROOT/scripts/resolve-enterprise-mtls-kind-kubectl.sh")"

umask 077
STATE_DIR="$(mktemp -d /tmp/lucairn-enterprise-mtls-kind.XXXXXX)"
CLUSTER="lucairn-enterprise-mtls-${USER:-local}-$$"
KUBECONFIG="$STATE_DIR/kubeconfig"
KIND_CONFIG="$STATE_DIR/kind.yaml"
PUBLIC_OVERLAY="$STATE_DIR/public-overlay.yaml"
APPLICATION_SECRETS_DIR="$STATE_DIR/application-secrets"
WITNESS_SIGNED_MANIFEST="$STATE_DIR/witness-signed-manifest.json"
RENDERED_MANIFEST="$STATE_DIR/rendered-topology.yaml"
PRELOAD_IMAGES="$STATE_DIR/rendered-topology-images.txt"
PRELOAD_ARCHIVE_DIR="$STATE_DIR/preload-archives"
HELM_RELEASE_VALUES="$STATE_DIR/helm-release-values.yaml"
HELM_RELEASE_MANIFEST="$STATE_DIR/helm-release-manifest.yaml"
HELM_RELEASE_ALL="$STATE_DIR/helm-release-all.txt"
EXTERNAL_SECRETS_CRDS="$ROOT/charts/lucairn/tests/fixtures/kind-external-secrets-crds.yaml"
PROBE_IMAGE=""
PROBE_ARCHIVE="$STATE_DIR/enterprise-mtls-probe.tar"
CLUSTER_CREATED=0
GATEWAY_HELPER_INSTALLED=0
PROJECTED_HELPER_INSTALLED=0

enterprise_mtls_kind_cleanup_helpers() {
  if [ "$GATEWAY_HELPER_INSTALLED" -eq 1 ] && declare -F gateway_tls_helper_cleanup >/dev/null 2>&1; then
    gateway_tls_helper_cleanup || true
  fi
  if [ "$PROJECTED_HELPER_INSTALLED" -eq 1 ] && declare -F projected_identity_helper_cleanup >/dev/null 2>&1; then
    projected_identity_helper_cleanup || true
  fi
}

cleanup() {
  local body_status=$?
  trap - EXIT
  enterprise_mtls_kind_cleanup "$body_status" || true
  if [ "${ENTERPRISE_MTLS_KIND_CLUSTER_DELETE_FAILED:-0}" -eq 1 ]; then
    exit 1
  fi
  exit "$body_status"
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

cat > "$KIND_CONFIG" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
YAML

kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG" --kubeconfig "$KUBECONFIG" --wait 180s
CLUSTER_CREATED=1
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

# Admit only the two API types rendered by the production profile. This is an
# API-admission fixture, not an External Secrets Operator installation: wait
# only for CRD Established and never inspect custom-resource status.
"${K[@]}" apply -f "$EXTERNAL_SECRETS_CRDS"
for crd in externalsecrets.external-secrets.io clustersecretstores.external-secrets.io; do
  "${K[@]}" wait --for=condition=Established "crd/$crd" --timeout=60s
done

bash "$ROOT/scripts/enterprise-mtls-fixture-certs.sh" "$STATE_DIR/certs"
# Generate Helm/doctor-safe Kind exceptions plus six private application Secret
# source files. The public overlay remains the only harness-generated YAML
# passed to doctor or Helm.
bash "$ROOT/scripts/generate-enterprise-mtls-kind-runtime-values.sh" \
  "$PUBLIC_OVERLAY" "$APPLICATION_SECRETS_DIR"
# The production gateway verifies this blob before opening its listeners. Build
# the signed output from the coherent public roster plus the private witness
# source file, then project it through a dedicated operator-style Secret before
# Helm is invoked.
bash "$ROOT/scripts/generate-enterprise-mtls-kind-signed-manifest.sh" \
  "$PUBLIC_OVERLAY" "$APPLICATION_SECRETS_DIR" "$WITNESS_SIGNED_MANIFEST"
"$ROOT/bin/lucairn" doctor \
  --values "$ROOT/charts/lucairn/values-prod.yaml" \
  --values "$PUBLIC_OVERLAY" \
  --offline

# Render with the exact values passed to the subsequent install. The manifest
# contains only the public overlay and production topology. The image list is
# derived only from workload PodSpecs and loaded into every node before Helm
# creates any workload; no registry credential is supplied to Helm because Kind
# already has every rendered product image preloaded.
HELM_RUNTIME_ARGS=(
  -f "$ROOT/charts/lucairn/values-prod.yaml"
  -f "$PUBLIC_OVERLAY"
  --set global.skipPullSecretGuard=true
  --set global.dnsRestriction=false
  --set global.wireguardEncryption=false
  --set global.postgresqlSslmode=disable
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

# Target Secrets are operator-style application inputs. Only an env-file path
# is an argv argument; kubectl consumes values from the 0600 file and the
# generated Secret YAML is streamed directly to the API, never read/logged.
create_application_secret() {
  local namespace="$1" service="$2"
  "${K[@]}" -n "$namespace" create secret generic "${service}-credentials" \
    --from-env-file="$APPLICATION_SECRETS_DIR/${service}.env" \
    --dry-run=client -o yaml | "${K[@]}" apply -f -
}

create_application_secret dsa-edge gateway
create_application_secret dsa-audit audit
create_application_secret dsa-bridge id-bridge
create_application_secret dsa-identity sandbox-a
create_application_secret dsa-ai sandbox-b
create_application_secret dsa-witness veil-witness

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

# The Kind harness keeps the production Vault backend and all six rendered
# ExternalSecrets. Stock Kind receives only CNI/Postgres TLS/test-provider
# exceptions through the public overlay; pre-created target Secrets make the
# mandatory workloads runnable without an ESO controller. The seven mTLS
# identity Secrets remain independently operator/PKI-owned.
helm upgrade --install lucairn "$ROOT/charts/lucairn" \
  "${HELM_RUNTIME_ARGS[@]}" \
  --create-namespace --kubeconfig "$KUBECONFIG" \
  --wait --wait-for-jobs --timeout 12m

# Helm release state is a custody boundary too. Keep all captures in the owned
# private state directory and reject an exact private source value in values,
# manifest, or `get all` output before accepting runtime evidence.
helm get values lucairn --namespace lucairn --kubeconfig "$KUBECONFIG" -o yaml > "$HELM_RELEASE_VALUES"
helm get manifest lucairn --namespace lucairn --kubeconfig "$KUBECONFIG" > "$HELM_RELEASE_MANIFEST"
helm get all lucairn --namespace lucairn --kubeconfig "$KUBECONFIG" > "$HELM_RELEASE_ALL"
bash "$ROOT/scripts/assert-enterprise-mtls-release-custody.sh" \
  "$APPLICATION_SECRETS_DIR" "$HELM_RELEASE_VALUES" "$HELM_RELEASE_MANIFEST" "$HELM_RELEASE_ALL"
ruby -ryaml -e '
  documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
  external = documents.map { |doc| doc.dig("metadata", "name") if doc["kind"] == "ExternalSecret" }.compact.sort
  expected = %w[gateway-credentials audit-credentials id-bridge-credentials sandbox-a-credentials sandbox-b-credentials veil-witness-credentials].sort
  abort "release manifest ExternalSecret contract drift: #{external.join(", ")}" unless external == expected
  stores = documents.map { |doc| doc.dig("metadata", "name") if doc["kind"] == "ClusterSecretStore" }.compact
  abort "release manifest ClusterSecretStore contract drift" unless stores == ["dsa-secret-store"]
  secrets = documents.select { |doc| doc["kind"] == "Secret" }
  abort "release manifest contains Helm-owned Secret objects" unless secrets.empty?
' "$HELM_RELEASE_MANIFEST"

for deployment in \
  dsa-edge/gateway dsa-audit/audit dsa-bridge/id-bridge \
  dsa-identity/sandbox-a dsa-ai/sandbox-b dsa-witness/veil-witness; do
  "${K[@]}" -n "${deployment%/*}" rollout status "deployment/${deployment#*/}" --timeout=8m
done

# Resolve the exact gateway Pod and container before building the short-lived
# in-container proof helper. A label or architecture ambiguity is evidence
# failure, not a reason to fall back to the disposable local probe Pod. This proves only
# execution with the gateway's projected leaf; stock Kind/kindnet does not make
# it NetworkPolicy enforcement evidence.
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
GATEWAY_MTLS_DIR="/var/run/lucairn/mtls"
gateway_container_count="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -Fxc "$GATEWAY_CONTAINER" || true)"
if [ "$gateway_container_count" -ne 1 ]; then
  echo "FAIL: expected exactly one $GATEWAY_CONTAINER container in gateway Pod $GATEWAY_POD" >&2
  exit 1
fi
gateway_mtls_volume="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
  -o go-template="{{range .spec.containers}}{{if eq .name \"$GATEWAY_CONTAINER\"}}{{range .volumeMounts}}{{if eq .mountPath \"$GATEWAY_MTLS_DIR\"}}{{.name}}{{end}}{{end}}{{end}}{{end}}")"
gateway_mtls_read_only="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
  -o go-template="{{range .spec.containers}}{{if eq .name \"$GATEWAY_CONTAINER\"}}{{range .volumeMounts}}{{if eq .mountPath \"$GATEWAY_MTLS_DIR\"}}{{.readOnly}}{{end}}{{end}}{{end}}{{end}}")"
gateway_mtls_secret="$("${K[@]}" -n dsa-edge get pod "$GATEWAY_POD" \
  -o go-template="{{range .spec.volumes}}{{if eq .name \"$gateway_mtls_volume\"}}{{with .secret}}{{.secretName}}{{end}}{{end}}{{end}}")"
if [ "$gateway_mtls_volume" != "enterprise-mtls" ] || [ "$gateway_mtls_read_only" != "true" ] || [ "$gateway_mtls_secret" != "lucairn-mtls-gateway" ]; then
  echo "FAIL: gateway helper would not use the Gateway read-only projected mTLS Secret at $GATEWAY_MTLS_DIR" >&2
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

GATEWAY_TLS_HELPER_SOURCE="$STATE_DIR/gateway-tls-helper.go"
GATEWAY_TLS_HELPER="$STATE_DIR/gateway-tls-helper"
cat > "$GATEWAY_TLS_HELPER_SOURCE" <<'GO'
// gateway-tls-helper is generated only in the disposable harness
// state. It performs verified TLS evidence operations, a bounded local probe
// server/readiness pair, or a loopback gateway health request. It prints no
// secret material, even on failure.
package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	healthURL              = "http://127.0.0.1:8085/healthz"
	healthRequestTimeout   = 10 * time.Second
	healthDialTimeout      = 5 * time.Second
	maxHealthResponseBytes = 64 * 1024
	tlsOperationTimeout    = 10 * time.Second
	probeServeLifetime     = 45 * time.Minute
	probeListenAddress     = "127.0.0.1:8080"
)

func failTLS() {
	fmt.Fprintln(os.Stderr, "verified TLS handshake failed")
	os.Exit(1)
}

func failGatewayHealth() {
	fmt.Fprintln(os.Stderr, "gateway health request failed")
	os.Exit(1)
}

func tlsConfig(caPath, certPath, keyPath, serverName string, clientMaterial bool) *tls.Config {
	if caPath == "" || serverName == "" || (clientMaterial && (certPath == "" || keyPath == "")) {
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
	config := &tls.Config{
		MinVersion:         tls.VersionTLS13,
		ServerName:         serverName,
		RootCAs:            roots,
		InsecureSkipVerify: false,
	}
	if clientMaterial {
		certificate, err := tls.LoadX509KeyPair(certPath, keyPath)
		if err != nil {
			failTLS()
		}
		config.Certificates = []tls.Certificate{certificate}
	}
	return config
}

func dialVerified(address, serverName, verifyHostname, caPath, certPath, keyPath string) (*tls.Conn, tls.ConnectionState) {
	if address == "" || verifyHostname == "" {
		failTLS()
	}
	raw, err := (&net.Dialer{Timeout: tlsOperationTimeout}).Dial("tcp", address)
	if err != nil {
		failTLS()
	}
	conn := tls.Client(raw, tlsConfig(caPath, certPath, keyPath, serverName, true))
	if err := conn.SetDeadline(time.Now().Add(tlsOperationTimeout)); err != nil {
		raw.Close()
		failTLS()
	}
	if err := conn.Handshake(); err != nil {
		raw.Close()
		failTLS()
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		conn.Close()
		failTLS()
	}
	// The standard TLS handshake verifies the chain and serverName/SNI. Keep an
	// explicit verifier too so the wrong-SAN negative can retain normal SNI
	// while proving a distinct expected server identity is rejected.
	if err := conn.VerifyHostname(verifyHostname); err != nil {
		conn.Close()
		failTLS()
	}
	return conn, conn.ConnectionState()
}

func runTLSHandshake(args []string) {
	if len(args) != 6 {
		failTLS()
	}
	conn, _ := dialVerified(args[0], args[1], args[2], args[3], args[4], args[5])
	defer conn.Close()
}

func formatFingerprint(raw []byte) string {
	digest := sha256.Sum256(raw)
	hexDigest := strings.ToUpper(hex.EncodeToString(digest[:]))
	parts := make([]string, 0, sha256.Size)
	for index := 0; index < len(hexDigest); index += 2 {
		parts = append(parts, hexDigest[index:index+2])
	}
	return "sha256 Fingerprint=" + strings.Join(parts, ":")
}

func runFingerprint(args []string) {
	if len(args) != 6 {
		failTLS()
	}
	conn, state := dialVerified(args[0], args[1], args[2], args[3], args[4], args[5])
	defer conn.Close()
	if len(state.PeerCertificates) == 0 {
		failTLS()
	}
	fmt.Println(formatFingerprint(state.PeerCertificates[0].Raw))
}

func isTimeout(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
		return true
	}
	return strings.Contains(err.Error(), "i/o timeout")
}

func runClientAuthRejection(args []string) {
	if len(args) != 4 && len(args) != 6 {
		failTLS()
	}
	address, serverName, verifyHostname, caPath := args[0], args[1], args[2], args[3]
	if address == "" || serverName == "" || verifyHostname == "" || caPath == "" {
		failTLS()
	}
	certPath, keyPath := "", ""
	clientMaterial := len(args) == 6
	if clientMaterial {
		certPath, keyPath = args[4], args[5]
	}
	if err := clientAuthRejectionError(address, serverName, verifyHostname, caPath, certPath, keyPath, clientMaterial); err != nil {
		failTLS()
	}
}

func clientAuthRejectionError(address, serverName, verifyHostname, caPath, certPath, keyPath string, clientMaterial bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), tlsOperationTimeout)
	defer cancel()
	raw, err := (&net.Dialer{}).DialContext(ctx, "tcp", address)
	if err != nil {
		return err
	}
	verifiedServer := false
	config := tlsConfig(caPath, certPath, keyPath, serverName, clientMaterial)
	// VerifyConnection runs only after Go's normal RootCAs/ServerName checks.
	// It additionally proves the expected target identity before an alert can be
	// credited as server-side client-auth rejection evidence.
	config.VerifyConnection = func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) == 0 {
			return errors.New("server verification returned no peer certificate")
		}
		if err := state.PeerCertificates[0].VerifyHostname(verifyHostname); err != nil {
			return err
		}
		verifiedServer = true
		return nil
	}
	conn := tls.Client(raw, config)
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(tlsOperationTimeout)); err != nil {
		return err
	}
	err = conn.HandshakeContext(ctx)
	if err == nil {
		// TLS 1.3 servers can send the client-auth alert just after the client
		// reports handshake completion. A read with the same bounded deadline
		// distinguishes that remote alert from an accepted/open connection.
		_, err = conn.Read(make([]byte, 1))
	}
	return clientAuthRejectionResult(verifiedServer, err)
}

func clientAuthRejectionResult(verifiedServer bool, err error) error {
	if !verifiedServer {
		return errors.New("server verification did not complete")
	}
	if err == nil {
		return errors.New("client authentication remained accepted/open")
	}
	if isTimeout(err) {
		return errors.New("timed out waiting for client authentication rejection")
	}
	if !isRemoteTLSAlert(err) {
		return errors.New("client authentication failed without a remote TLS alert")
	}
	return nil
}

func isRemoteTLSAlert(err error) bool {
	return strings.HasPrefix(err.Error(), "remote error: tls:")
}

func runProbeServe() {
	listener, err := net.Listen("tcp", probeListenAddress)
	if err != nil {
		failTLS()
	}
	defer listener.Close()
	deadline := time.Now().Add(probeServeLifetime)
	for time.Now().Before(deadline) {
		if err := listener.(*net.TCPListener).SetDeadline(time.Now().Add(time.Second)); err != nil {
			failTLS()
		}
		connection, err := listener.Accept()
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			failTLS()
		}
		connection.Close()
	}
	failTLS()
}

func runProbeReady() {
	connection, err := net.DialTimeout("tcp", probeListenAddress, healthDialTimeout)
	if err != nil {
		failTLS()
	}
	connection.Close()
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
	case "fingerprint":
		runFingerprint(os.Args[2:])
	case "client-auth-rejection":
		runClientAuthRejection(os.Args[2:])
	case "serve":
		if len(os.Args) != 2 {
			failTLS()
		}
		runProbeServe()
	case "ready":
		if len(os.Args) != 2 {
			failTLS()
		}
		runProbeReady()
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
  echo "BLOCKED: Go is required to build the disposable Gateway TLS helper." >&2
  exit 2
fi
if ! CGO_ENABLED=0 GOOS=linux GOARCH="$GATEWAY_NODE_ARCH" \
  go build -trimpath -ldflags='-s -w' -o "$GATEWAY_TLS_HELPER" "$GATEWAY_TLS_HELPER_SOURCE"; then
  echo "FAIL: could not cross-compile the gateway TLS helper for linux/$GATEWAY_NODE_ARCH" >&2
  exit 1
fi
[ -x "$GATEWAY_TLS_HELPER" ] || {
  echo "FAIL: gateway TLS helper was not built as an executable" >&2
  exit 1
}

# The disposable probe is a repository-built local image, not a release
# artifact and not a rendered topology image. Its scratch filesystem contains
# only the static helper. Verify the exact local image ID before exporting it
# to the named Kind cluster, then remove its tag/archive with harness state.
PROBE_IMAGE="lucairn-enterprise-mtls-probe:kind-$$"
PROBE_CONTEXT="$STATE_DIR/enterprise-mtls-probe-context"
PROBE_DOCKERFILE="$PROBE_CONTEXT/Dockerfile"

# The local scratch probe is not part of the Helm render, but its Pod uses this
# exact tag with imagePullPolicy: Never. Save the captured image ID together
# with that tag, then reject any archive that cannot prove the tag is its only
# manifest entry before it reaches Kind. Docker Desktop's .Id can be an OCI
# index digest while the archive config is platform-specific, so those two
# digest values are intentionally not compared.
require_probe_archive_tag_binding() {
  local archive="$1" runtime_tag="$2" expected_image_id="$3"
  if ! ruby -rjson -rrubygems/package -e '
    archive, runtime_tag, expected_image_id = ARGV
    abort "invalid captured image ID" unless expected_image_id.match?(/\Asha256:[0-9a-f]{64}\z/)
    manifest_json = nil

    File.open(archive, "rb") do |file|
      Gem::Package::TarReader.new(file) do |tar|
        tar.each do |entry|
          next unless entry.full_name == "manifest.json"
          abort "archive has multiple manifest.json entries" if manifest_json
          abort "archive manifest.json is not a regular file" unless entry.file?
          manifest_json = entry.read
        end
      end
    end

    abort "archive is missing manifest.json" unless manifest_json
    manifest = JSON.parse(manifest_json)
    abort "archive manifest is not an array" unless manifest.is_a?(Array)
    abort "archive must contain exactly one manifest entry" unless manifest.length == 1

    entry = manifest.fetch(0)
    abort "archive manifest entry is malformed" unless entry.is_a?(Hash)
    abort "archive has invalid runtime tag binding" unless entry["RepoTags"] == [runtime_tag]
    config = entry["Config"]
    case config
    when /\Ablobs\/sha256\/[0-9a-f]{64}\z/
    when /\A[0-9a-f]{64}\.json\z/
    else
      abort "archive config path is malformed"
    end
  ' "$archive" "$runtime_tag" "$expected_image_id"; then
    echo "FAIL: scratch probe archive tag binding is invalid: $runtime_tag" >&2
    exit 1
  fi
}

mkdir -p "$PROBE_CONTEXT"
cp "$GATEWAY_TLS_HELPER" "$PROBE_CONTEXT/probe"
cat > "$PROBE_DOCKERFILE" <<'DOCKERFILE'
FROM scratch
COPY probe /probe
DOCKERFILE
if ! docker build --network=none --pull=false --platform "linux/$GATEWAY_NODE_ARCH" --tag "$PROBE_IMAGE" \
  --file "$PROBE_DOCKERFILE" "$PROBE_CONTEXT" >/dev/null; then
  echo "FAIL: could not build the repository-generated scratch probe image for linux/$GATEWAY_NODE_ARCH" >&2
  exit 1
fi
PROBE_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$PROBE_IMAGE")"
if ! [[ "$PROBE_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "FAIL: local scratch probe image has no immutable image ID" >&2
  exit 1
fi
if ! docker image save --output "$PROBE_ARCHIVE" "$PROBE_IMAGE_ID" "$PROBE_IMAGE" \
  || [ ! -s "$PROBE_ARCHIVE" ]; then
  echo "FAIL: could not archive the verified local scratch probe image" >&2
  exit 1
fi
require_probe_archive_tag_binding "$PROBE_ARCHIVE" "$PROBE_IMAGE" "$PROBE_IMAGE_ID"
if ! kind load image-archive --name "$CLUSTER" "$PROBE_ARCHIVE"; then
  echo "FAIL: could not load the verified local scratch probe image into Kind" >&2
  exit 1
fi

"${K[@]}" -n dsa-edge create configmap enterprise-mtls-negative-ca \
  --from-file=wrong-ca.crt="$STATE_DIR/certs/wrong-ca.crt" --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" -n dsa-edge create secret generic enterprise-mtls-expired-gateway \
  --from-file=ca.crt="$STATE_DIR/certs/expired-gateway/ca.crt" \
  --from-file=tls.crt="$STATE_DIR/certs/expired-gateway/tls.crt" \
  --from-file=tls.key="$STATE_DIR/certs/expired-gateway/tls.key" \
  --dry-run=client -o yaml | "${K[@]}" apply -f -

cat <<YAML | "${K[@]}" -n dsa-edge apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: enterprise-mtls-probe
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      image: ${PROBE_IMAGE}
      imagePullPolicy: Never
      command: ["/probe", "serve"]
      readinessProbe:
        exec:
          command: ["/probe", "ready"]
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

# Gateway /healthz is an application-level call executed in the actual gateway
# container through its loopback listener. In particular,
# gateway/internal/clients/identity.go builds
# its gRPC client with
# tlsutil.ClientCredentialsForPeer(tlsutil.SANSandboxA), and Ping performs the
# GetIdentity RPC. A healthy identity check below is therefore one real
# representative call for the shared tlsutil gRPC mechanism class. The five
# non-witness exact-SAN checks use the repository-built local probe; the two witness checks
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
  local address="$1" san="$2" observed
  if ! observed="$("${K[@]}" -n dsa-edge exec enterprise-mtls-probe -- \
    /probe fingerprint "$address" "$san" "$san" /certs/gateway/ca.crt \
    /certs/gateway/tls.crt /certs/gateway/tls.key)"; then
    echo "FAIL: verified TLS fingerprint handshake failed" >&2
    return 1
  fi
  printf '%s\n' "$observed"
}

await_served_leaf_fingerprint() {
  local address="$1" san="$2" expected="$3"
  local observed="" last_diagnostic="no verified TLS fingerprint was observed"
  local deadline=$((SECONDS + 40)) remaining sleep_seconds

  while (( SECONDS < deadline )); do
    if observed="$(served_leaf_fingerprint "$address" "$san")"; then
      if ! grep -Eq '^sha256 Fingerprint=[0-9A-F:]+$' <<<"$observed"; then
        last_diagnostic="served fingerprint was unparseable"
      elif [ "$observed" = "$expected" ]; then
        printf '%s\n' "$observed"
        return 0
      else
        last_diagnostic="served fingerprint did not match the expected replacement"
      fi
    else
      last_diagnostic="verified TLS fingerprint handshake failed"
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

probe_tls_handshake() {
  local address="$1" server_name="$2" verify_hostname="$3" ca_file="$4" cert_file="$5" key_file="$6"
  "${K[@]}" -n dsa-edge exec enterprise-mtls-probe -- \
    /probe tls-handshake "$address" "$server_name" "$verify_hostname" "$ca_file" "$cert_file" "$key_file"
}

positive_handshake() {
  local address="$1" san="$2"
  if ! probe_tls_handshake "$address" "$san" "$san" /certs/gateway/ca.crt \
    /certs/gateway/tls.crt /certs/gateway/tls.key; then
    echo "FAIL: positive mTLS handshake failed: $address ($san)" >&2
    exit 1
  fi
  echo "supporting local-probe mTLS handshake verified: $address ($san)"
}

GATEWAY_HELPER_NAME=".enterprise-mtls-gateway-tls-helper"
GATEWAY_HELPER_PATH="$GATEWAY_HELPER_DIR/$GATEWAY_HELPER_NAME"

gateway_tls_helper_cleanup() {
  if ! "${K[@]}" -n dsa-edge exec "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- \
    sh -ec 'rm -f "$1"; test ! -e "$1"' -- "$GATEWAY_HELPER_PATH"; then
    echo "FAIL: could not delete temporary gateway TLS helper" >&2
    return 1
  fi
  GATEWAY_HELPER_INSTALLED=0
}

install_gateway_tls_helper() {
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
    "$GATEWAY_HELPER_DIR" "$GATEWAY_HELPER_NAME" < "$GATEWAY_TLS_HELPER"; then
    gateway_tls_helper_cleanup || true
    echo "FAIL: could not stream the gateway TLS helper into the keystore PVC" >&2
    exit 1
  fi
  GATEWAY_HELPER_INSTALLED=1
}

gateway_workload_handshake() {
  local address="$1" san="$2"
  if ! "${K[@]}" -n dsa-edge exec "$GATEWAY_POD" -c "$GATEWAY_CONTAINER" -- \
    "$GATEWAY_HELPER_PATH" tls-handshake "$address" "$san" "$san" \
    "$GATEWAY_MTLS_DIR/ca.crt" "$GATEWAY_MTLS_DIR/tls.crt" "$GATEWAY_MTLS_DIR/tls.key"; then
    echo "FAIL: actual Gateway-Pod TLS handshake failed: $address ($san)" >&2
    return 1
  fi
  echo "workload-originated TLS handshake verified from actual Gateway Pod: $address ($san)"
}

# Audit and ID Bridge intentionally expose no writable application volume, and
# all three required workloads retain readOnlyRootFilesystem. `/dev/shm` is the
# existing container-runtime tmpfs, not a chart-mounted Secret or a security
# context change. A static helper is streamed there only for one handshake,
# then removed before the next workload. The mTLS files remain read-only at the
# workload's own projected mount throughout.
WORKLOAD_HELPER_DIR="/dev/shm"
WORKLOAD_HELPER_NAME=".enterprise-mtls-projected-identity-tls-helper"
WORKLOAD_MTLS_DIR="/var/run/lucairn/mtls"

build_workload_witness_helper() {
  local node_arch="$1"
  local helper="$STATE_DIR/projected-identity-witness-tls-helper-${node_arch}"

  if [ ! -x "$helper" ]; then
    if ! CGO_ENABLED=0 GOOS=linux GOARCH="$node_arch" \
      go build -trimpath -ldflags='-s -w' -o "$helper" "$GATEWAY_TLS_HELPER_SOURCE"; then
      echo "FAIL: could not cross-compile the projected-identity witness TLS helper for linux/$node_arch" >&2
      return 1
    fi
  fi
  [ -x "$helper" ] || {
    echo "FAIL: projected-identity witness TLS helper was not built as an executable" >&2
    return 1
  }
  printf '%s\n' "$helper"
}

resolve_projected_identity_workload() {
  local identity="$1" namespace="$2" pod_label="$3" container="$4" expected_secret="$5"
  local pods=() pod mount_volume mounted_read_only mounted_secret node runtime_machine

  while IFS= read -r pod; do
    [ -n "$pod" ] && pods+=("$pod")
  done < <("${K[@]}" -n "$namespace" get pods -l "app.kubernetes.io/name=$pod_label" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [ "${#pods[@]}" -ne 1 ]; then
    echo "FAIL: expected exactly one $identity workload Pod in $namespace, found ${#pods[@]}" >&2
    printf '%s workload Pods: %s\n' "$identity" "${pods[*]:-(none)}" >&2
    return 1
  fi
  WORKLOAD_POD="${pods[0]}"
  WORKLOAD_NAMESPACE="$namespace"
  WORKLOAD_CONTAINER="$container"

  if [ "$("${K[@]}" -n "$namespace" get pod "$WORKLOAD_POD" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -Fxc "$container" || true)" -ne 1 ]; then
    echo "FAIL: expected exactly one $container container in $identity Pod $WORKLOAD_POD" >&2
    return 1
  fi
  mount_volume="$("${K[@]}" -n "$namespace" get pod "$WORKLOAD_POD" \
    -o go-template="{{range .spec.containers}}{{if eq .name \"$container\"}}{{range .volumeMounts}}{{if eq .mountPath \"$WORKLOAD_MTLS_DIR\"}}{{.name}}{{end}}{{end}}{{end}}{{end}}")"
  mounted_read_only="$("${K[@]}" -n "$namespace" get pod "$WORKLOAD_POD" \
    -o go-template="{{range .spec.containers}}{{if eq .name \"$container\"}}{{range .volumeMounts}}{{if eq .mountPath \"$WORKLOAD_MTLS_DIR\"}}{{.readOnly}}{{end}}{{end}}{{end}}{{end}}")"
  mounted_secret="$("${K[@]}" -n "$namespace" get pod "$WORKLOAD_POD" \
    -o go-template="{{range .spec.volumes}}{{if eq .name \"$mount_volume\"}}{{with .secret}}{{.secretName}}{{end}}{{end}}{{end}}")"
  if [ -z "$mount_volume" ] || [ "$mounted_read_only" != "true" ] || [ -z "$mounted_secret" ] || [ -z "$expected_secret" ] || [ "$mounted_secret" != "$expected_secret" ]; then
    echo "FAIL: $identity helper would not use its own read-only projected mTLS Secret at $WORKLOAD_MTLS_DIR" >&2
    return 1
  fi

  node="$("${K[@]}" -n "$namespace" get pod "$WORKLOAD_POD" -o jsonpath='{.spec.nodeName}')"
  if [ -z "$node" ]; then
    echo "FAIL: $identity Pod $WORKLOAD_POD has no scheduled node" >&2
    return 1
  fi
  WORKLOAD_NODE_ARCH="$("${K[@]}" get node "$node" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')"
  case "$WORKLOAD_NODE_ARCH" in
    amd64) WORKLOAD_NODE_MACHINES='x86_64 amd64' ;;
    arm64) WORKLOAD_NODE_MACHINES='aarch64 arm64' ;;
    *)
      echo "FAIL: unsupported $identity Kind node architecture: ${WORKLOAD_NODE_ARCH:-(missing)}" >&2
      return 1
      ;;
  esac
  runtime_machine="$("${K[@]}" -n "$namespace" exec "$WORKLOAD_POD" -c "$container" -- uname -m)"
  case " $WORKLOAD_NODE_MACHINES " in
    *" $runtime_machine "*) ;;
    *)
      echo "FAIL: $identity container architecture $runtime_machine does not match node architecture $WORKLOAD_NODE_ARCH" >&2
      return 1
      ;;
  esac
}

projected_identity_helper_cleanup() {
  if ! "${K[@]}" -n "$WORKLOAD_NAMESPACE" exec "$WORKLOAD_POD" -c "$WORKLOAD_CONTAINER" -- \
    sh -ec 'rm -f "$1"; test ! -e "$1"' -- "$WORKLOAD_HELPER_PATH"; then
    echo "FAIL: could not delete temporary projected-identity TLS helper for $WORKLOAD_CONTAINER" >&2
    return 1
  fi
  PROJECTED_HELPER_INSTALLED=0
}

install_projected_identity_helper() {
  if ! "${K[@]}" -n "$WORKLOAD_NAMESPACE" exec "$WORKLOAD_POD" -c "$WORKLOAD_CONTAINER" -- \
    sh -ec 'test -d "$1" && test -w "$1" && test ! -e "$1/$2"' -- \
    "$WORKLOAD_HELPER_DIR" "$WORKLOAD_HELPER_NAME"; then
    echo "FAIL: $WORKLOAD_CONTAINER has no empty writable /dev/shm location for the bounded TLS helper" >&2
    return 1
  fi
  if ! "${K[@]}" -n "$WORKLOAD_NAMESPACE" exec -i "$WORKLOAD_POD" -c "$WORKLOAD_CONTAINER" -- \
    sh -ec 'umask 077; cat > "$1/$2"; chmod 0700 "$1/$2"; test -s "$1/$2" && test -x "$1/$2"' -- \
    "$WORKLOAD_HELPER_DIR" "$WORKLOAD_HELPER_NAME" < "$WORKLOAD_HELPER_BINARY"; then
    projected_identity_helper_cleanup || true
    echo "FAIL: could not stream the projected-identity TLS helper into $WORKLOAD_CONTAINER /dev/shm" >&2
    return 1
  fi
  PROJECTED_HELPER_INSTALLED=1
}

projected_identity_witness_handshake() {
  local identity="$1" namespace="$2" pod_label="$3" container="$4" expected_secret="$5"
  local address="$6" san="$7"

  if ! resolve_projected_identity_workload "$identity" "$namespace" "$pod_label" "$container" "$expected_secret"; then
    return 1
  fi
  WORKLOAD_HELPER_BINARY="$(build_workload_witness_helper "$WORKLOAD_NODE_ARCH")" || return 1
  WORKLOAD_HELPER_PATH="$WORKLOAD_HELPER_DIR/$WORKLOAD_HELPER_NAME"
  if ! install_projected_identity_helper; then
    return 1
  fi
  if ! "${K[@]}" -n "$WORKLOAD_NAMESPACE" exec "$WORKLOAD_POD" -c "$WORKLOAD_CONTAINER" -- \
    "$WORKLOAD_HELPER_PATH" tls-handshake "$address" "$san" "$san" \
    "$WORKLOAD_MTLS_DIR/ca.crt" "$WORKLOAD_MTLS_DIR/tls.crt" "$WORKLOAD_MTLS_DIR/tls.key"; then
    projected_identity_helper_cleanup || true
    echo "FAIL: projected $identity workload TLS handshake failed: $address ($san)" >&2
    return 1
  fi
  if ! projected_identity_helper_cleanup; then
    return 1
  fi
  echo "PASS: projected workload identity $identity verified exact-SAN TLS to veil-witness:50057"
}

negative_handshake() {
  local description="$1" address="$2" server_name="$3" verify_hostname="$4" ca_file="$5" cert_file="$6" key_file="$7"
  if probe_tls_handshake "$address" "$server_name" "$verify_hostname" "$ca_file" "$cert_file" "$key_file"; then
    echo "FAIL: negative mTLS handshake unexpectedly passed: $description" >&2
    exit 1
  fi
  echo "negative mTLS handshake rejected: $description"
}
strict_client_auth_rejection() {
  local description="$1" address="$2" san="$3" ca_file="$4"
  local client_cert="${5:-}" client_key="${6:-}"
  local -a command=(/probe client-auth-rejection "$address" "$san" "$san" "$ca_file")

  if [ -n "$client_cert" ] && [ -z "$client_key" ]; then
    echo "FAIL: $description strict client-auth check has a certificate without a key" >&2
    exit 1
  fi
  if [ -z "$client_cert" ] && [ -n "$client_key" ]; then
    echo "FAIL: $description strict client-auth check has a key without a certificate" >&2
    exit 1
  fi

  if [ -n "$client_cert" ]; then
    command+=("$client_cert" "$client_key")
  fi
  # The helper rejects timeout/accepted connections and accepts only a verified
  # chain/SAN handshake that reaches an actual remote TLS alert.
  if ! "${K[@]}" -n dsa-edge exec enterprise-mtls-probe -- "${command[@]}"; then
    echo "FAIL: $description mTLS client authentication was not rejected by the server" >&2
    exit 1
  fi
  echo "negative mTLS handshake rejected: $description"
}

# Keep these local-probe positives for the client-auth negatives, fingerprint,
# and rotation logic below. They are supporting local-probe evidence only;
# the actual Gateway-Pod handshakes immediately following are the acceptance
# proof for every Gateway-originated mandatory edge.
positive_handshake audit.dsa-audit.svc.cluster.local:50051 dsa-audit
positive_handshake id-bridge.dsa-bridge.svc.cluster.local:50052 dsa-id-bridge
positive_handshake sandbox-a.dsa-identity.svc.cluster.local:50053 dsa-sandbox-a
positive_handshake sandbox-b.dsa-ai.svc.cluster.local:50054 dsa-sandbox-b
positive_handshake sandbox-a.dsa-identity.svc.cluster.local:8086 dsa-sanitizer

# Stream a static, standard-library-only TLS client into the actual Gateway
# Pod's existing non-secret writable keystore PVC. Every invocation uses the
# Gateway's verified read-only projected leaf and exact target SAN. These are
# transport proofs only; the representative application calls below remain
# the gateway gRPC identity and gateway→sanitizer HTTPS checks.
install_gateway_tls_helper
gateway_workload_handshake audit.dsa-audit.svc.cluster.local:50051 dsa-audit || exit 1
gateway_workload_handshake id-bridge.dsa-bridge.svc.cluster.local:50052 dsa-id-bridge || exit 1
gateway_workload_handshake sandbox-a.dsa-identity.svc.cluster.local:50053 dsa-sandbox-a || exit 1
gateway_workload_handshake sandbox-b.dsa-ai.svc.cluster.local:50054 dsa-sandbox-b || exit 1
gateway_workload_handshake sandbox-a.dsa-identity.svc.cluster.local:8086 dsa-sanitizer || exit 1
gateway_workload_handshake veil-witness.dsa-witness.svc.cluster.local:50057 dsa-veil-witness || exit 1
gateway_workload_handshake veil-witness.dsa-witness.svc.cluster.local:50058 dsa-veil-witness || exit 1

# Claim intake is the shared :50057 witness path. These are intentionally
# narrow TLS-only proofs, not application RPC or authorization tests. Audit,
# ID Bridge, the Sanitizer sidecar, and Sandbox B are distinct real workload
# identities. Sanitizer is the Sandbox A sidecar claim source. Sandbox B is
# the smallest mandatory pipeline choice because its rendered config points to
# this witness address and it emits the inference claim.
for identity_call in \
  'audit dsa-audit audit audit lucairn-mtls-audit' \
  'id-bridge dsa-bridge id-bridge id-bridge lucairn-mtls-id-bridge' \
  'sanitizer dsa-identity sandbox-a sanitizer lucairn-mtls-sanitizer' \
  'sandbox-b dsa-ai sandbox-b sandbox-b lucairn-mtls-sandbox-b'; do
  read -r identity namespace pod_label container secret <<<"$identity_call"
  if ! projected_identity_witness_handshake "$identity" "$namespace" "$pod_label" "$container" "$secret" \
    veil-witness.dsa-witness.svc.cluster.local:50057 dsa-veil-witness; then
    exit 1
  fi
done

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

negative_handshake wrong-ca audit.dsa-audit.svc.cluster.local:50051 dsa-audit dsa-audit \
  /certs/wrong-ca/wrong-ca.crt /certs/gateway/tls.crt /certs/gateway/tls.key
negative_handshake wrong-san audit.dsa-audit.svc.cluster.local:50051 dsa-audit dsa-sandbox-a \
  /certs/gateway/ca.crt /certs/gateway/tls.crt /certs/gateway/tls.key
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
gateway_tls_helper_cleanup
echo "gateway evidence helper deleted after workload transport and local health battery"

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

# Keep the customer-visible evidence classes explicit: a verified TLS
# handshake proves transport and projected-leaf use, while only the two lines
# below claim representative application behavior. Neither class proves
# NetworkPolicy enforcement on stock Kind/kindnet.
echo "PASS: coverage class=workload-originated transport handshake; origin=actual-gateway-pod; projected-leaf=gateway; edges=gateway-to-audit,gateway-to-id-bridge,gateway-to-sandbox-a,gateway-to-sandbox-b,gateway-to-sanitizer,gateway-to-witness-50057,gateway-to-witness-50058; server-SANs=dsa-audit,dsa-id-bridge,dsa-sandbox-a,dsa-sandbox-b,dsa-sanitizer,dsa-veil-witness"
echo "PASS: coverage class=workload-originated transport handshake; projected-leaves=audit,id-bridge,sanitizer,sandbox-b; edges=audit-to-witness,id-bridge-to-witness,sanitizer-to-witness,sandbox-b-to-witness; server-SAN=dsa-veil-witness"
echo "PASS: coverage class=application-layer call; gateway gRPC identity; expected-server-SAN=dsa-sandbox-a"
echo "PASS: coverage class=application-layer call; gateway-to-sanitizer HTTPS; expected-server-SAN=dsa-sanitizer"
echo "PASS: production ExternalSecret/ClusterSecretStore API admission plus workload/application/mTLS behavior using pre-created target Secrets; does not prove live ESO reconciliation"
echo "ENTERPRISE_HELM_MTLS_KIND: PASS"
