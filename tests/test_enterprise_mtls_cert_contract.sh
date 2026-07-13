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

# openssl x509 -checkhost exit codes are version-dependent (OpenSSL 3.0 —
# Ubuntu CI — always exits 0; 3.4+ exits 1 on mismatch), so the portable
# contract is the printed verdict text, failing closed on anything else.
san_matches() {
  local leaf="$1" san="$2" out
  out="$(openssl x509 -checkhost "$san" -noout -in "$leaf" 2>&1)" || true
  case "$out" in
    *"does NOT match certificate"*) return 1 ;;
    *"does match certificate"*) return 0 ;;
    *)
      printf 'unrecognized openssl -checkhost output for %s (%s): %s\n' \
        "$leaf" "$san" "$out" >&2
      exit 1
      ;;
  esac
}

while IFS=: read -r identity san; do
  leaf="$TMPDIR/certs/$identity/tls.crt"
  openssl verify -CAfile "$TMPDIR/certs/ca.crt" "$leaf" >/dev/null
  if ! san_matches "$leaf" "$san"; then
    echo "expected SAN $san does not match the $identity leaf" >&2
    exit 1
  fi
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
if san_matches "$TMPDIR/certs/sandbox-a/tls.crt" dsa-audit; then
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
if ! san_matches "$expired_server_leaf" dsa-sandbox-a; then
  echo "expired Sandbox A server leaf lost its expected SAN" >&2
  exit 1
fi
if ! openssl verify -no_check_time -CAfile "$TMPDIR/certs/ca.crt" "$expired_server_leaf" >/dev/null 2>&1; then
  echo "expired Sandbox A server leaf is not signed by the trusted fixture CA" >&2
  exit 1
fi
if openssl x509 -checkend 0 -noout -in "$expired_server_leaf" >/dev/null 2>&1; then
  echo "expired Sandbox A server leaf unexpectedly passed validity check" >&2
  exit 1
fi

echo "enterprise mTLS certificate contract: CA, SAN, trusted client/server expiry negatives: ok"
