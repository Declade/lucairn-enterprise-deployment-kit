#!/usr/bin/env bash
# bootstrap-grpc-certs.sh — per-deploy CA + per-service gRPC certs for the
# Lucairn production Helm posture (values-prod.yaml).
#
# WHAT THE PROD OVERLAY ACTUALLY ENFORCES
# ---------------------------------------
# values-prod.yaml sets dsaEnv=production + grpcTlsEnabled="true" on the Go
# gRPC services (gateway / audit / id-bridge / sandbox-a / admin; ingest when
# opted in). Those services call tlsutil.RequireTLSInProduction() at boot and
# refuse to start with PLAINTEXT transport under DSA_ENV=production — so the
# prod overlay's grpcTlsEnabled="true" is what clears that plaintext refusal.
#
# IMPORTANT — what grpcTlsEnabled="true" alone does (and does NOT) do:
#   * It enables ENCRYPTED gRPC transport (TLS). With NO cert PATHS wired,
#     tlsutil SELF-GENERATES an ephemeral server cert and the clients dial
#     with InsecureSkipVerify=true → the link is ENCRYPTED but NOT
#     peer-authenticated. The services do NOT hard-refuse when cert files are
#     absent in this mode; they fall back to the ephemeral self-signed cert.
#   * Full, peer-AUTHENTICATED mTLS (each side verifies the other against a
#     shared CA) requires the CA + per-service certs this script generates,
#     PLUS chart wiring that mounts them and sets the DSA_MTLS_*_PATH env vars.
#
# This script provisions the CA + certs for OPTIONAL full peer-authenticated
# mTLS. The chart-side cert-CONSUMPTION wiring (volume mounts + DSA_MTLS_*_PATH
# env) is a documented FOLLOW-UP (consistent with the PRD's cert-manager
# dependency deferral) — see the "NEXT STEPS" output printed at the end.
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
# admin + ingest are now included: values-prod.yaml sets grpcTlsEnabled="true"
# for both (admin calls RequireTLSInProduction at server/main.go:49; ingest at
# server/main.go:69), so a future full-mTLS rollout needs their certs.
# ns_for() already maps both. Harmless today — certs are generated but the
# chart cert-mount wiring (DSA_MTLS_*_PATH) is a documented follow-up.
DEFAULT_SERVICES="gateway audit id-bridge sandbox-a sandbox-b veil-witness admin ingest"
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
#   admin        → dsa-admin
#   ingest       → dsa-ingest
#
# NOTE: a plain `case` is used here on purpose — `declare -A` (associative
# arrays) is bash 4+, but macOS ships bash 3.2 as /bin/bash. Under
# `set -euo pipefail` an associative-array reference on bash 3.2 aborts the
# script after only the CA is generated (no service certs). The case below
# is portable to bash 3.2.
ns_for() {
  case "$1" in
    gateway)      printf 'dsa-edge' ;;
    audit)        printf 'dsa-audit' ;;
    id-bridge)    printf 'dsa-bridge' ;;
    sandbox-a)    printf 'dsa-identity' ;;
    sandbox-b)    printf 'dsa-ai' ;;
    veil-witness) printf 'dsa-witness' ;;
    admin)        printf 'dsa-admin' ;;
    ingest)       printf 'dsa-ingest' ;;
    *)            printf 'lucairn' ;;
  esac
}

for svc in $SERVICES; do
  ns="$(ns_for "$svc")"
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
log "   (repeat for each service: gateway audit id-bridge sandbox-a sandbox-b veil-witness admin ingest)"
log ""
log "   CERT_DIR=${CERT_DIR}"
log "   for svc in gateway audit id-bridge sandbox-a sandbox-b veil-witness admin ingest; do"
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
log "     gateway      → dsa-edge"
log "     audit        → dsa-audit"
log "     id-bridge    → dsa-bridge"
log "     sandbox-a    → dsa-identity"
log "     sandbox-b    → dsa-ai"
log "     veil-witness → dsa-witness"
log "     admin        → dsa-admin"
log "     ingest       → dsa-ingest"
log ""
log "3. [FOLLOW-UP] Wire each Secret into the subchart for full peer-"
log "   authenticated mTLS: mount the cert files and set the DSA_MTLS_*_PATH"
log "   env vars (server triple: CA_BUNDLE + SERVER_CERT + SERVER_KEY; client"
log "   triple: CA_BUNDLE + CLIENT_CERT + CLIENT_KEY). The chart cert-mount +"
log "   DSA_MTLS_*_PATH wiring is a documented follow-up (cert-manager"
log "   dependency deferral). Until that wiring lands, the prod overlay still"
log "   runs ENCRYPTED gRPC via tlsutil's ephemeral self-signed cert."
log ""
log "4. Apply values-prod.yaml (this is what clears the prod plaintext refuse —"
log "   it does NOT require the certs above; those are the optional mTLS upgrade):"
log "   helm upgrade --install lucairn charts/lucairn \\"
log "     -f charts/lucairn/values-prod.yaml \\"
log "     -f your-customer-values.yaml \\"
log "     --set-file global.imagePullDockerConfigJson=~/.docker/config.json"
log ""
log "NOTE: dsaEnv=production REQUIRES grpcTlsEnabled=\"true\" (values-prod.yaml"
log "sets both) — a Go service refuses to start with PLAINTEXT transport under"
log "production. With grpcTlsEnabled=\"true\" but no cert PATHS wired, transport"
log "is ENCRYPTED via an ephemeral self-signed cert (no peer auth, no crash)."
log "──────────────────────────────────────────────────────────────────────────"
