{{- /*
  Literal container env values (T-871; kit port of dual-sandbox-architecture
  T-837 / T-846, `deploy/helm/templates/_env_literals.tpl`).

  Kubernetes EXPANDS every container `env[].value` (and every `args` /
  `command` entry) at Pod creation: `$(NAME)` is replaced by an earlier
  variable of the same container and `$$` is reduced to `$`. So a chart value
  holding either spelling reaches the process as a DIFFERENT string from the
  one the chart validated and printed. MEASURED upstream (DSA T-846, astra
  #616 r1, P1): `gateway.evidenceGap.posture: "$(DSA_ENV)"` expands to
  "development"/"production". `valueFrom` and `envFrom` entries are not
  re-expanded, so ConfigMap/Secret-sourced settings are unaffected.

  Since DSA #622 (main `c3d2aa0d`) the gateway REFUSES TO BOOT on any SET
  GATEWAY_EVIDENCE_ADMISSION_POSTURE other than exactly "enforce"/"log", and
  on any SET GATEWAY_EVIDENCE_BOOT_MODE other than exactly ""/"strict"/
  "permissive". These helpers move that refusal to render time, with an
  operator-facing message, instead of a CrashLoopBackOff after an image re-pin.

  ⚑ Error messages describe the value's SHAPE (length, whitespace, case, a
  `$(`/`$$` spelling) and NEVER echo the value itself: the same helpers guard
  env values such as Redis URLs that can carry a password.

  These helpers live in the UMBRELLA chart because named templates are shared
  by the parent and every enabled sub-chart in one render. The kit gateway
  sub-chart does not render standalone (it dereferences `.Values.global`).
  sandbox-a DOES render standalone, so it carries its own `$`-refusal twin
  (charts/sandbox-a/templates/_env_literals.tpl); tests/test_gateway_env_enum_guard.sh
  asserts both refuse.

    lucairn.env.shape        describe a value without echoing it
    lucairn.env.noExpansion  refuse any "$" (both the `$(` and the `$$` spelling)
    lucairn.env.enum         an exact, case-sensitive member of `allowed`, else refuse
*/ -}}

{{- /*
  lucairn.env.shape — (dict "value" <raw> ["allowed" (list ...)])
*/ -}}
{{- define "lucairn.env.shape" -}}
{{- $raw := .value -}}
{{- if kindIs "invalid" $raw -}}
null
{{- else if not (kindIs "string" $raw) -}}
{{- printf "a YAML %s (not a string)" (kindOf $raw) -}}
{{- else if eq $raw "" -}}
an empty string
{{- else -}}
{{- $notes := list -}}
{{- if contains "$(" $raw -}}{{- $notes = append $notes "containing a `$(NAME)` variable reference" -}}
{{- else if contains "$$" $raw -}}{{- $notes = append $notes "containing `$$`" -}}
{{- else if contains "$" $raw -}}{{- $notes = append $notes "containing `$`" -}}
{{- end -}}
{{- if eq (trim $raw) "" -}}{{- $notes = append $notes "made only of whitespace" -}}
{{- else if ne $raw (trim $raw) -}}{{- $notes = append $notes "with leading or trailing whitespace" -}}
{{- end -}}
{{- if and .allowed (not (has $raw .allowed)) (has (lower (trim $raw)) .allowed) -}}
{{- $notes = append $notes "that matches an allowed value only after lowercasing/trimming" -}}
{{- end -}}
{{- printf "a %d-character string" (len $raw) -}}{{- if $notes }} {{ join ", " $notes }}{{ end -}}
{{- end -}}
{{- end -}}

{{- /*
  lucairn.env.noExpansion — (dict "scope" "..." "key" "x.y" "value" <raw>)
  Renders nothing; fails the render when the value contains "$".
*/ -}}
{{- define "lucairn.env.noExpansion" -}}
{{- if and (not (kindIs "invalid" .value)) (contains "$" (toString .value)) -}}
{{- fail (printf "%s: %s is %s (value withheld). It contains \"$\": Kubernetes expands `$(NAME)` in a container env value or argument against the container's earlier variables at Pod creation and reduces `$$` to `$`, so the process would read a DIFFERENT value from the one this chart validated (e.g. `$(DSA_ENV)` arrives as \"production\"). No valid value of this setting contains \"$\"; write the literal value (and put anything secret in a Secret, not a Helm value)." (default "ENV" .scope) .key (include "lucairn.env.shape" (dict "value" .value))) -}}
{{- end -}}
{{- end -}}

{{- /*
  lucairn.env.enum — (dict "scope" "..." "key" "x.y" "value" <raw> "allowed" (list ...))
  Returns the value when it is an exact, case-sensitive member of `allowed`;
  otherwise fails. "$" is refused first with the expansion-specific message.
  The CALLER decides what absence (null) means — this helper refuses it.
*/ -}}
{{- define "lucairn.env.enum" -}}
{{- $scope := default "ENV" .scope -}}
{{- $raw := .value -}}
{{- $allowedText := toJson .allowed -}}
{{- if not (kindIs "string" $raw) -}}
{{- fail (printf "%s: %s must be one of %s (exact, case-sensitive); got %s." $scope .key $allowedText (include "lucairn.env.shape" (dict "value" $raw "allowed" .allowed))) -}}
{{- end -}}
{{- include "lucairn.env.noExpansion" (dict "scope" $scope "key" .key "value" $raw) -}}
{{- if not (has $raw .allowed) -}}
{{- fail (printf "%s: %s is %s (value withheld), which is not one of %s (exact, case-sensitive). The gateway refuses to boot on an unrecognised SET value (DSA #622), so this render would CrashLoopBackOff." $scope .key (include "lucairn.env.shape" (dict "value" $raw "allowed" .allowed)) $allowedText) -}}
{{- end -}}
{{- $raw -}}
{{- end -}}
