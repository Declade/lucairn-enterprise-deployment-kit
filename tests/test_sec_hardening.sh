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

# ===========================================================================
# H10 (2026-06-26): render-based Helm-path doctor checks.
#
# Replaces the prior text-parser canary tests (and re-adds the reverted
# witness-mTLS partial-config tests) with RENDER-based assertions. The reverted
# text-parser (commit 195cc58) could not (a) merge Helm chart defaults nor
# (b) see that witness mTLS is SPLIT across gateway.witnessMtls.clientSecret +
# veil-witness.witnessMtls.serverSecret. The render-based checks
# (check_mtls_partial_config_helm + check_canary_hmac_key_helm in bin/lucairn)
# `helm template`-render the customer's values, merging chart defaults, and
# inspect the MERGED rendered env/secret output — the only correct path.
#
# These cases require helm. They self-skip (with a NOTE) on a helm-absent
# runner, mirroring the doctor's own graceful-skip behaviour, so the harness
# stays green on machines without helm.
# ===========================================================================

if ! command -v helm >/dev/null 2>&1; then
  echo "H10 render-based Helm doctor checks: SKIPPED — helm not installed (render-based checks require helm)"
else

# run_doctor_with_values <out_file> <values_file>  → echoes the doctor exit code.
# Combines stdout+stderr into <out_file> (doctor emits FAILs on stdout, WARNs on
# stderr; tests grep the merged stream). The base ENV_FILE drives the Compose
# checks; the values file drives the Helm-path render checks.
run_doctor_with_values() {
  local out="$1" vals="$2"
  set +e
  "$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
    --compose "$ROOT/docker-compose.customer.yml" \
    --values "$vals" \
    --offline > "$out" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

# A render-time canary value; the actual value is irrelevant to the check
# (it compares gateway vs sandbox-a for equality) but must be non-empty.
H10_CANARY="$(openssl rand -hex 32)"

# ---------------------------------------------------------------------------
# Witness mTLS partial-config — render-based (8 cases; re-add of the reverted
# text-parser tests, now render-and-inspect).
#
# Render signal: WITNESS_MTLS_CLIENT_CERT_PATH (gateway client side, gated on
# gateway.witnessMtls.clientSecret) + WITNESS_MTLS_SERVER_CERT_PATH (witness
# server side, gated on veil-witness.witnessMtls.serverSecret).
#   both / neither → consistent → PASS
#   exactly one    → split/half-config → FAIL
# ---------------------------------------------------------------------------

# Case M1: no witnessMtls block anywhere → mTLS off both sides → PASS (no flag).
MTLS_NONE_VALS="$TMPDIR/h10-mtls-none.yaml"
cat > "$MTLS_NONE_VALS" <<YAML
gateway:
  ingress:
    enabled: true
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
YAML
if ! run_doctor_with_values "$TMPDIR/h10-mtls-none.out" "$MTLS_NONE_VALS"; then
  echo "FAIL: H10-mTLS none → doctor should PASS (mTLS off both sides)" >&2
  cat "$TMPDIR/h10-mtls-none.out" >&2; exit 1
fi
if grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-mtls-none.out"; then
  echo "FAIL: H10-mTLS none → should NOT flag a mTLS FAIL" >&2
  cat "$TMPDIR/h10-mtls-none.out" >&2; exit 1
fi
echo "H10-mTLS: no witnessMtls → PASS (mTLS off): ok"

# Case M2: BOTH sides enabled (full mesh) → PASS.
MTLS_FULL_VALS="$TMPDIR/h10-mtls-full.yaml"
cat > "$MTLS_FULL_VALS" <<YAML
gateway:
  witnessMtls:
    clientSecret: "gateway-witness-mtls-certs"
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
veil-witness:
  witnessMtls:
    serverSecret: "witness-mtls-server-certs"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
YAML
if ! run_doctor_with_values "$TMPDIR/h10-mtls-full.out" "$MTLS_FULL_VALS"; then
  echo "FAIL: H10-mTLS full mesh → doctor should PASS (both sides set)" >&2
  cat "$TMPDIR/h10-mtls-full.out" >&2; exit 1
fi
if grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-mtls-full.out"; then
  echo "FAIL: H10-mTLS full mesh → should NOT flag a mTLS FAIL" >&2
  cat "$TMPDIR/h10-mtls-full.out" >&2; exit 1
fi
echo "H10-mTLS: full mesh (both sides) → PASS: ok"

# Case M3: gateway client ONLY (no witness server) → FAIL (half-config).
# This is a false-GREEN the text-parser produced; the render sees only the
# gateway-side WITNESS_MTLS_CLIENT_CERT_PATH.
MTLS_GW_ONLY_VALS="$TMPDIR/h10-mtls-gw-only.yaml"
cat > "$MTLS_GW_ONLY_VALS" <<YAML
gateway:
  witnessMtls:
    clientSecret: "gateway-witness-mtls-certs"
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
YAML
if run_doctor_with_values "$TMPDIR/h10-mtls-gw-only.out" "$MTLS_GW_ONLY_VALS"; then
  echo "FAIL: H10-mTLS gateway-only → doctor should FAIL (witness server side missing)" >&2
  cat "$TMPDIR/h10-mtls-gw-only.out" >&2; exit 1
fi
grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-mtls-gw-only.out" \
  || { echo "FAIL: H10-mTLS gateway-only missing expected FAIL message" >&2; cat "$TMPDIR/h10-mtls-gw-only.out" >&2; exit 1; }
grep -q "gateway client side is enabled" "$TMPDIR/h10-mtls-gw-only.out" \
  || { echo "FAIL: H10-mTLS gateway-only should name the gateway-enabled side" >&2; exit 1; }
echo "H10-mTLS: gateway client only → FAIL (half-config): ok"

# Case M4: witness server ONLY (no gateway client) → FAIL (half-config).
MTLS_SRV_ONLY_VALS="$TMPDIR/h10-mtls-srv-only.yaml"
cat > "$MTLS_SRV_ONLY_VALS" <<YAML
veil-witness:
  witnessMtls:
    serverSecret: "witness-mtls-server-certs"
gateway:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
YAML
if run_doctor_with_values "$TMPDIR/h10-mtls-srv-only.out" "$MTLS_SRV_ONLY_VALS"; then
  echo "FAIL: H10-mTLS witness-server-only → doctor should FAIL (gateway client side missing)" >&2
  cat "$TMPDIR/h10-mtls-srv-only.out" >&2; exit 1
fi
grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-mtls-srv-only.out" \
  || { echo "FAIL: H10-mTLS witness-server-only missing expected FAIL message" >&2; cat "$TMPDIR/h10-mtls-srv-only.out" >&2; exit 1; }
grep -q "witness server side is enabled" "$TMPDIR/h10-mtls-srv-only.out" \
  || { echo "FAIL: H10-mTLS witness-server-only should name the witness-enabled side" >&2; exit 1; }
echo "H10-mTLS: witness server only → FAIL (half-config): ok"

# Case M5: DEFAULT-MERGE proof — gateway clientSecret set but caBundle/clientCert/
# clientKey OMITTED from the values file (they come from chart DEFAULTS). The
# text-parser false-FAILed this (couldn't see the defaults). The render merges
# them, so with the witness server side also enabled this is a valid full mesh
# → PASS.
MTLS_DEFAULTS_VALS="$TMPDIR/h10-mtls-defaults.yaml"
cat > "$MTLS_DEFAULTS_VALS" <<YAML
gateway:
  witnessMtls:
    clientSecret: "gateway-witness-mtls-certs"
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
veil-witness:
  witnessMtls:
    serverSecret: "witness-mtls-server-certs"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
YAML
if ! run_doctor_with_values "$TMPDIR/h10-mtls-defaults.out" "$MTLS_DEFAULTS_VALS"; then
  echo "FAIL: H10-mTLS default-merge → doctor should PASS (cert paths from chart defaults)" >&2
  cat "$TMPDIR/h10-mtls-defaults.out" >&2; exit 1
fi
if grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-mtls-defaults.out"; then
  echo "FAIL: H10-mTLS default-merge → should NOT false-FAIL (defaults supply cert paths)" >&2
  cat "$TMPDIR/h10-mtls-defaults.out" >&2; exit 1
fi
echo "H10-mTLS: full mesh with cert paths from chart defaults → PASS (default-merge proof): ok"

# Case M6: gateway-side witnessMtls with EMPTY clientSecret → mTLS off → PASS.
MTLS_EMPTY_VALS="$TMPDIR/h10-mtls-empty.yaml"
cat > "$MTLS_EMPTY_VALS" <<YAML
gateway:
  witnessMtls:
    clientSecret: ""
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
veil-witness:
  witnessMtls:
    serverSecret: ""
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
YAML
if ! run_doctor_with_values "$TMPDIR/h10-mtls-empty.out" "$MTLS_EMPTY_VALS"; then
  echo "FAIL: H10-mTLS empty secrets → doctor should PASS (mTLS off)" >&2
  cat "$TMPDIR/h10-mtls-empty.out" >&2; exit 1
fi
if grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-mtls-empty.out"; then
  echo "FAIL: H10-mTLS empty secrets → should NOT flag (both sides off)" >&2
  cat "$TMPDIR/h10-mtls-empty.out" >&2; exit 1
fi
echo "H10-mTLS: empty client+server secret → PASS (mTLS off): ok"

# Case M7: half-config (witness server only) takes precedence even when canary is
# fully wired → the mTLS FAIL fires (independence of the two render checks).
# (Reuses M4's render but asserts the doctor stops on the mTLS FAIL.)
if run_doctor_with_values "$TMPDIR/h10-mtls-precedence.out" "$MTLS_SRV_ONLY_VALS"; then
  echo "FAIL: H10-mTLS precedence → half-mTLS must FAIL even with canary fully wired" >&2
  cat "$TMPDIR/h10-mtls-precedence.out" >&2; exit 1
fi
grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-mtls-precedence.out" \
  || { echo "FAIL: H10-mTLS precedence missing mTLS FAIL" >&2; exit 1; }
echo "H10-mTLS: half-config FAILs independently of canary wiring: ok"

# Case M8: Helm absence is fail-closed when the operator explicitly supplied
# --values. The legacy H10 sub-checks still INFO-skip because they cannot
# render, but the enterprise production-contract inspection itself must return
# nonzero rather than report a green doctor result without Helm.
H10_NOHELM_BIN="$TMPDIR/h10-nohelm-bin"
rm -rf "$H10_NOHELM_BIN"; mkdir -p "$H10_NOHELM_BIN"
# Mirror every PATH dir, symlinking each tool EXCEPT helm.
_h10_oldifs="$IFS"; IFS=':'
for _d in $PATH; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b="$(basename "$_f")"
    [ "$_b" = "helm" ] && continue
    [ -e "$H10_NOHELM_BIN/$_b" ] || ln -sf "$_f" "$H10_NOHELM_BIN/$_b" 2>/dev/null || true
  done
done
IFS="$_h10_oldifs"
H10_NOHELM_RC=0
PATH="$H10_NOHELM_BIN" "$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --values "$MTLS_SRV_ONLY_VALS" \
  --offline > "$TMPDIR/h10-nohelm.out" 2>&1 || H10_NOHELM_RC=$?
if [ "$H10_NOHELM_RC" -eq 0 ]; then
  echo "FAIL: doctor --values must fail closed when helm is absent" >&2
  cat "$TMPDIR/h10-nohelm.out" >&2; exit 1
fi
grep -q "mTLS config (Helm): skipped — helm not installed" "$TMPDIR/h10-nohelm.out" \
  || { echo "FAIL: H10 helm-absent → expected mTLS graceful-skip INFO" >&2; cat "$TMPDIR/h10-nohelm.out" >&2; exit 1; }
grep -q "enterprise mTLS (Helm): FAIL — helm is required with --values" "$TMPDIR/h10-nohelm.out" \
  || { echo "FAIL: doctor --values did not report the Helm fail-closed error" >&2; cat "$TMPDIR/h10-nohelm.out" >&2; exit 1; }
if grep -q "mTLS config (Helm): FAIL" "$TMPDIR/h10-nohelm.out"; then
  echo "FAIL: H10 helm-absent must preserve the legacy mTLS helper graceful skip" >&2
  cat "$TMPDIR/h10-nohelm.out" >&2; exit 1
fi

# Repeating --values must retain the same fail-closed Helm requirement. The
# files are deliberately valid local fixtures; without Helm doctor must not
# claim it inspected either their individual or layered render contract.
H10_NOHELM_MULTI_RC=0
PATH="$H10_NOHELM_BIN" "$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --values "$MTLS_SRV_ONLY_VALS" \
  --values "$MTLS_NONE_VALS" \
  --offline > "$TMPDIR/h10-nohelm-multi.out" 2>&1 || H10_NOHELM_MULTI_RC=$?
if [ "$H10_NOHELM_MULTI_RC" -eq 0 ]; then
  echo "FAIL: doctor with repeated --values must fail closed when helm is absent" >&2
  cat "$TMPDIR/h10-nohelm-multi.out" >&2; exit 1
fi
grep -q "enterprise mTLS (Helm): FAIL — helm is required with --values" "$TMPDIR/h10-nohelm-multi.out" \
  || { echo "FAIL: repeated --values did not report the Helm fail-closed error" >&2; cat "$TMPDIR/h10-nohelm-multi.out" >&2; exit 1; }

# Compose-only doctor remains deliberately graceful without Helm: it never
# claimed to inspect a Helm values contract, so the legacy H10 helpers and the
# enterprise render inspection all stay out of scope.
H10_COMPOSE_NOHELM_RC=0
PATH="$H10_NOHELM_BIN" "$ROOT/bin/lucairn" doctor --env "$ENV_FILE" \
  --compose "$ROOT/docker-compose.customer.yml" \
  --offline > "$TMPDIR/h10-compose-nohelm.out" 2>&1 || H10_COMPOSE_NOHELM_RC=$?
if [ "$H10_COMPOSE_NOHELM_RC" -ne 0 ]; then
  echo "FAIL: Compose-only doctor must remain graceful when helm is absent" >&2
  cat "$TMPDIR/h10-compose-nohelm.out" >&2; exit 1
fi
if grep -q "enterprise mTLS (Helm): FAIL" "$TMPDIR/h10-compose-nohelm.out"; then
  echo "FAIL: Compose-only doctor incorrectly attempted Helm production inspection" >&2
  cat "$TMPDIR/h10-compose-nohelm.out" >&2; exit 1
fi
echo "H10-mTLS: --values fail-closed; Compose-only Helm absence remains graceful: ok"

echo "H10 render-based witness-mTLS partial-config detection: ok"

# ---------------------------------------------------------------------------
# Canary two-consumer (gateway ↔ sandbox-a) — render-based.
#
# Render compares CANARY_HMAC_KEY from the gateway-credentials Secret vs the
# sandbox-a-credentials Secret:
#   both empty            → canary off          → WARN (PASS)
#   both set AND equal     → consistently wired  → PASS (no WARN/FAIL)
#   one set, other empty   → half-config         → FAIL
#   both set but unequal   → key mismatch        → FAIL
# ---------------------------------------------------------------------------

# Case C1: both empty → canary off → WARN, doctor still PASS.
CANARY_OFF_VALS="$TMPDIR/h10-canary-off.yaml"
cat > "$CANARY_OFF_VALS" <<'YAML'
gateway:
  secrets:
    values:
      canaryHmacKey: ""
sandbox-a:
  secrets:
    values:
      canaryHmacKey: ""
YAML
if ! run_doctor_with_values "$TMPDIR/h10-canary-off.out" "$CANARY_OFF_VALS"; then
  echo "FAIL: H10-canary both-empty → doctor should PASS (WARN only)" >&2
  cat "$TMPDIR/h10-canary-off.out" >&2; exit 1
fi
grep -q "canary key (Helm): CANARY_HMAC_KEY is empty on BOTH" "$TMPDIR/h10-canary-off.out" \
  || { echo "FAIL: H10-canary both-empty → expected WARN" >&2; cat "$TMPDIR/h10-canary-off.out" >&2; exit 1; }
if grep -q "canary key (Helm): FAIL" "$TMPDIR/h10-canary-off.out"; then
  echo "FAIL: H10-canary both-empty → must be WARN, not FAIL" >&2
  cat "$TMPDIR/h10-canary-off.out" >&2; exit 1
fi
echo "H10-canary: both empty → WARN (doctor still PASS): ok"

# Case C2: both set to the SAME value → consistently wired → PASS, no WARN/FAIL.
CANARY_MATCH_VALS="$TMPDIR/h10-canary-match.yaml"
cat > "$CANARY_MATCH_VALS" <<YAML
gateway:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
YAML
if ! run_doctor_with_values "$TMPDIR/h10-canary-match.out" "$CANARY_MATCH_VALS"; then
  echo "FAIL: H10-canary match → doctor should PASS" >&2
  cat "$TMPDIR/h10-canary-match.out" >&2; exit 1
fi
if grep -qE "canary key \(Helm\): (FAIL|CANARY_HMAC_KEY is empty)" "$TMPDIR/h10-canary-match.out"; then
  echo "FAIL: H10-canary match → should emit no canary WARN/FAIL" >&2
  cat "$TMPDIR/h10-canary-match.out" >&2; exit 1
fi
echo "H10-canary: both set + matching → PASS (no WARN/FAIL): ok"

# Case C3: gateway set, sandbox-a EMPTY → half-config → FAIL.
# (This is the exact two-consumer false-GREEN the gateway-only text-parser
# produced.)
CANARY_HALF_VALS="$TMPDIR/h10-canary-half.yaml"
cat > "$CANARY_HALF_VALS" <<YAML
gateway:
  secrets:
    values:
      canaryHmacKey: "$H10_CANARY"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: ""
YAML
if run_doctor_with_values "$TMPDIR/h10-canary-half.out" "$CANARY_HALF_VALS"; then
  echo "FAIL: H10-canary half (gateway set, sandbox-a empty) → doctor should FAIL" >&2
  cat "$TMPDIR/h10-canary-half.out" >&2; exit 1
fi
grep -q "canary key (Helm): FAIL" "$TMPDIR/h10-canary-half.out" \
  || { echo "FAIL: H10-canary half missing expected FAIL message" >&2; cat "$TMPDIR/h10-canary-half.out" >&2; exit 1; }
grep -q "sandbox-a.secrets.values.canaryHmacKey is EMPTY" "$TMPDIR/h10-canary-half.out" \
  || { echo "FAIL: H10-canary half should name the empty sandbox-a key" >&2; cat "$TMPDIR/h10-canary-half.out" >&2; exit 1; }
echo "H10-canary: gateway set + sandbox-a empty → FAIL (two-consumer half): ok"

# Case C4: both set but to DIFFERENT values → key mismatch → FAIL.
CANARY_MISMATCH_VALS="$TMPDIR/h10-canary-mismatch.yaml"
cat > "$CANARY_MISMATCH_VALS" <<YAML
gateway:
  secrets:
    values:
      canaryHmacKey: "$(openssl rand -hex 32)"
sandbox-a:
  secrets:
    values:
      canaryHmacKey: "$(openssl rand -hex 32)"
YAML
if run_doctor_with_values "$TMPDIR/h10-canary-mismatch.out" "$CANARY_MISMATCH_VALS"; then
  echo "FAIL: H10-canary mismatch (different values) → doctor should FAIL" >&2
  cat "$TMPDIR/h10-canary-mismatch.out" >&2; exit 1
fi
grep -q "canary key (Helm): FAIL" "$TMPDIR/h10-canary-mismatch.out" \
  || { echo "FAIL: H10-canary mismatch missing expected FAIL message" >&2; cat "$TMPDIR/h10-canary-mismatch.out" >&2; exit 1; }
grep -q "Both are set but to DIFFERENT values" "$TMPDIR/h10-canary-mismatch.out" \
  || { echo "FAIL: H10-canary mismatch should report DIFFERENT values" >&2; cat "$TMPDIR/h10-canary-mismatch.out" >&2; exit 1; }
echo "H10-canary: both set + mismatched → FAIL (key mismatch): ok"

# Case C5: external-secret backend (vault) → INFO-skip (no native canary
# evidence to compare); doctor PASSes. The chart intentionally omits
# CANARY_HMAC_KEY from the ExternalSecret.
CANARY_VAULT_VALS="$TMPDIR/h10-canary-vault.yaml"
cat > "$CANARY_VAULT_VALS" <<'YAML'
gateway:
  secrets:
    backend: vault
sandbox-a:
  secrets:
    backend: vault
YAML
if ! run_doctor_with_values "$TMPDIR/h10-canary-vault.out" "$CANARY_VAULT_VALS"; then
  echo "FAIL: H10-canary vault backend → doctor should PASS (INFO-skip canary check)" >&2
  cat "$TMPDIR/h10-canary-vault.out" >&2; exit 1
fi
grep -q "canary key (Helm): skipped — no native credentials Secret rendered" "$TMPDIR/h10-canary-vault.out" \
  || { echo "FAIL: H10-canary vault → expected external-backend INFO-skip" >&2; cat "$TMPDIR/h10-canary-vault.out" >&2; exit 1; }
if grep -q "canary key (Helm): FAIL" "$TMPDIR/h10-canary-vault.out"; then
  echo "FAIL: H10-canary vault → must NOT FAIL (external backend is operator-manual)" >&2
  cat "$TMPDIR/h10-canary-vault.out" >&2; exit 1
fi
echo "H10-canary: external-secret backend (vault) → INFO-skip (PASS): ok"

# Case C6: MIXED backend — gateway k8s-native (canary set), sandbox-a vault →
# INFO-skip (NOT a misleading "sandbox-a empty" FAIL). sandbox-a's native Secret
# is absent under vault, so there is no render evidence to compare on that side.
CANARY_MIXED_VALS="$TMPDIR/h10-canary-mixed.yaml"
cat > "$CANARY_MIXED_VALS" <<YAML
gateway:
  secrets:
    backend: k8s-native
    values:
      canaryHmacKey: "$H10_CANARY"
sandbox-a:
  secrets:
    backend: vault
YAML
if ! run_doctor_with_values "$TMPDIR/h10-canary-mixed.out" "$CANARY_MIXED_VALS"; then
  echo "FAIL: H10-canary mixed backend → doctor should PASS (INFO-skip, not a false sandbox-a-empty FAIL)" >&2
  cat "$TMPDIR/h10-canary-mixed.out" >&2; exit 1
fi
grep -q "canary key (Helm): skipped — no native credentials Secret rendered" "$TMPDIR/h10-canary-mixed.out" \
  || { echo "FAIL: H10-canary mixed → expected external-backend INFO-skip" >&2; cat "$TMPDIR/h10-canary-mixed.out" >&2; exit 1; }
if grep -q "canary key (Helm): FAIL" "$TMPDIR/h10-canary-mixed.out"; then
  echo "FAIL: H10-canary mixed → must NOT false-FAIL (sandbox-a is on vault, not empty)" >&2
  cat "$TMPDIR/h10-canary-mixed.out" >&2; exit 1
fi
echo "H10-canary: mixed backend (gateway native + sandbox-a vault) → INFO-skip (PASS): ok"

echo "H10 render-based canary two-consumer detection: ok"

fi  # end helm-present guard

echo "all sec-hardening tests: ok"
