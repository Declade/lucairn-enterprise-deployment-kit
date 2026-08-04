{{/*
Render-time validation guards for audit.

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
audit.requireSecretValue
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

T-490 (2026-08-04): the coercion above has its own hole — `toString` cannot
tell "the operator wrote a real secret" apart from "Helm parsed --set into a
non-string YAML type". `--set audit.secrets.values.postgresPassword=true` is
parsed by Helm as the BOOLEAN `true`, not the string "true"; `toString`
turns it into the string "true" all the same, which is non-empty and does
not match the placeholder regex, so the guard PASSED and rendered a
4-character password. The same happens for a bare `--set ...=12345678`
(int64) or an unquoted YAML-timestamp-shaped value. The type check below
runs BEFORE the coercion and rejects every non-string kind by name, so the
operator sees why their `--set` was silently the wrong type instead of
inheriting a low-entropy secret. `kindIs "invalid"` carves out the
genuinely-unset case (a missing values key resolves to Go's untyped nil,
kind `invalid`) so that path still falls through to the ordinary "is empty"
message below — only an explicitly-set NON-STRING value is rejected here.
A string stays a string regardless of what it looks like: a values file
that quotes a numeric-looking password (`postgresPassword: "12345678"`) is
unaffected, because YAML string quoting already makes it a string before
Helm ever sees it.
*/}}
{{- define "audit.requireSecretValue" -}}
{{- $raw := .value -}}
{{- if and (not (kindIs "invalid" $raw)) (not (typeIs "string" $raw)) -}}
{{- fail (printf "[audit] %s must be a YAML string, but a %s was given. %s Helm's --set infers a YAML type from the literal you pass (--set \"%s=true\" becomes a boolean, --set \"%s=123\" becomes a number), so an unquoted boolean/numeric/date-shaped value would silently become a low-entropy secret instead of failing this guard. Quote it explicitly — --set-string \"%s=...\" — or wrap the value in quotes in your values file." .path (kindOf $raw) .why .path .path .path) -}}
{{- end -}}
{{- $value := (default "" $raw | toString | trim) -}}
{{- if not $value -}}
{{- fail (printf "[audit] %s is empty. %s There is no safe default — generate one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file, or move this subchart onto an external secrets backend with audit.secrets.backend=vault|aws|azure." .path .why .path) -}}
{{- end -}}
{{- if mustRegexMatch "(?i)^(change[-_ ]?me|placeholder|todo)" $value -}}
{{- fail (printf "[audit] %s is still a shipped CHANGE-ME… placeholder, not a real secret. %s This value is published in the kit repository, so anyone can read it. Generate a real one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file." .path .why .path) -}}
{{- end -}}
{{- end -}}

{{/*
audit.validateSecretValues
──────────────────────────
Entry point invoked from templates/secret.yaml.

Scope of the checks mirrors what the chart actually renders:
  * `secrets.backend != k8s-native` — the credentials come from the
    ExternalSecret (templates/externalsecret.yaml) and the inline slots
    are intentionally empty (see charts/lucairn/values-prod.yaml).
  * `postgresql.enabled = false` — the operator supplies a full external
    DSN via `audit.external.databaseUrl`; neither the bundled Postgres
    StatefulSet nor the migration Job renders, so both passwords below
    are inert. Requiring them would break every external-Postgres install
    for no security gain.
*/}}
{{- define "audit.validateSecretValues" -}}
{{- if eq .Values.secrets.backend "k8s-native" -}}
{{- if .Values.postgresql.enabled -}}
{{- $sv := (default (dict) .Values.secrets.values) -}}
{{- include "audit.requireSecretValue" (dict "path" "audit.secrets.values.postgresPassword" "value" $sv.postgresPassword "why" "It is the superuser password of the bundled audit Postgres StatefulSet, rendered into DATABASE_URL and POSTGRES_PASSWORD.") -}}
{{- include "audit.requireSecretValue" (dict "path" "audit.secrets.values.auditAppPassword" "value" $sv.auditAppPassword "why" "It is the password of the least-privilege audit_app role created by the 000003_least_privilege_role migration, rendered into DATABASE_URL_APP and AUDIT_APP_PASSWORD.") -}}
{{- end -}}
{{- end -}}
{{- end -}}
