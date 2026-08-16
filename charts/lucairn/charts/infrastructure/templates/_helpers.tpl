{{- /*
  infrastructure.namespaceFor  (T-388)

  Resolve a dsa-* namespace NAME from its stable LABEL, using the single
  `infrastructure.namespaces` list that already drives namespaces.yaml,
  default-deny.yaml, dns-egress.yaml and pull-secrets.yaml.

  WHY THIS EXISTS. Every NetworkPolicy in this sub-chart used to hardcode its
  `metadata.namespace` (e.g. `namespace: dsa-identity`) while the workloads
  those policies are meant to select template theirs from `.Values.namespace`
  in their OWN sub-chart. Overriding a workload namespace therefore moved the
  pods but left every policy — including `default-deny-all` — pointing at the
  now-empty original namespace. The pods landed somewhere with NO policy
  selecting them, which under Kubernetes NetworkPolicy semantics is
  default-ALLOW: unrestricted egress for the PII plane, rendered silently at
  exit 0.

  Routing every policy namespace through this helper makes
  `infrastructure.namespaces` the one place a namespace name is written IN THIS
  SUB-CHART's rendered output, so an operator override moves the policies WITH
  the pods.

  SCOPE OF THAT CLAIM (SEC-002 — the first version of this comment overstated
  it). It is NOT true that a namespace name is written in only one place
  repo-wide. Two other classes of literal exist and are deliberately in scope
  here or explicitly out of it:
    - CiliumNetworkPolicy DNS suffixes in dns-restriction.yaml embed the
      namespace inside a match pattern (`*.<ns>.svc.cluster.local`) rather than
      in `metadata.namespace`. Those are ALSO routed through this helper. They
      had to be: with an override, the CNP correctly moved to the new namespace
      and then permitted only the OLD namespace's DNS names, so the sanitizer
      could not resolve its own postgres or ollama — an availability inversion
      that the metadata-only fix CREATED.
    - Each workload sub-chart's own `.Values.namespace`, which this helper
      cannot see (below).

  Sub-charts cannot read each other's values, so this helper cannot see
  `sandbox-a.namespace` directly. The remaining half of the invariant — that
  each workload sub-chart's `.namespace` still AGREES with this list — is
  enforced at the umbrella level by `validators.namespaceNetpolAlignment`
  (charts/lucairn/templates/_validators.tpl). Helper + validator together are
  what close T-388; neither is sufficient alone.

  Usage:
    namespace: {{ include "infrastructure.namespaceFor" (dict "root" $ "label" "identity") }}

  Fails the render when the label is absent, so deleting an entry from
  `infrastructure.namespaces` can never silently drop a policy's namespace to
  the empty string (which Helm would render as the release namespace).
*/ -}}
{{- define "infrastructure.namespaceFor" -}}
{{- $label := .label -}}
{{- $found := "" -}}
{{- range $i, $entry := .root.Values.namespaces -}}
{{- /* SEC-003: `--set infrastructure.namespaces[1].name=x` builds a SPARSE
       list — Helm fills the untouched indices with nil. Without this guard the
       range dereferences nil and Helm raises a raw template panic naming
       whichever label happened to be looked up first, which tells the operator
       nothing about what they actually did wrong. Fail with the real cause. */ -}}
{{- if not $entry -}}
{{- fail (printf "infrastructure.namespaces[%d] is null. This is what `--set infrastructure.namespaces[N].name=...` produces: Helm rebuilds the list with only index N populated and every other entry nil. Namespace overrides must be supplied as a values FILE containing the COMPLETE list (every entry keeping both `name` and `label`), e.g.\n\n  infrastructure:\n    namespaces:\n      - {name: dsa-edge, label: edge}\n      - {name: my-identity, label: identity}\n      - ... all remaining entries ...\n\nthen `helm ... -f my-namespaces.yaml`. Remember to set the matching workload sub-chart namespace too (e.g. sandbox-a.namespace), or validators.namespaceNetpolAlignment will refuse the render." $i) -}}
{{- end -}}
{{- if eq (toString $entry.label) $label -}}
{{- $found = (toString $entry.name) -}}
{{- end -}}
{{- end -}}
{{- if eq $found "" -}}
{{- fail (printf "infrastructure.namespaces has no entry with label %q, but a NetworkPolicy in the infrastructure sub-chart needs that namespace's name. Every entry must keep its `label` key (edge/identity/bridge/ai/audit/observability/ingest/admin/witness/demo) — the labels are the stable join key between namespaces.yaml, the NetworkPolicies, and validators.namespaceNetpolAlignment. Rename the `name` field to move a namespace; never drop or rename the `label`." $label) -}}
{{- end -}}
{{- $found -}}
{{- end -}}
