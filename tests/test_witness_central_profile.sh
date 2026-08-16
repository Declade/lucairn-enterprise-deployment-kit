#!/usr/bin/env bash
#
# Rendered-compose differential for the `witness-central` topology overlay.
#
# PRD: prd-2026-07-28-split-evidence-plane
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
#
# WHY A CROSS PRODUCT, NOT A LIST OF CELLS
# ----------------------------------------
# ⚠️ THIS IS THE STRUCTURAL POINT OF THE 2026-07-28 REWORK. Every previous round
# fixed an INSTANCE and the same CLASS came back, because each round widened the
# guard by exactly one topology while the property being asserted is a property
# of the CROSS PRODUCT:
#
#   round 1  asserted `customer` and `customer + overlay`
#   round 2  added `customer + self-hosted`, because the Slice-1 wiring had
#            landed in docker-compose.customer.yml and sandbox-b is defined only
#            in docker-compose.self-hosted.yml
#   round 3  found BLOCKER 1: `customer + self-hosted + overlay` — the full
#            on-prem set INSTALL.md documents, with the pilot topology on top —
#            DID NOT RENDER AT ALL, and no cell in this file rendered it.
#
# So the topologies are now a DATA TABLE and every assertion runs against every
# cell, with the per-cell expectations COMPUTED from the cell (how many emitters
# exist, whether the witness is present, which address they should carry) rather
# than hardcoded once against one render. Adding a shipped topology is one row.
#
# And a cell that SHOULD NOT render is a cell too: `--profile certification`
# with this overlay must fail, loudly, naming the missing service — because
# cert-builder genuinely needs a witness process. Asserting only the successes
# would let a future "fix" silently paper that over.
#
# VACUOUS PASSES
# --------------
# The failure mode this file is written against is a green run that checked
# nothing: `grep -c` over an empty render returns 0, so a `check 0 ...` passes
# when the render produced NOTHING. Two defences, both structural:
#   1. every per-cell assertion is a POSITIVE count (== emitters, == 1) rather
#      than a zero count, so an empty render fails it;
#   2. each renderable cell asserts its own service list is non-empty and
#      contains the services the cell is named after, before anything else runs.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE="docker-compose.customer.yml"
SELFHOSTED="docker-compose.self-hosted.yml"
CUSTOMER_ENV_EXAMPLE="customer.env.example"
OVERLAY="contrib/witness-central/docker-compose.witness-central.yml"
ENV_EXAMPLE="contrib/witness-central/witness-central.env.example"
RUNBOOK="docs/WITNESS_CENTRAL_RUNBOOK.md"

# The claim-hop address the synthetic env publishes, and the address the stock
# LAN topology must fall back to when it is absent.
CENTRAL_ADDR="witness.render.invalid:50057"
LOCAL_ADDR="veil-witness:50057"

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

if ! command -v jq >/dev/null 2>&1; then
  # Same reasoning as above, and for the same class of assertion. The
  # credential-separation checks read the rendered per-service `environment:`
  # and `volumes:`, which needs structure rather than a line grep — a `source:`
  # line in the YAML render carries no indication of which service owns it, so
  # a grep cannot answer "does any NON-gateway service mount this". Skipping
  # would make the check disappear exactly where it is load-bearing.
  echo "FATAL: 'jq' is required to inspect the rendered per-service config." >&2
  exit 1
fi

for f in "$BASE" "$SELFHOSTED" "$ENV_EXAMPLE" "$RUNBOOK" "$OVERLAY" "$CUSTOMER_ENV_EXAMPLE"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

# ── Synthetic env ───────────────────────────────────────────────────
#
# Only the ${VAR:?...} variables need real values; everything else may default.
# Values are obvious placeholders — this fixture never reaches a container.
#
# TWO fixtures, deliberately. The overlay's `:?` variables are REQUIRED, so an
# overlay cell needs them; a STOCK install has none of them set, and that is the
# only way to prove the fallbacks (`${LUCAIRN_CENTRAL_WITNESS_ADDR:-veil-witness:50057}`
# on sandbox-b) actually fall back. Rendering the stock cells with the central
# address set would have hidden HIGH 3's fix behind the fixture.
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
EOF
# docker-compose.self-hosted.yml needs two more signing keys that the customer
# compose does not.
cat >> "$STOCK_ENV" <<'EOF'
VEIL_GATEWAY_SIGNING_KEY=00
VEIL_SANDBOX_B_SIGNING_KEY=00
EOF

ENVFILE="$WK/render.env"
cat "$STOCK_ENV" > "$ENVFILE"
cat >> "$ENVFILE" <<EOF
LUCAIRN_CENTRAL_WITNESS_ADDR=${CENTRAL_ADDR}
LUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.render.invalid:50058
LUCAIRN_WITNESS_CLIENT_CERT_DIR=/tmp/render-only-certs
LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR=/tmp/render-only-gateway-certs
EOF

echo "== witness-central rendered-compose cross-product differential =="

# ── The topology table ──────────────────────────────────────────────
#
# name | compose files | extra flags
#
# `expect` is DERIVED, not listed: a cell that combines the certification
# profile with the overlay must fail (cert-builder needs a witness process); a
# cell that activates the dev-only profile gets the witness back. Deriving it
# means adding a row cannot accidentally assert the wrong thing, and it means
# the expectations stay consistent when a row is edited.
#
# ⚠️ `customer+self-hosted+witness-central` IS THE ROW THAT WAS MISSING. It is
# the full on-prem set from INSTALL.md:177 with the pilot topology applied, and
# until 2026-07-28 it did not render at all.
#
# The `llama-cpp` arms exist because INSTALL.md:177 documents the full on-prem
# command WITH a runtime profile attached, so the exact line an operator copies
# is `... -f docker-compose.self-hosted.yml --env-file customer.env
# --profile llama-cpp up -d` rather than the simplification this table used to
# cover. A runtime profile that pulled in another `depends_on: veil-witness`
# edge would be a second instance of BLOCKER 1.
#
# It does not, and that was checked rather than assumed: only TWO services in
# the whole kit declare a `depends_on` on the witness — `cert-builder`
# (docker-compose.customer.yml, profile "certification") and `sandbox-b`
# (docker-compose.self-hosted.yml). Every runtime/feature profile — llama-cpp,
# vllm, tgi, ollama, onnxruntime, triton, custom-runtime, vllm-l3, dashboard,
# phase7 — renders clean under the overlay; `certification` is the only one that
# does not. llama-cpp is the row carried here because it is the one INSTALL.md
# actually prints.
CELLS="
customer|-f $BASE|
customer+self-hosted|-f $BASE -f $SELFHOSTED|
customer+witness-central|-f $BASE -f $OVERLAY|
customer+self-hosted+witness-central|-f $BASE -f $SELFHOSTED -f $OVERLAY|
customer+witness-central+devonly|-f $BASE -f $OVERLAY|--profile witness-local-dev-only
customer+self-hosted+witness-central+devonly|-f $BASE -f $SELFHOSTED -f $OVERLAY|--profile witness-local-dev-only
customer+self-hosted+llama-cpp|-f $BASE -f $SELFHOSTED|--profile llama-cpp
customer+self-hosted+witness-central+llama-cpp|-f $BASE -f $SELFHOSTED -f $OVERLAY|--profile llama-cpp
customer+self-hosted+certification|-f $BASE -f $SELFHOSTED|--profile certification
customer+witness-central+certification|-f $BASE -f $OVERLAY|--profile certification
customer+self-hosted+witness-central+certification|-f $BASE -f $SELFHOSTED -f $OVERLAY|--profile certification
"

# The four emitters the customer compose defines. sandbox-b is the fifth and
# lives only in docker-compose.self-hosted.yml; the DSA repo has a sixth
# (reid-guard) that no kit compose file defines.
BASE_EMITTERS="audit gateway id-bridge sanitizer"

render_json_cell() { # files_flags extra_flags envfile
  # shellcheck disable=SC2086
  docker compose $1 $3 --env-file "$4" config --format json 2>/dev/null
}

# svc_env_map <json> <var>  ->  "svc=value" lines, sorted, for services that
# actually declare <var>. EXACT key match, which is the whole reason this is jq
# and not grep: `WITNESS_MTLS_CLIENT_CERT_PATH` is a SUFFIX of
# `LCR_WITNESS_MTLS_CLIENT_CERT_PATH`, and a bare grep for the former counts the
# latter's four occurrences too — it would have passed with the gateway's
# certificate-port credential entirely absent. An anchored grep can be made to
# work; an exact key lookup cannot be made to fail that way.
svc_env_map() {
  printf '%s' "$1" | jq -r --arg v "$2" '
    .services | to_entries[]
    | select((.value.environment // {}) | has($v))
    | "\(.key)=\(.value.environment[$v] // "")"' | sort
}
svc_env_count() { svc_env_map "$1" "$2" | grep -c . || true; }
# Count services whose <var> equals <value> EXACTLY. Positive-count by
# construction, so an empty render fails rather than passing vacuously.
svc_env_eq_count() {
  printf '%s' "$1" | jq -r --arg v "$2" --arg want "$3" '
    [.services[] | select((.environment // {})[$v] == $want)] | length'
}

# ── Per-cell assertions ─────────────────────────────────────────────

CELL_ROWS=""   # accumulated for the summary table

while IFS='|' read -r NAME FILES EXTRA; do
  [ -n "$NAME" ] || continue

  case "$FILES" in *"$SELFHOSTED"*) HAS_SELF=1 ;; *) HAS_SELF=0 ;; esac
  case "$FILES" in *"$OVERLAY"*)    HAS_OVER=1 ;; *) HAS_OVER=0 ;; esac
  case "$EXTRA" in *witness-local-dev-only*) HAS_DEV=1 ;;  *) HAS_DEV=0 ;; esac
  case "$EXTRA" in *certification*)          HAS_CERT=1 ;; *) HAS_CERT=0 ;; esac

  # Derived expectations.
  #
  # SHOULD-NOT-RENDER: cert-builder (profile "certification",
  # docker-compose.customer.yml) declares a HARD depends_on the witness, and it
  # is the one service that genuinely cannot work without a local witness
  # process — it drives one rather than dialling one. Under the overlay the
  # witness is profiled out, and a profiled-out service is UNDEFINED to Compose,
  # not merely not-started. That combination must fail, and the failure is the
  # correct outcome rather than a bug to route around.
  if [ "$HAS_CERT" = 1 ] && [ "$HAS_OVER" = 1 ] && [ "$HAS_DEV" = 0 ]; then
    SHOULD_RENDER=0
  else
    SHOULD_RENDER=1
  fi

  EMITTERS=$((4 + HAS_SELF))
  if [ "$HAS_OVER" = 1 ] && [ "$HAS_DEV" = 0 ]; then WANT_WITNESS=0; else WANT_WITNESS=1; fi
  if [ "$HAS_OVER" = 1 ]; then
    WANT_ADDR="$CENTRAL_ADDR"; CELL_ENV="$ENVFILE"
  else
    # A stock install sets none of the LUCAIRN_CENTRAL_* variables. Rendering it
    # with them set would prove nothing about the fallback.
    WANT_ADDR="$LOCAL_ADDR";   CELL_ENV="$STOCK_ENV"
  fi

  echo
  echo "-- cell: $NAME  (emitters=$EMITTERS witness=$WANT_WITNESS addr=$WANT_ADDR should_render=$SHOULD_RENDER)"

  # ⚠️ TWO SHARP EDGES, BOTH MEASURED, BOTH SILENT.
  #
  # 1. `VAR="$(cmd)"; RC=$?` EXITS under `set -e` when cmd fails — an assignment
  #    whose command substitution returns non-zero is itself a failed command.
  #    The should-not-render cells are SUPPOSED to fail, so written that way this
  #    loop died at the first one and the run ended with zero FAILs printed and a
  #    non-zero exit nobody read. `&& RC=0 || RC=$?` makes it a compound command,
  #    which `set -e` does not act on.
  #
  # 2. STDERR MUST NOT JOIN THE SERVICE LIST. `2>&1` looks harmless on
  #    `config --services`, but Compose writes a `level=warning ... variable is
  #    not set` line per unset variable — five of them on this fixture. Folded
  #    into the same capture they become five "services", so a render that
  #    produced NO services still counts as five and the anti-vacuous-pass gate
  #    below passes on warnings. That is the exact defect this file exists to
  #    catch, one level up. Streams stay separate: stdout is the service list,
  #    stderr is only ever read for the error text of a should-not-render cell.
  # shellcheck disable=SC2086
  ERRF="$WK/err.$$"
  SERVICES="$(docker compose $FILES $EXTRA --env-file "$CELL_ENV" config --services 2>"$ERRF")" && RC=0 || RC=$?
  ERRTEXT="$(cat "$ERRF")"
  # Belt and braces: a warning line must never be mistaken for a service name.
  SERVICES="$(printf '%s\n' "$SERVICES" | grep -v 'level=warning' || true)"
  [ "$RC" -eq 0 ] || SERVICES=""

  if [ "$SHOULD_RENDER" = 0 ]; then
    # ── The should-not-render cell ──────────────────────────────────
    check 1 "$([ "$RC" -ne 0 ] && echo 1 || echo 0)" \
      "$NAME: the certification profile + witness-central FAILS the render"
    # The message must name the missing service, or an operator cannot tell this
    # apart from any other compose error.
    #
    # ⚠️ COMPOSE OWNS THIS WORDING and it names neither the overlay nor the
    # profile — only the two services. So the requirement "the error names the
    # overlay and the profile" cannot be met by the message; it is met by the
    # DOCS instead, and asserted as such in the documentation block below
    # ("runbook names the certification profile as the should-not-render
    # combination"). Recorded here rather than quietly dropped.
    case "$ERRTEXT" in
      *veil-witness*) ok "$NAME: the error names veil-witness" ;;
      *)              fail "$NAME: the error does not name veil-witness — got: $(printf '%s' "$ERRTEXT" | tail -1)" ;;
    esac
    case "$ERRTEXT" in
      *cert-builder*) ok "$NAME: the error names cert-builder, the service that needs a local witness" ;;
      *)              fail "$NAME: the error does not name cert-builder" ;;
    esac
    CELL_ROWS="${CELL_ROWS}${NAME}|no-render|rc=$RC|witness=n/a
"
    continue
  fi

  # ── Renderable cells ────────────────────────────────────────────────
  #
  # 1. IT ACTUALLY RENDERED, AND RENDERED SOMETHING. A cell that produced no
  #    services would make every count below 0, and a `check 0` would then pass
  #    on nothing. This is the anti-vacuous-pass gate and it runs first.
  check 0 "$RC" "$NAME: renders"
  SVC_COUNT="$(printf '%s\n' "$SERVICES" | grep -c . || true)"
  if [ "$RC" -ne 0 ] || [ "$SVC_COUNT" -lt 10 ]; then
    fail "$NAME: render produced $SVC_COUNT services — every assertion below would be vacuous. Error: $(printf '%s' "$ERRTEXT" | tail -1)"
  else
    ok "$NAME: render is non-empty ($SVC_COUNT services)"
  fi

  # 2. The services this cell is named after are present. Names, not just a
  #    count: a render that lost the gateway and gained two postgres containers
  #    would keep the count plausible.
  EXPECT_SVCS="$BASE_EMITTERS"
  [ "$HAS_SELF" = 1 ] && EXPECT_SVCS="$EXPECT_SVCS sandbox-b"
  MISSING_SVCS=""
  for s in $EXPECT_SVCS; do
    printf '%s\n' "$SERVICES" | grep -qx "$s" || MISSING_SVCS="$MISSING_SVCS $s"
  done
  check "" "$MISSING_SVCS" "$NAME: every expected emitter service is in the render"

  # 3. The witness is present exactly when this cell says it should be.
  GOT_WITNESS="$(printf '%s\n' "$SERVICES" | grep -c '^veil-witness$' || true)"
  check "$WANT_WITNESS" "$GOT_WITNESS" "$NAME: local witness presence"

  JSON="$(render_json_cell "$FILES" "" "$EXTRA" "$CELL_ENV" || true)"

  # 4. ADDRESS — HIGH 3. Every emitter must dial the address this cell implies:
  #    the central one under the overlay, the local one without it. The count is
  #    positive so an empty render fails, and it is compared against the DERIVED
  #    emitter count so adding sandbox-b to a topology cannot go unnoticed.
  #
  #    ⚠️ sandbox-b's LCR_WITNESS_ADDR was the literal `veil-witness:50057` until
  #    2026-07-28. The overlay cannot repoint it — it must not declare a
  #    `sandbox-b:` block, because it is also applied without
  #    docker-compose.self-hosted.yml where such a block would create an
  #    imageless service. So the interpolation lives in
  #    docker-compose.self-hosted.yml and THIS is the assertion that holds it:
  #    left hardcoded, the customer+self-hosted+witness-central row below drops
  #    to 4/5 and fails.
  check "$EMITTERS" "$(svc_env_count "$JSON" LCR_WITNESS_ADDR)" \
    "$NAME: every emitter declares LCR_WITNESS_ADDR"
  check "$EMITTERS" "$(svc_env_eq_count "$JSON" LCR_WITNESS_ADDR "$WANT_ADDR")" \
    "$NAME: every emitter dials $WANT_ADDR"

  # 5. LATCH + CREDENTIAL TRIPLE reach every emitter (the witness carries the
  #    latch too, for its own server side).
  check "$((EMITTERS + WANT_WITNESS))" "$(svc_env_count "$JSON" LCR_WITNESS_REQUIRE_MTLS)" \
    "$NAME: the mTLS latch is wired into every emitter and the witness"
  for v in LCR_WITNESS_MTLS_CA_BUNDLE_PATH LCR_WITNESS_MTLS_CLIENT_CERT_PATH \
           LCR_WITNESS_MTLS_CLIENT_KEY_PATH; do
    check "$EMITTERS" "$(svc_env_count "$JSON" "$v")" \
      "$NAME: $v is wired into every emitter"
  done

  if [ "$HAS_OVER" = 0 ]; then
    # 6. STOCK: the latch renders as an explicit, legible `false` — not "",
    #    which is also off but leaves an operator unable to answer "is this
    #    latched?" from the rendered config.
    check "$((EMITTERS + WANT_WITNESS))" "$(svc_env_eq_count "$JSON" LCR_WITNESS_REQUIRE_MTLS false)" \
      "$NAME: an unconfigured stock install renders the latch as an explicit false"
    # And the witness ACL surface is wired into the witness itself.
    for v in LCR_WITNESS_EXPORT_ALLOWED_PEERS LCR_WITNESS_CERT_ALLOWED_PEERS \
             LCR_WITNESS_CLAIM_ALLOWED_PEERS LCR_WITNESS_EXPORT_CUSTOMER_MAP \
             LCR_WITNESS_EXPORT_CUSTOMER_BINDING LCR_WITNESS_EXPORT_MAX_CERTS \
             LCR_WITNESS_PEER_IDENTITY LCR_WITNESS_AUDIT_LOG_HMAC_KEY; do
      check 1 "$(svc_env_count "$JSON" "$v")" "$NAME: witness carries $v"
    done
  else
    # 7. OVERLAY: the four emitters the overlay CAN declare are latched and
    #    carry the claim-hop credential path.
    check 4 "$(svc_env_eq_count "$JSON" LCR_WITNESS_REQUIRE_MTLS true)" \
      "$NAME: the four overlay-declared emitters have the latch engaged"
    check 4 "$(svc_env_eq_count "$JSON" LCR_WITNESS_MTLS_CLIENT_CERT_PATH /etc/lucairn/witness-client/client.pem)" \
      "$NAME: the four overlay-declared emitters carry the claim-hop credential"

    if [ "$HAS_SELF" = 1 ]; then
      # 7b. THE PINNED RESIDUAL — 2026-07-28 review, HIGH 3 tail.
      #
      # The overlay mounts the claim credential into audit, id-bridge, sanitizer
      # and gateway. It CANNOT mount it into sandbox-b, because it must not
      # declare that service at all. So on the full on-prem set sandbox-b
      # renders with an EMPTY credential triple and, at the default latch, a
      # DIFFERENT latch value from its four peers.
      #
      # This is asserted rather than fixed, deliberately. It is a documented
      # operator step (docs/WITNESS_CENTRAL_RUNBOOK.md § 7b), and the compose
      # file must NOT paper over it with a default bind mount: Docker
      # materialises a bind mount of a non-existent host path as an EMPTY
      # DIRECTORY rather than an error, which would convert "no credential" into
      # "a mount that looks present and reads empty".
      #
      # Pinning it here means the day someone provisions it properly, this check
      # fails and forces the docs to be updated with it.
      check "sandbox-b=" "$(svc_env_map "$JSON" LCR_WITNESS_MTLS_CLIENT_CERT_PATH | grep '^sandbox-b=' || true)" \
        "$NAME: sandbox-b's claim credential is EMPTY (documented operator step, runbook § 7b)"
      check "sandbox-b=false" "$(svc_env_map "$JSON" LCR_WITNESS_REQUIRE_MTLS | grep '^sandbox-b=' || true)" \
        "$NAME: sandbox-b's latch is not inherited from the overlay (same reason)"
      # ...but its ADDRESS is repointed, which is the half that IS fixed.
      check "sandbox-b=$CENTRAL_ADDR" "$(svc_env_map "$JSON" LCR_WITNESS_ADDR | grep '^sandbox-b=' || true)" \
        "$NAME: sandbox-b dials the CENTRAL witness (HIGH 3)"
    fi

    # 8. ORDERING IS PRESERVED — BLOCKER 1. `required: false` relaxes only the
    #    "the service must exist" half; the health condition must survive, or the
    #    stock LAN topology silently loses its start ordering.
    if [ "$HAS_SELF" = 1 ]; then
      DEP="$(printf '%s' "$JSON" | jq -c '.services["sandbox-b"].depends_on["veil-witness"] // "absent"')"
      check '{"condition":"service_healthy","required":false}' "$DEP" \
        "$NAME: sandbox-b keeps condition:service_healthy AND required:false"
    fi
  fi

  CELL_ROWS="${CELL_ROWS}${NAME}|render|rc=$RC svcs=$SVC_COUNT|witness=$GOT_WITNESS
"
done <<EOF
$(printf '%s' "$CELLS")
EOF

# BLOCKER 1, the other half: the stock topology's ordering edge must ALSO still
# carry the health condition when the overlay is NOT applied. Asserted outside
# the loop because it is the before-state of the differential above.
FULLSET_JSON="$(docker compose -f "$BASE" -f "$SELFHOSTED" --env-file "$STOCK_ENV" config --format json 2>/dev/null || true)"
check '{"condition":"service_healthy","required":false}' \
  "$(printf '%s' "$FULLSET_JSON" | jq -c '.services["sandbox-b"].depends_on["veil-witness"] // "absent"')" \
  "stock customer+self-hosted still waits for a healthy witness (required:false is not condition-less)"

echo
echo "-- overlay-only structural assertions (canonical cell: customer + witness-central)"

# ── The differential ────────────────────────────────────────────────
#
# The overlay must remove the witness and NOTHING else. A profile typo on the
# wrong service would show up here as a second disappearance.
BASE_SERVICES="$(docker compose -f "$BASE" --env-file "$STOCK_ENV" config --services 2>/dev/null || true)"
OVER_SERVICES="$(docker compose -f "$BASE" -f "$OVERLAY" --env-file "$ENVFILE" config --services 2>/dev/null || true)"
MISSING="$(comm -23 <(printf '%s\n' "$BASE_SERVICES" | sort) <(printf '%s\n' "$OVER_SERVICES" | sort) | tr '\n' ' ' | sed 's/ *$//' || true)"
check "veil-witness" "$MISSING" "the overlay removes veil-witness and nothing else"

JSON="$(docker compose -f "$BASE" -f "$OVERLAY" --env-file "$ENVFILE" config --format json 2>/dev/null || true)"

# The gateway must not still be reading certificates from a witness that is not
# in the project.
check 0 "$(svc_env_eq_count "$JSON" LCR_WITNESS_CERT_ADDR veil-witness:50058)" \
  "the gateway no longer reads certificates from the local witness"

# ── The two hops use DIFFERENT credentials ──────────────────────────
#
# 2026-07-28 adversarial review, BLOCKER B. The overlay used to point the
# gateway's WITNESS_MTLS_* triple at /etc/lucairn/witness-client — the same
# three files the claim hop mounts into audit, id-bridge and sanitizer. That is
# not a wiring shortcut, it defeats the per-method authorization this whole
# slice adds:
#
#   - The witness's latched :50058 ACL admits CN `gateway` and nothing else
#     (authz.go defaultLatchedCertPeers), and the device leaf is
#     CN=lucairn-device-<name> — so certificate reads break.
#   - Repairing that by allowlisting the device CN grants ExportCertificates,
#     GetCertificate and VerifyCertificate to EVERY container holding that same
#     private key, sanitizer included. A shared identity is one identity; the
#     witness cannot authorise what it cannot distinguish.
#
# These assertions are computed from the render, not hardcoded against literal
# paths, so they keep meaning if the paths are renamed.
check 1 "$(svc_env_count "$JSON" WITNESS_MTLS_CLIENT_CERT_PATH)" \
  "exactly one service (the gateway) carries a :50058 client credential"
check 1 "$(printf '%s' "$JSON" | jq -r '[.services.gateway.environment | select(has("WITNESS_MTLS_CLIENT_CERT_PATH"))] | length')" \
  "and that service is the gateway"

GW_CERT="$(printf '%s' "$JSON" | jq -r '.services.gateway.environment.WITNESS_MTLS_CLIENT_CERT_PATH // ""')"
GW_KEY="$(printf '%s'  "$JSON" | jq -r '.services.gateway.environment.WITNESS_MTLS_CLIENT_KEY_PATH  // ""')"
GW_CA="$(printf '%s'   "$JSON" | jq -r '.services.gateway.environment.WITNESS_MTLS_CA_BUNDLE_PATH   // ""')"

# ⚠️ NOT a non-emptiness check. The BASE compose already declares all three of
# these as `${WITNESS_MTLS_...:-}`, so deleting the overlay's override leaves
# the key present in the render with the value `""` — a mutation run proved a
# `[ -n "$GW_CA" ]` test SURVIVES exactly that. Under the latch an empty CA
# bundle is a gateway boot failure, so the deployment is broken rather than
# insecure, but a test that cannot see it is not testing the wiring.
#
# Assert the CONCLUSION instead: all three paths resolve INTO one directory, and
# that directory is the certificate-hop mount — which is false for an empty
# value, for a partially-reverted triple, and for a triple split across two
# directories.
#
# An empty value maps to the literal <empty> rather than being skipped: dropping
# empties is how the FIRST version of this check let the same mutant through a
# second time. A missing member must widen the set, not silently leave it.
GW_DIRS="$(printf '%s\n%s\n%s\n' "$GW_CA" "$GW_CERT" "$GW_KEY" \
  | while IFS= read -r p; do
      if [ -z "$p" ]; then printf '<empty>\n'; else dirname "$p"; fi
    done \
  | sort -u | tr '\n' ' ' | sed 's/ *$//')"
check "/etc/lucairn/witness-gateway-client" "$GW_DIRS" \
  "the gateway's :50058 triple (CA + cert + key) all resolve into the cert-hop directory"

# Not one of the claim-hop paths, on ANY service. Counting collisions rather
# than comparing to a literal means a future edit that repoints the claim hop
# INTO the gateway directory fails here too.
check 0 "$(svc_env_eq_count "$JSON" LCR_WITNESS_MTLS_CLIENT_CERT_PATH "$GW_CERT")" \
  "no service's claim-hop cert path equals the gateway's :50058 cert path"
check 0 "$(svc_env_eq_count "$JSON" LCR_WITNESS_MTLS_CLIENT_KEY_PATH "$GW_KEY")" \
  "no service's claim-hop KEY path equals the gateway's :50058 key path"

# The private key is the identity. Same directory ⇒ same key ⇒ same identity,
# even if the filenames were made to differ.
GW_KEY_DIR="$(dirname "${GW_KEY:-/nonexistent/x}")"
check 0 "$(printf '%s' "$JSON" | jq -r --arg d "$GW_KEY_DIR/" '
  [.services[] | select(((.environment // {}).LCR_WITNESS_MTLS_CLIENT_KEY_PATH // "") | startswith($d))] | length')" \
  "no service's claim-hop key lives in the gateway's :50058 credential directory"

# And the gateway's own claim hop is STILL the device credential — the fix must
# separate the cert hop, not move the claim hop.
check 4 "$(svc_env_eq_count "$JSON" LCR_WITNESS_MTLS_CLIENT_KEY_PATH /etc/lucairn/witness-client/client.key)" \
  "the gateway's CLAIM hop still uses the shared per-device credential"

# ── Mounts, not just env ────────────────────────────────────────────
#
# Env paths and volume mounts are independent failure modes: a service can be
# given the path without the mount (file-not-found at boot) or the mount without
# the path (the credential is present in a container that should not hold it,
# which is the security-relevant half). Assert the mounts directly.
if [ -z "$JSON" ]; then
  fail "the JSON render produced nothing — the per-service mount assertions cannot run"
else
  MOUNTERS="$(printf '%s' "$JSON" | jq -r --arg t "$GW_KEY_DIR" '
    .services | to_entries[]
    | select((.value.volumes // []) | any(.target == $t))
    | .key' | sort | tr '\n' ' ' | sed 's/ *$//')"
  check "gateway" "$MOUNTERS" "ONLY the gateway mounts the :50058 credential directory"

  # Read-only, because a writable mount of a credential directory lets a
  # compromised gateway replace the leaf it authenticates with.
  #
  # `all` over an EMPTY list is true, so the emptiness is asserted separately —
  # otherwise deleting the mount would satisfy this check rather than fail it,
  # and a vacuous pass is the failure mode this whole file was written against.
  RO="$(printf '%s' "$JSON" | jq -r --arg t "$GW_KEY_DIR" '
    [.services.gateway.volumes[] | select(.target == $t) | (.read_only // false)]
    | (length > 0) and all')"
  check "true" "$RO" "the gateway's :50058 credential directory is mounted, and read-only"

  # The claim-hop directory is mounted by exactly the four emitters and nobody
  # else — the before-state of the differential, so "only the gateway mounts the
  # cert dir" cannot pass by the claim mounts having silently vanished.
  CLAIM_MOUNTERS="$(printf '%s' "$JSON" | jq -r --arg t /etc/lucairn/witness-client '
    .services | to_entries[]
    | select((.value.volumes // []) | any(.target == $t))
    | .key' | sort | tr '\n' ' ' | sed 's/ *$//')"
  check "audit gateway id-bridge sanitizer" "$CLAIM_MOUNTERS" \
    "exactly the four emitters mount the claim-hop credential directory"

  # The two directories are distinct on the HOST as well. Pointing both env vars
  # at one host path would satisfy every container-path assertion above while
  # putting the identical key behind both mounts.
  GW_SRC="$(printf '%s' "$JSON" | jq -r --arg t "$GW_KEY_DIR" '
    .services.gateway.volumes[] | select(.target == $t) | .source')"
  CLAIM_SRC="$(printf '%s' "$JSON" | jq -r --arg t /etc/lucairn/witness-client '
    .services.gateway.volumes[] | select(.target == $t) | .source')"
  if [ -n "$GW_SRC" ] && [ "$GW_SRC" != "$CLAIM_SRC" ]; then
    ok "the two hops resolve to different HOST directories ($CLAIM_SRC vs $GW_SRC)"
  else
    fail "both hops resolve to the same host directory ($GW_SRC) — one key, one identity"
  fi
fi

# ── The dev-only profile is LOUD about what it restores ─────────────
#
# 2026-07-28 review, BLOCKER 1 second half. Activating
# `--profile witness-local-dev-only` puts the local witness back, which is
# SELF-SIGNED EVIDENCE: the operator signs certificates about their own conduct.
# The operator who reaches for that flag is, by construction, someone who did
# not read the overlay file — they hit a compose error and searched for
# something that made it go away.
#
# ⚠️ A `${VAR:?...}` acknowledgement gate is NOT usable here, and that was
# MEASURED rather than assumed: Compose interpolates every service in a file
# regardless of profile, so a `:?` inside the profiled `veil-witness` block
# fires for EVERY cell including the ones that never start it. A `labels:` entry
# is the one channel that is inert at render time and still visible in
# `docker compose config`, `docker inspect` and `docker ps --filter label=`.
#
# It is asserted against the PROFILE-ACTIVE render because Compose omits
# profiled-out services from the default render entirely — so the label is
# visible exactly when the profile is on, which is when it matters.
DEV_JSON="$(docker compose -f "$BASE" -f "$OVERLAY" --env-file "$ENVFILE" \
  --profile witness-local-dev-only config --format json 2>/dev/null || true)"
DEV_LABEL="$(printf '%s' "$DEV_JSON" | jq -r '.services["veil-witness"].labels["eu.lucairn.witness.local-profile.warning"] // ""')"
case "$DEV_LABEL" in
  *"SELF-SIGNED EVIDENCE"*) ok "the dev-only witness carries a label naming SELF-SIGNED EVIDENCE" ;;
  *) fail "the profiled veil-witness has no warning label naming SELF-SIGNED EVIDENCE (got: ${DEV_LABEL:-<none>})" ;;
esac
case "$DEV_LABEL" in
  *witness-local-dev-only*) ok "the warning label names the profile that activates it" ;;
  *) fail "the warning label does not name the witness-local-dev-only profile" ;;
esac
case "$DEV_LABEL" in
  *"OFFLINE DEMOS ONLY"*|*"offline demos only"*) ok "the warning label states it is for offline demos only" ;;
  *) fail "the warning label does not say the topology is demo-only" ;;
esac

# ── Fail-closed: the required variables really are required ─────────
#
# Every candidate default is worse than a failed render: defaulting to the
# claim-hop directory silently restores the shared-identity state (render
# succeeds, containers start, the security property is quietly false), and a
# fixed path default becomes a bind mount of a directory Docker creates EMPTY,
# so the gateway dies at boot on a path nobody configured.
#
# Its old default for the cert ADDRESS was the local witness. With no local
# witness that default would resolve to a service that does not exist, and the
# failure would arrive at request time as a connection error rather than at
# config time as a configuration error.
for req in LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR LUCAIRN_CENTRAL_WITNESS_CERT_ADDR \
           LUCAIRN_CENTRAL_WITNESS_ADDR LUCAIRN_WITNESS_CLIENT_CERT_DIR; do
  STRIPPED="$WK/no-$req.env"
  grep -v "^${req}=" "$ENVFILE" > "$STRIPPED"
  if docker compose -f "$BASE" -f "$OVERLAY" --env-file "$STRIPPED" config >/dev/null 2>&1; then
    fail "omitting $req still renders under the overlay — it must fail closed"
  else
    ok "omitting $req fails the overlay render"
  fi
done

# ── Per-service credentials must be EXPRESSIBLE ─────────────────────
#
# Round 2, SEC-003. One shared client leaf across every emitter collapses the
# per-emitter claim allowlist to a single identity: any container on the host
# can then submit claims as any allowlisted emitter. The device-wide triple
# stays as the fallback (a genuine one-credential laptop still works); what this
# asserts is that an operator CAN bind each emitter to its own leaf without
# editing compose, mirroring what the :50058 hop has always done.
#
# sandbox-b is included because docker-compose.self-hosted.yml gives it the same
# LCR_WITNESS_MTLS_SANDBOX_B_* override slot, and that slot is the mechanism the
# runbook's § 7b operator step tells the customer to use.
#
# ⚠️ ROUND 5, LOW 1 — WHY ALL THREE SOURCES AND NOT JUST THE CERTIFICATE. This
# block used to set and assert only *_CLIENT_CERT_PATH. Every emitter reads a
# TRIPLE (CA + leaf + key), each with its own `${PER_SERVICE:-${GLOBAL:-}}`
# chain in compose, and the fallback is what makes a partial override invisible:
# misspell LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_KEY_PATH and the destination
# variable is still populated — from the DEVICE-WIDE key. The container starts,
# the render looks correct, and sandbox-b presents its own leaf with somebody
# else's key. That handshake fails, and (per the Python half of this slice) an
# unusable credential used to mean "serve normally, submit zero claims" rather
# than a visible error. A one-of-three assertion cannot see any of it. Assert
# the whole triple, per source, on both the override and the fallback path.
PSENV="$WK/perservice.env"
cat "$STOCK_ENV" > "$PSENV"
# The three device-wide slots, all distinguishable from the per-service values
# so a silent fallback is a VISIBLE prefix change rather than an empty string.
echo 'LCR_WITNESS_MTLS_CA_BUNDLE_PATH=/global/ca.pem' >> "$PSENV"
echo 'LCR_WITNESS_MTLS_CLIENT_CERT_PATH=/global/client.pem' >> "$PSENV"
echo 'LCR_WITNESS_MTLS_CLIENT_KEY_PATH=/global/client.key' >> "$PSENV"
for svc in audit id-bridge sanitizer gateway sandbox-b; do
  upper="$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')"
  echo "LCR_WITNESS_MTLS_${upper}_CA_BUNDLE_PATH=/per/${svc}-ca.pem" >> "$PSENV"
  echo "LCR_WITNESS_MTLS_${upper}_CLIENT_CERT_PATH=/per/${svc}.pem" >> "$PSENV"
  echo "LCR_WITNESS_MTLS_${upper}_CLIENT_KEY_PATH=/per/${svc}.key" >> "$PSENV"
done
PS_JSON="$(docker compose -f "$BASE" -f "$SELFHOSTED" --env-file "$PSENV" config --format json 2>/dev/null || true)"

# Count services whose <var> starts with <prefix>. Positive-count by
# construction (see the VACUOUS PASSES note at the top): an empty render yields
# 0 and fails every check below rather than passing one of them.
svc_env_prefix_count() {
  printf '%s' "$1" | jq -r --arg v "$2" --arg p "$3" '
    [.services[] | select((((.environment // {})[$v]) // "") | startswith($p))] | length'
}

for var in LCR_WITNESS_MTLS_CA_BUNDLE_PATH \
           LCR_WITNESS_MTLS_CLIENT_CERT_PATH \
           LCR_WITNESS_MTLS_CLIENT_KEY_PATH; do
  check 5 "$(svc_env_prefix_count "$PS_JSON" "$var" /per/)" \
    "each emitter incl. sandbox-b can be given its own $var (per-service override wins)"
  # THE MUTATION THIS CLOSES, stated as its own assertion so the failure names
  # the cause rather than an off-by-one count: not one emitter may still be
  # carrying the device-wide value once every per-service slot is set.
  check 0 "$(svc_env_prefix_count "$PS_JSON" "$var" /global/)" \
    "no emitter silently falls back to the device-wide $var when its own is set"
done

FALLBACK_JSON="$(docker compose -f "$BASE" -f "$SELFHOSTED" --env-file "$STOCK_ENV" config --format json 2>/dev/null || true)"
for var in LCR_WITNESS_MTLS_CA_BUNDLE_PATH \
           LCR_WITNESS_MTLS_CLIENT_CERT_PATH \
           LCR_WITNESS_MTLS_CLIENT_KEY_PATH; do
  check 5 "$(svc_env_count "$FALLBACK_JSON" "$var")" \
    "the device-wide $var slot is still wired when no per-service leaf is set"
done

echo
echo "-- documentation assertions"

# ⚠️ NORMALISED, not a line grep. These files are comment prose wrapped at ~78
# columns, so a sentence spans a newline and a leading "# ". A line-oriented
# `grep -q` does not see it: several of these checks were written as plain greps
# first and a mutation run proved they SURVIVED restoring the offending
# paragraph verbatim. Strip comment markers, fold to one line, collapse
# whitespace, then match.
# ⚠️ STRIPS BOTH `# ` AND `> `. The comment-prose rationale above applies
# verbatim to markdown blockquotes: the runbook's loudest warnings are `> `
# blocks wrapped at ~78 columns, so a folded sentence reads "...renders
# `peer_ids=gateway`, with > nothing after it." Three assertions below were
# written against the unfolded text first and failed on exactly that; leaving
# the marker in would have pushed them back to being line greps.
prose() { sed -E 's/^[[:space:]]*[#>][[:space:]]?//' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '; }
ENV_PROSE="$(prose "$ENV_EXAMPLE")"
RUNBOOK_PROSE="$(prose "$RUNBOOK")"
CUSTOMER_PROSE="$(prose "$CUSTOMER_ENV_EXAMPLE")"
OVERLAY_PROSE="$(prose "$OVERLAY")"
SELFHOSTED_PROSE="$(prose "$SELFHOSTED")"

has() { # haystack needle description
  case "$1" in *"$2"*) ok "$3" ;; *) fail "$3 (missing: $2)" ;; esac
}
hasnt() { case "$1" in *"$2"*) fail "$3" ;; *) ok "$3" ;; esac }

# --- the credential directories -------------------------------------
#
# The compose file can enforce SEPARATE. It cannot enforce CORRECT: the leaf in
# that directory must carry CN=gateway, because that is the witness's latched
# certificate-RPC allowlist. A separate directory holding another device leaf
# fails closed but wastes the operator's evening, and the tempting repair is the
# one that reopens the hole.
has "$ENV_PROSE"     LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR "env example declares the gateway credential directory"
has "$RUNBOOK_PROSE" LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR "runbook's ceremony provisions the gateway credential directory"
case "$RUNBOOK_PROSE" in
  *"CN=gateway"*|*'CN is EXACTLY `gateway`'*|*'CN must be exactly `gateway`'*)
    ok "runbook states the certificate-hop CN must be gateway" ;;
  *) fail "runbook does not state that the :50058 leaf must carry CN=gateway" ;;
esac
# The instruction that reproduced the flaw must be gone, and its replacement
# must not be a paraphrase of it.
case "$ENV_PROSE" in
  *"same three files serve both hops"*|*"serve both hops"*|*"same three files"*)
    fail "env example still tells the operator one credential serves both hops" ;;
  *) ok "env example no longer claims one credential serves both hops" ;;
esac
has "$RUNBOOK_PROSE"  "NEVER ADD A DEVICE CN"        "runbook forbids allowlisting a device CN for certificate reads"
has "$CUSTOMER_PROSE" "NEVER add a per-device CN here" "customer.env.example warns against adding a device CN to the export allowlist"

# --- SEC-002: per-device identity on the certificate hop -------------
#
# 2026-07-28, HIGH 1. §3.4 used to mint every device's cert-hop leaf as
# /O=Lucairn/CN=gateway with NO subjectAltName, so the witness's
# peerIdentities() returned exactly {"gateway"} fleet-wide and
# LCR_WITNESS_EXPORT_CUSTOMER_MAP had one possible key — "every device gets
# every tenant". At N>=2 devices any laptop operator could export another
# consultant's tenant, RedactionManifestBody included.
#
# The mechanism was verified against the witness source, not assumed:
# peerIdentities appends leaf.DNSNames only when MatchSANs is true, MatchSANs is
# latch-derived (parsePeerIdentity("", latched) returns latched), authorizePeer
# still admits on the CN so the shared allowlist entry keeps working, and
# authorizeCustomer walks [CN, ...SANs] FIRST-MATCH — which is why the map must
# never be keyed on the bare `gateway`.
case "$RUNBOOK_PROSE" in
  *"subjectAltName=DNS:lucairn-gateway-"*)
    ok "runbook §3.4 mints the cert-hop leaf with a per-device subjectAltName" ;;
  *) fail "runbook §3.4 has no per-device subjectAltName on the certificate-hop leaf (SEC-002)" ;;
esac
# The verification step, without which a missing SAN is silent.
has "$RUNBOOK_PROSE" "-ext subjectAltName" \
  "runbook tells the operator to verify the SAN landed on the issued leaf"
# ⚠️ AND THE QUOTING. §3.2 and §3.3 single-quote their printf because they have
# nothing to expand; §3.4 MUST double-quote, or ${DEVICE} does not expand and
# every device is issued the literal SAN `lucairn-gateway-${DEVICE}` — identical
# fleet-wide, which is precisely the state SEC-002 exists to end, reached by a
# one-character edit that looks like a consistency cleanup. Asserted on the raw
# file rather than the prose: the quote characters are the whole content of the
# check, and prose() would keep them but the surrounding line context is what
# makes it unambiguous.
if grep -qF -- '-extfile <(printf "subjectAltName=DNS:lucairn-gateway-${DEVICE}' "$RUNBOOK"; then
  ok "runbook §3.4's extfile is DOUBLE-quoted so \${DEVICE} actually expands"
else
  fail "runbook §3.4's extfile is not double-quoted — \${DEVICE} would not expand, giving every device the same literal SAN"
fi
# The customer map must be keyed on device identities, NOT the bare CN.
case "$RUNBOOK_PROSE" in
  *"LCR_WITNESS_EXPORT_CUSTOMER_MAP=lucairn-gateway-"*)
    ok "runbook §4.1's customer map is keyed on per-device identities" ;;
  *) fail "runbook §4.1's customer map example is not keyed on a per-device identity (SEC-002)" ;;
esac
hasnt "$RUNBOOK_PROSE" "LCR_WITNESS_EXPORT_CUSTOMER_MAP=gateway=" \
  "runbook §4.1 no longer keys the customer map on the fleet-wide gateway CN"
case "$RUNBOOK_PROSE" in
  *"IS AT BEST REDUNDANT"*)
    ok "runbook states in bold what mapping the bare gateway CN does (round 4: redundant, not a grant)" ;;
  *) fail "runbook does not state the bare \`gateway\` map-key rule in bold" ;;
esac
# And the honest limit: the audit line still prints the CN, so this is NOT
# per-device attribution in logs yet.
# ROUND 4 (DSA-side, verified against authz.go @cf72fcf76): the export audit
# record now carries `peer_ids=` — every identity on the verified leaf, joined
# with `+` — because `peer=` alone is the CommonName and §3.4 makes that
# identical fleet-wide. A device minted the OLD way renders `peer_ids=gateway`
# with nothing after it, which is how an operator DISCOVERS the ceremony predates
# the SAN. The runbook must show both, and must still be honest that the CLAIM
# path records no device identity at all.
has "$RUNBOOK_PROSE" "peer_ids=gateway+lucairn-gateway-" \
  "runbook shows the peer_ids= audit field with a per-device SAN"
has "$RUNBOOK_PROSE" "renders \`peer_ids=gateway\`, with nothing after it" \
  "runbook explains that a bare peer_ids=gateway means the leaf predates the SAN ceremony"
has "$RUNBOOK_PROSE" "CLAIM path still records no device identity at all" \
  "runbook is honest that per-device attribution covers export only, not claims"

# ROUND 4, SEC-003: the pseudonym is LOG-ONLY and the caller-side status carries
# a request-scoped random `corr=` token instead. Telling an operator to grep a
# caller-side error for customer_ref sends them looking for a string that is not
# there — and the old behaviour was a chosen-plaintext oracle over the audit key.
has "$RUNBOOK_PROSE" "grep \`corr=\`" \
  "runbook tells the operator to correlate a caller-side refusal with corr=, not customer_ref"
has "$RUNBOOK_PROSE" "customer_ref\` is LOG-ONLY" \
  "runbook states customer_ref never appears in the status returned to the caller"

# ROUND 4, SEC-002 tail: authorizeCustomer now requires EVERY mapped identity on
# the leaf to allow the customer_id (intersection), so the narrowest mapping
# wins. Mapping the shared CN went from silent fleet-wide grant to redundant —
# the advice is unchanged (map the SAN) but the REASON changed, and a runbook
# that still says "collapses the binding" describes a version that is not
# running.
has "$RUNBOOK_PROSE" "every MAPPED identity on the leaf must allow" \
  "runbook documents the intersection rule (every mapped identity must allow)"
has "$RUNBOOK_PROSE" "NARROWEST mapping wins" \
  "runbook states the narrowest mapping wins"
# ⚠️ §3.4 EXPLAINS THE SAME MECHANISM AND MUST NOT CONTRADICT §4.1. It described
# the pre-round-4 first-match rule ("stops at the FIRST identity that has a map
# entry") long after the code stopped doing that — two sections of one runbook
# giving opposite accounts of the control that decides who reads a tenant's PII.
# A doc-vs-doc contradiction has no compiler; this is its compiler.
hasnt "$RUNBOOK_PROSE" "stops at the FIRST identity that has a map entry" \
  "runbook §3.4 no longer describes the superseded first-match binding rule"
has "$RUNBOOK_PROSE" "requires EVERY identity that has a map entry to allow" \
  "runbook §3.4 describes the same intersection rule as §4.1"

# ROUND 4: CertTransportError widened from the two allowlists to any FAIL-OPEN
# :50058 control. Five variables now refuse boot; the HMAC key still only warns.
# Documenting the narrow version would leave an operator surprised by a refusal
# on a variable the docs called safe.
#
# ⚠️ ROUND 5 — THIS GUARD WAS SATISFIED BY A FALSE CLAIM, and that is the reason
# the second half below exists. The refusal is NOT absolute: round 5 exempted
# values that are semantically identical to leaving the variable unset
# (BINDING=off, MAX_CERTS=0, and the customer map while the binding is off),
# because refusing there BRICKS a deployment that deliberately disabled a
# control rather than protecting one. Both documents went on asserting the
# opposite — "there is deliberately no carve-out for writing the permissive
# value" — and this guard could not see it, because that very sentence CONTAINS
# "refuses to start". A substring check for the rule was being satisfied by the
# sentence that contradicted it.
#
# So the assertion is now a conjunction: the refusal rule AND its exception must
# both appear, and the superseded absolute claim must not. Reverting either
# document to the round-4 wording fails here rather than in a customer's config.
for f in RUNBOOK_PROSE CUSTOMER_PROSE; do
  eval "hay=\"\$$f\""
  # shellcheck disable=SC2154  # hay is assigned by the eval directly above
  case "$hay" in
    *"LCR_WITNESS_EXPORT_MAX_CERTS"*)
      case "$hay" in
        *"BOOT FAILURE"*|*"refuses to start"*|*"refusing to start"*)
          ok "$f names the widened :50058 fail-open boot refusal" ;;
        *) fail "$f does not state that the :50058 controls refuse boot when WITNESS_MTLS_* does not resolve" ;;
      esac ;;
    *) fail "$f does not name LCR_WITNESS_EXPORT_MAX_CERTS among the :50058 controls" ;;
  esac

  # HALF 2 — the exception, stated and made concrete. "Concrete" is the point:
  # a document may not gesture at "some exceptions" and leave the operator to
  # discover which, so a neutral VALUE has to be spelled out.
  has "$hay" "semantically IDENTICAL to leaving the variable unset" \
    "$f documents the neutral-value exception to the :50058 boot refusal"
  has "$hay" "MAX_CERTS=0" \
    "$f names a concrete neutral value that is exempt from the refusal"

  # HALF 3 — the superseded absolute claim must be gone. Without this, a doc
  # could carry both the new exception and the old "no carve-out" sentence and
  # satisfy every positive check above while still telling the operator that
  # BINDING=off stops the boot.
  hasnt "$hay" "carve-out for writing the permissive value" \
    "$f no longer claims the :50058 refusal has no permissive-value carve-out"
done
has "$RUNBOOK_PROSE" "LCR_WITNESS_AUDIT_LOG_HMAC_KEY is the exception" \
  "runbook records that the audit HMAC key warns rather than refusing boot"

# The COMPOSE FLOOR. `depends_on.<svc>.required` is v2.20.0+, and older clients
# do NOT ignore the unknown key — MEASURED 2026-07-28: v2.19.1 refuses the file
# with "Additional property required is not allowed", v2.20.0 and v2.20.3 accept
# it. That breaks the STOCK full on-prem set, not only witness-central, so the
# prerequisite had to move from "Docker Compose v2" to an explicit floor.
INSTALL_PROSE="$(prose INSTALL.md)"
has "$INSTALL_PROSE" "Docker Compose v2.20.0 or newer" \
  "INSTALL.md states the v2.20.0 Compose floor that depends_on.required requires"
has "$INSTALL_PROSE" "Additional property required is not allowed" \
  "INSTALL.md shows the exact error an older Compose client produces"
has "$SELFHOSTED_PROSE" "v2.20.0" \
  "docker-compose.self-hosted.yml records the Compose floor beside the required: key"

# T-243 (board): the same v2.20.0 floor was documented in INSTALL.md but left
# STALE — "Docker Compose v2" with no number — in the two other operator-facing
# entry points that also run `-f docker-compose.self-hosted.yml`. A guard that
# only checked INSTALL.md would keep passing while an operator following either
# runbook hit the raw schema error with no warning. This is the differential
# that closes that gap: assert the SAME floor + SAME error text in both.
CUSTOMER_RUNBOOK_PROSE="$(prose docs/CUSTOMER_INSTALL_RUNBOOK.md)"
CLEAN_HOST_PROSE="$(prose docs/CLEAN_HOST_REHEARSAL.md)"
for pair in "CUSTOMER_RUNBOOK_PROSE:docs/CUSTOMER_INSTALL_RUNBOOK.md" "CLEAN_HOST_PROSE:docs/CLEAN_HOST_REHEARSAL.md"; do
  varname="${pair%%:*}"
  fname="${pair#*:}"
  hay="$(eval echo "\$$varname")"
  has "$hay" "Docker Compose v2.20.0 or newer" \
    "$fname states the v2.20.0 Compose floor (not just \"Docker Compose v2\")"
  has "$hay" "Additional property required is not allowed" \
    "$fname shows the exact error an older Compose client produces"
  hasnt "$hay" "Docker Compose v2 (" \
    "$fname no longer states the stale unversioned \"Docker Compose v2\" floor"
done

# The preflight script this floor is enforced by. Must exist, be executable,
# and — this is the part a doc-only check cannot prove — actually get the
# comparison right. COMPOSE_VERSION_CMD lets the script be exercised against
# synthetic version strings with no network access and no real old Compose
# binary required, so this runs in any CI. (It was ALSO run by hand in this
# slice against real v2.19.1/v2.20.0/v2.20.3/v5.1.0 binaries — see the PR body
# for that evidence; that part isn't repeatable here without network access.)
CVCHECK="scripts/check-compose-version.sh"
if [ -x "$CVCHECK" ]; then
  ok "$CVCHECK exists and is executable"
else
  fail "$CVCHECK is missing or not executable"
fi

compose_version_case() { # version want_rc label
  # ⚠️ SAME SHARP EDGE AS THE CELL LOOP ABOVE: `cmd; rc=$?` EXITS under
  # `set -e` the moment cmd fails, before the next line ever assigns rc. Half
  # of these cases are SUPPOSED to fail (that's what "REJECTS" is asserting),
  # so written the naive way this function dies on the first rejection case
  # and the run ends with the rest silently unchecked. `&& rc=0 || rc=$?`
  # makes it one compound command, which `set -e` does not act on.
  local ver="$1" want_rc="$2" label="$3" rc
  COMPOSE_VERSION_CMD="echo $ver" "$CVCHECK" >/dev/null 2>&1 && rc=0 || rc=$?
  check "$want_rc" "$rc" "$label"
}
compose_version_case "2.19.1" 1 "check-compose-version.sh REJECTS v2.19.1 (the measured-failing version)"
compose_version_case "2.19.9" 1 "check-compose-version.sh REJECTS v2.19.9 (just under the floor)"
compose_version_case "2.20.0" 0 "check-compose-version.sh ACCEPTS v2.20.0 (exactly the floor)"
compose_version_case "2.20.3" 0 "check-compose-version.sh ACCEPTS v2.20.3 (measured-passing version)"
compose_version_case "5.1.0"  0 "check-compose-version.sh ACCEPTS v5.1.0 (measured-passing version, current major)"
compose_version_case "2.9.0"  1 "check-compose-version.sh REJECTS v2.9.0 (naive string-sort trap: \"2.9\" > \"2.20\" as text, < as a version)"
compose_version_case "garbage" 1 "check-compose-version.sh fails closed on an unparseable version string"

# --- the sandbox-b credential operator step (HIGH 3 residual) --------
#
# The overlay cannot mount a credential into a service it must not define, so
# `full on-prem + witness-central + latch=true` leaves sandbox-b latched with no
# credential. That is a NAMED OPERATOR STEP, documented in three places because
# an operator reaches for whichever one they already have open. Asserting the
# documentation exists is what stops it silently regressing back to a surprise.
for pair in \
  "SELFHOSTED_PROSE|LCR_WITNESS_MTLS_SANDBOX_B_CA_BUNDLE_PATH|docker-compose.self-hosted.yml names the sandbox-b credential variables" \
  "OVERLAY_PROSE|LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_CERT_PATH|the overlay header names the sandbox-b credential step" \
  "ENV_PROSE|LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_KEY_PATH|witness-central.env.example names the sandbox-b credential step" \
  "RUNBOOK_PROSE|LCR_WITNESS_MTLS_SANDBOX_B_CLIENT_CERT_PATH|the runbook names the sandbox-b credential step"; do
  var="${pair%%|*}"; rest="${pair#*|}"; needle="${rest%%|*}"; desc="${rest#*|}"
  # shellcheck disable=SC2154  # assigned by the eval on the line above
  eval "hay=\"\$$var\""
  has "$hay" "$needle" "$desc"
done
# ...and that the mount half is stated too, not just the env half. Paths without
# a mount is a file-not-found at boot.
has "$RUNBOOK_PROSE" "/etc/lucairn/witness-client:ro" \
  "the runbook shows the sandbox-b bind mount, not just the env variables"
# ⚠️ And WHY no default mount ships: Docker materialises a bind mount of a
# non-existent host path as an EMPTY DIRECTORY, which is the exact trap.
case "$RUNBOOK_PROSE" in
  *"empty"*"directory"*|*"EMPTY DIRECTORY"*|*"empty**"*)
    ok "the runbook explains why no default sandbox-b bind mount ships (empty-dir trap)" ;;
  *) fail "the runbook does not explain the empty-directory trap behind the missing default mount" ;;
esac

# --- the dev-only profile, in prose ---------------------------------
#
# Compose owns the wording of the should-not-render error and it names neither
# the overlay nor the profile. So the DOCS have to, and this is that assertion.
has "$RUNBOOK_PROSE" "profile certification"       "runbook names the certification profile as the should-not-render combination"
has "$RUNBOOK_PROSE" "witness-local-dev-only"      "runbook names the dev-only profile"
has "$ENV_PROSE"     "witness-local-dev-only"      "env example names the dev-only profile"
case "$RUNBOOK_PROSE" in
  *"self-signed evidence"*|*"SELF-SIGNED EVIDENCE"*)
    ok "runbook states the dev-only profile restores self-signed evidence" ;;
  *) fail "runbook does not say the dev-only profile restores self-signed evidence" ;;
esac
case "$ENV_PROSE" in
  *"SELF-SIGNED EVIDENCE"*|*"self-signed evidence"*)
    ok "env example states the dev-only profile restores self-signed evidence" ;;
  *) fail "env example does not say the dev-only profile restores self-signed evidence" ;;
esac
# The overlay must still warn that the certification profile re-activates the
# witness — the trap that made the dev-only flag tempting in the first place.
has "$OVERLAY_PROSE" "cert-builder" "overlay warns that the certification profile would re-activate the witness"

# --- the signing-key retirement step --------------------------------
#
# bin/lucairn init generates LCR_WITNESS_SIGNING_KEY for every topology and this
# overlay cannot reach into that generator, so removing it is a manual step. A
# manual step that is not written down is a step that does not happen, and the
# PRD's success criterion is that the laptop holds NO witness signing key.
has "$RUNBOOK_PROSE" "Retire the local signing key" "runbook documents retiring the local signing key"
has "$ENV_PROSE"     "LCR_WITNESS_SIGNING_KEY"      "env example names the signing key the operator must delete"
# The public key must be REPOINTED, not deleted: the gateway publishes it at
# /.well-known/veil-keys.json and verifiers fetch it. Deleting it breaks
# verification; leaving the old value advertises a key that signed nothing.
has "$RUNBOOK_PROSE" "LCR_WITNESS_PUBLIC_KEY" "runbook distinguishes the public key (repoint) from the private key (delete)"

# --- the authorization layer ----------------------------------------
#
# The mTLS latch is authentication. Without these, any device credential can
# call ExportCertificates for any customer_id.
for var in LCR_WITNESS_CLAIM_ALLOWED_PEERS LCR_WITNESS_EXPORT_ALLOWED_PEERS \
           LCR_WITNESS_EXPORT_CUSTOMER_MAP LCR_WITNESS_EXPORT_CUSTOMER_BINDING; do
  has "$RUNBOOK_PROSE" "$var" "runbook documents $var"
done

# The documented audit-log line must match what the witness actually prints.
# authz.go logs `customer_ref=h:<hmac>`, a keyed pseudonym; the runbook used to
# show `customer_id="cust_acme"`. A worked example that does not match reality
# teaches the operator to grep for a string that never appears, and — worse
# here — advertises that the log contains raw tenant identifiers when the whole
# point of the change was that it does not.
hasnt "$RUNBOOK_PROSE" 'customer_id="cust_acme"' "runbook does not show a raw customer_id in the export-audit log line"
has   "$RUNBOOK_PROSE" 'customer_ref=h:'          "runbook shows the keyed customer_ref pseudonym the witness actually emits"
has   "$RUNBOOK_PROSE" LCR_WITNESS_AUDIT_LOG_HMAC_KEY "runbook explains how to make the pseudonym stable/correlatable"

# The load-bearing sentence: a device credential must not be on the export list.
if grep -q 'not.*your device CNs' "$RUNBOOK" || grep -q 'NOT your device CNs' "$RUNBOOK"; then
  ok "runbook states device credentials are NOT on the export allowlist"
else
  fail "runbook does not state that device credentials cannot bulk-read certificates"
fi

# --- customer.env.example is the file customers actually edit --------
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

# --- the mandatory binding, where the operator sets it ---------------
#
# Under the latch with no customer map the witness now REFUSES TO START until
# LCR_WITNESS_EXPORT_CUSTOMER_BINDING is explicit (2026-07-28 review, HIGH 1).
# An operator who follows this runbook must not meet that refusal as a surprise.
if grep -qE '^LCR_WITNESS_EXPORT_CUSTOMER_BINDING=' "$RUNBOOK"; then
  ok "runbook's central-witness config sets the binding rather than commenting it out"
else
  fail "runbook still leaves LCR_WITNESS_EXPORT_CUSTOMER_BINDING commented out — the witness will refuse to start"
fi
has "$RUNBOOK_PROSE" "REFUSES TO START" "runbook says the witness refuses to start without an explicit binding"

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
has "$RUNBOOK_PROSE" "Retry-After" "runbook warns what a bare enforce looks like from the outside"
# The latch's strict grammar, where the operator types the value.
has "$ENV_PROSE" "STRICT VALUE GRAMMAR" "env example states the strict true/false grammar"

# ── Cross-product summary ───────────────────────────────────────────
echo
echo "-- cross-product matrix"
printf '   %-52s %-10s %-22s %s\n' CELL EXPECT RESULT WITNESS
printf '%s' "$CELL_ROWS" | while IFS='|' read -r n e r w; do
  [ -n "$n" ] && printf '   %-52s %-10s %-22s %s\n' "$n" "$e" "$r" "$w"
done

echo
echo "== $((N-FAILS))/$N passed =="
[ "$FAILS" -eq 0 ] || exit 1
