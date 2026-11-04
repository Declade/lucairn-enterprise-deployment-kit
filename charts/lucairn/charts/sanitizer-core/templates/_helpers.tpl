{{- /*
  Helpers + render-time guards of the sanitizer-core sub-chart (kit 2.0).

  Self-contained on purpose: the sub-chart renders on its own too
  (`helm template x charts/lucairn/charts/sanitizer-core …`), where the
  umbrella's templates/ helpers do not exist.

  Error messages describe a value's SHAPE and never echo it — the same helpers
  guard the registry key and the DB password.
*/ -}}

{{- /* sanitizerCore.tag: the effective core tag ("" = this chart's appVersion). */ -}}
{{- define "sanitizerCore.tag" -}}
{{- toString (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{- /* sanitizerCore.sidecarTag: the effective sidecar tag (same default). */ -}}
{{- define "sanitizerCore.sidecarTag" -}}
{{- toString (((.Values.sidecar).image).tag | default .Chart.AppVersion) -}}
{{- end -}}

{{- /*
  sanitizerCore.imageRef  (dict "root" $ "repository" … "tag" … "digest" …)
  registry/repo:tag, plus @sha256:… when a digest is pinned.
*/ -}}
{{- define "sanitizerCore.imageRef" -}}
{{- $reg := ((.root.Values.global | default dict).imageRegistry) -}}
{{- printf "%s%s:%s" (ternary (printf "%s/" $reg) "" (not (empty $reg))) .repository .tag -}}
{{- if .digest -}}@{{ .digest }}{{- end -}}
{{- end -}}

{{- /* The postgres image (digest-pinned by default). */ -}}
{{- define "sanitizerCore.postgresImage" -}}
{{- $img := .Values.postgresql.image -}}
{{- printf "%s:%s" $img.repository (toString $img.tag) -}}
{{- if $img.digest -}}@{{ $img.digest }}{{- end -}}
{{- end -}}

{{- /* sslmode for the registry connection. The BUNDLED registry serves no
       TLS, so it uses the chart-local postgresql.sslmode (default "disable"),
       NOT global.postgresqlSslmode — the same rule and reason as the bundled
       postgres-gateway (values-prod.yaml sets the global to "require" for
       external, TLS-enabled databases). An EXTERNAL registry uses
       external.sslmode, else the global, else "disable". */ -}}
{{- define "sanitizerCore.sslmode" -}}
{{- if .Values.postgresql.enabled -}}
{{- .Values.postgresql.sslmode | default "disable" -}}
{{- else -}}
{{- .Values.external.sslmode | default ((.Values.global | default dict).postgresqlSslmode) | default "disable" -}}
{{- end -}}
{{- end -}}

{{- /* Discrete libpq connection settings of the registry (never a URL). */ -}}
{{- define "sanitizerCore.pgHost" -}}
{{- if .Values.postgresql.enabled -}}postgres-sanitizer-core{{- else -}}{{ .Values.external.host }}{{- end -}}
{{- end -}}
{{- define "sanitizerCore.pgPort" -}}
{{- if .Values.postgresql.enabled -}}5432{{- else -}}{{ .Values.external.port | default 5432 }}{{- end -}}
{{- end -}}
{{- define "sanitizerCore.pgUser" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.user }}{{- else -}}{{ .Values.external.user }}{{- end -}}
{{- end -}}
{{- define "sanitizerCore.pgDatabase" -}}
{{- if .Values.postgresql.enabled -}}{{ .Values.postgresql.database }}{{- else -}}{{ .Values.external.database }}{{- end -}}
{{- end -}}

{{- /* The migration ceiling this kit release reviewed (docs/RELEASING.md
       § "Migration review"). Code, not values; must equal
       CEILING_SANITIZER_CORE in scripts/migration-ceilings.conf
       (tests/test_sanitizer_core_helm.sh asserts it). */ -}}
{{- define "sanitizerCore.migrationCeiling" -}}7{{- end -}}

{{- /*
  sanitizerCore.requireSecretValue  (dict "path" … "value" … "why" …)
  Empty / non-string / shipped-placeholder values fail the render (same rules
  as sandbox-a.requireSecretValue, T-10 / T-490 / T-490b).
*/ -}}
{{- define "sanitizerCore.requireSecretValue" -}}
{{- $raw := .value -}}
{{- if and (not (kindIs "invalid" $raw)) (not (typeIs "string" $raw)) -}}
{{- fail (printf "[sanitizer-core] %s must be a YAML string, but a %s was given. %s Quote it (--set-string \"%s=...\") — Helm's --set turns unquoted numbers and booleans into non-strings." .path (kindOf $raw) .why .path) -}}
{{- end -}}
{{- $value := (default "" $raw | toString | trim) -}}
{{- if not $value -}}
{{- fail (printf "[sanitizer-core] %s is empty. %s There is no safe default — generate one and pass it with --set-string \"%s=...\" or in your values file, or move this sub-chart onto an external secrets backend with sanitizer-core.secrets.backend=vault|aws|azure." .path .why .path) -}}
{{- end -}}
{{- if mustRegexMatch "(?i)^(change[-_ ]?me|placeholder|todo|replace[-_ ]?with)" $value -}}
{{- fail (printf "[sanitizer-core] %s is still a shipped placeholder (a CHANGE-ME… or REPLACE_WITH_… value), not a real secret. %s" .path .why) -}}
{{- end -}}
{{- end -}}

{{- /*
  sanitizerCore.validate — invoked once from templates/deployment.yaml.
*/ -}}
{{- define "sanitizerCore.validate" -}}
{{- $scope := "[sanitizer-core]" -}}
{{- /* 1. Image pair: one tag, digests together or not at all. */ -}}
{{- $coreTag := include "sanitizerCore.tag" . -}}
{{- $sideTag := include "sanitizerCore.sidecarTag" . -}}
{{- if ne $coreTag $sideTag -}}
{{- fail (printf "%s image.tag (%q) and sidecar.image.tag (%q) differ. The core and its model sidecar are ONE pair from one release commit — the core refuses to start against a sidecar from another build. Set one tag for both (or leave both empty = chart appVersion %s)." $scope $coreTag $sideTag .Chart.AppVersion) -}}
{{- end -}}
{{- /* Kit 2.0 K-B fix round 1 (sol r1, P1): the pair ONLY ever runs from
       the signed digests a kit release records (Compose parity: the compose
       file refuses to render without both). No tag-only fallback: a tag is
       mutable, a digest is the signed bytes. A digest is "sha256:" + 64
       lowercase hex and never a sentinel made of one repeated character
       (sha256:000…, sha256:aaa…) — the kind of filler that stands in for a
       digest nobody recorded. */ -}}
{{- $coreDigest := toString (.Values.image.digest | default "") -}}
{{- $sideDigest := toString (((.Values.sidecar).image).digest | default "") -}}
{{- range $pair := list (list "image.digest" $coreDigest "dsa-sanitizer-core") (list "sidecar.image.digest" $sideDigest "dsa-sanitizer-core-sidecar") -}}
{{- $v := index $pair 1 -}}
{{- if not $v -}}
{{- fail (printf "%s %s is empty. The core and its model sidecar start ONLY from the signed digests the kit release records for %s in image-manifest.yaml (image_digests.signed_artifacts) — never from a tag alone. A released kit's chart carries them; on an unreleased checkout set both (--set-string sanitizer-core.image.digest=sha256:… --set-string sanitizer-core.sidecar.image.digest=sha256:…) or disable the core (sanitizer-core.enabled=false + global.sanitizerCore.enabled=false)." $scope (index $pair 0) (index $pair 2)) -}}
{{- end -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $v) -}}
{{- fail (printf "%s %s must be sha256:<64 lowercase hex> (the signed digest image-manifest.yaml records for %s)." $scope (index $pair 0) (index $pair 2)) -}}
{{- end -}}
{{- range $c := splitList "" "0123456789abcdef" -}}
{{- if eq $v (printf "sha256:%s" (repeat 64 $c)) -}}
{{- fail (printf "%s %s is a placeholder (one repeated character), not a released digest. Use the signed digest image-manifest.yaml records for %s." $scope (index $pair 0) (index $pair 2)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq $coreDigest $sideDigest -}}
{{- fail (printf "%s image.digest and sidecar.image.digest are the same digest; the core and its sidecar are two different images of one release." $scope) -}}
{{- end -}}
{{- $pgDigest := toString (.Values.postgresql.image.digest | default "") -}}
{{- if and $pgDigest (not (regexMatch "^sha256:[0-9a-f]{64}$" $pgDigest)) -}}
{{- fail (printf "%s postgresql.image.digest must be sha256:<64 lowercase hex> (or empty)." $scope) -}}
{{- end -}}
{{- /* 2. Literals rendered into env / args: no "$" (Kubernetes expands
       $(NAME) and reduces $$ at Pod creation, so the process would read a
       different value from the one validated here). */ -}}
{{- $literals := dict
      "namespace" .Values.namespace
      "service.port" .Values.service.port
      "veilEnabled" .Values.veilEnabled
      "veilWitnessAddr" .Values.veilWitnessAddr
      "claimDrainSeconds" .Values.claimDrainSeconds
      "witnessGrpcMaxMessageBytes" .Values.witnessGrpcMaxMessageBytes
      "mtls.mountPath" .Values.mtls.mountPath
      "mtls.caKey" .Values.mtls.caKey
      "mtls.certKey" .Values.mtls.certKey
      "mtls.keyKey" .Values.mtls.keyKey
      "postgresql.user" .Values.postgresql.user
      "postgresql.database" .Values.postgresql.database
      "postgresql.sslmode" .Values.postgresql.sslmode
      "external.sslmode" .Values.external.sslmode
      "external.host" .Values.external.host
      "external.user" .Values.external.user
      "external.database" .Values.external.database -}}
{{- range $key := keys $literals | sortAlpha -}}
{{- $v := get $literals $key -}}
{{- if and (not (kindIs "invalid" $v)) (contains "$" (toString $v)) -}}
{{- fail (printf "%s %s contains \"$\" (value withheld). Kubernetes expands `$(NAME)` and reduces `$$` in container env values and arguments at Pod creation; no valid value of this setting contains \"$\"." $scope $key) -}}
{{- end -}}
{{- end -}}
{{- if not (has (toString .Values.veilEnabled) (list "true" "false")) -}}
{{- fail (printf "%s veilEnabled must be the string \"true\" or \"false\"." $scope) -}}
{{- end -}}
{{- if empty .Values.mtls.secretName -}}
{{- fail (printf "%s mtls.secretName is required: the core serves only verified mTLS (gateway -> core), and refuses to start without its server leaf. Create the Secret in namespace %s first (INSTALL.md § \"Sanitizer core (kit 2.0, Helm)\")." $scope .Values.namespace) -}}
{{- end -}}
{{- if or (empty .Values.signingKeySecretRef.name) (empty .Values.signingKeySecretRef.key) -}}
{{- fail (printf "%s signingKeySecretRef.name and .key are required (the claim signing seed, shared with the old sanitizer)." $scope) -}}
{{- end -}}
{{- /* 3. Migration target: an integer 1..ceiling. */ -}}
{{- $ceiling := int (include "sanitizerCore.migrationCeiling" .) -}}
{{- $tv := .Values.migrations.targetVersion -}}
{{- if or (kindIs "invalid" $tv) (kindIs "string" $tv) (kindIs "bool" $tv) -}}
{{- fail (printf "%s migrations.targetVersion must be an integer 1..%d (got %s)." $scope $ceiling (kindOf $tv)) -}}
{{- end -}}
{{- $tvf := float64 $tv -}}
{{- if or (ne $tvf (float64 (int $tv))) (lt (int $tv) 1) (gt (int $tv) $ceiling) -}}
{{- fail (printf "%s migrations.targetVersion must be an integer 1..%d: %d is this kit release's reviewed ceiling for the registry (docs/RELEASING.md § \"Migration review\"). Raising it is a kit-release change, not a value." $scope $ceiling $ceiling) -}}
{{- end -}}
{{- /* 4. External Postgres needs its discrete settings (the migration Job
       and the wait-for-migration init container connect with them). */ -}}
{{- if not .Values.postgresql.enabled -}}
{{- if or (empty .Values.external.host) (empty .Values.external.user) (empty .Values.external.database) -}}
{{- fail (printf "%s postgresql.enabled=false needs external.host, external.user and external.database." $scope) -}}
{{- end -}}
{{- end -}}
{{- /* 4b. The parts of the registry DSN URL (DSA #956 registry_dsn.go: the
       core takes ONLY a postgres:// URL from --registry-dsn-file and refuses,
       with a fixed message, one it cannot read as written). This chart writes
       them unencoded into REGISTRY_DSN, so each must be URL-safe as is: a user
       or database name with ':' '@' '/' '?' or '#' would move the URL's
       boundaries; a host is a DNS name or an IPv4 address; sslmode is a
       libpq keyword value; the port a number. */ -}}
{{- $pgUser := include "sanitizerCore.pgUser" . -}}
{{- $pgDb := include "sanitizerCore.pgDatabase" . -}}
{{- $pgHost := include "sanitizerCore.pgHost" . -}}
{{- $pgPort := include "sanitizerCore.pgPort" . -}}
{{- $pgSsl := include "sanitizerCore.sslmode" . -}}
{{- if not (regexMatch "^[A-Za-z0-9._~-]+$" $pgUser) -}}
{{- fail (printf "%s the registry DB user (postgresql.user / external.user) must use only A-Z a-z 0-9 . _ ~ - : it is written into the core's postgres:// DSN unencoded." $scope) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._~-]+$" $pgDb) -}}
{{- fail (printf "%s the registry database name (postgresql.database / external.database) must use only A-Z a-z 0-9 . _ ~ - : it is written into the core's postgres:// DSN unencoded." $scope) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$" $pgHost) -}}
{{- fail (printf "%s the registry DB host (external.host) must be a DNS name or an IPv4 address (no scheme, port, path or user): it is written into the core's postgres:// DSN." $scope) -}}
{{- end -}}
{{- if not (regexMatch "^[1-9][0-9]{0,4}$" $pgPort) -}}
{{- fail (printf "%s the registry DB port (external.port) must be a number 1..65535." $scope) -}}
{{- end -}}
{{- if gt (atoi $pgPort) 65535 -}}
{{- fail (printf "%s the registry DB port (external.port) must be a number 1..65535." $scope) -}}
{{- end -}}
{{- if not (has $pgSsl (list "disable" "allow" "prefer" "require" "verify-ca" "verify-full")) -}}
{{- fail (printf "%s the registry sslmode (postgresql.sslmode / external.sslmode / global.postgresqlSslmode) must be one of disable, allow, prefer, require, verify-ca, verify-full." $scope) -}}
{{- end -}}
{{- /* 5. Credentials (k8s-native only; ExternalSecret backends hold them). */ -}}
{{- if not (has .Values.secrets.backend (list "k8s-native" "vault" "aws" "azure")) -}}
{{- fail (printf "%s secrets.backend must be k8s-native, vault, aws or azure." $scope) -}}
{{- end -}}
{{- if eq .Values.secrets.backend "k8s-native" -}}
{{- $sv := default dict .Values.secrets.values -}}
{{- include "sanitizerCore.requireSecretValue" (dict "path" "sanitizer-core.secrets.values.registryKey" "value" $sv.registryKey "why" "It seals every registry row (AES-256-GCM + HMAC); generate it with: openssl rand -hex 32, and keep it stable.") -}}
{{- $key := trim (toString $sv.registryKey) -}}
{{- if not (regexMatch "^[0-9a-fA-F]{64}$" $key) -}}
{{- fail (printf "%s sanitizer-core.secrets.values.registryKey must be exactly 64 hex characters (a %d-character value was given; value withheld). Generate: openssl rand -hex 32." $scope (len $key)) -}}
{{- end -}}
{{- if regexMatch "^0{64}$" $key -}}
{{- fail (printf "%s sanitizer-core.secrets.values.registryKey is all zero; the core refuses it." $scope) -}}
{{- end -}}
{{- include "sanitizerCore.requireSecretValue" (dict "path" "sanitizer-core.secrets.values.postgresPassword" "value" $sv.postgresPassword "why" "It is the password of the core's registry database, rendered into POSTGRES_PASSWORD and the core's DSN file.") -}}
{{- if not (regexMatch "^[A-Za-z0-9._~-]+$" (toString $sv.postgresPassword)) -}}
{{- fail (printf "%s sanitizer-core.secrets.values.postgresPassword must use only A-Z a-z 0-9 . _ ~ - (value withheld): it is part of the core's connection URL. Generate: openssl rand -hex 24." $scope) -}}
{{- end -}}
{{- if and (eq (toString .Values.global.dsaEnv) "production") (lt (len (toString $sv.postgresPassword)) 12) -}}
{{- fail (printf "%s sanitizer-core.secrets.values.postgresPassword is shorter than 12 characters; production needs >= 12." $scope) -}}
{{- end -}}
{{- end -}}
{{- end -}}
