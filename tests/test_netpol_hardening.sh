#!/usr/bin/env bash
#
# T-388 / T-389 / T-390 + SEC-002/003/006 — NetworkPolicy hardening.
#
# Every case here is a POSITIVE CONTROL: it fails against the pre-change tree,
# or against a tree where the specific guard it names has been removed. A case
# that would pass either way is not evidence and does not belong in this file.
#
#   T-388  NetworkPolicy namespaces were hardcoded (`namespace: dsa-identity`)
#          while workloads template theirs from their own sub-chart's
#          `.Values.namespace`. Overriding a workload namespace moved the pods
#          but left every policy — INCLUDING default-deny-all — behind on the
#          old namespace. A namespace with no NetworkPolicy is default-ALLOW,
#          so the PII plane silently lost all egress restriction, at exit 0.
#          Fixed in two halves that are only sufficient together:
#            - infrastructure policies resolve their namespace from the single
#              `infrastructure.namespaces` list (helper: infrastructure.namespaceFor)
#            - `validators.namespaceNetpolAlignment` refuses the render when a
#              workload sub-chart's namespace disagrees with that list
#              (sub-charts cannot read each other's values, so templating alone
#              provably cannot close this).
#
#   T-389  `identity-egress` let `podSelector: {}` — i.e. EVERY pod in the
#          identity namespace — reach ollama-identity:11434. The Ollama API is
#          unauthenticated and POST /api/pull takes an arbitrary registry host
#          with `insecure: true`, so with the L3 runtime's TCP/443 egress that
#          was an exfiltration primitive for any compromised identity pod.
#          11434 is now restricted to `infrastructure.identityOllamaClients`
#          on BOTH the egress and the ingress side.
#
#   T-390  0.0.0.0/0 ipBlocks claimed "public registries only" while their
#          except-lists omitted 100.64.0.0/10 (RFC 6598 CGNAT — where
#          managed-Kubernetes Pod/Service CIDRs and overlay networks commonly
#          live) and 127.0.0.0/8 (loopback). Asserted across the WHOLE render,
#          not a list of policy names: the first version checked two policies
#          and four others escaped the property entirely (SEC-001).
#
#   SEC-002  The T-388 fix moved each CiliumNetworkPolicy to the overridden
#          namespace but left its DNS `matchPattern` suffixes naming the OLD
#          one, so pods could resolve the vacated namespace and not their own.
#          The fix CREATED that inversion, so it gets its own control.
#
#   SEC-003  `--set infrastructure.namespaces[N].name=...` builds a SPARSE list
#          (Helm nils every other index). That used to produce a raw template
#          panic naming an unrelated label; it must produce the actionable
#          "use a values file" message instead.
#
#   SEC-006  `infrastructure.enabled=false` deletes every policy in the chart,
#          default-deny-all included, while the data plane still deploys. The
#          chart already draws this line by `global.dsaEnv`: production
#          hard-rejects it via validators.enterpriseFullMeshMTLS's
#          $mandatoryProfiles, development supports it (the repo's own mTLS
#          suite renders it twice). The cases below pin BOTH halves, and pin the
#          production half against the message of the guard that actually
#          enforces it rather than our own backstop's.
#
# The reachability cases evaluate the UNION of all policies in the namespace,
# which is the only semantics that means anything here: Kubernetes unions
# NetworkPolicies, so an added restrictive policy cannot subtract a permission
# an existing blanket rule already granted. A test that inspected only the new
# policy would pass even if the blanket rules still opened 11434 to everyone.
#
# The selector/CIDR logic lives in tests/lib/netpol_assert.py, which is
# BYTE-IDENTICAL to dual-sandbox-architecture's tests/invariant/lib/netpol_assert.py.
# Keeping one implementation is deliberate: two hand-maintained copies of a
# security evaluator drift, and the drift is invisible until it matters.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
ASSERT="$ROOT/tests/lib/netpol_assert.py"

# shellcheck source=lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

# BH-F3: these are security controls, so they FAIL CLOSED on a missing
# dependency rather than exiting 0. A skipped guard reads as a pass in CI, which
# is the failure mode the whole file exists to prevent. CI installs helm
# explicitly and provisions PyYAML alongside it (.github/workflows/ci.yml).
if ! command -v helm >/dev/null 2>&1; then
  echo "FAIL: helm is required for the netpol hardening checks (not skippable)" >&2
  exit 1
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "FAIL: python3 with PyYAML is required for the netpol hardening checks." >&2
  echo "      Install it (pip install pyyaml) — these checks are not skippable:" >&2
  echo "      silently skipping a security control is worse than a red build." >&2
  exit 1
fi
[ -r "$ASSERT" ] || { echo "FAIL: missing $ASSERT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# L3 on: ollama-identity, the model-pull Job and the registry-egress policy all
# render only in this combination.
COMMON=(
  # T-10: the k8s-native default backend ships no working password defaults.
  "${HELM_TEST_SECRET_ARGS[@]}"
  --set global.skipPullSecretGuard=true
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
  --set sandbox-a.sanitizer.llmScanEnabled=true
  --set global.llmShieldEnabled=true
  --set global.identityModelRegistryEgress=true
)

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Render the default (no namespace override) tree once; most cases read it.
# stderr is NOT suppressed and a failed render is fatal: if the render broke,
# an "absent string" assertion below would otherwise report the ABSENCE as a
# pass-shaped finding.
# ---------------------------------------------------------------------------
if ! helm template lucairn "$CHART" "${COMMON[@]}" >"$WORK/default.yaml" 2>"$WORK/default.err"; then
  echo "default render FAILED:" >&2; cat "$WORK/default.err" >&2; exit 1
fi

# ===========================================================================
# T-388 case 1 — divergent namespace override must FAIL the render, for EVERY
# workload sub-chart (BH-F4), not just the one that surfaced the bug.
# Pre-change this rendered at exit 0 with six identity workloads (sanitizer,
# ollama-identity, postgres, redis cache, migrate Job, model-pull Job) in a
# namespace holding zero NetworkPolicies.
# ===========================================================================
for sub in sandbox-a gateway sandbox-b veil-witness; do
  if helm template lucairn "$CHART" "${COMMON[@]}" \
       --set "${sub}.namespace=acme-drift" >/dev/null 2>"$WORK/diverge-$sub.err"; then
    fail "T-388: divergent ${sub}.namespace override still renders (guard absent). Workloads would deploy unpoliced."
  fi
  grep -q "namespace/NetworkPolicy split-brain" "$WORK/diverge-$sub.err" \
    || fail "T-388: ${sub} render refused, but not by validators.namespaceNetpolAlignment. Got: $(head -2 "$WORK/diverge-$sub.err")"
done
echo "ok  T-388: divergent namespace override refused for sandbox-a, gateway, sandbox-b, veil-witness"

# ===========================================================================
# T-388 case 2 — CONSISTENT override renders, and the policies MOVE WITH the
# pods. This is the arm that proves the guard is not merely a blanket ban on
# overriding namespaces: the supported path still works.
# ===========================================================================
cat >"$WORK/ns-override.yaml" <<'YAML'
infrastructure:
  namespaces:
    - {name: dsa-edge, label: edge}
    - {name: acme-identity, label: identity}
    - {name: dsa-bridge, label: bridge}
    - {name: dsa-ai, label: ai}
    - {name: dsa-audit, label: audit}
    - {name: dsa-observability, label: observability}
    - {name: dsa-ingest, label: ingest}
    - {name: dsa-admin, label: admin}
    - {name: dsa-witness, label: witness}
    - {name: dsa-demo, label: demo}
sandbox-a:
  namespace: acme-identity
pii-ml:
  namespace: acme-identity
YAML
if ! helm template lucairn "$CHART" "${COMMON[@]}" -f "$WORK/ns-override.yaml" \
     >"$WORK/moved.yaml" 2>"$WORK/moved.err"; then
  echo "T-388: consistent override render FAILED:" >&2; cat "$WORK/moved.err" >&2; exit 1
fi
python3 "$ASSERT" moved "$WORK/moved.yaml" \
  || fail "T-388: consistent override left workloads unpoliced or policies stranded"
echo "ok  T-388: consistent override moves workloads AND policies together, none stranded"

# ===========================================================================
# T-388 case 3 — the helper fails closed on a malformed namespaces list.
# Dropping an entry's label must abort the render rather than emit an empty
# `namespace:` (which Helm would silently resolve to the release namespace).
# ===========================================================================
cat >"$WORK/ns-nolabel.yaml" <<'YAML'
infrastructure:
  namespaces:
    - {name: dsa-edge, label: edge}
    - {name: dsa-identity}
YAML
if helm template lucairn "$CHART" "${COMMON[@]}" -f "$WORK/ns-nolabel.yaml" \
     >/dev/null 2>"$WORK/nolabel.err"; then
  fail "T-388: namespaces entry with no label still rendered (helper does not fail closed)"
fi
grep -q "has no entry with label" "$WORK/nolabel.err" \
  || fail "T-388: malformed namespaces list refused, but not by infrastructure.namespaceFor"
echo "ok  T-388: namespaceFor helper fails closed on a missing label"

# ===========================================================================
# SEC-003 — a sparse list from `--set ...namespaces[N].name=` must produce the
# actionable message, not a nil-deref panic blaming an unrelated label.
# ===========================================================================
if helm template lucairn "$CHART" "${COMMON[@]}" \
     --set 'infrastructure.namespaces[1].name=acme-identity' \
     >/dev/null 2>"$WORK/sparse.err"; then
  fail "SEC-003: sparse namespaces list rendered — the nil entries were not caught"
fi
grep -q "is null. This is what" "$WORK/sparse.err" \
  || fail "SEC-003: sparse list refused, but without the actionable values-file guidance. Got: $(head -2 "$WORK/sparse.err")"
grep -q "values FILE" "$WORK/sparse.err" \
  || fail "SEC-003: message does not prescribe the values-file remediation"
echo "ok  SEC-003: sparse --set list yields the actionable values-file message"

# The split-brain message must ALSO prescribe a values file rather than the
# --set form that cannot work.
grep -q "values FILE" "$WORK/diverge-sandbox-a.err" \
  || fail "SEC-003: the split-brain message still prescribes an unexecutable --set remediation"
echo "ok  SEC-003: split-brain message prescribes an executable remediation"

# ===========================================================================
# T-389 — union reachability of ollama-identity:11434 in the identity namespace.
# ===========================================================================
python3 "$ASSERT" ollama "$WORK/default.yaml" \
  || fail "T-389: 11434 reachability is wrong — see message above"
echo "ok  T-389: 11434 reachable only by sanitizer + model-pull Job (union of all policies)"

# T-389 — the client list is the single source for BOTH directions, so a client
# can never be half-authorised. Removing a name must break both policies.
for pol in identity-ollama-client-egress identity-ollama-ingress; do
  grep -q "$pol" "$WORK/default.yaml" || fail "T-389: policy $pol not rendered"
done
python3 - "$WORK/default.yaml" <<'PY' || exit 1
import sys, yaml
d={p['metadata']['name']:p for p in yaml.safe_load_all(open(sys.argv[1]))
   if p and p.get('kind')=='NetworkPolicy'}
def vals(sel):
    for e in (sel.get('matchExpressions') or []):
        if e['key']=='app.kubernetes.io/name' and e['operator']=='In':
            return sorted(e['values'])
    return None
eg=vals(d['identity-ollama-client-egress']['spec']['podSelector'])
ing=vals(d['identity-ollama-ingress']['spec']['ingress'][0]['from'][0]['podSelector'])
if eg!=ing or not eg:
    print("FAIL: T-389: egress/ingress client lists disagree: %s vs %s"%(eg,ing), file=sys.stderr); sys.exit(1)
PY
echo "ok  T-389: egress and ingress read the same client list"

# ===========================================================================
# T-390 — EVERY 0.0.0.0/0 ipBlock in the render, not a name allowlist.
# ===========================================================================
python3 "$ASSERT" cgnat "$WORK/default.yaml" \
  || fail "T-390: an 0.0.0.0/0 except-list is incomplete — see message above"
echo "ok  T-390: every 0.0.0.0/0 ipBlock covers RFC1918 + CGNAT + loopback + metadata"

# The exception must stay VISIBLE: ai-egress / ingest-egress are excused only
# because their rationale is written at the rule. Render them and confirm the
# sweep still passes with them present.
if ! helm template lucairn "$CHART" "${COMMON[@]}" \
       --set global.llmEgressEnabled=true --set global.ingestEgressEnabled=true \
       >"$WORK/egress-on.yaml" 2>"$WORK/egress-on.err"; then
  echo "T-390: llm/ingest-egress render FAILED:" >&2; cat "$WORK/egress-on.err" >&2; exit 1
fi
grep -q "name: ai-egress" "$WORK/egress-on.yaml" \
  || fail "T-390: ai-egress did not render — the exception arm proved nothing"
python3 "$ASSERT" cgnat "$WORK/egress-on.yaml" \
  || fail "T-390: sweep failed with the documented exceptions rendered"
echo "ok  T-390: documented ai-egress/ingest-egress exceptions are honoured by the sweep"

# T-390 — the IPv4-only caveat must stay documented for dual-stack operators.
grep -q "IPv4-ONLY" "$ROOT/charts/lucairn/values.yaml" \
  || fail "T-390: the IPv4-only dual-stack caveat was removed from values.yaml"
echo "ok  T-390: IPv4-only dual-stack caveat documented"

# ===========================================================================
# SEC-002 — CiliumNetworkPolicy DNS suffixes follow a namespace override.
# ===========================================================================
if ! helm template lucairn "$CHART" "${COMMON[@]}" --set global.dnsRestriction=true \
       -f "$WORK/ns-override.yaml" >"$WORK/cnp.yaml" 2>"$WORK/cnp.err"; then
  echo "SEC-002: dnsRestriction override render FAILED:" >&2; cat "$WORK/cnp.err" >&2; exit 1
fi
python3 "$ASSERT" dnsnames "$WORK/cnp.yaml" \
  || fail "SEC-002: CNP DNS patterns did not follow the namespace override"
echo "ok  SEC-002: CNP permits its own NEW namespace, no stale suffixes remain"

# ===========================================================================
# SEC-006 — infrastructure-off must not silently strip the policy layer WHERE
# THAT MATTERS, and must stay legal where the chart supports it.
#
# `global.dsaEnv` is a closed enum {development, production} and the chart
# already draws the line on exactly this question. These cases pin BOTH halves,
# and they pin the half that actually protects users against the message of the
# guard that really enforces it.
# ===========================================================================

# The ACTIVE control: production hard-rejects infrastructure-off via
# validators.enterpriseFullMeshMTLS's $mandatoryProfiles. Asserting the
# PRE-EXISTING message is deliberate — see the note below on why asserting our
# own SEC-006 message here would be a test that cannot fail for its stated
# reason.
if helm template lucairn "$CHART" \
     -f "$CHART/values-prod.yaml" -f "$CHART/values-prod-site.example.yaml" \
     --set infrastructure.enabled=false >/dev/null 2>"$WORK/prod-infra-off.err"; then
  fail "SEC-006: production render ACCEPTED infrastructure.enabled=false — the PII plane would deploy with no policy at all"
fi
grep -q "infrastructure.enabled must be true when global.dsaEnv=production" "$WORK/prod-infra-off.err" \
  || fail "SEC-006: production refused infrastructure-off, but not via \$mandatoryProfiles: $(head -2 "$WORK/prod-infra-off.err")"
echo "ok  SEC-006: production hard-rejects infrastructure.enabled=false (active control: \$mandatoryProfiles)"

# Development is EXEMPT, and must stay renderable: the repo's own
# tests/test_enterprise_mtls_production_values.sh performs this exact render
# twice. The first version of the SEC-006 guard fired here and turned CI red.
if ! helm template lucairn "$CHART" \
       "${HELM_TEST_SECRET_ARGS[@]}" \
       --set global.dsaEnv=development \
       --set global.skipPullSecretGuard=true \
       --set infrastructure.enabled=false \
       --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
       >/dev/null 2>"$WORK/dev-infra-off.err"; then
  echo "SEC-006: development render with infrastructure off FAILED:" >&2
  cat "$WORK/dev-infra-off.err" >&2
  fail "SEC-006: guard over-fires into the supported development path"
fi
echo "ok  SEC-006: development render with infrastructure off still succeeds (supported path)"

# The SEC-006 guard itself is a BACKSTOP: with development exempt and production
# already rejected earlier by $mandatoryProfiles, no reachable state hits it
# today. That is asserted here rather than left implicit, so that if someone
# later drops infrastructure.enabled from $mandatoryProfiles this line flips and
# the backstop's message starts appearing — a signal, not a silent handover.
if grep -q "infrastructure.enabled=false but these data-plane sub-charts" "$WORK/prod-infra-off.err"; then
  fail "SEC-006: the backstop guard fired instead of \$mandatoryProfiles — the active control moved; re-read both guards before trusting either"
fi
echo "ok  SEC-006: backstop guard is correctly shadowed by the active production control"

echo "PASS: tests/test_netpol_hardening.sh"
