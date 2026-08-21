#!/usr/bin/env bash
#
# T-682 — the witness-central claim-egress guard.
#
# WHAT THIS SUITE EXISTS TO STOP (the defect, stated precisely):
#
#   contrib/witness-central/docker-compose.witness-central.yml repoints every
#   claim emitter at LUCAIRN_CENTRAL_WITNESS_ADDR. One of those claims is the
#   sanitizer's PII_SANITIZED, and it carries redaction_manifest_body — the
#   placeholder→original map. An operator who set that variable to a
#   Lucairn-operated host got a WORKING install that streamed the map to
#   Lucairn, with no error, no warning, and no line in any log. The only thing
#   standing between the product's non-negotiable promise ("no raw identity data
#   leaves your environment") and that outcome was a sentence in
#   docs/WITNESS_CENTRAL_RUNBOOK.md § 1.
#
#   Fable review 2026-08-21 § 2c, HIGH: "the witness-central overlay is
#   prose-guarded, not code-guarded".
#
# RED-PROOF (run it, do not take this comment's word for it):
#
#   git worktree add /tmp/wg-main origin/main
#   cp tests/test_witness_central_egress_guard.sh /tmp/wg-main/tests/
#   bash /tmp/wg-main/tests/test_witness_central_egress_guard.sh
#
#   Every section fails on origin/main: the script does not exist, the compose
#   service does not exist, the Helm validator does not exist. There is no
#   version of this file that passes against a tree without the guard.
#
# POSITIVE CONTROLS — no assertion here is a tautology:
#   - the near-miss host `notlucairn.eu.example.com` must PASS. A guard written
#     with a substring match instead of an exact-or-subdomain match goes red
#     here, and a suite that only asserted refusals would never notice.
#   - the stock topology (no central witness set) must PASS and must still
#     bring up every emitter. A guard that fires on the default install would be
#     caught here rather than by a customer.
#   - the hatch must OPEN the path, not merely be accepted. A hatch that is
#     validated and then ignored passes a kindIs check and fails this.
#   - the compose assertions read the RENDERED project (`docker compose
#     config`), not the source YAML, so a `depends_on` that exists in the file
#     but does not survive the overlay merge is caught.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/witness-egress-guard.sh"
BASE="$ROOT/docker-compose.customer.yml"
SELFHOSTED="$ROOT/docker-compose.self-hosted.yml"
OVERLAY="$ROOT/contrib/witness-central/docker-compose.witness-central.yml"
RUNBOOK="$ROOT/docs/WITNESS_CENTRAL_RUNBOOK.md"
ENV_EXAMPLE="$ROOT/contrib/witness-central/witness-central.env.example"

N=0
FAILS=0
pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }

echo "== T-682 witness-central claim-egress guard =="
echo ""
echo "0. The guard exists and ships"

if [ -f "$GUARD" ]; then
  pass "guard-script-present"
else
  fail "guard-script-present — $GUARD is missing; every assertion below is meaningless"
  echo ""
  echo "T-682 witness-central claim-egress guard: FAIL ($FAILS of $N assertions)"
  exit 1
fi

# Present-on-disk is not enough. `.gitignore` line 2 is `*.env`, the release
# tarball is `git archive HEAD`, and an untracked bind-mount source is
# materialised by Docker as an empty DIRECTORY — the exact air-gap failure
# T-350 B1 shipped. A mounted script that is not tracked is not shipped.
if git -C "$ROOT" ls-files --error-unmatch "scripts/witness-egress-guard.sh" >/dev/null 2>&1; then
  pass "guard-script-tracked-by-git"
else
  fail "guard-script-tracked-by-git — present on disk but NOT tracked; it will be absent from the commit and from \`git archive\` release tarballs"
fi

# The bundler derives its staging set from the ./scripts/* mounts in the base
# compose file, so the guard is only in an air-gapped bundle if it is mounted
# THERE. (tests/test_migration_version_cap.sh § 7 asserts the derivation
# itself; this asserts our script is inside the set it derives.)
if grep -q '\./scripts/witness-egress-guard\.sh:' "$BASE"; then
  pass "guard-script-mounted-in-base-compose (so \`bundle create\` stages it)"
else
  fail "guard-script-mounted-in-base-compose — not mounted in docker-compose.customer.yml; an air-gapped bundle would not carry it"
fi

echo ""
echo "1. Behaviour — the script itself"

# $1 name | $2 expected exit | $3 expected substring in output ("" = any) |
# rest: VAR=VALUE assignments
assert_guard() {
  local name="$1" want_rc="$2" want_sub="$3"
  shift 3
  local out rc
  out="$(env -i PATH="$PATH" "$@" sh "$GUARD" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    fail "$name (want exit $want_rc, got $rc) :: $(printf '%s' "$out" | head -1)"
    return
  fi
  if [ -n "$want_sub" ] && ! printf '%s' "$out" | grep -qF "$want_sub"; then
    fail "$name (exit $rc correct, but output lacks '$want_sub')"
    return
  fi
  pass "$name"
}

# ── Stock install: nothing configured, nothing refused ──────────────────────
assert_guard "stock-install-passes (no central witness set)" 0 "OK: no central witness configured"

# ── A customer's own witness passes ─────────────────────────────────────────
assert_guard "customer-host-passes" 0 "OK: checked 1" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.customer.example:50057

# POSITIVE CONTROL. A substring implementation ("does the value contain
# lucairn.eu") refuses this, and it must not: it is a customer domain that
# merely embeds the string. If this ever goes red the matcher has been widened
# into something that will refuse legitimate installs.
assert_guard "near-miss-host-passes (exact-or-subdomain, not substring)" 0 "OK" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=notlucairn.eu.example.com:50057

# ── The refusals ────────────────────────────────────────────────────────────
assert_guard "refuses-lucairn-eu-subdomain" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057
assert_guard "refuses-apex-lucairn-eu" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=lucairn.eu:50057
assert_guard "refuses-dsaveil-io-subdomain" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=gateway.dsaveil.io:50057
assert_guard "refuses-lucairn-com" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.com:50057
assert_guard "refuses-uppercase (matching is case-insensitive)" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=WITNESS.LUCAIRN.EU:50057
assert_guard "refuses-trailing-root-dot" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu.:50057
# gRPC's own target syntax. Measured: a naive `://` strip leaves a leading
# slash and the subsequent path-strip empties the value, so this address was
# refused as UNPARSEABLE — the right outcome for the wrong reason, while the
# same form on a CUSTOMER host was refused outright. Both directions are pinned.
assert_guard "refuses-grpc-dns-target-form" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=dns:///witness.lucairn.eu:50057
assert_guard "passes-grpc-dns-target-form-on-customer-host" 0 "OK" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=dns:///witness.customer.example:50057

# The CERTIFICATE port serves certificates that carry redaction_manifest_body
# back out (GetCertificate / ExportCertificates), so it is guarded too. A guard
# that only read the claim variable passes every other case in this file.
assert_guard "refuses-lucairn-host-on-the-CERT-address-alone" 96 "LUCAIRN_CENTRAL_WITNESS_CERT_ADDR" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.customer.example:50057 \
  LUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.lucairn.eu:50058

# ── Fail-closed on garbage ──────────────────────────────────────────────────
# Measured before the fix: ":" survived extraction as the "host" ':', matched
# nothing, and the guard printed OK — a value that names no host reported as
# checked-and-fine. Fail-open on unparseable input is the worst failure a guard
# can have, because the log then asserts a check that never happened.
assert_guard "refuses-unparseable-addr-colon-only" 90 "no hostname could be extracted" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=:
assert_guard "refuses-unparseable-addr-port-only" 90 "no hostname could be extracted" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=:50057

# ── The hatch ───────────────────────────────────────────────────────────────
# It must OPEN the path (exit 0), not merely be accepted, and it must say what
# it is doing. A hatch that validates and is then ignored passes a type check
# and fails this assertion.
assert_guard "hatch-true-opens-the-path" 0 "UNSAFE OVERRIDE ACTIVE" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057 \
  LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=true
assert_guard "hatch-true-names-what-is-being-sent" 0 "redaction_manifest_body" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057 \
  LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=true
assert_guard "hatch-true-names-the-blocked-host-verbatim" 0 "witness.lucairn.eu:50057" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057 \
  LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=true
assert_guard "hatch-false-is-the-default-and-still-refuses" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057 \
  LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=false

# Strict string boolean on the Compose path: an env var is a plain string and
# there is no YAML parser to consult, so an ambiguous spelling is REFUSED
# rather than guessed. Guessing "off" leaves the operator believing the hatch is
# open when it is not; guessing "on" is worse.
for spelling in True TRUE yes on 1 " true"; do
  assert_guard "hatch-refuses-ambiguous-spelling ('$spelling')" 95 "must be exactly 'true' or 'false'" \
    LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057 \
    "LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS=$spelling"
done

# ── The honest limit, stated in the output ──────────────────────────────────
# A bare IP cannot be name-checked. The guard must SAY so rather than print a
# clean OK that implies a check it did not perform.
assert_guard "bare-ip-emits-the-name-based-limitation-notice" 0 "NAME-based" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=10.0.0.5:50057

echo ""
echo "2. Compose wiring — asserted against the RENDERED project"

if ! docker compose version >/dev/null 2>&1; then
  echo "  SKIP — docker compose unavailable; the render assertions did not run"
else
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
DSA_ADMIN_KEY=render-only
VEIL_GATEWAY_SIGNING_KEY=00
VEIL_SANDBOX_B_SIGNING_KEY=00
EOF
  OVERLAY_ENV="$WK/overlay.env"
  cat "$ENVFILE" > "$OVERLAY_ENV"
  cat >> "$OVERLAY_ENV" <<'EOF'
LUCAIRN_CENTRAL_WITNESS_ADDR=witness.render.invalid:50057
LUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.render.invalid:50058
LUCAIRN_WITNESS_CLIENT_CERT_DIR=/tmp/render-only-certs
LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR=/tmp/render-only-gateway-certs
EOF

  render() { # $1 = env file; rest = -f files
    local ef="$1"; shift
    docker compose "$@" --env-file "$ef" -p wgtest config --format json 2>"$WK/err"
  }

  # Cell: stock customer install.
  if J="$(render "$ENVFILE" -f "$BASE")"; then
    pass "stock-cell-renders"
    if printf '%s' "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "witness-egress-guard" in d["services"] else 1)'; then
      pass "stock-cell-defines-the-guard-service"
    else
      fail "stock-cell-defines-the-guard-service"
    fi
    for svc in audit id-bridge sanitizer gateway; do
      if printf '%s' "$J" | python3 -c '
import json,sys
svc=sys.argv[1]
d=json.load(sys.stdin)
dep=d["services"][svc].get("depends_on",{})
g=dep.get("witness-egress-guard")
sys.exit(0 if g and g.get("condition")=="service_completed_successfully" else 1)' "$svc"; then
        pass "emitter-gated ($svc depends_on witness-egress-guard / completed_successfully)"
      else
        fail "emitter-gated ($svc) — the emitter can start without the guard having run"
      fi
    done
  else
    fail "stock-cell-renders :: $(head -1 "$WK/err")"
  fi

  # Cell: full on-prem + the witness-central overlay. This is the topology the
  # finding is about, and it is also the one where a guard defined in the
  # overlay instead of the base would fail to gate sandbox-b.
  if J="$(render "$OVERLAY_ENV" -f "$BASE" -f "$SELFHOSTED" -f "$OVERLAY")"; then
    pass "full-onprem+overlay-cell-renders"
    if printf '%s' "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
dep=d["services"]["sandbox-b"].get("depends_on",{})
g=dep.get("witness-egress-guard")
sys.exit(0 if g and g.get("condition")=="service_completed_successfully" else 1)'; then
      pass "sandbox-b-gated (the one emitter repointed from self-hosted.yml)"
    else
      fail "sandbox-b-gated — sandbox-b could still dial a Lucairn witness"
    fi
    # The guard must see the SAME variable the emitters are handed, or it is
    # checking something else and reporting on this.
    if printf '%s' "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
g=d["services"]["witness-egress-guard"]["environment"]
s=d["services"]["sanitizer"]["environment"]
sys.exit(0 if g.get("LUCAIRN_CENTRAL_WITNESS_ADDR")==s.get("LCR_WITNESS_ADDR") else 1)'; then
      pass "guard-checks-the-same-address-the-sanitizer-is-given"
    else
      fail "guard-checks-the-same-address-the-sanitizer-is-given — the guard and the emitter disagree about the target"
    fi
  else
    fail "full-onprem+overlay-cell-renders :: $(head -1 "$WK/err")"
  fi
fi

echo ""
echo "3. Helm twin"

if ! command -v helm >/dev/null 2>&1; then
  echo "  SKIP — helm unavailable; the chart assertions did not run"
else
  # shellcheck disable=SC1091
  . "$ROOT/tests/lib/test-helpers.sh"
  HB=(helm template lucairn "$ROOT/charts/lucairn"
      "${HELM_TEST_SECRET_ARGS[@]}"
      --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
      --set global.skipPullSecretGuard=true)

  if OUT="$("${HB[@]}" 2>&1)"; then
    pass "helm-stock-render-succeeds"
    if grep -q "lucairn-unsafe-lucairn-operated-witness" <<<"$OUT"; then
      fail "helm-stock-render-has-no-acknowledgement-configmap — the loud record renders on a clean install"
    else
      pass "helm-stock-render-has-no-acknowledgement-configmap"
    fi
  else
    fail "helm-stock-render-succeeds :: $(printf '%s' "$OUT" | head -1)"
  fi

  for sub in gateway audit id-bridge sandbox-a sandbox-b; do
    if OUT="$("${HB[@]}" --set "${sub}.veilWitnessAddr=witness.lucairn.eu:50057" 2>&1)"; then
      fail "helm-refuses-lucairn-host ($sub) — rendered anyway"
    elif grep -q "REFUSING TO RENDER" <<<"$OUT"; then
      pass "helm-refuses-lucairn-host ($sub)"
    else
      fail "helm-refuses-lucairn-host ($sub) — failed for another reason: $(printf '%s' "$OUT" | head -1)"
    fi
  done

  if OUT="$("${HB[@]}" --set "gateway.veilWitnessAddr=witness.customer.example:50057" 2>&1)"; then
    pass "helm-allows-a-customer-host"
  else
    fail "helm-allows-a-customer-host :: $(printf '%s' "$OUT" | head -1)"
  fi

  if OUT="$("${HB[@]}" --set "gateway.veilWitnessAddr=witness.lucairn.eu:50057" \
              --set "witnessEgress.unsafeAcknowledgeLucairnOperatedWitness=true" 2>&1)"; then
    pass "helm-hatch-opens-the-render"
    if grep -q "lucairn-unsafe-lucairn-operated-witness" <<<"$OUT"; then
      pass "helm-hatch-renders-the-loud-acknowledgement-configmap"
    else
      fail "helm-hatch-renders-the-loud-acknowledgement-configmap — the override left no trace in the manifests"
    fi
    if grep -q "redaction_manifest_body" <<<"$OUT"; then
      pass "helm-acknowledgement-names-what-is-being-sent"
    else
      fail "helm-acknowledgement-names-what-is-being-sent"
    fi
  else
    fail "helm-hatch-opens-the-render :: $(printf '%s' "$OUT" | head -1)"
  fi

  # A quoted string is truthy in some template contexts and falsy in others.
  if OUT="$("${HB[@]}" --set-string "witnessEgress.unsafeAcknowledgeLucairnOperatedWitness=true" 2>&1)"; then
    fail "helm-hatch-refuses-a-string — a quoted 'true' was accepted"
  elif grep -q "must be a YAML boolean" <<<"$OUT"; then
    pass "helm-hatch-refuses-a-string"
  else
    fail "helm-hatch-refuses-a-string — failed for another reason: $(printf '%s' "$OUT" | head -1)"
  fi

  if OUT="$("${HB[@]}" --set "audit.veilWitnessAddr=:::" 2>&1)"; then
    fail "helm-fails-closed-on-unparseable-addr — rendered anyway"
  elif grep -q "no hostname can be extracted" <<<"$OUT"; then
    pass "helm-fails-closed-on-unparseable-addr"
  else
    fail "helm-fails-closed-on-unparseable-addr — failed for another reason: $(printf '%s' "$OUT" | head -1)"
  fi
fi

echo ""
echo "4. The documentation matches the code"

# The flag is the operator's only escape route. If its name drifts in either
# direction the runbook sends people to a variable that does nothing — which is
# how a fail-closed guard turns into an outage nobody can resolve.
FLAG="LUCAIRN_WITNESS_UNSAFE_ACKNOWLEDGE_LUCAIRN_OPERATED_WITNESS"
for f in "$RUNBOOK" "$ENV_EXAMPLE"; do
  if grep -q "$FLAG" "$f"; then
    pass "flag-name-documented ($(basename "$f"))"
  else
    fail "flag-name-documented ($(basename "$f")) — the escape hatch is undocumented there"
  fi
done
if grep -q "$FLAG" "$GUARD"; then
  pass "flag-name-matches-the-implementation"
else
  fail "flag-name-matches-the-implementation"
fi
# The Helm value name is a separate literal and drifts separately.
if grep -q "unsafeAcknowledgeLucairnOperatedWitness" "$RUNBOOK"; then
  pass "helm-hatch-value-documented"
else
  fail "helm-hatch-value-documented"
fi
# The honest limit must be in the runbook, not only in a code comment: an
# operator reading the docs must learn that a bare IP is not checked.
if grep -qi "name-based" "$RUNBOOK"; then
  pass "runbook-states-the-name-based-limitation"
else
  fail "runbook-states-the-name-based-limitation — the docs would imply a check the guard does not perform"
fi

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "T-682 witness-central claim-egress guard: PASS ($N assertions)"
else
  echo "T-682 witness-central claim-egress guard: FAIL ($FAILS of $N assertions)"
  exit 1
fi
