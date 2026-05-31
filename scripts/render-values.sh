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

# SEC-04 (hardening 2026-05-28): the output file holds every signing-key
# seed, the keystore key, and all Postgres passwords in plaintext. Tighten
# the umask BEFORE the template is copied so the file is created 0600 (owner
# read/write only) rather than inheriting a world-/group-readable default
# umask (commonly 022 → 0644). We also chmod 600 explicitly after writing in
# case the destination already existed with looser perms.
umask 077

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
# Defensive: if $OUTPUT pre-existed with looser perms, the umask above does
# not retighten it (umask only affects newly-created files). Force 0600.
chmod 600 "$OUTPUT"

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
# The gateway signs its /.well-known manifest with VEIL_MANIFEST_SIGNING_KEY
# — a SEPARATE seed from SEED_GATEWAY (which is the gateway CLAIM seed). The
# gateway publishes VEIL_GATEWAY_MANIFEST_PUBLIC_KEY verbatim from env as the
# verifying key for that manifest signature (DSA gateway veil.go: signs with
# GatewayManifestSigningKeyHex=VEIL_MANIFEST_SIGNING_KEY, publishes
# VEIL_GATEWAY_MANIFEST_PUBLIC_KEY in the well-known-keys loop). So the
# manifest pubkey MUST be derived from THIS seed, not from SEED_GATEWAY.
# (Contrast WITNESS: the witness signs its manifest with the same SEED_WITNESS
# it uses for claims, so WITNESS_MANIFEST_PUBLIC_KEY = PUB_WITNESS is correct.)
SEED_MANIFEST=$(openssl rand -hex 32)

# SEC-04 (hardening 2026-05-28): feed each private-key seed to the derive
# helper via stdin, NOT as an argv parameter. As an argument, the 32-byte
# seed would be visible in `ps`/`/proc/<pid>/cmdline` to every local user for
# the duration of the python3 subprocess. Piping it keeps the secret off the
# process argument list. The helper now accepts the seed on stdin (and still
# supports argv for the legacy catch-all path / INSTALL.md one-liners).
PUB_GATEWAY=$(printf '%s' "$SEED_GATEWAY" | "$DERIVE")
PUB_WITNESS=$(printf '%s' "$SEED_WITNESS" | "$DERIVE")
PUB_BRIDGE=$(printf '%s' "$SEED_BRIDGE" | "$DERIVE")
PUB_SANITIZER=$(printf '%s' "$SEED_SANITIZER" | "$DERIVE")
PUB_SANDBOX_B=$(printf '%s' "$SEED_SANDBOX_B" | "$DERIVE")
PUB_AUDIT=$(printf '%s' "$SEED_AUDIT" | "$DERIVE")
PUB_MANIFEST=$(printf '%s' "$SEED_MANIFEST" | "$DERIVE")

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
#
# Order matters: GATEWAY_MANIFEST_PUBLIC_KEY + WITNESS_MANIFEST_PUBLIC_KEY
# share their canonical name suffix with the plain GATEWAY_PUBLIC_KEY +
# WITNESS_PUBLIC_KEY placeholders, so substitute the LONGER manifest
# variants FIRST. sed is greedy on the leftmost match and would otherwise
# leave the `_MANIFEST_PUBLIC_KEY` suffix as a partial-substitution
# trailing fragment (same defect class as the Vast cascade G prefix-match
# bug closure).
# GATEWAY_MANIFEST_PUBLIC_KEY pairs with VEIL_MANIFEST_SIGNING_KEY (=SEED_MANIFEST,
# substituted in step 5 below), NOT with SEED_GATEWAY — see the SEED_MANIFEST
# comment above. Using PUB_GATEWAY here (the v0 bug) published a manifest pubkey
# that did not match the manifest signer, silently failing the gateway's Runtime
# Invariant Harness #3 manifest self-check.
sed -i.bak "s|REPLACE_WITH_64_HEX_GATEWAY_MANIFEST_PUBLIC_KEY|$PUB_MANIFEST|g" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_64_HEX_WITNESS_MANIFEST_PUBLIC_KEY|$PUB_WITNESS|g" "$OUTPUT"
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
# 5. Veil manifest signing key (gateway manifest signer)
#
# This is the seed the gateway signs its /.well-known manifest with. Its
# derived pubkey (PUB_MANIFEST) was published above as
# VEIL_GATEWAY_MANIFEST_PUBLIC_KEY, so the published verifying key matches
# the signer. We substitute SEED_MANIFEST (captured alongside the other
# seeds) — NOT an inline `openssl rand` — so the seed and its published
# pubkey stay paired.
# ----------------------------------------------------------------------

sed -i.bak "s|REPLACE_WITH_64_HEX_MANIFEST_SIGNING_KEY|$SEED_MANIFEST|" "$OUTPUT"

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
# Sandbox-B inter-service auth token. The gateway sends this as the
# `x-dsa-license` gRPC metadata header on every inference RPC; sandbox-b's
# APIKeyInterceptor cross-checks it against the same shared value. They
# MUST be the same string.
#
# Two cascade bugs closed here (Vast cascade BLOCKER G, 2026-05-26):
#
#  1. The plural-named REPLACE_WITH_SANDBOX_B_API_KEYS placeholder MUST be
#     substituted BEFORE the singular REPLACE_WITH_SANDBOX_B_API_KEY.
#     Otherwise the shorter pattern matches first (sed is greedy on the
#     leftmost match but does NOT word-boundary), substituting the prefix
#     and leaving an unsubstituted trailing `S` in the plural slot —
#     producing two different runtime values that differ by one byte.
#
#  2. Both placeholders MUST resolve to the SAME random value. Two
#     independent `openssl rand -hex 32` calls produce two distinct keys,
#     so the gateway's x-dsa-license header never matches sandbox-b's
#     allowed-keys set — every inference RPC returns UNAUTHENTICATED and
#     the gateway translates that to HTTP 503 "Inference service
#     unavailable" for every customer request.
SHARED_SANDBOX_B_API_KEY=$(openssl rand -hex 32)
sed -i.bak "s|REPLACE_WITH_SANDBOX_B_API_KEYS|$SHARED_SANDBOX_B_API_KEY|" "$OUTPUT"
sed -i.bak "s|REPLACE_WITH_SANDBOX_B_API_KEY|$SHARED_SANDBOX_B_API_KEY|" "$OUTPUT"

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
# Sandbox-B api key must appear in BOTH the gateway slot (sandboxBApiKey)
# and the sandbox-b slot (sandboxBApiKeys) with the SAME value, and there
# must be ZERO leftover `S` chars from the prefix-match bug. Closes Vast
# cascade BLOCKER G.
SB_API_KEY_MATCHES=$(grep -c "$SHARED_SANDBOX_B_API_KEY" "$OUTPUT" || true)
SB_API_KEY_STRAY_S=$(grep -cE "^      sandboxBApiKey[sS]?:.*${SHARED_SANDBOX_B_API_KEY}S\"" "$OUTPUT" || true)

echo ""
echo "=== render-values.sh self-check ==="
echo "Output:           $OUTPUT"
echo "dsaEnv:           $DSAENV  (expected: development)"
echo "Shared svc token: $SVC_TOKEN_COUNT occurrence(s)  (expected: >=1 in global.dsaServiceToken)"
echo "Keystore padding: $KEYSTORE_PAD  (expected: 1 — must end in =)"
echo "Pubkey REPLACE_*: $PUBKEY_COUNT unresolved  (expected: 0)"
echo "Sandbox-B key:    $SB_API_KEY_MATCHES occurrence(s)  (expected: 2 — gateway slot + sandbox-b slot match)"
echo "Sandbox-B stray:  $SB_API_KEY_STRAY_S trailing-S (expected: 0 — cascade G prefix-match bug)"
echo ""

if [ "$KEYSTORE_PAD" != "1" ]; then
  echo "ERROR: GATEWAY_KEYSTORE_KEY lost its base64 padding. Gateway will boot-fatal." >&2
  exit 1
fi

if [ "$PUBKEY_COUNT" -ne 0 ]; then
  echo "ERROR: Unresolved VEIL_*_PUBLIC_KEY placeholders remain — witness verifier will reject signatures." >&2
  exit 1
fi

if [ "$SB_API_KEY_MATCHES" -lt 2 ]; then
  echo "ERROR: SANDBOX_B_API_KEY did not render into both gateway + sandbox-b slots. Cascade G regression." >&2
  exit 1
fi

if [ "$SB_API_KEY_STRAY_S" -ne 0 ]; then
  echo "ERROR: Sandbox-B api key has a trailing S — sed prefix-match regression. Cascade G." >&2
  exit 1
fi

# SEC-04 (hardening 2026-05-28): verify the rendered file is owner-only
# readable. The umask + explicit chmod above should guarantee 0600, but a
# pre-existing file, an exotic filesystem (e.g. a FAT/exFAT USB stick that
# ignores Unix mode bits), or an ACL could leave it group/world-readable.
# Surface that loudly — this file is a plaintext secret bundle.
OUTPUT_MODE=""
if stat -f '%Lp' "$OUTPUT" >/dev/null 2>&1; then
  OUTPUT_MODE="$(stat -f '%Lp' "$OUTPUT")"   # BSD/macOS stat
elif stat -c '%a' "$OUTPUT" >/dev/null 2>&1; then
  OUTPUT_MODE="$(stat -c '%a' "$OUTPUT")"    # GNU/Linux stat
fi
if [ -n "$OUTPUT_MODE" ] && [ "$OUTPUT_MODE" != "600" ]; then
  echo "" >&2
  echo "WARNING — $OUTPUT is mode $OUTPUT_MODE, not 600. It holds plaintext" >&2
  echo "signing seeds, the keystore key, and DB passwords. Run:" >&2
  echo "  chmod 600 \"$OUTPUT\"" >&2
  echo "and store it on an encrypted, access-controlled volume." >&2
  echo "" >&2
fi

echo "render-values.sh: $OUTPUT ready (mode ${OUTPUT_MODE:-unknown}; keep it 0600)."
