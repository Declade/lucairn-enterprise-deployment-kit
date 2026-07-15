{{/*
Fail closed before a direct Sandbox A chart render can rely on the service's
runtime default. This mirrors the umbrella guard because Helm permits the
child chart to be installed independently.
*/}}
{{- define "sandbox-a.validateEphemeral" -}}
{{- if not (hasKey .Values "ephemeral") -}}
{{- fail "sandbox-a.ephemeral is required and must be the YAML string \"true\" or \"false\"; set it explicitly in the selected profile." -}}
{{- end -}}
{{- $ephemeral := index .Values "ephemeral" -}}
{{- if or (not (kindIs "string" $ephemeral)) (not (has $ephemeral (list "true" "false"))) -}}
{{- fail "sandbox-a.ephemeral must be the YAML string \"true\" or \"false\"; YAML booleans, null, numbers, lists, maps, and other strings are refused." -}}
{{- end -}}
{{- end -}}
