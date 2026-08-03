{{/*
Render-time validation guards for admin.

Helm renders all templates before applying them; {{ fail }} aborts the
render with a clear message so the operator sees the problem at
`helm template` / `helm install` time rather than after a Secret carrying
a publicly-known password has already been applied to the cluster.

T-10 (security STOP-SHIP, 2026-08-03): this chart used to ship a literal
`CHANGE-ME…` placeholder as a WORKING default password in a public repo.
Nothing rejected it — not the chart, not Postgres, not the services — so a
`helm install` with untouched values produced a running system whose
credentials are published on GitHub. The default is now empty and the
guard below refuses BOTH the empty value and any `CHANGE-ME…`-shaped
placeholder.

The guard is deliberately NOT gated on `global.dsaEnv`: the umbrella
default is `dsaEnv: development` (charts/lucairn/values.yaml), so a
production-only guard would never fire on the install path that actually
ships the weak credential.
*/}}

{{/*
admin.requireSecretValue
────────────────────────
Fail the render when a chart-managed credential is missing or is still a
shipped placeholder.

Arguments (dict):
  path  — the umbrella values path the operator must set, used verbatim in
          the error message so the fix is copy-pasteable.
  value — the resolved value to check.
  why   — one sentence explaining what the credential actually protects.

NOTE on the coercion below, both halves of which are load-bearing:

  * `default "" .value` MUST come before `toString`. sprig's toString
    renders a nil as the literal string "<nil>", which is non-empty and
    does not match the placeholder regex — an unset value would sail
    through both checks. This ordering turns a missing key into "" so the
    empty check trips.
  * `trim` MUST come before BOTH checks. Go template truthiness treats
    any non-empty string as true, so an untrimmed "   " passes the empty
    check; and the placeholder regex is `^`-anchored, so an untrimmed
    " CHANGE-ME…" passes the placeholder check. One leading space would
    otherwise defeat the whole guard. Only the CHECK is trimmed — the
    Secret still renders the operator's value byte-for-byte.
*/}}
{{- define "admin.requireSecretValue" -}}
{{- $value := (default "" .value | toString | trim) -}}
{{- if not $value -}}
{{- fail (printf "[admin] %s is empty. %s There is no safe default — generate one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file. If you do not deploy the admin surface at all, set admin.enabled=false." .path .why .path) -}}
{{- end -}}
{{- if mustRegexMatch "(?i)^(change[-_ ]?me|placeholder|todo)" $value -}}
{{- fail (printf "[admin] %s is still a shipped CHANGE-ME… placeholder, not a real secret. %s This value is published in the kit repository, so anyone can read it. Generate a real one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file." .path .why .path) -}}
{{- end -}}
{{- end -}}

{{/*
admin.validateSecretValues
──────────────────────────
Entry point invoked from templates/secret.yaml.

Unlike audit / id-bridge / sandbox-a / veil-witness, this guard is NOT
gated on `secrets.backend`, and the remediation text above does NOT offer
an external-secrets escape hatch — because this chart HAS NO
`templates/externalsecret.yaml`. `secrets.backend` values other than
`k8s-native` do not move the credential anywhere; they only suppress the
`admin-credentials` Secret, while templates/deployment.yaml still mounts
it unconditionally via `envFrom.secretRef` — a pre-existing footgun that
lands as CreateContainerConfigError at pod start. An unconditional guard
therefore surfaces the SAME broken install at render time with an
actionable message instead, and closes the hole a backend-gated guard
would leave (a `backend: vault` install skipping the placeholder check).

Fixing that footgun properly — either an ExternalSecret for admin or a
backend gate on the Deployment's secretRef — is a separate change and is
deliberately NOT attempted here (T-10 is a password-default fix).
*/}}
{{- define "admin.validateSecretValues" -}}
{{- $sv := (default (dict) .Values.secrets.values) -}}
{{- include "admin.requireSecretValue" (dict "path" "admin.secrets.values.adminPassword" "value" $sv.adminPassword "why" "It is the admin-service login password, rendered into the admin-credentials Secret as ADMIN_PASSWORD.") -}}
{{- end -}}
