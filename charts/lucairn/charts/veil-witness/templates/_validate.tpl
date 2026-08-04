{{/*
Render-time validation guards for veil-witness.

Helm renders all templates before applying them; {{ fail }} aborts the
render with a clear message so the operator sees the problem at
`helm template` / `helm install` time rather than at runtime.
*/}}

{{/*
veilWitness.validateSigningKey
──────────────────────────────
Fail-fast on the two most dangerous signing-key misconfigurations:

  1. Empty / missing value  — the witness would start with no signing key,
     silently issuing unsigned or zero-key certificates.
  2. All-zeroes placeholder — the shipped default
     "0000000000000000000000000000000000000000000000000000000000000000"
     is a known-bad key. Any attacker can reproduce it. Every certificate
     signed with it is forgeable.

To generate a real key:
  openssl rand -hex 32
     → 64 hex characters (32 random bytes), e.g.
       a1b2c3d4e5f6...

Then pass it at install time:
  --set "veil-witness.secrets.values.signingKey=$(openssl rand -hex 32)"

Or store it in a sealed secret / Vault and reference it via
veil-witness.secrets.backend = vault | aws | azure (see values.yaml).
*/}}
{{- define "veilWitness.validateSigningKey" -}}
{{- $key := .Values.secrets.values.signingKey | default "" -}}
{{- if not $key -}}
{{- fail "[veil-witness] secrets.values.signingKey is empty or missing. A real Ed25519 signing key is required — every certificate issued by the witness is signed with this key. Generate one with: openssl rand -hex 32" -}}
{{- end -}}
{{- $zeroKey := "0000000000000000000000000000000000000000000000000000000000000000" -}}
{{- if eq $key $zeroKey -}}
{{- fail "[veil-witness] secrets.values.signingKey is the all-zeroes placeholder. This is a known-bad default: every certificate issued under it is trivially forgeable. Generate a real key with: openssl rand -hex 32\nThen pass it via --set \"veil-witness.secrets.values.signingKey=$(openssl rand -hex 32)\" or store it in your secrets backend (vault/aws/azure)." -}}
{{- end -}}
{{- if not (mustRegexMatch "^[0-9a-fA-F]{64}$" $key) -}}
{{- fail "[veil-witness] secrets.values.signingKey must be exactly 64 hex characters (32 bytes, encoded as lowercase or uppercase hex). Generate a valid key with: openssl rand -hex 32" -}}
{{- end -}}
{{- end -}}

{{/*
T-10 (security STOP-SHIP, 2026-08-03): the two Postgres role passwords
below used to ship a literal `CHANGE-ME…` placeholder as a WORKING default
in a public repo. Nothing rejected it — not the chart, not Postgres, not
the services — so a `helm install` with untouched values produced a
running witness whose database credentials are published on GitHub. The
defaults are now empty and the guards refuse BOTH the empty value and any
`CHANGE-ME…`-shaped placeholder, matching the posture the signing-key
guard above has always had.

The guards are deliberately NOT gated on `global.dsaEnv`: the umbrella
default is `dsaEnv: development` (charts/lucairn/values.yaml), so a
production-only guard would never fire on the install path that actually
ships the weak credential.
*/}}

{{/*
veilWitness.requireSecretValue
──────────────────────────────
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
non-string YAML type". `--set veil-witness.secrets.values.postgresPassword=true`
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
that quotes a numeric-looking password (`postgresPassword: "12345678"`) is
unaffected, because YAML string quoting already makes it a string before
Helm ever sees it. Deliberately NOT applied to veilWitness.validateSigningKey
above: that guard already does its own hex-format `mustRegexMatch` check
(a non-string signing key fails that regex — or, for a bool/int, errors out
of Go template's built-in `eq` on the type-mismatched zero-key comparison —
either way it cannot render a Secret, so it does not share this function's
silent-coercion defect and is out of scope for this fix).
*/}}
{{- define "veilWitness.requireSecretValue" -}}
{{- $raw := .value -}}
{{- if and (not (kindIs "invalid" $raw)) (not (typeIs "string" $raw)) -}}
{{- fail (printf "[veil-witness] %s must be a YAML string, but a %s was given. %s Helm's --set infers a YAML type from the literal you pass (--set \"%s=true\" becomes a boolean, --set \"%s=123\" becomes a number), so an unquoted boolean/numeric/date-shaped value would silently become a low-entropy secret instead of failing this guard. Quote it explicitly — --set-string \"%s=...\" — or wrap the value in quotes in your values file." .path (kindOf $raw) .why .path .path .path) -}}
{{- end -}}
{{- $value := (default "" $raw | toString | trim) -}}
{{- if not $value -}}
{{- fail (printf "[veil-witness] %s is empty. %s There is no safe default — generate one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file, or move this subchart onto an external secrets backend with veil-witness.secrets.backend=vault|aws|azure." .path .why .path) -}}
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
{{- fail (printf "[veil-witness] %s is still a shipped placeholder (a CHANGE-ME… or REPLACE_WITH_… value), not a real secret. %s This value is published in the kit repository, so anyone can read it. Generate a real one (openssl rand -base64 24) and pass it with --set \"%s=...\" or in your values file." .path .why .path) -}}
{{- end -}}
{{- end -}}

{{/*
veilWitness.validateSecretValues
────────────────────────────────
Entry point invoked from templates/secret.yaml.

Scope of the checks mirrors what the chart actually renders:
  * `secrets.backend != k8s-native` — the credentials come from the
    ExternalSecret (templates/externalsecret.yaml) and the inline slots
    are intentionally empty (see charts/lucairn/values-prod.yaml).
  * `postgresql.enabled = false` — the operator supplies a full external
    DSN via `veil-witness.external.databaseUrl`; neither the bundled
    Postgres StatefulSet nor the migration Job renders, so both passwords
    below are inert. Requiring them would break every external-Postgres
    install for no security gain.
*/}}
{{- define "veilWitness.validateSecretValues" -}}
{{- if eq .Values.secrets.backend "k8s-native" -}}
{{- if .Values.postgresql.enabled -}}
{{- $sv := (default (dict) .Values.secrets.values) -}}
{{- include "veilWitness.requireSecretValue" (dict "path" "veil-witness.secrets.values.postgresPassword" "value" $sv.postgresPassword "why" "It is the superuser password of the bundled veil-witness Postgres StatefulSet — the database that holds the certificate log — rendered into DATABASE_URL and POSTGRES_PASSWORD.") -}}
{{- include "veilWitness.requireSecretValue" (dict "path" "veil-witness.secrets.values.veilAppPassword" "value" $sv.veilAppPassword "why" "It is the password of the least-privilege veil_app role created by the 000002_restrict_veil_role migration, rendered into DATABASE_URL_APP and VEIL_APP_PASSWORD.") -}}
{{- end -}}
{{- end -}}
{{- end -}}
