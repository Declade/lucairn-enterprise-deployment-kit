#!/usr/bin/env bash
#
# test_sec_hardening.sh — regression tests for the 2026-05-28 secrets &
# install hardening pass (audit findings SEC-01, SEC-04, SEC-05, SEC-08).
#
# Why this is a separate harness from test_lucairn_cli.sh:
#   test_lucairn_cli.sh ships a static env fixture that predates the
#   `validate_no_placeholder` sentinel-hex check and the `check_veil_keypairs`
#   coherence check, so its `aaaa…`/`1111…` sentinel keys no longer pass a
#   full `doctor` run (a pre-existing breakage on origin/main, unrelated to
#   this pass). Rather than retrofit that fixture, this harness generates a
#   coherent fixture with REAL openssl-derived keys (exactly the way
#   scripts/render-values.sh does) so the full doctor pipeline reaches — and
#   exercises — the new password / keystore checks.
#
# Covers:
#   SEC-01  Postgres + app-role password validation (blank / weak / short).
#   SEC-04  render-values.sh writes 0600 + feeds seeds to derive via stdin.
#   SEC-05  keystore-key validation is in-memory (no predictable /tmp file).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DERIVE="$ROOT/scripts/derive-veil-pubkey.sh"
gen_seed() { openssl rand -hex 32; }

# --- Build a coherent, doctor-passing env fixture --------------------------
SEED_AUDIT=$(gen_seed); SEED_BRIDGE=$(gen_seed); SEED_SAN=$(gen_seed)
SEED_WIT=$(gen_seed); SEED_GW=$(gen_seed); SEED_SBB=$(gen_seed)
PUB_AUDIT=$(printf '%s' "$SEED_AUDIT" | "$DERIVE")
PUB_BRIDGE=$(printf '%s' "$SEED_BRIDGE" | "$DERIVE")
PUB_SAN=$(printf '%s' "$SEED_SAN" | "$DERIVE")
PUB_WIT=$(printf '%s' "$SEED_WIT" | "$DERIVE")
PUB_GW=$(printf '%s' "$SEED_GW" | "$DERIVE")
PUB_SBB=$(printf '%s' "$SEED_SBB" | "$DERIVE")

# Image tag must fall inside image-manifest.yaml's sanitizer_config_compat
# window so the G2-CLOSE drift check passes. Read it from the manifest so
# this test does not hardcode a value that drifts on the next image bump.
COMPAT="$(awk -F: '/^[[:space:]]*sanitizer_config_compat:/ {gsub(/[" ]/,"",$2); gsub(/#.*/,"",$2); print $2; exit}' "$ROOT/image-manifest.yaml")"
# "0.4.x" -> "0.4.1"; a bare "0.4" -> "0.4.1"; anything else -> use as-is.
case "$COMPAT" in
  *.x) IMAGE_TAG="${COMPAT%.x}.1" ;;
  *)   IMAGE_TAG="$COMPAT" ;;
esac

# Self-signed cert triple for the split-deployment mTLS coherence check.
# check_certs requires the files to exist + be valid x509 (>30 days).
openssl req -x509 -newkey ed25519 -nodes -days 365 \
  -subj "/CN=lucairn-test" \
  -keyout "$TMPDIR/sb-client.key" -out "$TMPDIR/sb-client.crt" >/dev/null 2>&1
cp "$TMPDIR/sb-client.crt" "$TMPDIR/sb-ca.crt"

# Witness-signed manifest blob for the production check_manifest_blob pre-flight
# (overnight follow-up 2026-06-15). DSA_ENV=production now FAILS doctor without
# it; a coherent prod fixture must carry one. The content is only stat'd by the
# doctor (existence + non-empty), so a placeholder blob suffices here.
printf '{"canonical_body_b64":"e30=","witness_signature_hex":"00"}\n' \
  > "$TMPDIR/witness-signed-manifest.json"

ENV_FILE="$TMPDIR/customer.env"
cat > "$ENV_FILE" <<ENV
LUCAIRN_IMAGE_REGISTRY=ghcr.io/declade
LUCAIRN_IMAGE_TAG=$IMAGE_TAG
DSA_ENV=production
DSA_LICENSE_KEY=lcr_enterprise_test_secret
DSA_LICENSE_SIGNING_KEY=test-license-signing-secret
SANDBOX_B_REMOTE_ENDPOINT=https://inference.customer.example
SANDBOX_B_API_KEY=sk-test-sandbox-b-secret-value-32chars
SANDBOX_B_CLIENT_CERT=$TMPDIR/sb-client.crt
SANDBOX_B_CLIENT_KEY=$TMPDIR/sb-client.key
SANDBOX_B_CA_CERT=$TMPDIR/sb-ca.crt
DSA_SERVICE_TOKEN=$(gen_seed)
DSA_BRIDGE_ENCRYPTION_KEY=$(gen_seed)
SANDBOX_A_ENCRYPTION_KEY=$(gen_seed)
BRIDGE_MASTER_KEY=$(gen_seed)
DSA_ADMIN_KEY=$(gen_seed)
GATEWAY_KEYSTORE_KEY=$(openssl rand -base64 32 | tr -d '\n')
GATEWAY_BASE_URL=https://lucairn.customer.example
LUCAIRN_RESOURCE_BASE_URL=https://lucairn.customer.example
LCR_REKOR_URL=https://rekor.sigstore.dev
LCR_TSA_URL=https://freetsa.org/tsr
LCR_AUDIT_SIGNING_KEY=$SEED_AUDIT
LCR_BRIDGE_SIGNING_KEY=$SEED_BRIDGE
LCR_SANITIZER_SIGNING_KEY=$SEED_SAN
LCR_WITNESS_SIGNING_KEY=$SEED_WIT
LCR_GATEWAY_SIGNING_KEY=$SEED_GW
LCR_MANIFEST_SIGNING_KEY=$(gen_seed)
LCR_WITNESS_SIGNED_MANIFEST_PATH=$TMPDIR/witness-signed-manifest.json
LCR_WITNESS_PUBLIC_KEY=$PUB_WIT
LCR_BRIDGE_PUBLIC_KEY=$PUB_BRIDGE
LCR_SANITIZER_PUBLIC_KEY=$PUB_SAN
LCR_AUDIT_PUBLIC_KEY=$PUB_AUDIT
LCR_SANDBOX_B_PUBLIC_KEY=$PUB_SBB
LCR_SANDBOX_B_SIGNING_KEY=$SEED_SBB
LCR_GATEWAY_PUBLIC_KEY=$PUB_GW
CANARY_HMAC_KEY=$(gen_seed)
POSTGRES_AUDIT_PASSWORD=postgres-audit-secret-value
POSTGRES_BRIDGE_PASSWORD=postgres-bridge-secret-value
POSTGRES_SANDBOX_A_PASSWORD=postgres-sandbox-a-secret-value
POSTGRES_VEIL_PASSWORD=postgres-veil-secret-value
AUDIT_APP_PASSWORD=audit-app-role-secret-value
VEIL_APP_PASSWORD=veil-app-role-secret-value
BUILD_AUTH_TOKEN=build-token-secret
CUSTOMER_KEY_ID=customer-key-id-secret
PORTAL_API_KEY=portal-api-key-secret
ENV

run_doctor() {  # writes output to $1, returns doctor's exit status
  local out="$1" env="${2:-$ENV_FILE}"
  set +e
  "$ROOT/bin/lucairn" doctor --env "$env" --compose "$ROOT/docker-compose.customer.yml" --offline > "$out" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

# --- Happy path: a coherent prod env passes doctor -------------------------
if ! run_doctor "$TMPDIR/happy.out"; then
  echo "FAIL: happy-path doctor should pass with coherent prod env" >&2
  cat "$TMPDIR/happy.out" >&2
  exit 1
fi
grep -q "doctor: ok" "$TMPDIR/happy.out"
echo "SEC hardening happy-path: ok"

# --- Stage 3 legacy fallback: pre-Stage-3 customer.env with VEIL_ prefix ---
# Builds the same fixture but renames ALL 12 dual-name keys to their legacy
# VEIL_ form (6 signing + 6 public). Doctor must still PASS via
# env_value_with_legacy. This exercises the full Stage-3 deprecation surface
# (was 5 keys pre-fix-up-#3; bug-hunter proved the missing 7 broke the
# customer migration path — bin/lucairn:243-260 + docker-compose.customer.yml
# lines 425-489/544).
LEGACY_ENV="$TMPDIR/legacy-veil.env"
sed -E -e 's/^LCR_AUDIT_SIGNING_KEY=/VEIL_AUDIT_SIGNING_KEY=/' \
       -e 's/^LCR_BRIDGE_SIGNING_KEY=/VEIL_BRIDGE_SIGNING_KEY=/' \
       -e 's/^LCR_SANITIZER_SIGNING_KEY=/VEIL_SANITIZER_SIGNING_KEY=/' \
       -e 's/^LCR_WITNESS_SIGNING_KEY=/VEIL_WITNESS_SIGNING_KEY=/' \
       -e 's/^LCR_GATEWAY_SIGNING_KEY=/VEIL_GATEWAY_SIGNING_KEY=/' \
       -e 's/^LCR_MANIFEST_SIGNING_KEY=/VEIL_MANIFEST_SIGNING_KEY=/' \
       -e 's/^LCR_WITNESS_PUBLIC_KEY=/VEIL_WITNESS_PUBLIC_KEY=/' \
       -e 's/^LCR_BRIDGE_PUBLIC_KEY=/VEIL_BRIDGE_PUBLIC_KEY=/' \
       -e 's/^LCR_SANITIZER_PUBLIC_KEY=/VEIL_SANITIZER_PUBLIC_KEY=/' \
       -e 's/^LCR_AUDIT_PUBLIC_KEY=/VEIL_AUDIT_PUBLIC_KEY=/' \
       -e 's/^LCR_GATEWAY_PUBLIC_KEY=/VEIL_GATEWAY_PUBLIC_KEY=/' \
       -e 's/^LCR_SANDBOX_B_PUBLIC_KEY=/VEIL_SANDBOX_B_PUBLIC_KEY=/' \
       "$ENV_FILE" > "$LEGACY_ENV"
if ! run_doctor "$TMPDIR/legacy.out" "$LEGACY_ENV"; then
  echo "FAIL: Stage 3 legacy-fallback doctor should PASS for pre-Stage-3 customer.env" >&2
  cat "$TMPDIR/legacy.out" >&2
  exit 1
fi
grep -q "doctor: ok" "$TMPDIR/legacy.out"
echo "Stage 3 legacy-fallback: ok"

# --- SEC-01: password validation -------------------------------------------
# Run doctor on a copy of the fixture with one var overridden; expect failure
# + a matching error substring.
expect_fail_on() {
  local label="$1" var="$2" value="$3" needle="$4"
  local env="$TMPDIR/sec01-$label.env"
  grep -v "^${var}=" "$ENV_FILE" > "$env"
  [ -n "$value" ] && printf '%s=%s\n' "$var" "$value" >> "$env"
  if run_doctor "$TMPDIR/sec01-$label.out" "$env"; then
    echo "FAIL: SEC-01 ($label) doctor should FAIL for $var=${value:-<blank>}" >&2
    cat "$TMPDIR/sec01-$label.out" >&2
    exit 1
  fi
  if ! grep -q "$needle" "$TMPDIR/sec01-$label.out"; then
    echo "FAIL: SEC-01 ($label) expected error containing '$needle'" >&2
    cat "$TMPDIR/sec01-$label.out" >&2
    exit 1
  fi
}

expect_fail_on weak-audit   POSTGRES_AUDIT_PASSWORD     dsa                "well-known weak fallback"
expect_fail_on weak-veil    POSTGRES_VEIL_PASSWORD      veil               "well-known weak fallback"
expect_fail_on weak-appaud  AUDIT_APP_PASSWORD          audit_app_password "well-known weak fallback"
expect_fail_on weak-appveil VEIL_APP_PASSWORD           veil_app_password  "well-known weak fallback"
expect_fail_on short-bridge POSTGRES_BRIDGE_PASSWORD    short              "too short"
expect_fail_on blank-sbxa   POSTGRES_SANDBOX_A_PASSWORD ""                 "unset in production"
echo "SEC-01 db-password validation: ok"

# Non-production must NOT enforce the password rules (matches the other
# prod-gated checks). Flip DSA_ENV=development + blank a password.
DEV_ENV="$TMPDIR/sec01-dev.env"
grep -v "^DSA_ENV=" "$ENV_FILE" | grep -v "^POSTGRES_AUDIT_PASSWORD=" > "$DEV_ENV"
printf 'DSA_ENV=development\nPOSTGRES_AUDIT_PASSWORD=\n' >> "$DEV_ENV"
if ! run_doctor "$TMPDIR/sec01-dev.out" "$DEV_ENV"; then
  # development may fail for OTHER reasons, but it must NOT be the password
  # check; assert the password error is absent.
  if grep -q "db password:" "$TMPDIR/sec01-dev.out"; then
    echo "FAIL: SEC-01 password check fired in development mode" >&2
    cat "$TMPDIR/sec01-dev.out" >&2
    exit 1
  fi
fi
echo "SEC-01 prod-gating: ok"

# --- SEC-05: keystore-key validation, no /tmp file -------------------------
# Wrong decoded length (16 bytes) rejected.
expect_fail_on ks-short  GATEWAY_KEYSTORE_KEY "AAAAAAAAAAAAAAAAAAAAAA==" "must decode to 32 bytes"
# Malformed keystore key rejected. openssl's base64 decoder is permissive
# (it silently skips non-base64 bytes), so a string with stray chars decodes
# to the wrong length rather than erroring outright — either rejection
# ("must be base64" OR "must decode to 32 bytes") is a correct fail.
expect_fail_on ks-badb64 GATEWAY_KEYSTORE_KEY "not!base64!!!"            "GATEWAY_KEYSTORE_KEY must"
# No predictable /tmp keystore file left behind by any of the runs above.
if ls /tmp/lucairn-keystore-key.* >/dev/null 2>&1; then
  echo "FAIL: SEC-05 doctor left a predictable /tmp keystore-key file behind" >&2
  exit 1
fi
echo "SEC-05 keystore-key in-memory validation: ok"

# --- SEC-04: render-values.sh perms + stdin derive -------------------------
RV_OUT="$TMPDIR/customer-values.yaml"
"$ROOT/scripts/render-values.sh" "$RV_OUT" > "$TMPDIR/render.out" 2>&1
# Mode must be 600 (BSD or GNU stat).
if MODE="$(stat -f '%Lp' "$RV_OUT" 2>/dev/null)"; then :; else MODE="$(stat -c '%a' "$RV_OUT")"; fi
if [ "$MODE" != "600" ]; then
  echo "FAIL: SEC-04 render-values.sh output is mode $MODE, expected 600" >&2
  exit 1
fi
# All paired pubkeys must have resolved (renderer feeds seeds via stdin).
grep -q "Pubkey REPLACE_\*: 0 unresolved" "$TMPDIR/render.out"
# Pre-existing-loose-perms case: re-render over a 0644 file still ends 0600.
printf 'x\n' > "$RV_OUT"; chmod 644 "$RV_OUT"
"$ROOT/scripts/render-values.sh" "$RV_OUT" > /dev/null 2>&1
if MODE="$(stat -f '%Lp' "$RV_OUT" 2>/dev/null)"; then :; else MODE="$(stat -c '%a' "$RV_OUT")"; fi
[ "$MODE" = "600" ] || { echo "FAIL: SEC-04 re-render over 0644 left mode $MODE" >&2; exit 1; }
echo "SEC-04 render-values.sh hardening: ok"

# derive-veil-pubkey.sh stdin == argv parity (and rejects bad input).
SEED="$(gen_seed)"
P_STDIN="$(printf '%s' "$SEED" | "$DERIVE")"
P_ARGV="$("$DERIVE" "$SEED")"
[ "$P_STDIN" = "$P_ARGV" ] || { echo "FAIL: SEC-04 derive stdin != argv" >&2; exit 1; }
if printf 'notvalidhex' | "$DERIVE" >/dev/null 2>&1; then
  echo "FAIL: SEC-04 derive accepted invalid stdin seed" >&2
  exit 1
fi
echo "SEC-04 derive-veil-pubkey stdin path: ok"

# ---------------------------------------------------------------------------
# H9 fix (2026-06-23): mTLS partial-config detection now reads WITNESS_MTLS_*
# (the vars customers actually set, per customer.env.example:157-163).
#
# Previously this test injected DSA_MTLS_* (internal mesh overlay prefix),
# so the check permanently fired on a path no customer ever reaches.
# Now injects WITNESS_MTLS_* and asserts the check fires on partial configs.
#
# Rule: once ANY of the 5 WITNESS_MTLS_* credential-bearing vars is set,
# ALL FIVE must be set. A complete server-only triple or complete client-only
# triple still crashes sandbox-b and the sanitizer at boot (full mesh required).
# ---------------------------------------------------------------------------
M1_BASE="$TMPDIR/m1-base.env"
# Strip any existing WITNESS_MTLS_* vars from the coherent fixture so we start clean.
grep -v '^WITNESS_MTLS_' "$ENV_FILE" > "$M1_BASE"

# Case 1: none → pass (mTLS disabled).
if ! run_doctor "$TMPDIR/m1-none.out" "$M1_BASE"; then
  echo "FAIL: H9 none-set should PASS (mTLS disabled)" >&2
  cat "$TMPDIR/m1-none.out" >&2
  exit 1
fi
echo "H9: none-set → PASS (mTLS disabled): ok"

# Case 2: all 5 set (pointing at the already-created $TMPDIR test certs) → pass.
# The cert-existence check (check_certs) also runs and must be satisfied, so we
# reuse the self-signed $TMPDIR/sb-client.{crt,key} + sb-ca.crt created above.
M1_ALL="$TMPDIR/m1-all.env"
cp "$M1_BASE" "$M1_ALL"
{
  printf 'WITNESS_MTLS_CA_BUNDLE_PATH=%s\n'               "$TMPDIR/sb-ca.crt"
  printf 'WITNESS_MTLS_SERVER_CERT_PATH=%s\n'             "$TMPDIR/sb-client.crt"
  printf 'WITNESS_MTLS_SERVER_KEY_PATH=%s\n'              "$TMPDIR/sb-client.key"
  printf 'WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH=%s\n'     "$TMPDIR/sb-client.crt"
  printf 'WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH=%s\n'      "$TMPDIR/sb-client.key"
} >> "$M1_ALL"
if ! run_doctor "$TMPDIR/m1-all.out" "$M1_ALL"; then
  echo "FAIL: H9 all-5-set should PASS (full mesh)" >&2
  cat "$TMPDIR/m1-all.out" >&2
  exit 1
fi
echo "H9: all-5-set → PASS (full mesh): ok"

# Case 3: complete server triple (CA+SERVER_CERT+SERVER_KEY) but NO client
# vars → FAIL (partial config; real customer would get a crash at boot).
M1_SERVER_ONLY="$TMPDIR/m1-server-only.env"
cp "$M1_BASE" "$M1_SERVER_ONLY"
{
  printf 'WITNESS_MTLS_CA_BUNDLE_PATH=%s\n'   "$TMPDIR/sb-ca.crt"
  printf 'WITNESS_MTLS_SERVER_CERT_PATH=%s\n' "$TMPDIR/sb-client.crt"
  printf 'WITNESS_MTLS_SERVER_KEY_PATH=%s\n'  "$TMPDIR/sb-client.key"
} >> "$M1_SERVER_ONLY"
if run_doctor "$TMPDIR/m1-server-only.out" "$M1_SERVER_ONLY"; then
  echo "FAIL: H9 complete-server-only should FAIL (no client vars)" >&2
  cat "$TMPDIR/m1-server-only.out" >&2
  exit 1
fi
grep -q "mTLS config: FAIL" "$TMPDIR/m1-server-only.out" \
  || { echo "FAIL: H9 server-only missing expected error" >&2; cat "$TMPDIR/m1-server-only.out" >&2; exit 1; }
grep -q "WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH" "$TMPDIR/m1-server-only.out" \
  || { echo "FAIL: H9 server-only should name missing WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH" >&2; exit 1; }
grep -q "WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH" "$TMPDIR/m1-server-only.out" \
  || { echo "FAIL: H9 server-only should name missing WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH" >&2; exit 1; }
echo "H9: complete-server-only → FAIL (client vars missing): ok"

# Case 4: complete client triple (CA+CLIENT_CERT+CLIENT_KEY) but NO server
# vars → FAIL (partial config; real customer would get a crash at boot).
M1_CLIENT_ONLY="$TMPDIR/m1-client-only.env"
cp "$M1_BASE" "$M1_CLIENT_ONLY"
{
  printf 'WITNESS_MTLS_CA_BUNDLE_PATH=%s\n'               "$TMPDIR/sb-ca.crt"
  printf 'WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH=%s\n'     "$TMPDIR/sb-client.crt"
  printf 'WITNESS_MTLS_GATEWAY_CLIENT_KEY_PATH=%s\n'      "$TMPDIR/sb-client.key"
} >> "$M1_CLIENT_ONLY"
if run_doctor "$TMPDIR/m1-client-only.out" "$M1_CLIENT_ONLY"; then
  echo "FAIL: H9 complete-client-only should FAIL (no server vars)" >&2
  cat "$TMPDIR/m1-client-only.out" >&2
  exit 1
fi
grep -q "mTLS config: FAIL" "$TMPDIR/m1-client-only.out" \
  || { echo "FAIL: H9 client-only missing expected error" >&2; cat "$TMPDIR/m1-client-only.out" >&2; exit 1; }
grep -q "WITNESS_MTLS_SERVER_CERT_PATH" "$TMPDIR/m1-client-only.out" \
  || { echo "FAIL: H9 client-only should name missing WITNESS_MTLS_SERVER_CERT_PATH" >&2; exit 1; }
grep -q "WITNESS_MTLS_SERVER_KEY_PATH" "$TMPDIR/m1-client-only.out" \
  || { echo "FAIL: H9 client-only should name missing WITNESS_MTLS_SERVER_KEY_PATH" >&2; exit 1; }
echo "H9: complete-client-only → FAIL (server vars missing): ok"

echo "H9 mTLS partial-config detection (WITNESS_MTLS_* fix): ok"

# ---------------------------------------------------------------------------
# M5 fix (PR #81 review): drop host-path stat for readiness bundle.
#
# GATEWAY_REQUIRE_READINESS=true + bundle UNSET → FAIL (env-var missing).
# GATEWAY_REQUIRE_READINESS=true + bundle = container-internal path (e.g.
# /etc/dsa/readiness/readiness-bundle.json, never on the host) → PASS.
# Previously the path-existence stat triggered a false-RED for any Helm install.
# ---------------------------------------------------------------------------
M5_BASE="$TMPDIR/m5-base.env"
grep -v '^GATEWAY_REQUIRE_READINESS=\|^GATEWAY_READINESS_BUNDLE=' "$ENV_FILE" > "$M5_BASE"

# Case 1: GATEWAY_REQUIRE_READINESS unset → pass (feature off).
if ! run_doctor "$TMPDIR/m5-off.out" "$M5_BASE"; then
  echo "FAIL: M5 require-readiness unset should PASS (feature off)" >&2
  cat "$TMPDIR/m5-off.out" >&2
  exit 1
fi
echo "M5: GATEWAY_REQUIRE_READINESS unset → PASS (feature off): ok"

# Case 2: GATEWAY_REQUIRE_READINESS=true, bundle UNSET → FAIL.
M5_UNSET="$TMPDIR/m5-unset-bundle.env"
cp "$M5_BASE" "$M5_UNSET"
printf 'GATEWAY_REQUIRE_READINESS=true\n' >> "$M5_UNSET"
if run_doctor "$TMPDIR/m5-unset.out" "$M5_UNSET"; then
  echo "FAIL: M5 require-readiness=true + bundle unset should FAIL" >&2
  cat "$TMPDIR/m5-unset.out" >&2
  exit 1
fi
grep -q "readiness bundle: FAIL" "$TMPDIR/m5-unset.out" \
  || { echo "FAIL: M5 missing expected readiness bundle FAIL message" >&2; cat "$TMPDIR/m5-unset.out" >&2; exit 1; }
echo "M5: GATEWAY_REQUIRE_READINESS=true + bundle unset → FAIL: ok"

# Case 3: GATEWAY_REQUIRE_READINESS=true + container-internal path that does
# NOT exist on the host → PASS (the path-existence stat was a false-RED).
M5_HELM="$TMPDIR/m5-helm-path.env"
cp "$M5_BASE" "$M5_HELM"
{
  printf 'GATEWAY_REQUIRE_READINESS=true\n'
  printf 'GATEWAY_READINESS_BUNDLE=/etc/dsa/readiness/readiness-bundle.json\n'
} >> "$M5_HELM"
if ! run_doctor "$TMPDIR/m5-helm.out" "$M5_HELM"; then
  echo "FAIL: M5 require-readiness=true + container-internal bundle path should PASS (false-RED fixed)" >&2
  cat "$TMPDIR/m5-helm.out" >&2
  exit 1
fi
echo "M5: GATEWAY_REQUIRE_READINESS=true + container-internal path → PASS (false-RED fixed): ok"

echo "M5 readiness-bundle host-path-stat removed (PR #81 fix-up): ok"

# ---------------------------------------------------------------------------
# M9 fix (PR #81 review): drop phantom LUCAIRN_HELM_BACKUP_ENABLED arm.
#
# Helm backup is validated fail-closed at helm-upgrade time by _validators.tpl,
# so doctor must NOT check a phantom var. The Compose path (LUCAIRN_BACKUP_S3_BUCKET
# non-empty) is the only doctor-visible signal.
#
# Cases to prove:
#   - production + LUCAIRN_BACKUP_S3_BUCKET set → PASS.
#   - production + LUCAIRN_HELM_BACKUP_ENABLED=true (phantom) + no bucket → WARN/FAIL.
#   - production + no bucket, no phantom var → WARN (default), FAIL under --strict.
# ---------------------------------------------------------------------------
M9_BASE="$TMPDIR/m9-base.env"
grep -v '^DSA_ENV=\|^LUCAIRN_BACKUP_S3_BUCKET=\|^LUCAIRN_HELM_BACKUP_ENABLED=' "$ENV_FILE" > "$M9_BASE"
printf 'DSA_ENV=production\n' >> "$M9_BASE"

# Case 1: production + bucket set → PASS.
M9_BUCKET="$TMPDIR/m9-bucket.env"
cp "$M9_BASE" "$M9_BUCKET"
printf 'LUCAIRN_BACKUP_S3_BUCKET=lucairn-backups-prod\n' >> "$M9_BUCKET"
if ! run_doctor "$TMPDIR/m9-bucket.out" "$M9_BUCKET"; then
  echo "FAIL: M9 production + bucket set should PASS" >&2
  cat "$TMPDIR/m9-bucket.out" >&2
  exit 1
fi
echo "M9: production + LUCAIRN_BACKUP_S3_BUCKET set → PASS: ok"

# Case 2: production + LUCAIRN_HELM_BACKUP_ENABLED=true (phantom var) + no bucket
# → must still WARN/FAIL (phantom var must not suppress the warning).
M9_PHANTOM="$TMPDIR/m9-phantom.env"
cp "$M9_BASE" "$M9_PHANTOM"
printf 'LUCAIRN_HELM_BACKUP_ENABLED=true\n' >> "$M9_PHANTOM"
# doctor exits 0 in WARN mode but emits the backup warning on stderr.
M9_PHANTOM_RC=0
"$ROOT/bin/lucairn" doctor --env "$M9_PHANTOM" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/m9-phantom.out" 2> "$TMPDIR/m9-phantom.err" || M9_PHANTOM_RC=$?
if ! grep -q "backup pre-flight: WARN" "$TMPDIR/m9-phantom.err"; then
  echo "FAIL: M9 phantom LUCAIRN_HELM_BACKUP_ENABLED=true must still WARN (phantom var falsely suppressed the warning)" >&2
  cat "$TMPDIR/m9-phantom.out" "$TMPDIR/m9-phantom.err" >&2
  exit 1
fi
echo "M9: LUCAIRN_HELM_BACKUP_ENABLED=true (phantom) + no bucket → WARN (phantom not accepted): ok"

# Case 3: production + no bucket, no phantom var.
# Test WARN (strict=0) and FAIL (strict=1) by calling check_backup_preflight
# directly (sourcing the CLI with empty args so main "$@" is harmless).
# This avoids the --offline + --strict incompatibility enforced by
# check_image_digests (which runs before backup in the full doctor flow and
# would block the backup check from ever being reached).
# Test WARN (strict=0) and FAIL (strict=1) by calling check_backup_preflight
# directly via source, writing output to files to avoid subshell RC confusion.
M9_WARN_OUT="$TMPDIR/m9-warn.out"
M9_STRICT_OUT="$TMPDIR/m9-strict.out"

set +e
(
  set --
  # shellcheck disable=SC1090
  . "$ROOT/bin/lucairn" >/dev/null 2>&1
  check_backup_preflight "$M9_BASE" 0
) > "$M9_WARN_OUT" 2>&1
M9_WARN_RC=$?
set -e
if [ "$M9_WARN_RC" -ne 0 ]; then
  echo "FAIL: M9 check_backup_preflight(strict=0) should return 0 (warn only), got $M9_WARN_RC" >&2
  cat "$M9_WARN_OUT" >&2
  exit 1
fi
grep -q "backup pre-flight: WARN" "$M9_WARN_OUT" \
  || { echo "FAIL: M9 expected backup pre-flight WARN in output" >&2; cat "$M9_WARN_OUT" >&2; exit 1; }
echo "M9: production no-backup check_backup_preflight(strict=0) → WARN (rc=0): ok"

set +e
(
  set --
  # shellcheck disable=SC1090
  . "$ROOT/bin/lucairn" >/dev/null 2>&1
  check_backup_preflight "$M9_BASE" 1
) > "$M9_STRICT_OUT" 2>&1
M9_STRICT_RC=$?
set -e
if [ "$M9_STRICT_RC" -eq 0 ]; then
  echo "FAIL: M9 check_backup_preflight(strict=1) should return 1 (--strict fail), got 0" >&2
  cat "$M9_STRICT_OUT" >&2
  exit 1
fi
grep -q "backup pre-flight: FAIL" "$M9_STRICT_OUT" \
  || { echo "FAIL: M9 --strict FAIL message missing" >&2; cat "$M9_STRICT_OUT" >&2; exit 1; }
echo "M9: production no-backup check_backup_preflight(strict=1) → FAIL (rc=1): ok"

echo "M9 phantom-Helm-var removed (PR #81 fix-up): ok"

# ---------------------------------------------------------------------------
# M9-HELM-MANAGED: LUCAIRN_BACKUP_HELM_MANAGED=true passes check_backup_preflight
# under both default (strict=0) and --strict (strict=1) when no bucket is set.
# This is the central Helm-path behavior added alongside the M9 phantom-var fix
# (PR #81 review r2): the Helm operator sets this var to assert chart-managed
# backup; doctor accepts it without requiring a bucket.
# ---------------------------------------------------------------------------
M9_HM_ENV="$TMPDIR/m9-helm-managed.env"
grep -v '^DSA_ENV=\|^LUCAIRN_BACKUP_S3_BUCKET=\|^LUCAIRN_HELM_BACKUP_ENABLED=' "$ENV_FILE" > "$M9_HM_ENV"
printf 'DSA_ENV=production\nLUCAIRN_BACKUP_HELM_MANAGED=true\n' >> "$M9_HM_ENV"

# Case: LUCAIRN_BACKUP_HELM_MANAGED=true + no bucket → PASS (strict=0).
M9_HM_WARN_OUT="$TMPDIR/m9-hm-warn.out"
set +e
(
  set --
  # shellcheck disable=SC1090
  . "$ROOT/bin/lucairn" >/dev/null 2>&1
  check_backup_preflight "$M9_HM_ENV" 0
) > "$M9_HM_WARN_OUT" 2>&1
M9_HM_WARN_RC=$?
set -e
if [ "$M9_HM_WARN_RC" -ne 0 ]; then
  echo "FAIL: M9-HELM-MANAGED check_backup_preflight(strict=0) should PASS (LUCAIRN_BACKUP_HELM_MANAGED=true), got rc=$M9_HM_WARN_RC" >&2
  cat "$M9_HM_WARN_OUT" >&2
  exit 1
fi
echo "M9-HELM-MANAGED: LUCAIRN_BACKUP_HELM_MANAGED=true, no bucket, strict=0 → PASS: ok"

# Case: LUCAIRN_BACKUP_HELM_MANAGED=true + no bucket → PASS (strict=1).
M9_HM_STRICT_OUT="$TMPDIR/m9-hm-strict.out"
set +e
(
  set --
  # shellcheck disable=SC1090
  . "$ROOT/bin/lucairn" >/dev/null 2>&1
  check_backup_preflight "$M9_HM_ENV" 1
) > "$M9_HM_STRICT_OUT" 2>&1
M9_HM_STRICT_RC=$?
set -e
if [ "$M9_HM_STRICT_RC" -ne 0 ]; then
  echo "FAIL: M9-HELM-MANAGED check_backup_preflight(strict=1) should PASS (LUCAIRN_BACKUP_HELM_MANAGED=true), got rc=$M9_HM_STRICT_RC" >&2
  cat "$M9_HM_STRICT_OUT" >&2
  exit 1
fi
echo "M9-HELM-MANAGED: LUCAIRN_BACKUP_HELM_MANAGED=true, no bucket, strict=1 → PASS: ok"

echo "M9-HELM-MANAGED backup_preflight Helm path (--strict passes): ok"

# ---------------------------------------------------------------------------
# M23 Helm-path: empty canaryHmacKey WARN (audit 2026-06-23).
# NOTE: H9 Helm-path mTLS partial-config tests (witnessMtls: block) were removed
# here.  A raw values.yaml text-parser cannot (a) merge Helm chart defaults (would
# false-FAIL a valid config where caBundle/clientCert/clientKey come from chart
# defaults) nor (b) see that witness mTLS is SPLIT across gateway.witnessMtls.
# clientSecret + veil-witness.witnessMtls.serverSecret (would false-GREEN a
# half-enabled config).  Correct validation requires `helm template` render —
# deferred to the kit-CI follow-up (H10).
#
# When gateway.secrets.values.canaryHmacKey is absent or empty in the Helm
# values.yaml, the gateway's canary L3-leak detection is silently disabled.
# Doctor must emit a WARN (return 0 — not a hard failure).
# ---------------------------------------------------------------------------

# Case 1: canaryHmacKey absent → WARN present, doctor still passes.
HELM_NO_CANARY_VALS="$TMPDIR/helm-no-canary.yaml"
cat > "$HELM_NO_CANARY_VALS" <<'YAML'
gateway:
  secrets:
    values:
      licenseKey: "test-license"
YAML
HELM_NO_CANARY_RC=0
"$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --values "$HELM_NO_CANARY_VALS" \
  --offline > "$TMPDIR/helm-no-canary.out" 2> "$TMPDIR/helm-no-canary.err" || HELM_NO_CANARY_RC=$?
if [ "$HELM_NO_CANARY_RC" -ne 0 ]; then
  echo "FAIL: M23-Helm canaryHmacKey absent → doctor should PASS (warn only, not fail)" >&2
  cat "$TMPDIR/helm-no-canary.out" "$TMPDIR/helm-no-canary.err" >&2
  exit 1
fi
if ! grep -q "canary key (Helm)" "$TMPDIR/helm-no-canary.err"; then
  echo "FAIL: M23-Helm canaryHmacKey absent → expected WARN on stderr" >&2
  cat "$TMPDIR/helm-no-canary.out" "$TMPDIR/helm-no-canary.err" >&2
  exit 1
fi
echo "M23-Helm: canaryHmacKey absent → WARN (doctor still PASS): ok"

# Case 2: canaryHmacKey explicitly empty → same WARN, same PASS.
HELM_EMPTY_CANARY_VALS="$TMPDIR/helm-empty-canary.yaml"
cat > "$HELM_EMPTY_CANARY_VALS" <<'YAML'
gateway:
  secrets:
    values:
      canaryHmacKey: ""
YAML
HELM_EMPTY_CANARY_RC=0
"$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --values "$HELM_EMPTY_CANARY_VALS" \
  --offline > "$TMPDIR/helm-empty-canary.out" 2> "$TMPDIR/helm-empty-canary.err" || HELM_EMPTY_CANARY_RC=$?
if [ "$HELM_EMPTY_CANARY_RC" -ne 0 ]; then
  echo "FAIL: M23-Helm canaryHmacKey='' → doctor should PASS (warn only, not fail)" >&2
  cat "$TMPDIR/helm-empty-canary.out" "$TMPDIR/helm-empty-canary.err" >&2
  exit 1
fi
if ! grep -q "canary key (Helm)" "$TMPDIR/helm-empty-canary.err"; then
  echo "FAIL: M23-Helm canaryHmacKey='' → expected WARN on stderr" >&2
  cat "$TMPDIR/helm-empty-canary.out" "$TMPDIR/helm-empty-canary.err" >&2
  exit 1
fi
echo "M23-Helm: canaryHmacKey='' → WARN (doctor still PASS): ok"

# Case 3: canaryHmacKey set → no WARN.
HELM_SET_CANARY_VALS="$TMPDIR/helm-set-canary.yaml"
printf 'gateway:\n  secrets:\n    values:\n      canaryHmacKey: "%s"\n' "$(openssl rand -hex 32)" > "$HELM_SET_CANARY_VALS"
HELM_SET_CANARY_RC=0
"$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --values "$HELM_SET_CANARY_VALS" \
  --offline > "$TMPDIR/helm-set-canary.out" 2> "$TMPDIR/helm-set-canary.err" || HELM_SET_CANARY_RC=$?
if [ "$HELM_SET_CANARY_RC" -ne 0 ]; then
  echo "FAIL: M23-Helm canaryHmacKey set → doctor should PASS" >&2
  cat "$TMPDIR/helm-set-canary.out" "$TMPDIR/helm-set-canary.err" >&2
  exit 1
fi
if grep -q "canary key (Helm)" "$TMPDIR/helm-set-canary.err"; then
  echo "FAIL: M23-Helm canaryHmacKey set → should NOT emit canary WARN" >&2
  cat "$TMPDIR/helm-set-canary.err" >&2
  exit 1
fi
echo "M23-Helm: canaryHmacKey set → PASS (no WARN): ok"

echo "M23 Helm-path canaryHmacKey empty WARN: ok"

# ---------------------------------------------------------------------------
# M23-P2: backend-aware canary WARN (Codex r3, 2026-06-23).
# For vault/aws/azure backends the inline canaryHmacKey field is ignored by
# the chart (ExternalSecret uses the remote store, not the inline values).
# Doctor must NOT warn about the inline field being empty for those backends;
# instead it warns about canaryHmacKeyInRemote not being true.
# ---------------------------------------------------------------------------

# Case 4: vault backend + empty inline canaryHmacKey → warn about remote opt-in
# (NOT the inline-field warn), doctor still PASS.
HELM_VAULT_NO_REMOTE_VALS="$TMPDIR/helm-vault-no-remote.yaml"
cat > "$HELM_VAULT_NO_REMOTE_VALS" <<'YAML'
gateway:
  secrets:
    backend: vault
    values:
      licenseKey: "test-license"
YAML
HELM_VAULT_NO_REMOTE_RC=0
"$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --values "$HELM_VAULT_NO_REMOTE_VALS" \
  --offline > "$TMPDIR/helm-vault-no-remote.out" 2> "$TMPDIR/helm-vault-no-remote.err" || HELM_VAULT_NO_REMOTE_RC=$?
if [ "$HELM_VAULT_NO_REMOTE_RC" -ne 0 ]; then
  echo "FAIL: M23-P2 vault backend + no remote opt-in → doctor should PASS (warn only, not fail)" >&2
  cat "$TMPDIR/helm-vault-no-remote.out" "$TMPDIR/helm-vault-no-remote.err" >&2
  exit 1
fi
# Must NOT emit the k8s-native inline-value warning.
if grep -q "gateway.secrets.values.canaryHmacKey" "$TMPDIR/helm-vault-no-remote.err"; then
  echo "FAIL: M23-P2 vault backend → must NOT warn about inline canaryHmacKey (that field is ignored for external backends)" >&2
  cat "$TMPDIR/helm-vault-no-remote.err" >&2
  exit 1
fi
# Must emit the remote opt-in warning instead.
if ! grep -q "canaryHmacKeyInRemote" "$TMPDIR/helm-vault-no-remote.err"; then
  echo "FAIL: M23-P2 vault backend → expected WARN mentioning canaryHmacKeyInRemote" >&2
  cat "$TMPDIR/helm-vault-no-remote.err" >&2
  exit 1
fi
echo "M23-P2: vault backend + no remote opt-in → remote WARN (not inline WARN), doctor PASS: ok"

# Case 5: vault backend + canaryHmacKeyInRemote: true → no WARN at all.
HELM_VAULT_WITH_REMOTE_VALS="$TMPDIR/helm-vault-with-remote.yaml"
cat > "$HELM_VAULT_WITH_REMOTE_VALS" <<'YAML'
gateway:
  secrets:
    backend: vault
    canaryHmacKeyInRemote: true
    values:
      licenseKey: "test-license"
YAML
HELM_VAULT_WITH_REMOTE_RC=0
"$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --values "$HELM_VAULT_WITH_REMOTE_VALS" \
  --offline > "$TMPDIR/helm-vault-with-remote.out" 2> "$TMPDIR/helm-vault-with-remote.err" || HELM_VAULT_WITH_REMOTE_RC=$?
if [ "$HELM_VAULT_WITH_REMOTE_RC" -ne 0 ]; then
  echo "FAIL: M23-P2 vault backend + canaryHmacKeyInRemote=true → doctor should PASS" >&2
  cat "$TMPDIR/helm-vault-with-remote.out" "$TMPDIR/helm-vault-with-remote.err" >&2
  exit 1
fi
if grep -q "canary key (Helm)" "$TMPDIR/helm-vault-with-remote.err"; then
  echo "FAIL: M23-P2 vault backend + canaryHmacKeyInRemote=true → should NOT emit canary WARN" >&2
  cat "$TMPDIR/helm-vault-with-remote.err" >&2
  exit 1
fi
echo "M23-P2: vault backend + canaryHmacKeyInRemote=true → PASS (no WARN): ok"

echo "M23-P2 backend-aware canary WARN: ok"

echo "all sec-hardening tests: ok"
