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
# WHAT THAT RUN ACTUALLY MEASURES — stated precisely, because the earlier
# wording here ("every section fails on origin/main") was a claim this file
# cannot make. Section 0 asserts the guard script exists and, finding it does
# not, prints one FAIL and calls `exit 1` on the spot. Sections 1-3 therefore
# never execute against a tree without the guard: they are not measured there,
# and "not measured" is not "failed".
#
# What IS measured, and is the real anti-tautology evidence:
#   - section 0 goes red on any tree lacking the script (that run, first line);
#   - sections 1-3 are proven non-vacuous by MUTATION rather than by absence —
#     deleting the `is_plausible_host` call, widening the domain matcher to a
#     substring test, dropping the CERT_ADDR variable from the sweep, and
#     downgrading the compose `depends_on` condition to `service_started` each
#     turn this suite red on a tree that HAS the guard. That is the property
#     worth asserting; a suite is only as good as the mutations it catches.
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

# gRPC's FULL target syntax is `scheme://authority/endpoint`, and for the dns
# resolver the authority is the NAME SERVER while the endpoint is the host
# actually dialled. Measured on the previous revision, which kept only the text
# before the first "/": this exact value extracted `resolver.example.com`,
# discarded the Lucairn endpoint, and printed "OK: checked 1 ..." with exit 0 —
# the same fail-open-with-an-OK-line shape as the `ADDR=":"` defect below, one
# syntax variant over. Both halves are checked now, and both directions are
# pinned here.
assert_guard "refuses-dns-authority-form-with-lucairn-ENDPOINT" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=dns://resolver.example.com/witness.lucairn.eu:50057
assert_guard "refuses-dns-authority-form-with-lucairn-AUTHORITY" 96 "REFUSING TO START" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=dns://witness.lucairn.eu/safe.example.com:50057
# POSITIVE CONTROL for the same rule: a legitimate `dns://resolver/endpoint`
# target where neither half is Lucairn must still install. A fix that simply
# refused every value containing a "/" would pass the two assertions above and
# fail this one.
assert_guard "passes-dns-authority-form-when-neither-half-is-lucairn" 0 "OK" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=dns://8.8.8.8/safe.example.com:50057

# The CERTIFICATE port serves certificates that carry redaction_manifest_body
# back out (GetCertificate / ExportCertificates), so it is guarded too. A guard
# that only read the claim variable passes every other case in this file.
assert_guard "refuses-lucairn-host-on-the-CERT-address-alone" 96 "LUCAIRN_CENTRAL_WITNESS_CERT_ADDR" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.customer.example:50057 \
  LUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.lucairn.eu:50058

# The THIRD operator-facing witness address. docs/WITNESS_CENTRAL_RUNBOOK.md § 9
# tells operators to repoint the dashboard at the central witness under this
# overlay, so it is a route to a Lucairn-operated evidence plane that our own
# runbook names — and it went unchecked until this was added.
assert_guard "refuses-lucairn-host-on-the-DASHBOARD-endpoint-alone" 96 "LUCAIRN_DASHBOARD_WITNESS_ENDPOINT" \
  LUCAIRN_DASHBOARD_WITNESS_ENDPOINT=witness.lucairn.eu:50058
assert_guard "passes-the-stock-local-dashboard-endpoint" 0 "OK: checked 1" \
  LUCAIRN_DASHBOARD_WITNESS_ENDPOINT=veil-witness:50058

# ── Fail-closed on garbage ──────────────────────────────────────────────────
# Measured before the fix: ":" survived extraction as the "host" ':', matched
# nothing, and the guard printed OK — a value that names no host reported as
# checked-and-fine. Fail-open on unparseable input is the worst failure a guard
# can have, because the log then asserts a check that never happened.
assert_guard "refuses-unparseable-addr-colon-only" 90 "no hostname could be extracted" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=:
assert_guard "refuses-unparseable-addr-port-only" 90 "no hostname could be extracted" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=:50057
# ":::" is not an IPv6 literal. It is pinned because the IPv6 arm of
# looks_like_ip() is what decides whether a colon-bearing token counts as a
# host at all, and a character-class implementation of that arm ("hex digits
# and colons") classifies both ":::" and a bare ":" as addresses. MEASURED
# while writing this round's colon fix: it did exactly that, printed the bare-IP
# NOTICE, and exited 0 — reintroducing the ADDR=":" fail-open from the other
# side. The Helm twin refuses ":::" too.
assert_guard "refuses-unparseable-addr-triple-colon" 90 "no hostname could be extracted" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=:::

# A name-shaped value with a colon left over after the port strip is garbage,
# not a host. MEASURED before this rule: `witness.lucairn.eu:50057:50057`
# reduced to the "host" `witness.lucairn.eu:50057`, which matched no blocked
# domain (the suffix test is anchored on the whole string) and passed with a
# clean OK line — a LUCAIRN host waved through.
assert_guard "refuses-residual-colon-after-port-strip" 90 "no hostname could be extracted" \
  LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057:50057

# `grep` is LINE-oriented, so a plausibility check answers about SOME line of a
# multi-line value rather than about the value. MEASURED before this rule:
# a two-line value whose FIRST line was a Lucairn host passed with exit 0
# because the second line satisfied the hostname regex. No witness address
# contains a newline, so the value is refused rather than parsed.
assert_guard "refuses-a-value-containing-a-newline" 90 "contains a newline" \
  "LUCAIRN_CENTRAL_WITNESS_ADDR=witness.lucairn.eu:50057
safe.example.com:50057"

# A bracketed IPv6 literal is a legitimate dial target and the extractor's own
# comment claimed it was handled. MEASURED before this fix: the brackets came
# off, the port regex then ate the `:1` of `::1`, and the guard exited 90 on a
# valid address. It now reaches the bare-IP notice like any other IP literal —
# which is the honest outcome, since a name-based guard cannot check it.
assert_guard "bracketed-ipv6-literal-is-treated-as-an-IP-not-as-garbage" 0 "NAME-based" \
  LUCAIRN_CENTRAL_WITNESS_ADDR='[::1]:50057'

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
LUCAIRN_DASHBOARD_WITNESS_ENDPOINT=witness.render.invalid:50058
LUCAIRN_WITNESS_CLIENT_CERT_DIR=/tmp/render-only-certs
LUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR=/tmp/render-only-gateway-certs
EOF

  render() { # $1 = env file; rest = -f files
    local ef="$1"; shift
    docker compose "$@" --env-file "$ef" -p wgtest --profile dashboard config --format json 2>"$WK/err"
  }

  # Cell: stock customer install.
  if J="$(render "$ENVFILE" -f "$BASE")"; then
    pass "stock-cell-renders"
    if printf '%s' "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "witness-egress-guard" in d["services"] else 1)'; then
      pass "stock-cell-defines-the-guard-service"
    else
      fail "stock-cell-defines-the-guard-service"
    fi
    # The guard is only checking what the emitters are actually handed if the
    # variable reaches its own environment. A variable named in the script's
    # sweep but never passed through to the guard SERVICE is a check that reads
    # an unset value and reports OK — the fail-open shape, one layer out.
    for v in LUCAIRN_CENTRAL_WITNESS_ADDR LUCAIRN_CENTRAL_WITNESS_CERT_ADDR LUCAIRN_DASHBOARD_WITNESS_ENDPOINT; do
      if printf '%s' "$J" | python3 -c '
import json,sys
v=sys.argv[1]
d=json.load(sys.stdin)
sys.exit(0 if v in d["services"]["witness-egress-guard"]["environment"] else 1)' "$v"; then
        pass "guard-service-is-passed ($v)"
      else
        fail "guard-service-is-passed ($v) — the script sweeps it but the service never receives it, so the check reads an unset value"
      fi
    done
    # lucairn-dashboard dials LUCAIRN_DASHBOARD_WITNESS_ENDPOINT at the cert
    # port. Without this edge the guard would CHECK that variable while nothing
    # acted on the refusal — an advisory guard, which is the shape this whole
    # service exists to not be.
    for svc in audit id-bridge sanitizer gateway lucairn-dashboard; do
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
    # Same property for the third address: the guard must see the endpoint the
    # dashboard is handed, not a default of its own.
    if printf '%s' "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
g=d["services"]["witness-egress-guard"]["environment"]
b=d["services"]["lucairn-dashboard"]["environment"]
sys.exit(0 if g.get("LUCAIRN_DASHBOARD_WITNESS_ENDPOINT")==b.get("LUCAIRN_DASHBOARD_WITNESS_ENDPOINT") else 1)'; then
      pass "guard-checks-the-same-endpoint-the-dashboard-is-given"
    else
      fail "guard-checks-the-same-endpoint-the-dashboard-is-given — the guard and the dashboard disagree about the target"
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

  # ── The other two witness addresses the chart exposes ──────────────────────
  #
  # gateway.veilWitnessCertAddr is a REAL, separately-settable value
  # (charts/lucairn/charts/gateway/values.yaml, rendered into
  # LCR_WITNESS_CERT_ADDR at port 50058) and GetCertificate /
  # ExportCertificates serve certificates carrying redaction_manifest_body over
  # it. MEASURED on the previous revision: this render SUCCEEDED and emitted
  #   LCR_WITNESS_CERT_ADDR: "witness.lucairn.eu:50058"
  # while the Compose twin refused the identical configuration and the CHANGELOG
  # claimed both surfaces checked the certificate port. Twin drift at exactly
  # the place the twins exist to agree.
  #
  # dashboard.witness.endpoint is the third; docs/WITNESS_CENTRAL_RUNBOOK.md § 9
  # instructs operators to repoint it at the central witness.
  for pair in "gateway.veilWitnessCertAddr=witness.lucairn.eu:50058" \
              "dashboard.witness.endpoint=witness.lucairn.eu:50058"; do
    if OUT="$("${HB[@]}" --set "$pair" 2>&1)"; then
      fail "helm-refuses-lucairn-host (${pair%%=*}) — rendered anyway"
    elif grep -q "REFUSING TO RENDER" <<<"$OUT"; then
      pass "helm-refuses-lucairn-host (${pair%%=*})"
    else
      fail "helm-refuses-lucairn-host (${pair%%=*}) — failed for another reason: $(printf '%s' "$OUT" | head -1)"
    fi
  done
  # POSITIVE CONTROLS: a customer host on either of those two values installs.
  for pair in "gateway.veilWitnessCertAddr=witness.customer.example:50058" \
              "dashboard.witness.endpoint=witness.customer.example:50058"; do
    if OUT="$("${HB[@]}" --set "$pair" 2>&1)"; then
      pass "helm-allows-a-customer-host (${pair%%=*})"
    else
      fail "helm-allows-a-customer-host (${pair%%=*}) :: $(printf '%s' "$OUT" | head -1)"
    fi
  done

  # ── TWIN PARITY, asserted directly rather than eyeballed ───────────────────
  #
  # Every finding in this round that was not a missing check was a DRIFT: the
  # two implementations disagreeing about one input. So the property is stated
  # as a table and both twins are run against it. `refuse` means "does not
  # install" on either surface — exit 96 (Lucairn host) or 90 (unparseable) for
  # the script, a failed render for the chart — because from an operator's seat
  # those are the same outcome and the reason is asserted separately above.
  while IFS='|' read -r want addr; do
    [ -n "$want" ] || continue
    env -i PATH="$PATH" "LUCAIRN_CENTRAL_WITNESS_ADDR=$addr" sh "$GUARD" >/dev/null 2>&1
    src_rc=$?
    "${HB[@]}" --set "gateway.veilWitnessAddr=$addr" >/dev/null 2>&1
    helm_rc=$?
    if [ "$want" = refuse ]; then
      src_ok=$([ "$src_rc" -ne 0 ] && echo y || echo n)
      helm_ok=$([ "$helm_rc" -ne 0 ] && echo y || echo n)
    else
      src_ok=$([ "$src_rc" -eq 0 ] && echo y || echo n)
      helm_ok=$([ "$helm_rc" -eq 0 ] && echo y || echo n)
    fi
    if [ "$src_ok$helm_ok" = "yy" ]; then
      pass "twin-parity [$want] $addr"
    else
      fail "twin-parity [$want] $addr — script exit $src_rc, helm exit $helm_rc (they must agree)"
    fi
  done <<'PARITY'
refuse|witness.lucairn.eu:50057
refuse|dns:///witness.lucairn.eu:50057
refuse|dns://resolver.example.com/witness.lucairn.eu:50057
refuse|dns://witness.lucairn.eu/safe.example.com:50057
refuse|WITNESS.LUCAIRN.EU:50057
refuse|witness.lucairn.eu.:50057
refuse|gateway.dsaveil.io:50057
refuse|witness.lucairn.eu:50057:50057
refuse|:
refuse|:::
refuse|https://evil.example/redirect?url=http://lucairn.eu:50057
allow|witness.customer.example:50057
allow|dns:///witness.customer.example:50057
allow|dns://8.8.8.8/safe.example.com:50057
allow|notlucairn.eu.example.com:50057
allow|[::1]:50057
PARITY

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

# CLAIM HONESTY. The CHANGELOG and the runbook both say the two surfaces check
# the certificate port. That sentence was FALSE for Helm when it was written —
# the chart read only veilWitnessAddr. A documented claim about coverage is only
# worth what a mechanism can count, so each address the docs name is asserted to
# be present in BOTH implementations rather than in prose alone.
VALIDATORS="$ROOT/charts/lucairn/templates/_validators.tpl"
while IFS='|' read -r envvar helmvalue; do
  [ -n "$envvar" ] || continue
  if grep -q "$envvar" "$GUARD"; then
    pass "compose-guard-checks ($envvar)"
  else
    fail "compose-guard-checks ($envvar) — named in the docs, absent from the script"
  fi
  if grep -q "$helmvalue" "$VALIDATORS"; then
    pass "helm-validator-checks ($helmvalue)"
  else
    fail "helm-validator-checks ($helmvalue) — named in the docs, absent from the chart (this is exactly the CHANGELOG's 'both surfaces' claim going false)"
  fi
done <<'ADDRS'
LUCAIRN_CENTRAL_WITNESS_ADDR|veilWitnessAddr
LUCAIRN_CENTRAL_WITNESS_CERT_ADDR|veilWitnessCertAddr
LUCAIRN_DASHBOARD_WITNESS_ENDPOINT|dashboard.witness.endpoint
ADDRS

# The guard is a run-once job: it exits and disappears from `ps`. An install
# runbook whose steady-state container list does not say so turns a healthy
# guard into a support ticket.
INSTALL_RUNBOOK="$ROOT/docs/CUSTOMER_INSTALL_RUNBOOK.md"
if grep -q "witness-egress-guard" "$INSTALL_RUNBOOK"; then
  pass "install-runbook-lists-the-guard-among-the-run-once-jobs"
else
  fail "install-runbook-lists-the-guard-among-the-run-once-jobs — an operator would read its absence from \`ps\` as a missing container"
fi

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "T-682 witness-central claim-egress guard: PASS ($N assertions)"
else
  echo "T-682 witness-central claim-egress guard: FAIL ($FAILS of $N assertions)"
  exit 1
fi
