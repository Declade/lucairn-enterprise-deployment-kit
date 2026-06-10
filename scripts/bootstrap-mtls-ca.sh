#!/usr/bin/env bash
# bootstrap-mtls-ca.sh — deploy-local CA + witness server cert + per-caller
# client certs for TOB-S009 witness mTLS.
#
# Generates a per-deploy CA, signs a server cert for the witness, and signs
# one client cert per authorised caller (gateway, sandbox-a by default). The
# CA private key never leaves the output directory; the public CA cert is
# mounted read-only into both the witness and gateway containers as the trust
# anchor.
#
# Idempotent: each cert / key pair is generated only when missing, so repeat
# runs do not rotate keys. To rotate, delete the output directory (or
# individual files) and re-run.
#
# Run once at deploy time, BEFORE recreating the witness + gateway containers
# with the WITNESS_MTLS_* env vars wired:
#
#   bash scripts/bootstrap-mtls-ca.sh /opt/dsa/certs/witness-mtls
#
#   # Compose path — add to customer.env then recreate the two services:
#   LCR_WITNESS_MTLS_HOST_DIR=/opt/dsa/certs/witness-mtls
#   WITNESS_MTLS_CA_BUNDLE_PATH=/etc/witness-mtls/ca.crt
#   WITNESS_MTLS_SERVER_CERT_PATH=/etc/witness-mtls/witness-server.crt
#   WITNESS_MTLS_SERVER_KEY_PATH=/etc/witness-mtls/witness-server.key
#   WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH=/etc/witness-mtls/gateway-client.crt
#   WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH=/etc/witness-mtls/gateway-client.key
#   WITNESS_MTLS_SERVER_NAME=witness
#   docker compose -f docker-compose.customer.yml up -d --no-deps --force-recreate \
#     veil-witness gateway
#
#   # Kubernetes path — see INSTALL.md § "Witness mTLS (optional)" for
#   # the kubectl create secret + values.yaml wiring steps.
#
# See INSTALL.md § "Witness mTLS" for the full operator runbook.
#
# Environment overrides:
#   CERT_DIR (positional $1 takes precedence) — output directory
#   CA_DAYS             — CA validity in days        (default: 3650)
#   LEAF_DAYS           — leaf cert validity in days (default: 365)
#   WITNESS_MTLS_CLIENTS   — space-separated caller names (default: "gateway sandbox-a")
#   WITNESS_MTLS_SAN       — witness server SANs (default: DNS:witness + DNS:veil-witness
#                            + DNS:localhost + IP:127.0.0.1)

set -euo pipefail

CERT_DIR="${1:-${CERT_DIR:-/opt/dsa/certs/witness-mtls}}"
CA_DAYS="${CA_DAYS:-3650}"
LEAF_DAYS="${LEAF_DAYS:-365}"

# Callers to mint a client cert for. The witness ACL interceptor checks the
# Subject CN against its allowed-callers list; the CNs below match the
# services/veil-witness/internal/server/acl.go MethodACL defaults.
DEFAULT_CLIENTS="gateway sandbox-a"
CLIENTS="${WITNESS_MTLS_CLIENTS:-$DEFAULT_CLIENTS}"

# Witness server SANs — must include the DNS name the gateway dials at
# WITNESS_MTLS_SERVER_NAME (default "witness").
DEFAULT_SAN="DNS:witness, DNS:veil-witness, DNS:localhost, IP:127.0.0.1"
SAN="${WITNESS_MTLS_SAN:-$DEFAULT_SAN}"

mkdir -p "${CERT_DIR}"
chmod 700 "${CERT_DIR}"

log() { printf '[bootstrap-mtls-ca] %s\n' "$*"; }

# ── 1. Per-deploy CA ──────────────────────────────────────────────────────────
if [ ! -f "${CERT_DIR}/ca.key" ]; then
  log "generating CA private key (ED25519)"
  openssl genpkey -algorithm ED25519 -out "${CERT_DIR}/ca.key"
  log "issuing self-signed CA cert (${CA_DAYS} days)"
  openssl req -new -x509 -days "${CA_DAYS}" \
    -key "${CERT_DIR}/ca.key" \
    -out "${CERT_DIR}/ca.crt" \
    -subj "/CN=lucairn-witness-deploy-ca"
else
  log "ca.key exists — reusing"
fi

# ── 2. Witness server cert ────────────────────────────────────────────────────
if [ ! -f "${CERT_DIR}/witness-server.key" ]; then
  log "generating witness server key + cert (${LEAF_DAYS} days)"
  openssl genpkey -algorithm ED25519 -out "${CERT_DIR}/witness-server.key"
  openssl req -new \
    -key "${CERT_DIR}/witness-server.key" \
    -out "${CERT_DIR}/witness-server.csr" \
    -subj "/CN=witness"
  cat > "${CERT_DIR}/witness-server.ext" <<EXT
subjectAltName = ${SAN}
extendedKeyUsage = serverAuth
keyUsage = digitalSignature, keyEncipherment
basicConstraints = CA:FALSE
EXT
  openssl x509 -req \
    -in "${CERT_DIR}/witness-server.csr" \
    -CA "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/witness-server.crt" \
    -days "${LEAF_DAYS}" \
    -extfile "${CERT_DIR}/witness-server.ext"
  rm -f "${CERT_DIR}/witness-server.csr" "${CERT_DIR}/witness-server.ext"
else
  log "witness-server.key exists — reusing"
fi

# ── 3. Per-caller client certs ────────────────────────────────────────────────
# Each caller gets a leaf cert with CN = the role name. The witness ACL
# interceptor validates VerifiedChains[0][0].Subject.CommonName.
for client in $CLIENTS; do
  if [ ! -f "${CERT_DIR}/${client}-client.key" ]; then
    log "generating ${client} client key + cert (${LEAF_DAYS} days)"
    openssl genpkey -algorithm ED25519 -out "${CERT_DIR}/${client}-client.key"
    openssl req -new \
      -key "${CERT_DIR}/${client}-client.key" \
      -out "${CERT_DIR}/${client}-client.csr" \
      -subj "/CN=${client}"
    cat > "${CERT_DIR}/${client}-client.ext" <<EXT
extendedKeyUsage = clientAuth
keyUsage = digitalSignature, keyEncipherment
basicConstraints = CA:FALSE
EXT
    openssl x509 -req \
      -in "${CERT_DIR}/${client}-client.csr" \
      -CA "${CERT_DIR}/ca.crt" \
      -CAkey "${CERT_DIR}/ca.key" \
      -CAcreateserial \
      -out "${CERT_DIR}/${client}-client.crt" \
      -days "${LEAF_DAYS}" \
      -extfile "${CERT_DIR}/${client}-client.ext"
    rm -f "${CERT_DIR}/${client}-client.csr" "${CERT_DIR}/${client}-client.ext"
  else
    log "${client}-client.key exists — reusing"
  fi
done

# ── 4. Tighten permissions ────────────────────────────────────────────────────
# Keys must NOT be world-readable. ca.key is the root of trust — anyone with
# read access can mint new client certs and bypass the ACL.
chmod 600 "${CERT_DIR}"/*.key
chmod 644 "${CERT_DIR}"/*.crt 2>/dev/null || true

log "bootstrap complete: ${CERT_DIR}"
log "files generated:"
ls -1 "${CERT_DIR}"
log ""
log "next steps (Compose path):"
log "  1. Add to customer.env:"
log "       LCR_WITNESS_MTLS_HOST_DIR=${CERT_DIR}"
log "       WITNESS_MTLS_CA_BUNDLE_PATH=/etc/witness-mtls/ca.crt"
log "       WITNESS_MTLS_SERVER_CERT_PATH=/etc/witness-mtls/witness-server.crt"
log "       WITNESS_MTLS_SERVER_KEY_PATH=/etc/witness-mtls/witness-server.key"
log "       WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH=/etc/witness-mtls/gateway-client.crt"
log "       WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH=/etc/witness-mtls/gateway-client.key"
log "       WITNESS_MTLS_SERVER_NAME=witness"
log "  2. Recreate the witness and gateway containers:"
log "       docker compose -f docker-compose.customer.yml up -d --no-deps --force-recreate veil-witness gateway"
log ""
log "For the Kubernetes path see INSTALL.md § 'Witness mTLS'."
