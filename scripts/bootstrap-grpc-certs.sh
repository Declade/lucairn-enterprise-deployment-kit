#!/usr/bin/env bash
# bootstrap-grpc-certs.sh — per-deploy CA + per-service gRPC TLS certs for
# the Lucairn production Helm posture (values-prod.yaml).
#
# Required BEFORE applying values-prod.yaml (dsaEnv=production +
# grpcTlsEnabled=true). The Go gateway / audit / id-bridge / sandbox-a
# services call tlsutil.RequireTLSInProduction() at boot and hard-refuse
# (log.Fatal) when DSA_ENV=production and GRPC_TLS_ENABLED=true but the
# expected cert files are absent.
#
# Usage:
#   bash scripts/bootstrap-grpc-certs.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to ./grpc-certs (create it before helm install).
# Re-running is IDEMPOTENT: existing key/cert pairs are NOT overwritten.
# To rotate, delete the individual files (or the whole dir) and re-run.
#
# Produces:
#   ca.crt / ca.key         — per-deploy CA (keep ca.key offline after use)
#   <service>-server.crt/key — gRPC server cert+key per service
#   <service>-client.crt/key — gRPC client cert+key per service
#
# Services provisioned (mirroring the Lucairn gRPC mesh):
#   gateway  audit  id-bridge  sandbox-a  sandbox-b  veil-witness
#
# After running, load each cert pair into the cluster as a K8s Secret, then
# reference the Secret in the relevant subchart's values (witnessMtls or a
# DSA_MTLS_* env-var injection). See INSTALL.md § "Production gRPC TLS" for
# the full wiring runbook.
#
# Environment overrides:
#   CERT_DIR   (positional $1 takes precedence)  — output directory
#   CA_DAYS    — CA validity in days  (default: 3650)
#   LEAF_DAYS  — leaf cert validity   (default: 365)
#   SERVICES   — space-separated list (default: the 6 core services)

set -euo pipefail

CERT_DIR="${1:-${CERT_DIR:-./grpc-certs}}"
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-365}"

# Core Lucairn gRPC services. Each gets a server cert + a client cert so
# that both sides of every dial can present a cert (full mTLS).
DEFAULT_SERVICES="gateway audit id-bridge sandbox-a sandbox-b veil-witness"
SERVICES="${SERVICES:-$DEFAULT_SERVICES}"

mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"

log() { printf '[bootstrap-grpc-certs] %s\n' "$*"; }

# ── 1. Per-deploy CA ──────────────────────────────────────────────────────────
if [ ! -f "${CERT_DIR}/ca.key" ]; then
  log "generating CA private key (ED25519)"
  openssl genpkey -algorithm ED25519 -out "${CERT_DIR}/ca.key"
  log "issuing self-signed CA cert (${CA_DAYS} days)"
  openssl req -new -x509 -days "${CA_DAYS}" \
    -key "${CERT_DIR}/ca.key" \
    -out "${CERT_DIR}/ca.crt" \
    -subj "/CN=lucairn-grpc-deploy-ca"
else
  log "ca.key exists — reusing"
fi

# ── 2. Per-service server + client certs ─────────────────────────────────────
# Each service gets:
#   <svc>-server.crt / <svc>-server.key   — presented by its gRPC listener
#   <svc>-client.crt / <svc>-client.key   — presented when it dials another svc
#
# SANs for the server cert include the canonical K8s in-cluster DNS name
# (<svc>.<namespace>.svc, <svc>.<namespace>.svc.cluster.local) plus
# localhost for local port-forwards and CI probes.
#
# Namespace mapping (matches kit chart defaults):
#   gateway      → dsa-edge
#   audit        → dsa-audit
#   id-bridge    → dsa-bridge
#   sandbox-a    → dsa-identity
#   sandbox-b    → dsa-ai
#   veil-witness → dsa-witness

declare -A SVC_NS
SVC_NS["gateway"]="dsa-edge"
SVC_NS["audit"]="dsa-audit"
SVC_NS["id-bridge"]="dsa-bridge"
SVC_NS["sandbox-a"]="dsa-identity"
SVC_NS["sandbox-b"]="dsa-ai"
SVC_NS["veil-witness"]="dsa-witness"

for svc in $SERVICES; do
  ns="${SVC_NS[$svc]:-lucairn}"
  server_key="${CERT_DIR}/${svc}-server.key"
  server_crt="${CERT_DIR}/${svc}-server.crt"
  client_key="${CERT_DIR}/${svc}-client.key"
  client_crt="${CERT_DIR}/${svc}-client.crt"

  # Server cert
  if [ ! -f "${server_key}" ]; then
    log "generating ${svc} server key + cert (${LEAF_DAYS} days)"
    openssl genpkey -algorithm ED25519 -out "${server_key}"
    openssl req -new \
      -key "${server_key}" \
      -out "${CERT_DIR}/${svc}-server.csr" \
      -subj "/CN=${svc}"
    cat > "${CERT_DIR}/${svc}-server.ext" <<EXT
subjectAltName = DNS:${svc}, DNS:${svc}.${ns}.svc, DNS:${svc}.${ns}.svc.cluster.local, DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
keyUsage = digitalSignature, keyEncipherment
basicConstraints = CA:FALSE
EXT
    openssl x509 -req \
      -in "${CERT_DIR}/${svc}-server.csr" \
      -CA "${CERT_DIR}/ca.crt" \
      -CAkey "${CERT_DIR}/ca.key" \
      -CAcreateserial \
      -out "${server_crt}" \
      -days "${LEAF_DAYS}" \
      -extfile "${CERT_DIR}/${svc}-server.ext"
    rm -f "${CERT_DIR}/${svc}-server.csr" "${CERT_DIR}/${svc}-server.ext"
  else
    log "${svc}-server.key exists — reusing"
  fi

  # Client cert (used when this service dials other services)
  if [ ! -f "${client_key}" ]; then
    log "generating ${svc} client key + cert (${LEAF_DAYS} days)"
    openssl genpkey -algorithm ED25519 -out "${client_key}"
    openssl req -new \
      -key "${client_key}" \
      -out "${CERT_DIR}/${svc}-client.csr" \
      -subj "/CN=${svc}-client"
    cat > "${CERT_DIR}/${svc}-client.ext" <<EXT
extendedKeyUsage = clientAuth
keyUsage = digitalSignature, keyEncipherment
basicConstraints = CA:FALSE
EXT
    openssl x509 -req \
      -in "${CERT_DIR}/${svc}-client.csr" \
      -CA "${CERT_DIR}/ca.crt" \
      -CAkey "${CERT_DIR}/ca.key" \
      -CAcreateserial \
      -out "${client_crt}" \
      -days "${LEAF_DAYS}" \
      -extfile "${CERT_DIR}/${svc}-client.ext"
    rm -f "${CERT_DIR}/${svc}-client.csr" "${CERT_DIR}/${svc}-client.ext"
  else
    log "${svc}-client.key exists — reusing"
  fi
done

# ── 3. Tighten permissions ────────────────────────────────────────────────────
# Keys must NOT be world-readable. ca.key in particular — anyone with read
# access can mint new certs and bypass peer-verification.
chmod 600 "${CERT_DIR}"/*.key
chmod 644 "${CERT_DIR}"/*.crt 2>/dev/null || true

log ""
log "bootstrap complete: ${CERT_DIR}"
log "files generated:"
ls -1 "${CERT_DIR}"
log ""
log "──────────────────────────────────────────────────────────────────────────"
log "NEXT STEPS"
log "──────────────────────────────────────────────────────────────────────────"
log ""
log "1. Store the CA private key offline:"
log "     cp ${CERT_DIR}/ca.key /path/to/secure/offline/storage"
log "     shred -u ${CERT_DIR}/ca.key  # or equivalent secure delete"
log ""
log "2. Load each service cert pair as a K8s Secret:"
log "   (repeat for each service: gateway audit id-bridge sandbox-a sandbox-b veil-witness)"
log ""
log "   CERT_DIR=${CERT_DIR}"
log "   for svc in gateway audit id-bridge sandbox-a sandbox-b veil-witness; do"
log "     kubectl create secret generic lucairn-\${svc}-grpc-tls \\"
log "       --namespace=<service-namespace> \\"
log "       --from-file=ca.crt=\${CERT_DIR}/ca.crt \\"
log "       --from-file=server.crt=\${CERT_DIR}/\${svc}-server.crt \\"
log "       --from-file=server.key=\${CERT_DIR}/\${svc}-server.key \\"
log "       --from-file=client.crt=\${CERT_DIR}/\${svc}-client.crt \\"
log "       --from-file=client.key=\${CERT_DIR}/\${svc}-client.key"
log "   done"
log ""
log "   Namespace per service (kit defaults):"
log "     gateway     → dsa-edge"
log "     audit       → dsa-audit"
log "     id-bridge   → dsa-bridge"
log "     sandbox-a   → dsa-identity"
log "     sandbox-b   → dsa-ai"
log "     veil-witness → dsa-witness"
log ""
log "3. Wire each Secret into the subchart via DSA_MTLS_* env vars or"
log "   the subchart's mTLS values block in your customer-values.yaml."
log "   See INSTALL.md § 'Production gRPC TLS' for the full wiring runbook."
log ""
log "4. THEN apply values-prod.yaml:"
log "   helm upgrade --install lucairn charts/lucairn \\"
log "     -f charts/lucairn/values-prod.yaml \\"
log "     -f your-customer-values.yaml \\"
log "     --set-file global.imagePullDockerConfigJson=~/.docker/config.json"
log ""
log "WARNING: Do NOT apply values-prod.yaml (dsaEnv=production) before step 2."
log "Services crash-loop if GRPC_TLS_ENABLED=true and cert files are absent."
log "──────────────────────────────────────────────────────────────────────────"
