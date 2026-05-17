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
