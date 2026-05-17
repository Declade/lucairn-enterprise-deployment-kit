{{/*
Helper templates for the dashboard sub-chart.
*/}}

{{- define "dashboard.fullname" -}}
{{- printf "lucairn-dashboard" -}}
{{- end -}}

{{- define "dashboard.bootstrapAdminSecretName" -}}
{{- if .Values.bootstrapAdmin.passwordSecretName -}}
{{ .Values.bootstrapAdmin.passwordSecretName }}
{{- else -}}
{{ include "dashboard.fullname" . }}-bootstrap-admin
{{- end -}}
{{- end -}}

{{- /*
  dashboard.image
  ────────────────
  The dashboard image tag is INDEPENDENT from global.imageTag — bumping
  the umbrella chart's --set global.imageTag=X does NOT bump this image's
  tag. The dashboard ships on its own release cadence (bound to the kit's
  appVersion via .Chart.AppVersion). Operators override the dashboard tag
  via .Values.image.tag (or LUCAIRN_DASHBOARD_IMAGE_TAG on the compose
  path). TODO(slice-2 design review): decide whether to passthrough
  global.imageTag here when dashboard releases are aligned with kit
  releases, or keep the independent cadence forever.
  TODO(bug-hunter F-14): add a chart test asserting that
  .Values.bootstrapAdmin.passwordSecretName override path renders the
  Secret-less code path correctly.
*/ -}}
{{- define "dashboard.image" -}}
{{- $registry := default "" .Values.global.imageRegistry -}}
{{- $repo := .Values.image.repository -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if $registry -}}
{{ printf "%s/%s:%s" $registry $repo $tag }}
{{- else -}}
{{ printf "%s:%s" $repo $tag }}
{{- end -}}
{{- end -}}

{{- define "dashboard.labels" -}}
app.kubernetes.io/name: {{ include "dashboard.fullname" . }}
app.kubernetes.io/part-of: lucairn
app.kubernetes.io/component: dashboard
{{- end -}}

{{- /*
  dashboard.grafanaJWTSecretName
  ───────────────────────────────
  Slice 4 — Helm-managed shared-secret name. Mirrors the
  dashboard.bootstrapAdminSecretName helper: when the operator pre-creates
  their own Secret + sets dashboard.grafana.jwt.secretName, we honour that
  name; otherwise we generate a default name + render the Secret via
  secret-grafana-jwt.yaml.
*/ -}}
{{- define "dashboard.grafanaJWTSecretName" -}}
{{- if .Values.grafana.jwt.secretName -}}
{{ .Values.grafana.jwt.secretName }}
{{- else -}}
{{ include "dashboard.fullname" . }}-grafana-jwt
{{- end -}}
{{- end -}}
