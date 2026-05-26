#!/usr/bin/env bash
#
# render-values.sh — turn customer-values.yaml.example into a ready-to-install
# customer-values.yaml by filling every REPLACE_* placeholder with a
# correctly-shaped random value.
#
# Usage:
#   scripts/render-values.sh <output-path>
#
# Example:
#   scripts/render-values.sh /root/customer-values.yaml
#
# What this script does (and why it matters):
#
#   1. Paired Ed25519 keys — every VEIL_*_SIGNING_KEY seed is generated
#      via `openssl rand -hex 32` and its matching VEIL_*_PUBLIC_KEY is
#      DERIVED via scripts/derive-veil-pubkey.sh. Treating the public key
#      as an independent random hex (the v0 bug) yields a key that does
#      NOT match the signing seed; every claim the service signs is
#      silently rejected by the witness verifier with
#      `UNAUTHENTICATED: invalid signature`. (Vast cascade BLOCKER C,
#      2026-05-26.)
#
#   2. Shared inter-service token — every REPLACE_WITH_64_HEX_SERVICE_TOKEN
#      occurrence collapses to a SINGLE random value written to
#      global.dsaServiceToken. The chart's subchart secret templates read
#      from global with a per-subchart fallback. Treating each occurrence
#      as an independent random value (the v0 bug) silently breaks
#      service-to-service auth. (Vast cascade BLOCKER D, 2026-05-26.)
#
#   3. GATEWAY_KEYSTORE_KEY base64 padding — `openssl rand -base64 32`
#      emits 44 chars including the trailing `=`. Go's
#      `base64.StdEncoding.DecodeString` REQUIRES the padding; stripping
#      it (the v0 bug `tr -d "=\n"`) makes the gateway boot-fatal with a
#      base64 decode error. We strip only `\n`. (Vast cascade MED E,
#      2026-05-26.)
#
#   4. dsaEnv — left as the chart default (`development`) so the
#      bundled subcharts (which ship without inter-service gRPC TLS
#      certs) boot cleanly on a vanilla cluster. Customers wiring
#      cert-manager + flipping every subchart's `grpcTlsEnabled: "true"`
#      override to `production` via `--set global.dsaEnv=production` or
#      `values-prod.yaml`.
#
# Prerequisites:
#   - openssl (any modern version)
#   - python3 with cryptography (>=2.6) or pynacl  (for derive-veil-pubkey.sh)
#   - bash 4+ (uses associative arrays)
#
# Idempotency: this script generates new random values every run. The
# output file is overwritten without prompting; cp the result somewhere
# safe IMMEDIATELY after running.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <output-path>" >&2
  echo "" >&2
  echo "Example: $0 /root/customer-values.yaml" >&2
  exit 2
fi

OUTPUT="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$KIT_ROOT/customer-values.yaml.example"
DERIVE="$SCRIPT_DIR/derive-veil-pubkey.sh"

if [ ! -f "$TEMPLATE" ]; then
  echo "error: template not found at $TEMPLATE" >&2
  exit 1
fi

if [ ! -x "$DERIVE" ]; then
  echo "error: derive-veil-pubkey.sh not found or not executable at $DERIVE" >&2
  exit 1
fi

cp "$TEMPLATE" "$OUTPUT"

# ----------------------------------------------------------------------
# 1. Paired Ed25519 keys (BLOCKER C closure)
#
# Every signing key seed is 32 random bytes (64 hex chars). The matching
# public key is the Ed25519 derivation of that seed via the bundled
# helper. Filling the public-key slots with independent random hex
# breaks the witness verifier silently.
# ----------------------------------------------------------------------

# Bash 3.2 (macOS default) doesn't support associative arrays; we use
# parallel name + value arrays + a tiny lookup function.
SEED_GATEWAY=$(openssl rand -hex 32)
SEED_WITNESS=$(openssl rand -hex 32)
SEED_BRIDGE=$(openssl rand -hex 32)
SEED_SANITIZER=$(openssl rand -hex 32)
SEED_SANDBOX_B=$(openssl rand -hex 32)
SEED_AUDIT=$(openssl rand -hex 32)

PUB_GATEWAY=$("$DERIVE" "$SEED_GATEWAY")
PUB_WITNESS=$("$DERIVE" "$SEED_WITNESS")
PUB_BRIDGE=$("$DERIVE" "$SEED_BRIDGE")
PUB_SANITIZER=$("$DERIVE" "$SEED_SANITIZER")
PUB_SANDBOX_B=$("$DERIVE" "$SEED_SANDBOX_B")
PUB_AUDIT=$("$DERIVE" "$SEED_AUDIT")

# Substitute the signing-key slots. Each placeholder name uses the
# canonical chart literal. Note SANITIZER's signing slot is
# `REPLACE_WITH_64_HEX_SANITIZER_OR_SANDBOX_A_SIGNING_KEY` (the legacy
# naming the chart picked) — its derived pubkey lands in the SANITIZER
# pubkey slot.
sed -i.bak "s|REPLACE_WITH_64_HEX_GATEWAY_SIGNING_KEY|$SEED_GATEWAY|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_WITNESS_SIGNING_KEY|$SEED_WITNESS|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_BRIDGE_SIGNING_KEY|$SEED_BRIDGE|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_SANITIZER_OR_SANDBOX_A_SIGNING_KEY|$SEED_SANITIZER|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_SANDBOX_B_SIGNING_KEY|$SEED_SANDBOX_B|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_AUDIT_SIGNING_KEY|$SEED_AUDIT|" "$OUTPUT"

# Substitute the DERIVED public-key slots. Each pubkey appears in
# multiple chart locations (gateway.secrets.values + veil-witness.config
# for BRIDGE/SANITIZER/SANDBOX_B/AUDIT); -g substitutes every occurrence.
sed -i.bak "s|REPLACE_WITH_64_HEX_GATEWAY_PUBLIC_KEY|$PUB_GATEWAY|g" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_WITNESS_PUBLIC_KEY|$PUB_WITNESS|g" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_BRIDGE_PUBLIC_KEY|$PUB_BRIDGE|g" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_SANITIZER_PUBLIC_KEY|$PUB_SANITIZER|g" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_SANDBOX_B_PUBLIC_KEY|$PUB_SANDBOX_B|g" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_AUDIT_PUBLIC_KEY|$PUB_AUDIT|g" "$OUTPUT"

# ----------------------------------------------------------------------
# 2. Shared inter-service token + admin key (BLOCKER D closure)
#
# Every REPLACE_WITH_64_HEX_SERVICE_TOKEN occurrence collapses to ONE
# random value. The chart's subchart secret templates read from
# global.dsaServiceToken with per-subchart slots as fallback.
# adminKey is similarly shared across gateway / sandbox-a / sandbox-b.
# ----------------------------------------------------------------------

SHARED_SERVICE_TOKEN=$(openssl rand -hex 32)
SHARED_ADMIN_KEY=$(openssl rand -hex 32)
sed -i.bak "s|REPLACE_WITH_64_HEX_SERVICE_TOKEN|$SHARED_SERVICE_TOKEN|g" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_ADMIN_KEY|$SHARED_ADMIN_KEY|g" "$OUTPUT"

# ----------------------------------------------------------------------
# 3. GATEWAY_KEYSTORE_KEY base64 with PADDING preserved (MED E closure)
#
# Go's base64.StdEncoding REQUIRES the trailing `=`. Strip only `\n`.
# ----------------------------------------------------------------------

KEYSTORE_KEY=$(openssl rand -base64 32 | tr -d '\n')
# `sed` uses `|` as delimiter so `=` in the value is safe.
sed -i.bak "s|REPLACE_WITH_BASE64_32_BYTES|$KEYSTORE_KEY|" "$OUTPUT"

# ----------------------------------------------------------------------
# 4. License key + license signing key
#
# In dev mode both stay EMPTY (matches the Compose dev-path setting
# `DSA_LICENSE_KEY=` in customer.env). The gateway binary parses the
# license envelope at boot — a non-empty malformed value crashes the
# pod with `invalid license key: malformed license key`, while an
# empty value combined with DSA_ENV=development is the supported dev
# bypass. In production the operator replaces both via --set or a
# values overlay before flipping global.dsaEnv to "production".
# ----------------------------------------------------------------------

sed -i.bak "s|REPLACE_WITH_LICENSE_KEY||" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_LICENSE_SIGNING_KEY||" "$OUTPUT"

# ----------------------------------------------------------------------
# 5. Veil manifest signing key (single hex32, no paired pubkey)
# ----------------------------------------------------------------------

sed -i.bak "s|REPLACE_WITH_64_HEX_MANIFEST_SIGNING_KEY|$(openssl rand -hex 32)|" "$OUTPUT"

# ----------------------------------------------------------------------
# 6. Postgres + app-role passwords
# ----------------------------------------------------------------------

# Each named POSTGRES password placeholder appears at most once in the
# template, so a global per-pattern substitution is sufficient. We
# enumerate the unique patterns and replace each in its own pass to keep
# each placeholder distinct (different passwords per database).
for pat in $(grep -oE "REPLACE_WITH_[A-Z_]*POSTGRES_PASSWORD" "$OUTPUT" | sort -u); do
  val=$(openssl rand -hex 16)
  sed -i.bak "s|$pat|$val|" "$OUTPUT"
done

sed -i.bak "s|REPLACE_WITH_AUDIT_APP_PASSWORD|$(openssl rand -hex 16)|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_VEIL_APP_PASSWORD|$(openssl rand -hex 16)|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_REDIS_PASSWORD|$(openssl rand -hex 16)|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_CANARY_HMAC_KEY|$(openssl rand -hex 32)|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_SANDBOX_B_API_KEY|$(openssl rand -hex 32)|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_SANDBOX_B_API_KEYS|$(openssl rand -hex 32)|" "$OUTPUT"

# Bridge master + encryption keys — paired-named but independent values
sed -i.bak "s|REPLACE_WITH_64_HEX_BRIDGE_MASTER_KEY|$(openssl rand -hex 32)|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_BRIDGE_ENCRYPTION_KEY|$(openssl rand -hex 32)|" "$OUTPUT"

# Sandbox-A encryption key
sed -i.bak "s|REPLACE_WITH_64_HEX_SANDBOX_A_ENCRYPTION_KEY|$(openssl rand -hex 32)|" "$OUTPUT"

# Witness signing key — already substituted in step 1 (paired with WITNESS pubkey).
# Re-run is a no-op because the placeholder is gone; kept here as a defensive
# guard against template drift.
sed -i.bak "s|REPLACE_WITH_64_HEX_WITNESS_SIGNING_KEY|$SEED_WITNESS|" "$OUTPUT"

# Catch-all for any remaining 64-HEX slots not handled above. Each unique
# placeholder name gets its own random value.
for pat in $(grep -oE "REPLACE_WITH_64_HEX_[A-Z_]+" "$OUTPUT" | sort -u); do
  val=$(openssl rand -hex 32)
  sed -i.bak "s|$pat|$val|" "$OUTPUT"
done

# ----------------------------------------------------------------------
# 7. Clean up sed backup file
# ----------------------------------------------------------------------

rm -f "$OUTPUT.bak"

# ----------------------------------------------------------------------
# 8. Self-verification — every replacement closes
# ----------------------------------------------------------------------

# Filter the docstring noise (`REPLACE_WITH_*` mentions inside YAML
# comments that describe the placeholder convention) so the warning
# surfaces only real LIVE placeholders the chart will consume.
REMAINING=$(grep -nE "REPLACE_[A-Z_]+" "$OUTPUT" \
  | grep -v '^[^:]*:[[:space:]]*#' \
  | grep -oE "REPLACE_[A-Z_]+" \
  | grep -v '^REPLACE_WITH_$' \
  | sort -u || true)
if [ -n "$REMAINING" ]; then
  echo "" >&2
  echo "WARNING — unfilled REPLACE_* tokens remain in $OUTPUT:" >&2
  echo "$REMAINING" >&2
  echo "" >&2
  echo "These are opt-in feature placeholders the renderer doesn't know" >&2
  echo "about (e.g. cert-prober keyID when certification.enabled=true)." >&2
  echo "Operator must fill them manually if they enable the corresponding" >&2
  echo "feature before running \`helm install\`." >&2
  echo "" >&2
fi

# Spot-check the four invariants that BLOCKER A / B / C / D / E close.
#
# These are not exhaustive — `helm lint` + `helm template` + the umbrella
# validators do the heavy lifting. These checks just verify the renderer
# wrote what it claims to have written.

DSAENV=$(grep -E "^  dsaEnv:" "$OUTPUT" | awk '{print $2}' | tr -d '"' || echo "(missing)")
SVC_TOKEN_COUNT=$(grep -c "$SHARED_SERVICE_TOKEN" "$OUTPUT" || true)
KEYSTORE_PAD=$(echo "$KEYSTORE_KEY" | grep -cE '=$' || true)
PUBKEY_COUNT=$(grep -cE "REPLACE_WITH_64_HEX.*PUBLIC_KEY" "$OUTPUT" || true)

echo ""
echo "=== render-values.sh self-check ==="
echo "Output:           $OUTPUT"
echo "dsaEnv:           $DSAENV  (expected: development)"
echo "Shared svc token: $SVC_TOKEN_COUNT occurrence(s)  (expected: >=1 in global.dsaServiceToken)"
echo "Keystore padding: $KEYSTORE_PAD  (expected: 1 — must end in =)"
echo "Pubkey REPLACE_*: $PUBKEY_COUNT unresolved  (expected: 0)"
echo ""

if [ "$KEYSTORE_PAD" != "1" ]; then
  echo "ERROR: GATEWAY_KEYSTORE_KEY lost its base64 padding. Gateway will boot-fatal." >&2
  exit 1
fi

if [ "$PUBKEY_COUNT" -ne 0 ]; then
  echo "ERROR: Unresolved VEIL_*_PUBLIC_KEY placeholders remain — witness verifier will reject signatures." >&2
  exit 1
fi

echo "render-values.sh: $OUTPUT ready."
