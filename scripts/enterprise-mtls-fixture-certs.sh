#!/usr/bin/env bash
set -euo pipefail

# Creates disposable test material for the isolated enterprise mTLS harness.
# It is deliberately not a customer PKI tool: it writes private keys only to
# the caller-provided disposable directory and never writes into this repo.

OUT_DIR="${1:-}"
if [ -z "$OUT_DIR" ]; then
  echo "usage: $0 <empty-output-directory>" >&2
  exit 2
fi
if [ -e "$OUT_DIR" ] && [ -n "$(find "$OUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "refusing to write fixture certificates into non-empty directory: $OUT_DIR" >&2
  exit 2
fi

umask 077
mkdir -p "$OUT_DIR"

make_ca() {
  local cert="$1" key="$2" subject="$3"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7 \
    -subj "$subject" \
    -keyout "$key" -out "$cert" >/dev/null 2>&1
}

issue_leaf() {
  local identity="$1" san="$2" dir="$OUT_DIR/$identity"
  mkdir -p "$dir"
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -subj "/CN=$san" \
    -keyout "$dir/tls.key" -out "$dir/request.csr" >/dev/null 2>&1
  printf '%s\n' \
    "subjectAltName=DNS:$san" \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage=serverAuth,clientAuth' > "$dir/extensions.cnf"
  openssl x509 -req -sha256 -days 2 \
    -in "$dir/request.csr" \
    -CA "$OUT_DIR/ca.crt" -CAkey "$OUT_DIR/ca.key" -CAcreateserial \
    -extfile "$dir/extensions.cnf" -out "$dir/tls.crt" >/dev/null 2>&1
  cp "$OUT_DIR/ca.crt" "$dir/ca.crt"
  rm -f "$dir/request.csr" "$dir/extensions.cnf"
}

make_ca "$OUT_DIR/ca.crt" "$OUT_DIR/ca.key" '/CN=Lucairn Enterprise mTLS Test CA'
make_ca "$OUT_DIR/wrong-ca.crt" "$OUT_DIR/wrong-ca.key" '/CN=Lucairn Enterprise Wrong Test CA'

while IFS=: read -r identity san; do
  issue_leaf "$identity" "$san"
done <<'IDENTITIES'
gateway:dsa-gateway
audit:dsa-audit
id-bridge:dsa-id-bridge
sandbox-a:dsa-sandbox-a
sanitizer:dsa-sanitizer
sandbox-b:dsa-sandbox-b
veil-witness:dsa-veil-witness
IDENTITIES

# An explicitly expired client/server-capable leaf drives the expiry-negative
# acceptance test. openssl ca is used here because `openssl x509 -req` cannot
# set an end date in the past.
EXPIRED_DIR="$OUT_DIR/expired-gateway"
CA_DB="$OUT_DIR/ca-db"
mkdir -p "$EXPIRED_DIR" "$CA_DB/newcerts"
: > "$CA_DB/index.txt"
printf '1000\n' > "$CA_DB/serial"
openssl req -newkey rsa:2048 -nodes -sha256 \
  -subj '/CN=dsa-gateway' \
  -addext 'subjectAltName=DNS:dsa-gateway' \
  -keyout "$EXPIRED_DIR/tls.key" -out "$EXPIRED_DIR/request.csr" >/dev/null 2>&1
cat > "$CA_DB/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = $CA_DB
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
certificate = $OUT_DIR/ca.crt
private_key = $OUT_DIR/ca.key
serial = \$dir/serial
default_md = sha256
policy = policy_any
copy_extensions = copy
unique_subject = no
[ expired_leaf ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
[ policy_any ]
commonName = supplied
EOF
openssl ca -batch -notext -config "$CA_DB/openssl.cnf" \
  -extensions expired_leaf \
  -startdate 20240101000000Z -enddate 20240102000000Z \
  -in "$EXPIRED_DIR/request.csr" -out "$EXPIRED_DIR/tls.crt" >/dev/null 2>&1
cp "$OUT_DIR/ca.crt" "$EXPIRED_DIR/ca.crt"
rm -f "$EXPIRED_DIR/request.csr"

echo "enterprise mTLS fixture certificates: $OUT_DIR"
