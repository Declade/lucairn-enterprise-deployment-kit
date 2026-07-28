#!/usr/bin/env bash
#
# Rendered-compose differential for the `witness-central` topology overlay.
#
# PRD: Opus Advisor specs/2026-07/prd-2026-07-28-split-evidence-plane.md
# Board: #206 (topology) / #223 (authorization) / #225 (PKI operations)
#
# WHY A RENDER, NOT A GREP
# ------------------------
# The claim this file exists to hold is "the laptop runs no witness". You cannot
# check that by grepping the overlay: the `veil-witness` service is DEFINED in
# docker-compose.customer.yml and a compose overlay cannot delete a service, only
# add keys to it. What the overlay does is assign a `profiles:` value that nobody
# activates, and the only thing that proves that works is asking Compose itself
# what it would start.
#
# It is also a DIFFERENTIAL: the same render without the overlay must still list
# the witness. A test that only asserts the absence would keep passing if the
# service name were renamed, if the base file dropped it, or if the env fixture
# silently failed to render at all — three ways to get a green light for the
# wrong reason. Asserting the before-state as well makes the absence mean
# something.
#
# `docker compose config` is client-side only; no daemon, no network, no images.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE="docker-compose.customer.yml"
SELFHOSTED="docker-compose.self-hosted.yml"
CUSTOMER_ENV_EXAMPLE="customer.env.example"
OVERLAY="contrib/witness-central/docker-compose.witness-central.yml"
ENV_EXAMPLE="contrib/witness-central/witness-central.env.example"
RUNBOOK="docs/WITNESS_CENTRAL_RUNBOOK.md"

FAILS=0
N=0

ok()   { N=$((N+1)); printf '  ok   %s\n' "$1"; }
fail() { N=$((N+1)); FAILS=$((FAILS+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (want=$1 got=$2)"; fi; }

if ! docker compose version >/dev/null 2>&1; then
  # NOT a skip. A rendered-config differential is the only oracle for the
  # "control exists but reaches no container" class (2026-07-28 review,
  # BLOCKER 1), and a guard that silently disappears when a tool is absent was
  # absent on every run nobody checked. `docker compose config` is client-side
  # only: no daemon, no network, no images.
  echo "FATAL: 'docker compose' is required to render the compose files." >&2
  exit 1
fi

for f in "$BASE" "$SELFHOSTED" "$ENV_EXAMPLE" "$RUNBOOK" "$OVERLAY"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

# ── Synthetic env ───────────────────────────────────────────────────
#
# Only the ${VAR:?...} variables need real values; everything else may default.
# Values are obvious placeholders — this fixture never reaches a container.
WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT
ENVFILE="$WK/render.env"
cat > "$ENVFILE" <<'EOF'
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
LUCAIRN_CENTRAL_WITNESS_ADDR=witness.render.invalid:50057
LUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.render.invalid:50058
LUCAIRN_WITNESS_CLIENT_CERT_DIR=/tmp/render-only-certs
DSA_ADMIN_KEY=render-only
EOF

render_services() { docker compose "$@" --env-file "$ENVFILE" config --services 2>/dev/null; }
render_full()     { docker compose "$@" --env-file "$ENVFILE" config          2>/dev/null; }

echo "== witness-central rendered-compose differential =="

# ── 1. The differential ─────────────────────────────────────────────

BASE_SERVICES="$(render_services -f "$BASE")"
OVER_SERVICES="$(render_services -f "$BASE" -f "$OVERLAY")"

if [ -z "$BASE_SERVICES" ] || [ -z "$OVER_SERVICES" ]; then
  echo "FAIL: a render produced no services at all — the env fixture is incomplete, so every"
  echo "      assertion below would pass vacuously. Re-check the \${VAR:?} set in $BASE."
  exit 1
fi

check 1 "$(printf '%s\n' "$BASE_SERVICES" | grep -c '^veil-witness$' || true)" \
  "baseline (no overlay) DOES start a local witness"

check 0 "$(printf '%s\n' "$OVER_SERVICES" | grep -c '^veil-witness$' || true)" \
  "witness-central does NOT start a local witness (ratified 2026-07-28)"

# The overlay must remove the witness and NOTHING else. A profile typo on the
# wrong service would show up here as a second disappearance.
MISSING="$(comm -23 <(printf '%s\n' "$BASE_SERVICES" | sort) <(printf '%s\n' "$OVER_SERVICES" | sort) | tr '\n' ' ' | sed 's/ *$//')"
check "veil-witness" "$MISSING" "the overlay removes veil-witness and nothing else"

# ── 2. The escape hatch still exists, and is opt-in ─────────────────

DEV_SERVICES="$(render_services -f "$BASE" -f "$OVERLAY" --profile witness-local-dev-only)"
check 1 "$(printf '%s\n' "$DEV_SERVICES" | grep -c '^veil-witness$' || true)" \
  "the dev-only profile can still start it deliberately"

# ── 3. Emitters point at the central witness ────────────────────────

FULL="$(render_full -f "$BASE" -f "$OVERLAY")"

check 0 "$(printf '%s\n' "$FULL" | grep -c 'LCR_WITNESS_ADDR: veil-witness' || true)" \
  "no emitter still dials the local claim port"
check 0 "$(printf '%s\n' "$FULL" | grep -c 'LCR_WITNESS_CERT_ADDR: veil-witness' || true)" \
  "the gateway no longer reads certificates from the local witness"

# All four kit emitters (audit, id-bridge, sanitizer, gateway) must be repointed.
check 4 "$(printf '%s\n' "$FULL" | grep -c 'LCR_WITNESS_ADDR: witness.render.invalid:50057' || true)" \
  "all four kit emitters dial the central claim port"
check 4 "$(printf '%s\n' "$FULL" | grep -c 'LCR_WITNESS_REQUIRE_MTLS: "true"' || true)" \
  "all four kit emitters have the fail-closed mTLS latch engaged"

# The :50058 hop has its OWN credential family (no LCR_ prefix). Without it the
# gateway dials the cert port anonymously and a latched witness refuses the
# handshake — which surfaces much later as "certificates never load".
#
# ⚠️ ANCHORED, not a substring match. `WITNESS_MTLS_CLIENT_CERT_PATH` is a
# suffix of `LCR_WITNESS_MTLS_CLIENT_CERT_PATH`, the claim-hop family that all
# four emitters carry — a bare grep counts 5 and would have passed with the
# gateway's cert-port credential entirely absent. The two families are
# deliberately distinct and a test that cannot tell them apart is testing
# neither.
check 1 "$(printf '%s\n' "$FULL" | grep -cE '^[[:space:]]+WITNESS_MTLS_CLIENT_CERT_PATH: /etc/lucairn/witness-client/client\.pem$' || true)" \
  "the gateway carries a client credential for the certificate port (:50058 family)"
check 4 "$(printf '%s\n' "$FULL" | grep -cE '^[[:space:]]+LCR_WITNESS_MTLS_CLIENT_CERT_PATH: /etc/lucairn/witness-client/client\.pem$' || true)" \
  "all four emitters carry the witness-scoped claim-hop credential (:50057 family)"

# ── 4. The cert address is REQUIRED, not defaulted ──────────────────
#
# Its old default was the local witness. With no local witness that default
# would resolve to a service that does not exist, and the failure would arrive
# at request time as a connection error rather than at config time as a
# configuration error.
STRIPPED="$WK/no-cert-addr.env"
grep -v '^LUCAIRN_CENTRAL_WITNESS_CERT_ADDR=' "$ENVFILE" > "$STRIPPED"
if docker compose -f "$BASE" -f "$OVERLAY" --env-file "$STRIPPED" config >/dev/null 2>&1; then
  fail "omitting LUCAIRN_CENTRAL_WITNESS_CERT_ADDR still renders — it must fail closed"
else
  ok "omitting LUCAIRN_CENTRAL_WITNESS_CERT_ADDR fails the render"
fi

# ── 5. The signing-key retirement step is documented ────────────────
#
# bin/lucairn init generates LCR_WITNESS_SIGNING_KEY for every topology and this
# overlay cannot reach into that generator, so removing it is a manual step. A
# manual step that is not written down is a step that does not happen, and the
# PRD's success criterion is that the laptop holds NO witness signing key.
if grep -q 'Retire the local signing key' "$RUNBOOK"; then
  ok "runbook documents retiring the local signing key"
else
  fail "runbook has no 'Retire the local signing key' section"
fi
if grep -q 'LCR_WITNESS_SIGNING_KEY' "$ENV_EXAMPLE"; then
  ok "env example names the signing key the operator must delete"
else
  fail "env example does not tell the operator to delete LCR_WITNESS_SIGNING_KEY"
fi
# The public key must be REPOINTED, not deleted: the gateway publishes it at
# /.well-known/veil-keys.json and verifiers fetch it. Deleting it breaks
# verification; leaving the old value advertises a key that signed nothing.
if grep -q 'LCR_WITNESS_PUBLIC_KEY' "$RUNBOOK"; then
  ok "runbook distinguishes the public key (repoint) from the private key (delete)"
else
  fail "runbook does not say what happens to LCR_WITNESS_PUBLIC_KEY"
fi

# ── 6. The authorization layer is documented ────────────────────────
#
# The mTLS latch is authentication. Without these, any device credential can
# call ExportCertificates for any customer_id.
for var in LCR_WITNESS_CLAIM_ALLOWED_PEERS LCR_WITNESS_EXPORT_ALLOWED_PEERS \
           LCR_WITNESS_EXPORT_CUSTOMER_MAP LCR_WITNESS_EXPORT_CUSTOMER_BINDING; do
  if grep -q "$var" "$RUNBOOK"; then
    ok "runbook documents $var"
  else
    fail "runbook does not document $var"
  fi
done

# The load-bearing sentence: a device credential must not be on the export list.
if grep -q 'not.*your device CNs' "$RUNBOOK" || grep -q 'NOT your device CNs' "$RUNBOOK"; then
  ok "runbook states device credentials are NOT on the export allowlist"
else
  fail "runbook does not state that device credentials cannot bulk-read certificates"
fi

# ── 6b. The STOCK topology carries the wiring too ───────────────────
#
# 2026-07-28 review, BLOCKER 1. Everything above tests the OVERLAY, and the
# overlay was fine. What was not fine is that a kit customer running the stock
# witness-local topology — the default install — could set every one of these
# variables in customer.env and have none of them reach a container, because
# `docker-compose.customer.yml` listed none of them and the kit has no
# `env_file:` channel either. The security layer was configurable and inert.
#
# Rendered without the overlay, so this is the default install's answer.
BASE_FULL="$(render_full -f "$BASE")"

for var in LCR_WITNESS_REQUIRE_MTLS LCR_WITNESS_MTLS_CA_BUNDLE_PATH \
           LCR_WITNESS_MTLS_CLIENT_CERT_PATH LCR_WITNESS_MTLS_CLIENT_KEY_PATH; do
  # Four emitters (audit, id-bridge, sanitizer, gateway) plus the witness for
  # the latch itself; the credential triple is emitters-only.
  want=4
  [ "$var" = "LCR_WITNESS_REQUIRE_MTLS" ] && want=5
  got="$(printf '%s\n' "$BASE_FULL" | grep -cE "^[[:space:]]+${var}: " || true)"
  check "$want" "$got" "stock topology wires $var into every service that reads it"
done

for var in LCR_WITNESS_EXPORT_ALLOWED_PEERS LCR_WITNESS_CERT_ALLOWED_PEERS \
           LCR_WITNESS_CLAIM_ALLOWED_PEERS LCR_WITNESS_EXPORT_CUSTOMER_MAP \
           LCR_WITNESS_EXPORT_CUSTOMER_BINDING LCR_WITNESS_EXPORT_MAX_CERTS \
           LCR_WITNESS_PEER_IDENTITY LCR_WITNESS_AUDIT_LOG_HMAC_KEY; do
  got="$(printf '%s\n' "$BASE_FULL" | grep -cE "^[[:space:]]+${var}: " || true)"
  check 1 "$got" "stock topology wires $var into the witness"
done

# The latch must render as an explicit, legible `false` on an unconfigured
# install — not "", which is also off but leaves an operator unable to answer
# "is this latched?" from the rendered config.
check 5 "$(printf '%s\n' "$BASE_FULL" | grep -c 'LCR_WITNESS_REQUIRE_MTLS: "false"' || true)" \
  "an unconfigured stock install renders the latch as an explicit false"

# ── 6b-ii. Per-service credentials must be EXPRESSIBLE ──────────────
#
# Round 2, TOB-003. One shared client leaf across every emitter collapses the
# per-emitter claim allowlist to a single identity: any container on the host
# can then submit claims as any allowlisted emitter. The device-wide triple
# stays as the fallback (a genuine one-credential laptop still works); what this
# asserts is that an operator CAN bind each emitter to its own leaf without
# editing compose, mirroring what the :50058 hop has always done with
# WITNESS_MTLS_GATEWAY_CLIENT_CERT_PATH.
PSENV="$WK/perservice.env"
cat "$ENVFILE" > "$PSENV"
echo 'LCR_WITNESS_MTLS_CLIENT_CERT_PATH=/global/client.pem' >> "$PSENV"
for svc in audit id-bridge sanitizer gateway; do
  upper="$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')"
  echo "LCR_WITNESS_MTLS_${upper}_CLIENT_CERT_PATH=/per/${svc}.pem" >> "$PSENV"
done
PS_FULL="$(docker compose -f "$BASE" --env-file "$PSENV" config)"
check 4 "$(printf '%s\n' "$PS_FULL" | grep -cE '^[[:space:]]+LCR_WITNESS_MTLS_CLIENT_CERT_PATH: /per/' || true)" \
  "each emitter can be given its own witness client leaf (per-service override wins)"
check 4 "$(printf '%s\n' "$BASE_FULL" | grep -cE '^[[:space:]]+LCR_WITNESS_MTLS_CLIENT_CERT_PATH: ' || true)" \
  "the device-wide fallback is still wired when no per-service leaf is set"

# ── 6b-iii. The SELF-HOSTED overlay carries it too ──────────────────
#
# ⚠️ THIS EXISTS BECAUSE IT WAS MISSED. The Slice-1 wiring went into
# docker-compose.customer.yml, and `sandbox-b` is defined ONLY in
# docker-compose.self-hosted.yml — so there was no merge source for it, while
# INSTALL.md and OPS.md document `customer + self-hosted` as the mandatory full
# on-prem set. An operator latching that install got every emitter gated except
# the AI plane, whose claim dial stayed cleartext.
#
# Rendering only $BASE cannot see that. This renders the documented pair.
FULLSET="$(render_full -f "$BASE" -f "$SELFHOSTED")"

for var in LCR_WITNESS_REQUIRE_MTLS LCR_WITNESS_MTLS_CA_BUNDLE_PATH \
           LCR_WITNESS_MTLS_CLIENT_CERT_PATH LCR_WITNESS_MTLS_CLIENT_KEY_PATH; do
  # audit + id-bridge + sanitizer + gateway + sandbox-b = 5 emitters, plus the
  # witness itself for the latch.
  want=5
  [ "$var" = "LCR_WITNESS_REQUIRE_MTLS" ] && want=6
  got="$(printf '%s\n' "$FULLSET" | grep -cE "^[[:space:]]+${var}: " || true)"
  check "$want" "$got" "customer+self-hosted wires $var into every emitter incl. sandbox-b"
done

# ── 6d. customer.env.example is the file customers actually edit ────
#
# The DSA repo's guard enforces the config.env.template counterpart. The kit had
# no equivalent, so all twelve controls were wired into compose and discoverable
# nowhere.
for var in LCR_WITNESS_REQUIRE_MTLS LCR_WITNESS_MTLS_CA_BUNDLE_PATH \
           LCR_WITNESS_MTLS_CLIENT_CERT_PATH LCR_WITNESS_MTLS_CLIENT_KEY_PATH \
           LCR_WITNESS_EXPORT_ALLOWED_PEERS LCR_WITNESS_CERT_ALLOWED_PEERS \
           LCR_WITNESS_CLAIM_ALLOWED_PEERS LCR_WITNESS_EXPORT_CUSTOMER_MAP \
           LCR_WITNESS_EXPORT_CUSTOMER_BINDING LCR_WITNESS_EXPORT_MAX_CERTS \
           LCR_WITNESS_PEER_IDENTITY LCR_WITNESS_AUDIT_LOG_HMAC_KEY; do
  if grep -qE "^#?${var}=" "$CUSTOMER_ENV_EXAMPLE"; then
    ok "customer.env.example declares $var"
  else
    fail "customer.env.example does not declare $var — customers configure from this file"
  fi
done

# ── 6c. The mandatory binding is stated where the operator sets it ──
#
# Under the latch with no customer map the witness now REFUSES TO START until
# LCR_WITNESS_EXPORT_CUSTOMER_BINDING is explicit (2026-07-28 review, HIGH 1).
# An operator who follows this runbook must not meet that refusal as a surprise.
if grep -qE '^LCR_WITNESS_EXPORT_CUSTOMER_BINDING=' "$RUNBOOK"; then
  ok "runbook's central-witness config sets the binding rather than commenting it out"
else
  fail "runbook still leaves LCR_WITNESS_EXPORT_CUSTOMER_BINDING commented out — the witness will refuse to start"
fi
if grep -q 'REFUSES TO START' "$RUNBOOK"; then
  ok "runbook says the witness refuses to start without an explicit binding"
else
  fail "runbook does not warn that the binding is mandatory under the latch"
fi

# 🛑 THE MAP AND THE BINDING ARE A PAIR, and the runbook must ship them as one.
# `enforce` with the map left commented out denies EVERY export: the latched
# default allowlist is the `gateway` identity, an unmapped gateway is refused,
# and the refusal surfaces as a PERMANENT HTTP 503 "Witness temporarily
# unavailable, Retry-After: 30". A config error wearing an outage's clothes. An
# earlier revision of this runbook shipped exactly that, and the check that was
# supposed to cover it only asserted the binding line was uncommented.
if grep -qE '^LCR_WITNESS_EXPORT_CUSTOMER_BINDING=enforce' "$RUNBOOK"; then
  if grep -qE '^LCR_WITNESS_EXPORT_CUSTOMER_MAP=' "$RUNBOOK"; then
    ok "runbook ships the customer map alongside enforce (they are a pair)"
  else
    fail "runbook sets LCR_WITNESS_EXPORT_CUSTOMER_BINDING=enforce with the customer map commented out — that denies EVERY export and surfaces as a permanent HTTP 503"
  fi
else
  ok "runbook does not ship a bare enforce"
fi
if grep -q 'Retry-After' "$RUNBOOK"; then
  ok "runbook warns what a bare enforce looks like from the outside"
else
  fail "runbook does not describe the 503-that-is-really-a-config-error symptom"
fi
# The latch's strict grammar, where the operator types the value.
if grep -q 'STRICT VALUE GRAMMAR' "$ENV_EXAMPLE"; then
  ok "env example states the strict true/false grammar"
else
  fail "env example does not state that a mistyped latch stops the process"
fi

# ── 7. The overlay warns about the profile-activation trap ──────────
#
# cert-builder declares depends_on: veil-witness (condition: service_healthy),
# and recent Compose versions auto-activate a dependency's profile — which would
# silently restart the witness this overlay exists to remove.
if grep -q 'cert-builder' "$OVERLAY"; then
  ok "overlay warns that the certification profile would re-activate the witness"
else
  fail "overlay does not warn about cert-builder's depends_on re-activating the witness"
fi

echo
echo "== $((N-FAILS))/$N passed =="
[ "$FAILS" -eq 0 ] || exit 1
