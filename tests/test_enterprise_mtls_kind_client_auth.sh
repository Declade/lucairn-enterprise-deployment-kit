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
  '/probe client-auth-rejection "$address" "$san" "$san" "$ca_file"' \
  'command+=("$client_cert" "$client_key")' \
  'exec enterprise-mtls-probe -- "${command[@]}"' \
  'actual remote TLS alert'; do
  if ! grep -Fq -- "$required" <<<"$helper"; then
    echo "strict client-auth rejection helper is missing: $required" >&2
    exit 1
  fi
done

go_source="$(sed -n '/^package main$/,/^GO$/p' "$KIND_GATE")"
for required in \
  'func runClientAuthRejection(args []string)' \
  'func clientAuthRejectionError(address, serverName, verifyHostname, caPath, certPath, keyPath string, clientMaterial bool) error' \
  'verifiedServer := false' \
  'config.VerifyConnection = func(state tls.ConnectionState) error' \
  'if err := state.PeerCertificates[0].VerifyHostname(verifyHostname); err != nil {' \
  'verifiedServer = true' \
  'if !verifiedServer {' \
  'conn.HandshakeContext(ctx)' \
  'isTimeout(err)' \
  'isRemoteTLSAlert(err)' \
  'strings.HasPrefix(err.Error(), "remote error: tls:")'; do
  grep -Fq -- "$required" <<<"$go_source" \
    || { echo "strict client-auth static helper is missing: $required" >&2; exit 1; }
done
if [ "$(grep -Fc 'verifiedServer = true' <<<"$go_source")" -ne 1 ]; then
  echo "strict client-auth verification flag must be set only by VerifyConnection" >&2
  exit 1
fi
if grep -Fq 'openssl s_client' <<<"$helper" || grep -Fq 'sh -ec' <<<"$helper"; then
  echo "strict client-auth rejection must not retain an OpenSSL/shell probe" >&2
  exit 1
fi

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

command -v go >/dev/null 2>&1 || {
  echo "Go is required to test the generated client-auth rejection helper" >&2
  exit 1
}
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
HELPER_SOURCE="$TMPDIR/gateway-tls-helper.go"
HELPER_TEST="$TMPDIR/client-auth-rejection_test.go"
ruby -e '
  source = File.read(ARGV.fetch(0))
  source_start = source.index("package main") || abort("Kind harness misses generated Gateway Go source")
  source_end = source.index("\nGO\n", source_start) || abort("Kind harness does not terminate generated Gateway Go source")
  File.write(ARGV.fetch(1), source[source_start...source_end])
' "$KIND_GATE" "$HELPER_SOURCE"
cat > "$HELPER_TEST" <<'GO'
package main

import (
	"errors"
	"testing"
)

func TestClientAuthRejectionRequiresVerifiedServer(t *testing.T) {
	remoteAlert := errors.New("remote error: tls: certificate required")
	if err := clientAuthRejectionResult(false, remoteAlert); err == nil {
		t.Fatal("unverified remote TLS alert counted as client-auth rejection")
	}
	if err := clientAuthRejectionResult(true, remoteAlert); err != nil {
		t.Fatalf("verified server client-cert alert was not accepted: %v", err)
	}
}
GO
CGO_ENABLED=0 go test "$HELPER_SOURCE" "$HELPER_TEST"

echo "enterprise mTLS Kind strict client-auth negatives: contract ok"
