{{/*
Render-time validation guards for id-bridge.

Helm renders all templates before applying them; {{ fail }} aborts the
render with a clear message so the operator sees the problem at
`helm template` / `helm install` time rather than after a Secret carrying
a publicly-known password has already been applied to the cluster.

T-10 (security STOP-SHIP, 2026-08-03): this chart used to ship a literal
`CHANGE-ME…` placeholder as a WORKING default password in a public repo.
Nothing rejected it — not the chart, not Postgres, not the services — so a
`helm install` with untouched values produced a running system whose
credentials are published on GitHub. The defaults are now empty and the
guards below refuse BOTH the empty value and any `CHANGE-ME…`-shaped
placeholder.

The guards are deliberately NOT gated on `global.dsaEnv`: the umbrella
default is `dsaEnv: development` (charts/lucairn/values.yaml), so a
production-only guard would never fire on the install path that actually
ships the weak credential.
*/}}

{{/*
idBridge.requireSecretValue
───────────────────────────
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
{{- define "idBridge.requireSecretValue" -}}
{{- $value := (default "" .value | toString | trim) -}}
{{- if not $value -}}
{{- fail (printf "[id-bridge] %s is empty. %s There is no safe default — generate one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file, or move this subchart onto an external secrets backend with id-bridge.secrets.backend=vault|aws|azure." .path .why .path) -}}
{{- end -}}
{{- if mustRegexMatch "(?i)^(change[-_ ]?me|placeholder|todo)" $value -}}
{{- fail (printf "[id-bridge] %s is still a shipped CHANGE-ME… placeholder, not a real secret. %s This value is published in the kit repository, so anyone can read it. Generate a real one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file." .path .why .path) -}}
{{- end -}}
{{- end -}}

{{/*
idBridge.validateSecretValues
─────────────────────────────
Entry point invoked from templates/secret.yaml.

Scope of the checks mirrors what the chart actually renders:
  * `secrets.backend != k8s-native` — the credential comes from the
    ExternalSecret (templates/externalsecret.yaml) and the inline slot is
    intentionally empty (see charts/lucairn/values-prod.yaml).
  * `postgresql.enabled = false` — the operator supplies a full external
    DSN via `id-bridge.external.databaseUrl`; neither the bundled Postgres
    StatefulSet nor the migration Job renders, so the password below is
    inert. Requiring it would break every external-Postgres install for no
    security gain.
*/}}
{{- define "idBridge.validateSecretValues" -}}
{{- if eq .Values.secrets.backend "k8s-native" -}}
{{- if .Values.postgresql.enabled -}}
{{- $sv := (default (dict) .Values.secrets.values) -}}
{{- include "idBridge.requireSecretValue" (dict "path" "id-bridge.secrets.values.postgresPassword" "value" $sv.postgresPassword "why" "It is the password of the bundled id-bridge Postgres StatefulSet — the database that holds the pseudonym mapping — rendered into DATABASE_URL and POSTGRES_PASSWORD.") -}}
{{- end -}}
{{- end -}}
{{- end -}}
