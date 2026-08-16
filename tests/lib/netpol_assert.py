#!/usr/bin/env python3
"""NetworkPolicy assertions for the T-388/T-389/T-390 hardening.

Called by tests/invariant/helm_networkpolicy_test.sh (checks 6-8). Kept out of
the shell script because label-selector and CIDR-set semantics cannot be
evaluated correctly with grep -- and a check that only LOOKS like it evaluates
them is worse than no check.

Modes
  moved  <render>   T-388: no namespace may hold workloads with zero
                    NetworkPolicies, the override target must have received
                    both, and nothing may be stranded on the vacated namespace.
  ollama <render>   T-389: ollama-identity:11434 reachable from the sanitizer
                    and the model-pull Job, and from nothing else.
  cgnat  <render>   T-390: model-registry ipBlock except-lists cover RFC 1918,
                    RFC 6598 CGNAT, loopback and the metadata endpoint.

Exit 0 = invariant holds. Exit 1 = violation, reason on stdout.
"""
import sys

import yaml

IDENTITY_NS = "dsa-identity"
OLLAMA_PORT = 11434

# The pod that serves the L3 runtime. Ingress rules are evaluated against this
# label set; egress rules are evaluated against it as the DESTINATION.
OLLAMA_POD = {
    "app.kubernetes.io/name": "ollama-identity",
    "app.kubernetes.io/part-of": "dsa",
}

# Clients that MUST keep working. Dropping either breaks a real function:
# sandbox-a is the sanitizer (L3 scanning), ollama-identity-model-pull is the
# staging Job that drives the pull through the server.
ALLOWED_CLIENTS = {
    "sanitizer (sandbox-a)": {
        "app.kubernetes.io/name": "sandbox-a",
        "app.kubernetes.io/part-of": "dsa",
    },
    "model-pull Job": {
        "app.kubernetes.io/name": "ollama-identity-model-pull",
        "dsa.io/model-pull": "true",
    },
}

# Pods that must NOT reach the Ollama API. "attacker" stands in for any
# compromised or future workload in the namespace -- it carries only the labels
# every dsa pod carries, so if the selector matches it, the rule is namespace-wide.
DENIED_CLIENTS = {
    "generic/compromised pod": {
        "app.kubernetes.io/name": "attacker",
        "app.kubernetes.io/part-of": "dsa",
    },
    "postgresql": {"app.kubernetes.io/name": "sandbox-a-postgresql"},
    # Present only in the enterprise kit's chart. Listed anyway: the assertion is
    # about whether a pod carrying these labels WOULD be selected, which is a
    # property of the policies alone. That keeps this file byte-identical across
    # both repos, so the two copies cannot drift.
    "pii-ml": {"app.kubernetes.io/name": "pii-ml"},
    "redis sanitizer-cache": {"app.kubernetes.io/name": "sandbox-a-sanitizer-cache"},
}

REQUIRED_EXCEPT = {
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "100.64.0.0/10",  # RFC 6598 CGNAT: managed-k8s Pod/Service CIDRs, overlays
    "127.0.0.0/8",  # loopback
}

# T-390 assertion scope: EVERY 0.0.0.0/0 ipBlock in the render must carry the
# full except-list -- asserting over a two-name allowlist let four rules escape
# the property (SEC-001). Rules that legitimately differ are named here, so the
# exception is visible in the test rather than implied by the test's silence.
#
# Both entries reach an OPERATOR-CONFIGURED endpoint where a CGNAT address is a
# supported topology (a Tailscale-hosted model gateway; a customer's on-prem
# data source across an overlay). Excluding 100.64.0.0/10 there would break real
# installs. The rationale and the residual risk are stated at each rule in
# infrastructure/templates/network-policies.yaml. Adding a name here requires
# the same treatment -- do not extend this list to silence a failure.
CGNAT_EXEMPT_POLICIES = {
    "ai-egress": "external LLM providers; operator may host behind CGNAT/Tailscale",
    "ingest-egress": "customer data sources; on-prem/overlay CGNAT is ordinary",
}

# The labels a namespace carries, for evaluating namespaceSelector peers. Keyed
# by namespace name; mirrors infrastructure/templates/namespaces.yaml.
NAMESPACE_LABELS = {
    "dsa-edge": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "edge"},
    "dsa-identity": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "identity"},
    "dsa-bridge": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "bridge"},
    "dsa-ai": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "ai"},
    "dsa-audit": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "audit"},
    "dsa-observability": {
        "app.kubernetes.io/part-of": "dsa",
        "dsa.io/namespace": "observability",
    },
    "dsa-ingest": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "ingest"},
    "dsa-admin": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "admin"},
    "dsa-witness": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "witness"},
    "dsa-demo": {"app.kubernetes.io/part-of": "dsa", "dsa.io/namespace": "demo"},
}


def load(path):
    return [d for d in yaml.safe_load_all(open(path)) if d]


def selector_matches(selector, labels):
    """Evaluate a Kubernetes LabelSelector against a pod's labels.

    `None` means the enclosing peer had no podSelector at all (no match here);
    `{}` is the empty selector, which matches EVERY pod in the namespace.
    """
    if selector is None:
        return False
    if selector == {}:
        return True
    for key, want in (selector.get("matchLabels") or {}).items():
        if labels.get(key) != want:
            return False
    for expr in selector.get("matchExpressions") or []:
        key, op = expr["key"], expr["operator"]
        values = expr.get("values", [])
        have = labels.get(key)
        if op == "In" and have not in values:
            return False
        if op == "NotIn" and have in values:
            return False
        if op == "Exists" and key not in labels:
            return False
        if op == "DoesNotExist" and key in labels:
            return False
    return True


def port_allowed(rule, port):
    """Does `rule` permit `port`?

    An absent `ports` key means EVERY port -- the T-389 root cause.

    SEC-005: a `ports` entry may declare a RANGE via `endPort`, in which case
    `port` is the range's lower bound. Comparing only against `port` would miss
    a rule that covers 11434 as part of e.g. 11000-12000, and the check would
    report BLOCKED for traffic the cluster actually allows.
    """
    ports = rule.get("ports")
    if ports is None:
        return True
    for spec in ports:
        start = spec.get("port")
        if not isinstance(start, int):
            # A named port (string) cannot be resolved without the pod spec.
            # Treat it as non-matching rather than guessing, and surface it so a
            # future named-port rule cannot silently weaken this evaluator.
            continue
        end = spec.get("endPort", start)
        if start <= port <= end:
            return True
    return False


def peer_matches_pod(peer, pod_labels, pod_namespace):
    """Does a NetworkPolicy peer select the pod (`pod_labels` in `pod_namespace`)?

    SEC-005: the original evaluator skipped every peer carrying a
    namespaceSelector, which silently under-counted reachability. The three
    forms that matter:

      {podSelector: X}                     same namespace as the policy, X selects the pod
      {namespaceSelector: N}               any pod in a namespace matching N
      {namespaceSelector: N, podSelector: X}   AND -- both must match

    The AND-form with `podSelector: {}` is the one that bites: it reads like a
    namespace-only rule but is a full cross-namespace grant to every pod there.
    """
    if "ipBlock" in peer:
        return False
    ns_sel = peer.get("namespaceSelector")
    pod_sel = peer.get("podSelector")

    if ns_sel is not None:
        if not selector_matches(ns_sel, NAMESPACE_LABELS.get(pod_namespace, {})):
            return False
        # namespaceSelector alone selects every pod in the matching namespace.
        if pod_sel is None:
            return True
        return selector_matches(pod_sel, pod_labels)

    # No namespaceSelector: the peer is scoped to the policy's own namespace.
    return selector_matches(pod_sel, pod_labels)


def reaches_ollama(policies, labels):
    """True when `labels` can open a connection to ollama-identity:11434.

    Needs BOTH an egress rule on the source and an ingress rule on the
    destination, and considers the UNION of every policy -- which is the only
    correct reading, since Kubernetes never lets one policy subtract another's
    permission.
    """
    egress_ok = ingress_ok = False
    for pol in policies:
        spec = pol["spec"]
        types = spec.get("policyTypes", [])
        if "Egress" in types and selector_matches(spec.get("podSelector"), labels):
            for rule in spec.get("egress") or []:
                if not port_allowed(rule, OLLAMA_PORT):
                    continue
                for peer in rule.get("to") or []:
                    if peer_matches_pod(peer, OLLAMA_POD, IDENTITY_NS):
                        egress_ok = True
        if "Ingress" in types and selector_matches(spec.get("podSelector"), OLLAMA_POD):
            for rule in spec.get("ingress") or []:
                if not port_allowed(rule, OLLAMA_PORT):
                    continue
                for peer in rule.get("from") or []:
                    if peer_matches_pod(peer, labels, IDENTITY_NS):
                        ingress_ok = True
    return egress_ok and ingress_ok


def check_moved(docs):
    """T-388: an override moves workloads and their policies together.

    SCOPE (BH-F5): "no namespace holds workloads with zero policies" is asserted
    for the STOCK enable-set this suite renders. It is not a whole-chart
    invariant -- the kit's `dashboard` sub-chart deploys into namespace
    `lucairn`, which has no entry in infrastructure.namespaces and no policy of
    its own, and is excluded from validators.namespaceNetpolAlignment for that
    reason (tracked as T-417). Enabling it would legitimately trip this check.

    CiliumNetworkPolicy counts alongside NetworkPolicy (SEC-002): with
    `global.dnsRestriction` on -- the DEFAULT in dual-sandbox-architecture --
    the CNPs are part of what must follow the pods, and counting only
    NetworkPolicy would call a namespace policed while its DNS restrictions
    still pointed at the vacated one.
    """
    pods, nps = {}, {}
    for d in docs:
        ns = (d.get("metadata") or {}).get("namespace")
        if not ns:
            continue
        if d.get("kind") in ("Deployment", "StatefulSet", "Job", "DaemonSet"):
            pods[ns] = pods.get(ns, 0) + 1
        if d.get("kind") in ("NetworkPolicy", "CiliumNetworkPolicy"):
            nps[ns] = nps.get(ns, 0) + 1
    problems = []
    unpoliced = [ns for ns in pods if nps.get(ns, 0) == 0]
    if unpoliced:
        problems.append(
            "namespaces holding workloads but ZERO policies "
            "(default-ALLOW): %s" % sorted(unpoliced)
        )
    if not pods.get("acme-identity") or not nps.get("acme-identity"):
        problems.append(
            "consistent override did not move both: acme-identity has "
            "%d workloads / %d policies"
            % (pods.get("acme-identity", 0), nps.get("acme-identity", 0))
        )
    if nps.get("dsa-identity", 0):
        problems.append(
            "%d policies stranded on the vacated dsa-identity" % nps["dsa-identity"]
        )
    return problems


def check_ollama(docs):
    policies = [
        d
        for d in docs
        if d.get("kind") == "NetworkPolicy"
        and (d.get("metadata") or {}).get("namespace") == IDENTITY_NS
    ]
    if not policies:
        return ["no NetworkPolicy rendered in %s" % IDENTITY_NS]
    problems = []
    for name, labels in ALLOWED_CLIENTS.items():
        if not reaches_ollama(policies, labels):
            problems.append(
                "legitimate client BLOCKED from 11434: %s -- this breaks "
                "L3 scanning or model staging" % name
            )
    for name, labels in DENIED_CLIENTS.items():
        if reaches_ollama(policies, labels):
            problems.append("unauthorised pod CAN reach ollama-identity:11434: %s" % name)
    return problems


def check_cgnat(docs):
    """Every 0.0.0.0/0 ipBlock carries the full except-list, or is a named exception.

    Asserting over a hand-listed pair of policy names (the first version of this
    check) meant four other 0.0.0.0/0 rules were never examined -- the property
    only held where someone had remembered to look. Sweeping the whole render
    inverts that: a NEW rule is covered the moment it is added, and skipping one
    requires writing its name and reason into CGNAT_EXEMPT_POLICIES.
    """
    problems = []
    seen = 0
    for doc in docs:
        if doc.get("kind") != "NetworkPolicy":
            continue
        name = doc["metadata"]["name"]
        for direction in ("egress", "ingress"):
            for rule in doc["spec"].get(direction) or []:
                peers = rule.get("to" if direction == "egress" else "from") or []
                for peer in peers:
                    block = peer.get("ipBlock")
                    if not block or block.get("cidr") != "0.0.0.0/0":
                        continue
                    seen += 1
                    if name in CGNAT_EXEMPT_POLICIES:
                        continue
                    missing = REQUIRED_EXCEPT - set(block.get("except") or [])
                    if missing:
                        problems.append(
                            "%s (%s) 0.0.0.0/0 ipBlock except-list missing %s"
                            % (name, direction, sorted(missing))
                        )
    if seen == 0:
        problems.append(
            "no 0.0.0.0/0 ipBlock found in the render -- the sweep examined "
            "nothing, so a green result here would be vacuous"
        )
    return problems


def check_dnsnames(docs):
    """SEC-002: CiliumNetworkPolicy DNS patterns follow the namespace override.

    The T-388 metadata fix moved each CNP to the overridden namespace but left
    its `matchPattern` suffixes naming the OLD one, so a pod in the new
    namespace was permitted to resolve the vacated namespace's service names and
    NOT its own -- the sanitizer could not resolve its own postgres or ollama.
    An availability inversion introduced BY the fix, which is why it gets its own
    control rather than riding on check_moved.

    Run against a render whose identity namespace was overridden to
    `acme-identity`.
    """
    cnps = [d for d in docs if d.get("kind") == "CiliumNetworkPolicy"]
    if not cnps:
        return [
            "no CiliumNetworkPolicy rendered -- global.dnsRestriction must be on "
            "for this control to mean anything"
        ]
    problems = []
    own_ns_checked = False
    for cnp in cnps:
        ns = cnp["metadata"].get("namespace")
        patterns = []
        for rule in cnp["spec"].get("egress") or []:
            for port in rule.get("toPorts") or []:
                for dns in (port.get("rules") or {}).get("dns") or []:
                    if "matchPattern" in dns:
                        patterns.append(dns["matchPattern"])
        # Any pattern still naming the vacated namespace is the bug itself.
        stale = [p for p in patterns if "dsa-identity" in p]
        if stale:
            problems.append(
                "%s (ns=%s) still permits the VACATED namespace's DNS names: %s"
                % (cnp["metadata"]["name"], ns, stale)
            )
        # The identity CNP must permit its own (new) namespace.
        if ns == "acme-identity":
            own_ns_checked = True
            if not any("acme-identity" in p for p in patterns):
                problems.append(
                    "%s sits in acme-identity but permits no *.acme-identity "
                    "DNS names -- pods cannot resolve their own services: %s"
                    % (cnp["metadata"]["name"], patterns)
                )
    if not own_ns_checked:
        problems.append(
            "no CiliumNetworkPolicy landed in acme-identity -- the override "
            "under test did not take effect, so this control proved nothing"
        )
    return problems


MODES = {
    "moved": check_moved,
    "ollama": check_ollama,
    "cgnat": check_cgnat,
    "dnsnames": check_dnsnames,
}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in MODES:
        print("usage: netpol_assert.py {%s} <render.yaml>" % "|".join(MODES))
        return 2
    problems = MODES[sys.argv[1]](load(sys.argv[2]))
    for p in problems:
        print("    %s" % p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
