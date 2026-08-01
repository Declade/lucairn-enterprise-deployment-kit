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
  `infrastructure.namespaces` the one place a namespace name is written, so an
  operator override moves the policies WITH the pods.

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
{{- range .root.Values.namespaces -}}
{{- if eq (toString .label) $label -}}
{{- $found = (toString .name) -}}
{{- end -}}
{{- end -}}
{{- if eq $found "" -}}
{{- fail (printf "infrastructure.namespaces has no entry with label %q, but a NetworkPolicy in the infrastructure sub-chart needs that namespace's name. Every entry must keep its `label` key (edge/identity/bridge/ai/audit/observability/ingest/admin/witness/demo) — the labels are the stable join key between namespaces.yaml, the NetworkPolicies, and validators.namespaceNetpolAlignment. Rename the `name` field to move a namespace; never drop or rename the `label`." $label) -}}
{{- end -}}
{{- $found -}}
{{- end -}}
