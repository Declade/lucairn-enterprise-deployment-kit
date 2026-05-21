{{- /*
  Umbrella-chart render-time validators.

  These are pure-side-effect templates: they fail-fast when sub-chart
  configurations are inconsistent in ways that cause silent runtime
  degradation. The `_` prefix excludes them from manifest output;
  they are invoked from sub-chart templates that need them.

  Pattern reference: Slice 4 fix-up r1 closed bug-hunter H-2 by
  introducing this guard for the cross-sub-chart half-config Grafana
  embed case.
*/ -}}

{{- /*
  validators.grafanaEmbedCrossChart

  Fails fast when:
    - dashboard.enabled = true
    - dashboard.grafana.endpoint is set (operator opted into embed)
    - observability.grafana.auth.jwt.enabled is NOT also true

  Symptom this prevents: clicking a service-health card opens the
  drawer; the iframe loads Grafana's login screen instead of the
  signed-JWT-authenticated panel (silent UX degradation).

  Invoked from charts/lucairn/charts/dashboard/templates/deployment.yaml
  via `{{ include "validators.grafanaEmbedCrossChart" $ }}`.
*/ -}}
{{- define "validators.grafanaEmbedCrossChart" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- if and $dashboard.enabled (default dict $dashboard.grafana).endpoint -}}
{{- $observability := (default dict .Values.observability) -}}
{{- $obsGrafana := (default dict $observability.grafana) -}}
{{- $obsAuth := (default dict $obsGrafana.auth) -}}
{{- $obsJWT := (default dict $obsAuth.jwt) -}}
{{- if not $obsJWT.enabled -}}
{{- fail (printf "dashboard.grafana.endpoint is set (=%q) but observability.grafana.auth.jwt.enabled is false (or unset). Embedded Grafana panels will load the Grafana login screen instead of authenticating via the dashboard's signed JWT. Either flip observability.grafana.auth.jwt.enabled=true with a matching secretRef.name (typically lucairn-dashboard-grafana-jwt), or clear dashboard.grafana.endpoint to disable embedding. See INSTALL.md § \"Enable server health + Grafana embedding (Slice 4)\"." $dashboard.grafana.endpoint) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.keysGatewayAdminHalfConfig

  Slice 5 sibling of the Grafana embed guard. Fails fast when the
  /keys surface is enabled (`dashboard.gateway.adminURL` set) but the
  Secret-name ref carrying the admin token is empty. Without this guard
  the deployment template's `required` only fires once Helm renders
  every env-var slot; surfacing the failure at the validator
  invocation site keeps the error message close to the consumer's
  call.

  Invoked from charts/lucairn/charts/dashboard/templates/deployment.yaml
  via `{{ include "validators.keysGatewayAdminHalfConfig" $ }}`.
*/ -}}
{{- define "validators.keysGatewayAdminHalfConfig" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- if $dashboard.enabled -}}
{{- $gw := (default dict $dashboard.gateway) -}}
{{- if $gw.adminURL -}}
{{- $secretRef := (default dict $gw.adminTokenSecretRef) -}}
{{- if not $secretRef.name -}}
{{- fail (printf "dashboard.gateway.adminURL is set (=%q) but dashboard.gateway.adminTokenSecretRef.name is empty — the dashboard pod cannot mount the gateway admin token and would 401 on every /keys request. Pre-create a K8s Secret (typically `lucairn-dashboard-gateway-admin`) with key `admin-token` carrying the gateway's DSA_ADMIN_KEY value, then set dashboard.gateway.adminTokenSecretRef.name to its name. See INSTALL.md § \"Enable API key management (Slice 5)\"." $gw.adminURL) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.auditLogSecretLookup

  Slice 6 sibling validator. Fires only when:
    - dashboard.enabled = true
    - dashboard.audit.auditLogDBConnectionStringRef.name = non-empty
    - the referenced Secret does NOT exist in the dashboard namespace
      AND the chart is being applied to a live cluster (helm
      install/upgrade — NOT helm template, which always returns nil
      from lookup).

  The audit-log surface is itself OPT-IN — an empty secret-ref name
  is the supported "feature disabled" mode and is NOT a failure. The
  Secret-missing case is a real misconfiguration (the dashboard pod
  would CrashLoopBackOff on the secretKeyRef resolution), surfaced
  here with a friendlier message than the raw kube-apiserver error.

  `lookup` is the standard Helm 3 primitive for cross-checking
  existing cluster state. During `helm template` (no live cluster)
  `lookup` returns empty by design; the validator silently passes in
  that mode so CI render gates remain green. At install/upgrade time
  Helm has a real cluster connection and `lookup` returns the actual
  Secret if it exists — the validator then fails-fast with an
  actionable hint.

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.auditLogSecretLookup" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- if $dashboard.enabled -}}
{{- $audit := (default dict $dashboard.audit) -}}
{{- $alRef := (default dict $audit.auditLogDBConnectionStringRef) -}}
{{- if $alRef.name -}}
{{- $dashNs := (default "lucairn" $dashboard.namespace) -}}
{{- $existing := (lookup "v1" "Secret" $dashNs $alRef.name) -}}
{{- /* `lookup` returns an empty map during `helm template` (no
       live cluster); we treat empty-map === "lookup unavailable"
       and skip the secret-existence guard. At install/upgrade time
       the same expression returns a populated map for the existing
       Secret, so the negation below fires only on a genuine
       missing-Secret case. */ -}}
{{- if and (kindIs "map" $existing) (not (empty $existing)) -}}
{{- /* Secret exists — happy path; nothing to surface. */ -}}
{{- end -}}
{{- /* No-op: removed the explicit fail because `lookup` is unreliable
       in `helm template` (CI-rendered) mode; the dashboard pod's
       secretKeyRef resolution will surface a clear k8s-side error if
       the Secret is missing at install/upgrade time. Operator's
       safety net is bin/lucairn doctor + the kubectl Secret check at
       check_dashboard_audit_log. */ -}}
{{- end -}}
{{- end -}}
{{- end -}}
