{{/*
Render-time validation guards for observability.

Helm renders all templates before applying them; {{ fail }} aborts the
render with a clear message so the operator sees the problem at
`helm template` / `helm install` time rather than after a Secret carrying
a publicly-known password has already been applied to the cluster.

T-10 (security STOP-SHIP, 2026-08-03): this chart used to ship a literal
`CHANGE-ME…` placeholder as a WORKING default Grafana admin password in a
public repo — Grafana accepts it, so `helm install` with untouched values
produced a Grafana whose admin credentials are published on GitHub. The
default is now empty and the guard refuses BOTH the empty value and any
`CHANGE-ME…`-shaped placeholder.

The guard is deliberately NOT gated on `global.dsaEnv`: the umbrella
default is `dsaEnv: development` (charts/lucairn/values.yaml), so a
production-only guard would never fire on the install path that actually
ships the weak credential.
*/}}

{{/*
observability.requireSecretValue
────────────────────────────────
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
non-string YAML type". `--set observability.secrets.values.grafanaAdminPassword=true`
is parsed by Helm as the BOOLEAN `true`, not the string "true"; `toString`
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
that quotes a numeric-looking password (`grafanaAdminPassword: "12345678"`)
is unaffected, because YAML string quoting already makes it a string before
Helm ever sees it.
*/}}
{{- define "observability.requireSecretValue" -}}
{{- $raw := .value -}}
{{- if and (not (kindIs "invalid" $raw)) (not (typeIs "string" $raw)) -}}
{{- fail (printf "[observability] %s must be a YAML string, but a %s was given. %s Helm's --set infers a YAML type from the literal you pass (--set \"%s=true\" becomes a boolean, --set \"%s=123\" becomes a number), so an unquoted boolean/numeric/date-shaped value would silently become a low-entropy secret instead of failing this guard. Quote it explicitly — --set-string \"%s=...\" — or wrap the value in quotes in your values file." .path (kindOf $raw) .why .path .path .path) -}}
{{- end -}}
{{- $value := (default "" $raw | toString | trim) -}}
{{- if not $value -}}
{{- fail (printf "[observability] %s is empty. %s There is no safe default — generate one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file. If you do not want the chart to manage a Grafana admin credential at all, set observability.enabled=false and run Grafana outside the Lucairn release." .path .why .path) -}}
{{- end -}}
{{/*
T-490b (2026-08-04): the placeholder regex above matched the ORIGINAL
FINDING's literal (`CHANGE-ME…`) but not the guard's own RATIONALE — "is
this value published in a public repo?" `customer-values.yaml.example`
ships ~46 `REPLACE_WITH_*` slots, several of them password fields; an
operator who copies that example and misses one slot gets a Secret whose
password IS the published string `REPLACE_WITH_ADMIN_PASSWORD` — exactly
the class this guard exists to close. The pattern below now also rejects
that shape (case-insensitive, tolerant of `-`/`_`/space separators, same
as the `change[-_ ]?me` alternative it sits next to).
*/}}
{{- if mustRegexMatch "(?i)^(change[-_ ]?me|placeholder|todo|replace[-_ ]?with)" $value -}}
{{- fail (printf "[observability] %s is still a shipped placeholder (a CHANGE-ME… or REPLACE_WITH_… value), not a real secret. %s This value is published in the kit repository, so anyone can read it. Generate a real one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file." .path .why .path) -}}
{{- end -}}
{{- end -}}

{{/*
observability.validateSecretValues
──────────────────────────────────
Entry point invoked from templates/grafana-secret.yaml.

Unlike the other subcharts this guard is NOT gated on
`secrets.backend`: observability ships no ExternalSecret template, so
grafana-secret.yaml renders the inline value on every backend setting.
Gating on `backend == k8s-native` would therefore leave a hole — a
`backend: vault` install would still base64 the placeholder into the
grafana-admin Secret. The production overlay
(charts/lucairn/values-prod.yaml) sets `observability.enabled: false`, so
this guard does not affect the names-and-paths-only production profile.

Also enforces the removal of the dead `grafana.adminPassword` key (see
below) rather than dropping it silently.
*/}}
{{- define "observability.validateSecretValues" -}}
{{/*
  `grafana.adminPassword` was a DEAD key: it shipped a `CHANGE-ME…`
  placeholder and read like the Grafana admin credential, but no template
  in this chart ever consumed it (grafana-deployment.yaml reads the
  grafana-admin Secret, which is rendered from
  `secrets.values.grafanaAdminPassword`). It has been removed rather than
  guarded — guarding a value nothing reads would force operators to
  populate a knob that protects nothing, and reinforce the false belief
  that setting it secured Grafana.

  Deleting it silently would be worse for anyone who already set it, so
  the removal is enforced loudly here: an operator whose values file still
  carries the dead key gets an actionable error naming the live key
  instead of a Grafana that quietly uses a different password than the one
  they set. Same idiom as the REMOVED-key guards in
  charts/lucairn/templates/_validators.tpl (sandbox-a.sanitizer.l3Required,
  veil-witness.config.l3Required).
*/}}
{{- if hasKey (default (dict) .Values.grafana) "adminPassword" -}}
{{- fail "[observability] observability.grafana.adminPassword is REMOVED. It was a dead key — no template in this chart ever read it, so setting it never protected the Grafana admin account (the Grafana pod reads the grafana-admin Secret). The live knob is observability.secrets.values.grafanaAdminPassword. Move your value there and delete observability.grafana.adminPassword from your values file." -}}
{{- end -}}
{{- $sv := (default (dict) .Values.secrets.values) -}}
{{- include "observability.requireSecretValue" (dict "path" "observability.secrets.values.grafanaAdminPassword" "value" $sv.grafanaAdminPassword "why" "It is the Grafana admin login password, base64-rendered into the grafana-admin Secret and consumed by the Grafana Deployment as GF_SECURITY_ADMIN_PASSWORD.") -}}
{{- end -}}
