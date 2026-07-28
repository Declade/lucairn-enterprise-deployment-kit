#!/usr/bin/env bash
#
# Rendered-compose guard for the customer-device countersignature prerequisite.
#
# PRD: Opus Advisor specs/2026-07/prd-2026-07-28-cert-anchor-hardening-wave1.md
# (Slice 4) · research base findings-2026-07-28-cert-hardening-deep-research.md
# §B row 1.
#
# WHAT IS BEING GUARDED
# ---------------------
# The gateway countersigns a sha256 commitment over each raw request with the
# device's WITNESS-CLAIM-HOP mTLS credential (DSA pkg/devicesign, wired in
# services/gateway/cmd/server/main.go from
# tlsutil.WitnessClientCredentialPaths()). It needs exactly two things inside
# the container and takes no new configuration of its own:
#
#   LCR_WITNESS_MTLS_CLIENT_CERT_PATH / _KEY_PATH   pointing at
#   /etc/lucairn/witness-client/{client.pem,client.key}, read-only mounted.
#
# That reuse is the whole design — no new key, no new ceremony step, no new env
# var — and it is also why this guard exists. Because the countersignature
# borrows an existing credential, an overlay edit that stopped mounting the
# CLAIM credential into the gateway (e.g. "the gateway already has a cert-hop
# credential, drop the duplicate") would have NO visible symptom: claims still
# flow, certificates still seal, the stack looks healthy. The only thing that
# changes is that certificates quietly stop carrying customer evidence — and
# "quietly stop carrying evidence" is precisely the failure an evidence product
# cannot detect by feeling fine.
#
# WHAT THIS IS NOT
# ----------------
# It is not a test of the signature. That lives with the code that produces it
# (DSA pkg/devicesign/devicesign_test.go, the intake matrix in
# services/veil-witness/internal/server/device_countersign_test.go). This file
# asserts the one fact only the kit can state: the credential the signer reads
# actually reaches the gateway container in the topology that ships.
#
# A RENDER, NOT A GREP — and a DIFFERENTIAL
# -----------------------------------------
# Same discipline as tests/test_witness_central_profile.sh. Grepping the overlay
# would prove the text exists, not that Compose composes it onto the gateway
# after the base files have had their say. And a one-sided assertion would pass
# for the wrong reason, so the stock (no-overlay) render is asserted too: there
# the credential must be ABSENT, which is the honest-absence topology — a stock
# install has no device identity and its certificates correctly carry no
# countersignature.
#
# `docker compose config` is client-side only: no daemon, no network, no images.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE="docker-compose.customer.yml"
SELFHOSTED="docker-compose.self-hosted.yml"
OVERLAY="contrib/witness-central/docker-compose.witness-central.yml"
RUNBOOK="docs/WITNESS_CENTRAL_RUNBOOK.md"

CLAIM_MOUNT="/etc/lucairn/witness-client"
GATEWAY_MOUNT="/etc/lucairn/witness-gateway-client"

FAILS=0
N=0
ok()   { N=$((N+1)); printf '  ok   %s\n' "$1"; }
fail() { N=$((N+1)); FAILS=$((FAILS+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (want=$1 got=$2)"; fi; }

# NOT a skip, for the reason spelled out in test_witness_central_profile.sh: a
# guard that vanishes when a tool is missing was absent on every run nobody
# checked.
if ! docker compose version >/dev/null 2>&1; then
  echo "FATAL: 'docker compose' is required to render the compose files." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: 'jq' is required to inspect the rendered per-service config." >&2
  exit 1
fi

for f in "$BASE" "$SELFHOSTED" "$OVERLAY" "$RUNBOOK"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT

STOCK_ENV="$WK/stock.env"
cat > "$STOCK_ENV" <<'EOF'
AUDIT_APP_PASSWORD=render-only
BUILD_AUTH_TOKEN=render-only
CANARY_HMAC_KEY=render-only
CUSTOMER_KEY_ID=render-only
DSA_BRIDGE_ENCRYPTION_KEY=render-only
DSA_SERVICE_TOKEN=render-only
GATEWAY_KEYSTORE_KEY=render-only
PORTAL_API_KEY=render-only
POSTGRES_AUDIT_PASSWORD=render-only
POSTGRES_BRIDGE_PASSWORD=render-only
POSTGRES_SANDBOX_A_PASSWORD=render-only
POSTGRES_VEIL_PASSWORD=render-only
VEIL_APP_PASSWORD=render-only
VEIL_WITNESS_SIGNING_KEY=00
VEIL_WITNESS_PUBLIC_KEY=00
VEIL_BRIDGE_PUBLIC_KEY=00
VEIL_SANITIZER_PUBLIC_KEY=00
VEIL_AUDIT_PUBLIC_KEY=00
VEIL_GATEWAY_PUBLIC_KEY=00
VEIL_SANDBOX_B_PUBLIC_KEY=00
VEIL_AUDIT_SIGNING_KEY=00
VEIL_BRIDGE_SIGNING_KEY=00
VEIL_SANITIZER_SIGNING_KEY=00
DSA_ADMIN_KEY=render-only
VEIL_GATEWAY_SIGNING_KEY=00
VEIL_SANDBOX_B_SIGNING_KEY=00
EOF

ENVFILE="$WK/render.env"
cat "$STOCK_ENV" > "$ENVFILE"
cat >> "$ENVFILE" <<'EOF'
LUCAIRN_CENTRAL_WITNESS_ADDR=witness.render.invalid:50057
LUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.render.invalid:50058
LUCAIRN_WITNESS_CLIENT_CERT_DIR=/tmp/render-only-certs
LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR=/tmp/render-only-gateway-certs
EOF

echo "== device-countersignature prerequisite: rendered-compose differential =="

render() { # render <env-file> <compose flags...>
  local env="$1"; shift
  docker compose $* --env-file "$env" config --format json
}

# Every overlay topology the kit ships, because the credential must reach the
# gateway in all of them and a single-cell guard would keep passing while
# another cell rotted (the class the witness-central cross-product rework was
# written against).
OVERLAY_CELLS="
customer+witness-central|-f $BASE -f $OVERLAY
customer+self-hosted+witness-central|-f $BASE -f $SELFHOSTED -f $OVERLAY
"

while IFS='|' read -r name flags; do
  [ -n "$name" ] || continue
  echo "-- $name"
  if ! J="$(render "$ENVFILE" $flags 2>"$WK/err")"; then
    fail "$name renders"
    sed 's/^/       /' "$WK/err"
    continue
  fi
  ok "$name renders"

  # Positive service-list assertion FIRST, so nothing below can pass vacuously
  # against an empty render.
  gw="$(printf '%s' "$J" | jq -r '.services.gateway // empty')"
  if [ -z "$gw" ]; then
    fail "$name: no gateway service in the render — every assertion below would be vacuous"
    continue
  fi
  ok "$name: gateway service present"

  cert_env="$(printf '%s' "$J" | jq -r '.services.gateway.environment.LCR_WITNESS_MTLS_CLIENT_CERT_PATH // ""')"
  key_env="$(printf '%s' "$J" | jq -r '.services.gateway.environment.LCR_WITNESS_MTLS_CLIENT_KEY_PATH // ""')"
  check "$CLAIM_MOUNT/client.pem" "$cert_env" "$name: gateway reads the device CLAIM cert (signer input)"
  check "$CLAIM_MOUNT/client.key" "$key_env"  "$name: gateway reads the device CLAIM key (signer input)"

  # The env vars are worthless if the directory is not actually mounted — the
  # "configured but unenforced" class (2026-07-28: env not passed into
  # containers; a missing bind-mount is an empty dir, not an error).
  mounted="$(printf '%s' "$J" | jq -r --arg t "$CLAIM_MOUNT" \
    '[.services.gateway.volumes // [] | .[] | select(.target == $t)] | length')"
  check "1" "$mounted" "$name: gateway mounts the device claim credential dir"

  ro="$(printf '%s' "$J" | jq -r --arg t "$CLAIM_MOUNT" \
    '[.services.gateway.volumes // [] | .[] | select(.target == $t) | select(.read_only == true)] | length')"
  check "1" "$ro" "$name: the device claim credential is mounted READ-ONLY"

  # The countersigning identity must be the CLAIM leaf (CN=lucairn-device-<name>),
  # not the certificate-hop leaf (CN=gateway, fleet-wide by design — runbook
  # §3.4 / TOB-002). The signer reads LCR_WITNESS_MTLS_*, so pointing that
  # family at the gateway leaf's directory would silently countersign with an
  # identity the witness cannot bind to the claim connection.
  case "$cert_env" in
    "$GATEWAY_MOUNT"/*) fail "$name: the signer would use the fleet-wide cert-hop leaf, not the per-device claim leaf" ;;
    *) ok "$name: the signer uses the per-device claim leaf, not the cert-hop leaf" ;;
  esac
done <<EOF
$OVERLAY_CELLS
EOF

# ── Honest absence: the stock install has no device identity ─────────
#
# A stock kit runs no witness-central ceremony, so it has no device credential
# and its certificates correctly carry no countersignature. Asserting this is
# what stops the checks above from passing for the wrong reason — if the
# credential were somehow present everywhere, they would be measuring nothing.
echo "-- customer (stock, no overlay)"
if ! J="$(render "$STOCK_ENV" -f "$BASE" 2>"$WK/err")"; then
  fail "stock renders"
  sed 's/^/       /' "$WK/err"
else
  ok "stock renders"
  gw="$(printf '%s' "$J" | jq -r '.services.gateway // empty')"
  if [ -z "$gw" ]; then
    fail "stock: no gateway service in the render"
  else
    ok "stock: gateway service present"
    stock_cert="$(printf '%s' "$J" | jq -r '.services.gateway.environment.LCR_WITNESS_MTLS_CLIENT_CERT_PATH // ""')"
    check "" "$stock_cert" "stock: no device credential → honest absence, no countersignature"
    stock_mounted="$(printf '%s' "$J" | jq -r --arg t "$CLAIM_MOUNT" \
      '[.services.gateway.volumes // [] | .[] | select(.target == $t)] | length')"
    check "0" "$stock_mounted" "stock: no device claim credential mounted"
  fi
fi

# ── The runbook must say what an operator will otherwise ask support ──
echo "-- runbook"
# The three outcomes must all be documented BY NAME. An operator who reads only
# two of them collapses the third into one of the others, and the collapse that
# matters — reading "present but does not verify" as "absent" — is the exact
# confusion this feature exists to prevent.
for phrase in "countersign" "device_countersign" "did not countersign" "does not verify"; do
  if grep -qi -- "$phrase" "$RUNBOOK"; then
    ok "runbook documents '$phrase'"
  else
    fail "runbook does not document '$phrase'"
  fi
done
# The honest-absence statement must survive a rewrite: the runbook must say the
# countersignature never blocks a request. A doc guard satisfied by the claim's
# own negation is a doc guard that passes on the sentence "this DOES block"
# (2026-07-28 lesson), so match the assertion, not the topic.
if grep -qiE "never (blocks|block) (a |the )?(request|turn)" "$RUNBOOK"; then
  ok "runbook states the countersignature never blocks a request"
else
  fail "runbook does not state that the countersignature never blocks a request"
fi

echo
echo "== $((N-FAILS))/$N checks passed =="
[ "$FAILS" -eq 0 ] || exit 1
