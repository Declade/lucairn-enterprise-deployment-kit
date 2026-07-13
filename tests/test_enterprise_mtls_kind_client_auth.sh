#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND_GATE="$ROOT/scripts/test-enterprise-mtls-kind.sh"

bash -n "$KIND_GATE"

helper="$(sed -n '/^strict_client_auth_rejection() {/,/^positive_handshake audit\.dsa-audit/p' "$KIND_GATE")"
if [ -z "$helper" ]; then
  echo "enterprise mTLS Kind gate is missing the strict client-auth rejection helper" >&2
  exit 1
fi

for required in \
  'timeout 15 openssl s_client' \
  '-connect "$address"' \
  '-servername "$san"' \
  '-verify_hostname "$san"' \
  '-verify_return_error' \
  '-CAfile "$ca_file"' \
  '-quiet -ign_eof' \
  '[ "$status" -eq 124 ]' \
  '[ "$status" -eq 0 ]' \
  '[ "$status" -ge 125 ] && [ "$status" -le 127 ]' \
  '(tls|ssl).*alert|alert.*(tls|ssl)'; do
  if ! grep -Fq -- "$required" <<<"$helper"; then
    echo "strict client-auth rejection helper is missing: $required" >&2
    exit 1
  fi
done

if grep -Eq '^negative_handshake missing-client-cert ' "$KIND_GATE"; then
  echo "missing-client-cert must use the strict server-side client-auth helper" >&2
  exit 1
fi
if grep -Eq '^expired_client_cert_rejection\(\)' "$KIND_GATE"; then
  echo "expired-client-cert must not retain a duplicate strict rejection helper" >&2
  exit 1
fi

grep -Fxq 'strict_client_auth_rejection missing-client-cert audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/gateway/ca.crt' "$KIND_GATE" \
  || { echo "missing-client-cert strict check lost audit CA/SNI/hostname inputs" >&2; exit 1; }
grep -Fxq 'strict_client_auth_rejection expired-client-cert audit.dsa-audit.svc.cluster.local:50051 dsa-audit /certs/expired/ca.crt /certs/expired/tls.crt /certs/expired/tls.key' "$KIND_GATE" \
  || { echo "expired-client-cert strict check lost audit CA/SNI/hostname inputs" >&2; exit 1; }

echo "enterprise mTLS Kind strict client-auth negatives: contract ok"
