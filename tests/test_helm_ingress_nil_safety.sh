#!/usr/bin/env bash
#
# T-421 — turning an Ingress OFF by nulling its block must render, not panic.
#
# WHAT THIS SUITE EXISTS TO STOP (the defect, stated precisely):
#
#   Both Ingress templates read `.Values.ingress.enabled` bare. Go templates do
#   not treat a field access against an untyped nil as false — they abort the
#   whole render with "nil pointer evaluating interface {}.enabled". So the two
#   most natural ways an operator expresses "I do not want an Ingress" —
#
#       --set gateway.ingress=null
#       gateway:
#         ingress:            # key written, nothing under it
#
#   — killed `helm template`/`helm install` outright, with an error naming a
#   pointer rather than the thing they turned off. `ingress.enabled: false` was
#   the only spelling that worked, and nothing said so.
#
#   The umbrella NOTES.txt half of this ticket was fixed in 9b88fc7. That
#   commit's own message recorded that a full end-to-end render still died one
#   template later, at charts/lucairn/charts/gateway/templates/ingress.yaml, and
#   scoped it out. This suite covers that residual and its sibling in the
#   dashboard subchart.
#
# POSITIVE CONTROLS (each case goes red against the pre-fix tree — none is a
# tautology):
#   - null-renders (§1): reverting either template's `{{- $ingress := default
#     dict .Values.ingress }}` binding to a bare `.Values.ingress.enabled` turns
#     the matching case red with the nil-pointer panic. This is the RED-PROOF.
#   - enabled-still-renders (§2): the guard must not be a mute — with
#     ingress.enabled=true the template must still emit exactly one Ingress
#     carrying className/host/tlsSecret. A `default dict` that swallowed the
#     populated case would pass §1 and fail here.
#   - notes-nil-safe (§3): pins the ALREADY-FIXED umbrella NOTES.txt half
#     (9b88fc7) so a future edit cannot silently reintroduce the bare access.
#   - umbrella-real-consequence (§4, T-697): the umbrella-level
#     `gateway.ingress=null` check is NOT this ticket's positive control (§1
#     is — see below) because Helm 3.16.4, the version CI pins, coalesces a
#     nulled PARENT value back to the sub-chart's own default before the
#     template ever sees it, so the nil-pointer path is unreachable from here
#     under CI's Helm. §4 instead asserts the real, falsifiable, version-
#     agnostic consequence — zero Ingress OR exactly the reviewed default,
#     never a duplicate or malformed one — closing the vacuity where the old
#     check only asked "did the process exit 0", true either way.
#
# ISOLATION: §1 and §2 render each Ingress template inside a throwaway chart
# containing ONLY that template (plus _helpers.tpl where it is referenced).
# That is deliberate and load-bearing. A whole-subchart render of `dashboard`
# or `gateway` fails on unrelated templates that need values this suite does
# not supply, and a whole-UMBRELLA render masks the dashboard case entirely
# because dashboard.enabled defaults to false — the defect would sit there
# reachable-but-untested. Isolating the template under test is the only way the
# assertion is about the Ingress nil-guard and nothing else.
#
# Requires: helm. No cluster, GPU, Docker, or network.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"
CHART="$ROOT/charts/lucairn"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FAILS=0
N=0
pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }

command -v helm >/dev/null 2>&1 || {
  echo "T-421 gate: ERROR — helm is required" >&2
  exit 2
}

echo "T-421 — Ingress nil-safety gate"

# Build a throwaway chart holding ONLY <subchart>'s ingress.yaml.
isolate() {
  local sub="$1" d="$TMPDIR/iso-$1"
  rm -rf "$d"
  mkdir -p "$d/templates"
  printf 'apiVersion: v2\nname: %s\nversion: 0.0.0\n' "$sub" >"$d/Chart.yaml"
  cp "$CHART/charts/$sub/values.yaml" "$d/values.yaml"
  cp "$CHART/charts/$sub/templates/ingress.yaml" "$d/templates/"
  # dashboard's ingress.yaml calls dashboard.fullname / dashboard.labels.
  if [ -f "$CHART/charts/$sub/templates/_helpers.tpl" ]; then
    cp "$CHART/charts/$sub/templates/_helpers.tpl" "$d/templates/"
  fi
  echo "$d"
}

# ── §1 Disabling by nulling the block renders instead of panicking ──────────
printf 'ingress:\n' >"$TMPDIR/empty-ingress.yaml"

for sub in gateway dashboard; do
  iso="$(isolate "$sub")"

  if helm template t "$iso" --set ingress=null >"$TMPDIR/$sub-null.out" 2>"$TMPDIR/$sub-null.err"; then
    if grep -q 'kind: Ingress' "$TMPDIR/$sub-null.out"; then
      fail "$sub: --set ingress=null renders NO Ingress (an Ingress was emitted anyway)"
    else
      pass "$sub: --set ingress=null renders, and emits no Ingress"
    fi
  elif grep -q 'nil pointer' "$TMPDIR/$sub-null.err"; then
    fail "$sub: --set ingress=null renders (nil-pointer panic — the T-421 defect)"
  else
    fail "$sub: --set ingress=null renders (failed for another reason: $(head -1 "$TMPDIR/$sub-null.err"))"
  fi

  if helm template t "$iso" -f "$TMPDIR/empty-ingress.yaml" >"$TMPDIR/$sub-empty.out" 2>"$TMPDIR/$sub-empty.err"; then
    if grep -q 'kind: Ingress' "$TMPDIR/$sub-empty.out"; then
      fail "$sub: a values file writing bare 'ingress:' renders NO Ingress (one was emitted)"
    else
      pass "$sub: a values file writing bare 'ingress:' renders, and emits no Ingress"
    fi
  elif grep -q 'nil pointer' "$TMPDIR/$sub-empty.err"; then
    fail "$sub: bare 'ingress:' in a values file renders (nil-pointer panic — the T-421 defect)"
  else
    fail "$sub: bare 'ingress:' in a values file renders (other reason: $(head -1 "$TMPDIR/$sub-empty.err"))"
  fi

  # ── §2 …and the guard is not a mute: the enabled path still renders ───────
  if helm template t "$iso" --set ingress.enabled=true >"$TMPDIR/$sub-on.out" 2>"$TMPDIR/$sub-on.err"; then
    count="$(grep -c 'kind: Ingress' "$TMPDIR/$sub-on.out" || true)"
    if [ "$count" = "1" ] && grep -q 'ingressClassName:' "$TMPDIR/$sub-on.out" &&
      grep -q 'host:' "$TMPDIR/$sub-on.out"; then
      pass "$sub: ingress.enabled=true still renders exactly one populated Ingress"
    else
      fail "$sub: ingress.enabled=true still renders one populated Ingress (got $count, className/host missing?)"
    fi
  else
    fail "$sub: ingress.enabled=true still renders: $(head -1 "$TMPDIR/$sub-on.err")"
  fi
done

# ── §3 The already-fixed umbrella NOTES.txt half stays fixed (9b88fc7) ──────
# A bare .Values.gateway.ingress.<key> anywhere in NOTES.txt reintroduces the
# original ticket. The fix routes every read through $gatewayIngress.
if grep -qE '\.Values\.gateway\.ingress\.' "$CHART/templates/NOTES.txt"; then
  fail "NOTES.txt reads .Values.gateway.ingress.<key> bare (T-421 regression — use \$gatewayIngress)"
else
  pass "NOTES.txt reads gateway.ingress only through the nil-safe \$gatewayIngress binding"
fi

# ── §4 The umbrella path checks a REAL consequence, not just "did it render"
# (T-697). `--set gateway.ingress=null` at the UMBRELLA is not this ticket's
# positive control for the nil-pointer panic — §1's isolated renders are, and
# stay so. It CANNOT be: Helm 3.16.4, the version .github/workflows/ci.yml
# pins, treats a nil in the PARENT's values as absent and restores gateway's
# OWN values.yaml default (ingress.enabled: true, confirmed by direct probe
# under helm 3.16.4 in a container — exit 0, one Ingress emitted), so a null
# written at the umbrella never reaches `$ingress.enabled` as nil under the
# pinned CI Helm at all. The OLD check here (`if helm template ...; then pass;
# else fail`, stdout discarded) was therefore true regardless of whether the
# T-421 guard exists — a render succeeding is not evidence the guard ran.
#
# What this check verifies instead, true on every Helm major: an explicit
# `gateway.ingress=null` never produces anything other than (a) zero Ingress
# objects — the nil-safe outcome, on a major that propagates the null all the
# way to `$ingress.enabled` — or (b) exactly the ONE Ingress the reviewed
# default renders, never a duplicate or a malformed one missing its
# className/host. Both arms are real, falsifiable consequences a regression
# can break; "did the process exit 0" was not.
if helm template lucairn "$CHART" \
  "${HELM_TEST_SECRET_ARGS[@]}" \
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
  --set global.skipPullSecretGuard=true \
  --set gateway.ingress=null >"$TMPDIR/umbrella.out" 2>"$TMPDIR/umbrella.err"; then
  count="$(grep -c 'kind: Ingress' "$TMPDIR/umbrella.out" || true)"
  case "$count" in
    0)
      pass "umbrella: gateway.ingress=null renders zero Ingress (this Helm major propagates the null — nil-safe path)"
      ;;
    1)
      if grep -q 'ingressClassName: nginx' "$TMPDIR/umbrella.out" && grep -q 'host: dsa.local' "$TMPDIR/umbrella.out"; then
        pass "umbrella: gateway.ingress=null renders exactly the reviewed default Ingress (this Helm major coalesces the null away to gateway's own default — known, documented)"
      else
        fail "umbrella: gateway.ingress=null rendered one Ingress that does NOT match the reviewed default (className/host missing)"
      fi
      ;;
    *)
      fail "umbrella: gateway.ingress=null rendered $count Ingress objects (expected 0 or 1)"
      ;;
  esac
else
  if grep -q 'nil pointer' "$TMPDIR/umbrella.err"; then
    fail "umbrella chart renders end-to-end with gateway.ingress nulled (nil-pointer panic — the T-421 defect, reachable on this Helm major)"
  else
    fail "umbrella chart renders end-to-end with gateway.ingress nulled: $(head -2 "$TMPDIR/umbrella.err" | tr '\n' ' ')"
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "T-421 gate: PASS ($N checks)"
else
  echo "T-421 gate: FAIL ($FAILS of $N checks)"
  exit 1
fi
