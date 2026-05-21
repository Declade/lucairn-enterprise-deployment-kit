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
