#!/usr/bin/env bash
#
# T-388 / T-389 / T-390 — NetworkPolicy hardening.
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
#   T-390  The `identity-model-registry-egress` ipBlock claimed "public
#          registries only" while its except-list omitted 100.64.0.0/10 (RFC
#          6598 CGNAT — where managed-Kubernetes Pod/Service CIDRs and overlay
#          networks commonly live) and 127.0.0.0/8 (loopback).
#
# The reachability cases evaluate the UNION of all policies in the namespace,
# which is the only semantics that means anything here: Kubernetes unions
# NetworkPolicies, so an added restrictive policy cannot subtract a permission
# an existing blanket rule already granted. A test that inspected only the new
# policy would pass even if the blanket rules still opened 11434 to everyone.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"

# shellcheck source=lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

if ! command -v helm >/dev/null 2>&1; then
  echo "SKIP: helm not installed"; exit 0
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "SKIP: python3 pyyaml not available"; exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# L3 on: ollama-identity, the model-pull Job and the registry-egress policy all
# render only in this combination.
COMMON=(
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
# T-388 case 1 — divergent namespace override must FAIL the render.
# Pre-change this rendered at exit 0 with six identity workloads (sanitizer,
# ollama-identity, postgres, redis cache, migrate Job, model-pull Job) in a
# namespace holding zero NetworkPolicies.
# ===========================================================================
if helm template lucairn "$CHART" "${COMMON[@]}" \
     --set sandbox-a.namespace=acme-identity >"$WORK/diverge.yaml" 2>"$WORK/diverge.err"; then
  fail "T-388: divergent sandbox-a.namespace override still renders (guard absent). Workloads would deploy unpoliced."
fi
grep -q "namespace/NetworkPolicy split-brain" "$WORK/diverge.err" \
  || fail "T-388: render refused, but not by validators.namespaceNetpolAlignment. Got: $(head -2 "$WORK/diverge.err")"
echo "ok  T-388: divergent namespace override is refused at render time"

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
YAML
if ! helm template lucairn "$CHART" "${COMMON[@]}" -f "$WORK/ns-override.yaml" \
     >"$WORK/moved.yaml" 2>"$WORK/moved.err"; then
  echo "T-388: consistent override render FAILED:" >&2; cat "$WORK/moved.err" >&2; exit 1
fi
python3 - "$WORK/moved.yaml" <<'PY' || exit 1
import sys, yaml
docs=[d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
pods={}; nps={}
for d in docs:
    ns=(d.get('metadata') or {}).get('namespace')
    if not ns: continue
    if d.get('kind') in ('Deployment','StatefulSet','Job','DaemonSet'):
        pods[ns]=pods.get(ns,0)+1
    if d.get('kind')=='NetworkPolicy':
        nps[ns]=nps.get(ns,0)+1
bad=[ns for ns in pods if nps.get(ns,0)==0]
if bad:
    print("FAIL: T-388: namespaces with workloads but ZERO NetworkPolicies: %s"%bad, file=sys.stderr); sys.exit(1)
if pods.get('acme-identity',0)==0 or nps.get('acme-identity',0)==0:
    print("FAIL: T-388: consistent override did not move workloads+policies to acme-identity "
          "(workloads=%d policies=%d)"%(pods.get('acme-identity',0),nps.get('acme-identity',0)), file=sys.stderr); sys.exit(1)
if nps.get('dsa-identity',0)!=0:
    print("FAIL: T-388: %d policies stranded on the vacated dsa-identity"%nps['dsa-identity'], file=sys.stderr); sys.exit(1)
PY
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
# T-389 — union reachability of ollama-identity:11434 in the identity namespace.
# ===========================================================================
python3 - "$WORK/default.yaml" <<'PY' || exit 1
import sys, yaml
pols=[d for d in yaml.safe_load_all(open(sys.argv[1]))
      if d and d.get('kind')=='NetworkPolicy'
      and (d.get('metadata') or {}).get('namespace')=='dsa-identity']

def sel_match(sel, labels):
    if sel is None: return False
    if sel == {}: return True
    for k,v in (sel.get('matchLabels') or {}).items():
        if labels.get(k)!=v: return False
    for e in (sel.get('matchExpressions') or []):
        k,op,vals=e['key'],e['operator'],e.get('values',[])
        lv=labels.get(k)
        if op=='In' and lv not in vals: return False
        if op=='NotIn' and lv in vals: return False
        if op=='Exists' and k not in labels: return False
        if op=='DoesNotExist' and k in labels: return False
    return True

def port_allowed(rule, port):
    ps=rule.get('ports')
    if ps is None: return True          # no ports key = EVERY port
    return any(p.get('port')==port for p in ps)

OLLAMA={'app.kubernetes.io/name':'ollama-identity','app.kubernetes.io/part-of':'dsa'}
PORT=11434

def reaches(labels):
    eg=ing=False
    for p in pols:
        s=p['spec']; t=s.get('policyTypes',[])
        if 'Egress' in t and sel_match(s.get('podSelector'),labels):
            for r in (s.get('egress') or []):
                if not port_allowed(r,PORT): continue
                for to in (r.get('to') or []):
                    if 'ipBlock' in to or 'namespaceSelector' in to: continue
                    if sel_match(to.get('podSelector'),OLLAMA): eg=True
        if 'Ingress' in t and sel_match(s.get('podSelector'),OLLAMA):
            for r in (s.get('ingress') or []):
                if not port_allowed(r,PORT): continue
                for fr in (r.get('from') or []):
                    if 'ipBlock' in fr or 'namespaceSelector' in fr: continue
                    if sel_match(fr.get('podSelector'),labels): ing=True
    return eg and ing

ALLOWED={
  'sanitizer (sandbox-a)': {'app.kubernetes.io/name':'sandbox-a','app.kubernetes.io/part-of':'dsa'},
  'model-pull Job':        {'app.kubernetes.io/name':'ollama-identity-model-pull','dsa.io/model-pull':'true'},
}
DENIED={
  'generic/compromised pod': {'app.kubernetes.io/name':'attacker','app.kubernetes.io/part-of':'dsa'},
  'postgresql':              {'app.kubernetes.io/name':'sandbox-a-postgresql'},
  'pii-ml':                  {'app.kubernetes.io/name':'pii-ml'},
  'redis sanitizer-cache':   {'app.kubernetes.io/name':'sandbox-a-sanitizer-cache'},
}
rc=0
for n,l in ALLOWED.items():
    if not reaches(l):
        print("FAIL: T-389: legitimate client %s can NOT reach 11434 — this breaks %s"%(
              n, "L3 scanning" if 'sandbox-a'==l['app.kubernetes.io/name'] else "model staging"), file=sys.stderr); rc=1
for n,l in DENIED.items():
    if reaches(l):
        print("FAIL: T-389: %s CAN still reach ollama-identity:11434"%n, file=sys.stderr); rc=1
sys.exit(rc)
PY
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
# T-390 — model-registry except-list covers CGNAT + loopback.
# ===========================================================================
python3 - "$WORK/default.yaml" <<'PY' || exit 1
import sys, yaml
REQ={'10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16','100.64.0.0/10','127.0.0.0/8'}
pols=[d for d in yaml.safe_load_all(open(sys.argv[1]))
      if d and d.get('kind')=='NetworkPolicy'
      and d['metadata']['name'] in ('identity-model-registry-egress','model-pull-egress')]
if not pols:
    print("FAIL: T-390: no model-registry egress policy rendered", file=sys.stderr); sys.exit(1)
rc=0
for p in pols:
    for r in p['spec'].get('egress') or []:
        for to in (r.get('to') or []):
            ib=to.get('ipBlock')
            if not ib or ib.get('cidr')!='0.0.0.0/0': continue
            missing=REQ-set(ib.get('except') or [])
            if missing:
                print("FAIL: T-390: %s ipBlock except-list missing %s"%(
                      p['metadata']['name'], sorted(missing)), file=sys.stderr); rc=1
sys.exit(rc)
PY
echo "ok  T-390: model-registry except-lists cover RFC1918 + CGNAT + loopback + metadata"

# T-390 — the IPv4-only caveat must stay documented for dual-stack operators.
grep -q "IPv4-ONLY" "$ROOT/charts/lucairn/values.yaml" \
  || fail "T-390: the IPv4-only dual-stack caveat was removed from values.yaml"
echo "ok  T-390: IPv4-only dual-stack caveat documented"

echo "PASS: tests/test_netpol_hardening.sh"
