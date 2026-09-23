{{- /*
  sandbox-a.env.noExpansion — (dict "key" "x.y" "value" <raw>)   (T-871)

  Standalone twin of the umbrella's `lucairn.env.noExpansion`
  (charts/lucairn/templates/_env_literals.tpl): this sub-chart renders
  standalone (tests/test_wp1_s4_helm_boundary.sh), where umbrella templates are
  not loaded. Renders nothing; fails the render when the value contains "$",
  because Kubernetes expands `$(NAME)` and reduces `$$` in container env values
  and args at Pod creation, so the process would read a different value from
  the one rendered. The message NEVER echoes the value (a Redis URL can carry a
  password); it names only its length.
*/ -}}
{{- define "sandbox-a.env.noExpansion" -}}
{{- if and (not (kindIs "invalid" .value)) (contains "$" (toString .value)) -}}
{{- $s := toString .value -}}
{{- $spelling := "`$`" -}}
{{- if contains "$(" $s -}}{{- $spelling = "a `$(NAME)` variable reference" -}}{{- else if contains "$$" $s -}}{{- $spelling = "`$$`" -}}{{- end -}}
{{- fail (printf "sandbox-a: %s is a %d-character value containing %s (value withheld). It contains \"$\": Kubernetes expands `$(NAME)` in a container env value or argument against the container's earlier variables at Pod creation and reduces `$$` to `$`, so the process would read a DIFFERENT value from the one this chart rendered. No valid value of this setting contains \"$\"; write the literal value (and put anything secret in a Secret, not a Helm value)." .key (len $s) $spelling) -}}
{{- end -}}
{{- end -}}
