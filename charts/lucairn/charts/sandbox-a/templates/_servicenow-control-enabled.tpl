{{- define "servicenowControl.enabled" -}}
{{- $global := .Values.global | default dict -}}
{{- $c := get $global "servicenowControl" | default dict -}}
{{- if hasKey $c "enabled" -}}
{{- if not (kindIs "bool" $c.enabled) -}}{{- fail "servicenowControl.enabled must be boolean" -}}{{- end -}}
{{- if $c.enabled -}}
{{- if and (ne .Chart.Name "lucairn") (not (contains "/charts/" .Template.BasePath)) -}}
{{- fail "ServiceNow control requires the umbrella chart; standalone subchart enablement is unsupported" -}}
{{- end -}}true{{- end -}}
{{- end -}}
{{- end -}}
