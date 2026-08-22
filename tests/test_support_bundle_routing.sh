#!/usr/bin/env bash
set -euo pipefail

# T-675 fixture (e): every customer-derived file in the support bundle must go
# through redact_stream.
#
# Two files did not. Both are written by support_bundle() (bin/lucairn):
#
#   certs/cert-validity.txt  — write_cert_report echoes `$key=$path` for each
#                              configured cert path plus the openssl subject/
#                              issuer DNs. Cert paths and DNs carry operator
#                              names and email addresses.
#   README.txt               — embeds `hostname` and `uname -a`, both
#                              customer-controlled strings.
#
# Neither passed redact_stream, so a planted secret reached the archive verbatim.
# This test plants one in each and asserts it does not survive.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"; rm -f "$ROOT/.lucairn-customer-id"' EXIT

CERT_SECRET='ops.person@customer.example'
HOST_SECRET='ops.admin@customer.example'

ENV_FILE="$TMPDIR/customer.env"
"$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name acme-support-llm --model-file acme-support-q4.gguf --model-path . \
  --output "$ENV_FILE" --skip-doctor >/dev/null 2>&1

# Planted secret #1: an operator email inside a configured cert path. The path
# does not exist, so write_cert_report takes its deterministic "(missing)"
# branch and no openssl call is needed.
printf 'WITNESS_MTLS_CA_BUNDLE_PATH=/etc/lucairn/%s/ca.pem\n' "$CERT_SECRET" >> "$ENV_FILE"

# Planted secret #2: an operator email in the host name, via a PATH stub so the
# assertion is deterministic on any machine.
STUB="$TMPDIR/stub"
mkdir -p "$STUB"
cat > "$STUB/hostname" <<STUBEOF
#!/usr/bin/env bash
echo "bundle-host-$HOST_SECRET"
STUBEOF
chmod +x "$STUB/hostname"

PATH="$STUB:$PATH" "$ROOT/bin/lucairn" support-bundle \
  --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --output "$TMPDIR/bundles" \
  --offline > "$TMPDIR/support.out"

BUNDLE="$(find "$TMPDIR/bundles" -name 'lucairn-support-bundle-*.tar.gz' -print -quit)"
test -n "$BUNDLE" || { echo "routing test FAILED: no bundle produced" >&2; exit 1; }

EXTRACTED="$TMPDIR/extracted"
mkdir -p "$EXTRACTED"
tar -xzf "$BUNDLE" -C "$EXTRACTED"

CERT_FILE="$(find "$EXTRACTED" -path '*/certs/cert-validity.txt' -print -quit)"
README_FILE="$(find "$EXTRACTED" -name 'README.txt' -print -quit)"
test -n "$CERT_FILE" || { echo "routing test FAILED: cert-validity.txt missing" >&2; exit 1; }
test -n "$README_FILE" || { echo "routing test FAILED: README.txt missing" >&2; exit 1; }

if grep -Fq -- "$CERT_SECRET" "$CERT_FILE"; then
  echo "routing test FAILED: certs/cert-validity.txt leaked $CERT_SECRET" >&2
  cat "$CERT_FILE" >&2
  exit 1
fi
if grep -Fq -- "$HOST_SECRET" "$README_FILE"; then
  echo "routing test FAILED: README.txt leaked $HOST_SECRET" >&2
  cat "$README_FILE" >&2
  exit 1
fi

# Nothing anywhere in the archive may carry either planted secret.
if grep -RFq -- "$CERT_SECRET" "$EXTRACTED" || grep -RFq -- "$HOST_SECRET" "$EXTRACTED"; then
  echo "routing test FAILED: a planted secret survived somewhere in the bundle" >&2
  grep -RF -- "$CERT_SECRET" "$EXTRACTED" >&2 || true
  grep -RF -- "$HOST_SECRET" "$EXTRACTED" >&2 || true
  exit 1
fi

# Routing must not have mangled the files into uselessness.
grep -q "Lucairn support bundle" "$README_FILE" \
  || { echo "routing test FAILED: README.txt lost its header" >&2; cat "$README_FILE" >&2; exit 1; }
grep -q "Customer review required" "$README_FILE" \
  || { echo "routing test FAILED: README.txt lost its review notice" >&2; cat "$README_FILE" >&2; exit 1; }
grep -q "WITNESS_MTLS_CA_BUNDLE_PATH" "$CERT_FILE" \
  || { echo "routing test FAILED: cert-validity.txt lost its key line" >&2; cat "$CERT_FILE" >&2; exit 1; }

# The raw pre-redaction cert report must never be archived.
if find "$EXTRACTED" -name '*.raw' | grep -q .; then
  echo "routing test FAILED: a raw pre-redaction file was archived" >&2
  exit 1
fi

echo "support bundle redaction-routing tests: ok"
