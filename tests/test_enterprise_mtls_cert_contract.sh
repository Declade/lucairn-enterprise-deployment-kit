#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if ! command -v openssl >/dev/null 2>&1; then
  echo "enterprise mTLS certificate contract: SKIPPED — openssl not installed"
  exit 0
fi

"$ROOT/scripts/enterprise-mtls-fixture-certs.sh" "$TMPDIR/certs" >/dev/null

while IFS=: read -r identity san; do
  leaf="$TMPDIR/certs/$identity/tls.crt"
  openssl verify -CAfile "$TMPDIR/certs/ca.crt" "$leaf" >/dev/null
  openssl x509 -checkhost "$san" -noout -in "$leaf" >/dev/null
done <<'IDENTITIES'
gateway:dsa-gateway
audit:dsa-audit
id-bridge:dsa-id-bridge
sandbox-a:dsa-sandbox-a
sanitizer:dsa-sanitizer
sandbox-b:dsa-sandbox-b
veil-witness:dsa-veil-witness
IDENTITIES

if openssl verify -CAfile "$TMPDIR/certs/wrong-ca.crt" "$TMPDIR/certs/audit/tls.crt" >/dev/null 2>&1; then
  echo "wrong CA unexpectedly verified an enterprise mTLS leaf" >&2
  exit 1
fi
if openssl x509 -checkhost dsa-audit -noout -in "$TMPDIR/certs/sandbox-a/tls.crt" >/dev/null 2>&1; then
  echo "wrong SAN unexpectedly matched the sandbox-a leaf" >&2
  exit 1
fi
expired_leaf="$TMPDIR/certs/expired-gateway/tls.crt"
if ! openssl verify -no_check_time -CAfile "$TMPDIR/certs/ca.crt" "$expired_leaf" >/dev/null 2>&1; then
  echo "expired enterprise mTLS leaf is not signed by the trusted fixture CA" >&2
  exit 1
fi
if ! openssl x509 -noout -text -in "$expired_leaf" | grep -Fq 'TLS Web Client Authentication'; then
  echo "expired enterprise mTLS leaf is missing clientAuth" >&2
  exit 1
fi
if openssl x509 -checkend 0 -noout -in "$expired_leaf" >/dev/null 2>&1; then
  echo "expired enterprise mTLS leaf unexpectedly passed validity check" >&2
  exit 1
fi

# The representative server-material negative is deliberately SAN-correct and
# still CA-issued: the real gateway client test can attribute its failure to
# expiry, rather than to a mismatched identity or trust root.
expired_server_leaf="$TMPDIR/certs/expired-sandbox-a/tls.crt"
openssl x509 -checkhost dsa-sandbox-a -noout -in "$expired_server_leaf" >/dev/null
if ! openssl verify -no_check_time -CAfile "$TMPDIR/certs/ca.crt" "$expired_server_leaf" >/dev/null 2>&1; then
  echo "expired Sandbox A server leaf is not signed by the trusted fixture CA" >&2
  exit 1
fi
if openssl x509 -checkend 0 -noout -in "$expired_server_leaf" >/dev/null 2>&1; then
  echo "expired Sandbox A server leaf unexpectedly passed validity check" >&2
  exit 1
fi

echo "enterprise mTLS certificate contract: CA, SAN, trusted client/server expiry negatives: ok"
