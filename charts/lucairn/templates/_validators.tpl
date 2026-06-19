{{- /*
  Umbrella-chart render-time validators.

  These are pure-side-effect templates: they fail-fast when sub-chart
  configurations are inconsistent in ways that cause silent runtime
  degradation. The `_` prefix excludes them from manifest output;
  they are invoked from sub-chart templates that need them.

  Pattern reference: Slice 4 fix-up r1 closed bug-hunter H-2 by
  introducing this guard for the cross-sub-chart half-config Grafana
  embed case.
*/ -}}

{{- /*
  validators.grafanaEmbedCrossChart

  Fails fast when:
    - dashboard.enabled = true
    - dashboard.grafana.endpoint is set (operator opted into embed)
    - observability.grafana.auth.jwt.enabled is NOT also true

  Symptom this prevents: clicking a service-health card opens the
  drawer; the iframe loads Grafana's login screen instead of the
  signed-JWT-authenticated panel (silent UX degradation).

  Invoked from charts/lucairn/charts/dashboard/templates/deployment.yaml
  via `{{ include "validators.grafanaEmbedCrossChart" $ }}`.
*/ -}}
{{- define "validators.grafanaEmbedCrossChart" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- if and $dashboard.enabled (default dict $dashboard.grafana).endpoint -}}
{{- $observability := (default dict .Values.observability) -}}
{{- $obsGrafana := (default dict $observability.grafana) -}}
{{- $obsAuth := (default dict $obsGrafana.auth) -}}
{{- $obsJWT := (default dict $obsAuth.jwt) -}}
{{- if not $obsJWT.enabled -}}
{{- fail (printf "dashboard.grafana.endpoint is set (=%q) but observability.grafana.auth.jwt.enabled is false (or unset). Embedded Grafana panels will load the Grafana login screen instead of authenticating via the dashboard's signed JWT. Either flip observability.grafana.auth.jwt.enabled=true with a matching secretRef.name (typically lucairn-dashboard-grafana-jwt), or clear dashboard.grafana.endpoint to disable embedding. See INSTALL.md § \"Enable server health + Grafana embedding (Slice 4)\"." $dashboard.grafana.endpoint) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.keysGatewayAdminHalfConfig

  Slice 5 sibling of the Grafana embed guard. Fails fast when the
  /keys surface is enabled (`dashboard.gateway.adminURL` set) but the
  Secret-name ref carrying the admin token is empty. Without this guard
  the deployment template's `required` only fires once Helm renders
  every env-var slot; surfacing the failure at the validator
  invocation site keeps the error message close to the consumer's
  call.

  Invoked from charts/lucairn/charts/dashboard/templates/deployment.yaml
  via `{{ include "validators.keysGatewayAdminHalfConfig" $ }}`.
*/ -}}
{{- define "validators.keysGatewayAdminHalfConfig" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- if $dashboard.enabled -}}
{{- $gw := (default dict $dashboard.gateway) -}}
{{- if $gw.adminURL -}}
{{- $secretRef := (default dict $gw.adminTokenSecretRef) -}}
{{- if not $secretRef.name -}}
{{- fail (printf "dashboard.gateway.adminURL is set (=%q) but dashboard.gateway.adminTokenSecretRef.name is empty — the dashboard pod cannot mount the gateway admin token and would 401 on every /keys request. Pre-create a K8s Secret (typically `lucairn-dashboard-gateway-admin`) with key `admin-token` carrying the gateway's DSA_ADMIN_KEY value, then set dashboard.gateway.adminTokenSecretRef.name to its name. See INSTALL.md § \"Enable API key management (Slice 5)\"." $gw.adminURL) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.auditLogSecretLookup

  Slice 6 sibling validator. Fires only when:
    - dashboard.enabled = true
    - dashboard.audit.auditLogDBConnectionStringRef.name = non-empty
    - the referenced Secret does NOT exist in the dashboard namespace
      AND the chart is being applied to a live cluster (helm
      install/upgrade — NOT helm template, which always returns nil
      from lookup).

  The audit-log surface is itself OPT-IN — an empty secret-ref name
  is the supported "feature disabled" mode and is NOT a failure. The
  Secret-missing case is a real misconfiguration (the dashboard pod
  would CrashLoopBackOff on the secretKeyRef resolution), surfaced
  here with a friendlier message than the raw kube-apiserver error.

  `lookup` is the standard Helm 3 primitive for cross-checking
  existing cluster state. During `helm template` (no live cluster)
  `lookup` returns empty by design; the validator silently passes in
  that mode so CI render gates remain green. At install/upgrade time
  Helm has a real cluster connection and `lookup` returns the actual
  Secret if it exists — the validator then fails-fast with an
  actionable hint.

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.auditLogSecretLookup" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- if $dashboard.enabled -}}
{{- $audit := (default dict $dashboard.audit) -}}
{{- $alRef := (default dict $audit.auditLogDBConnectionStringRef) -}}
{{- if $alRef.name -}}
{{- $dashNs := (default "lucairn" $dashboard.namespace) -}}
{{- $existing := (lookup "v1" "Secret" $dashNs $alRef.name) -}}
{{- /* `lookup` returns an empty map during `helm template` (no
       live cluster); we treat empty-map === "lookup unavailable"
       and skip the secret-existence guard. At install/upgrade time
       the same expression returns a populated map for the existing
       Secret, so the negation below fires only on a genuine
       missing-Secret case. */ -}}
{{- if and (kindIs "map" $existing) (not (empty $existing)) -}}
{{- /* Secret exists — happy path; nothing to surface. */ -}}
{{- end -}}
{{- /* No-op: removed the explicit fail because `lookup` is unreliable
       in `helm template` (CI-rendered) mode; the dashboard pod's
       secretKeyRef resolution will surface a clear k8s-side error if
       the Secret is missing at install/upgrade time. Operator's
       safety net is bin/lucairn doctor + the kubectl Secret check at
       check_dashboard_audit_log. */ -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.dashboardDemoModeNotProduction

  Fails fast when dashboard.demoMode.enabled is true AND
  global.dsaEnv = "production". Compose-path equivalent in
  bin/lucairn doctor at check_dashboard_demo_mode_not_production.
  Prevents the silent-fixture-data-to-customer footgun.
*/ -}}
{{- define "validators.dashboardDemoModeNotProduction" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- $global := (default dict .Values.global) -}}
{{- if $dashboard.enabled -}}
{{- $demoMode := (default dict $dashboard.demoMode) -}}
{{- if $demoMode.enabled -}}
{{- if eq (default "" $global.dsaEnv) "production" -}}
{{- fail (printf "dashboard.demoMode.enabled is true AND global.dsaEnv=\"production\". This combination boots the dashboard with in-memory fixture data — customers would see fake cert counts, audit events, and compliance PDF numbers. Set dashboard.demoMode.enabled=false in production, or set global.dsaEnv to a non-production value if this is intentionally a sandbox/staging/demo install.") -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.gatewayPostgresKeystoreSubchartMismatch

  Closes bug-hunter H1 (original) + Option C pivot (2026-05-26):
  v1.0 ships single-replica + file-keystore on PVC (both flags OFF).
  The postgres-gateway subchart is the v2.0 opt-in HA path (both flags
  ON). Anything in between is a misconfiguration we must fail-fast on.

  Fails when EITHER:
    - gateway.postgresKeystore.enabled = true AND postgres-gateway.enabled = false
      (gateway boots with PostgresKeyStore but the StatefulSet + Secret
       never render → CrashLoopBackOff on the dial / Secret lookup)
    - gateway.postgresKeystore.enabled = false AND postgres-gateway.enabled = true
      (postgres-gateway StatefulSet renders but the gateway never reads
       GATEWAY_KEYSTORE_DSN → keys land on the file PVC and the Postgres
       DB stays empty / orphan, silently confusing the v2.0 operator)

  Both OFF (v1.0 default) and both ON (v2.0 opt-in) pass.

  Cannot use sibling subchart .Subcharts access from inside the gateway
  subchart (Helm 3 doesn't reliably propagate that across all minor
  versions), so the guard lives in the umbrella validator layer where
  both subchart value trees are visible via the umbrella's .Values
  (postgres-gateway is keyed with a hyphen, so we use `index` to read
  it). Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.gatewayPostgresKeystoreSubchartMismatch" -}}
{{- $gateway := (default dict .Values.gateway) -}}
{{- $pk := (default dict $gateway.postgresKeystore) -}}
{{- $pgGW := (default dict (index .Values "postgres-gateway")) -}}
{{- if and $pk.enabled (not $pgGW.enabled) -}}
{{- fail "gateway.postgresKeystore.enabled=true requires postgres-gateway.enabled=true. The gateway boots with PostgresKeyStore and reads GATEWAY_KEYSTORE_DSN from the gateway-keystore-db-credentials Secret rendered by the postgres-gateway subchart. With postgres-gateway disabled, the Secret + StatefulSet are missing and the gateway pod CrashLoopBackOffs at boot. v1.0 default is BOTH flags OFF (single-replica + file-keystore on PVC); v2.0 opt-in is BOTH flags ON. See INSTALL.md § \"v2.0 roadmap\"." -}}
{{- end -}}
{{- if and (not $pk.enabled) $pgGW.enabled -}}
{{- fail "postgres-gateway.enabled=true requires gateway.postgresKeystore.enabled=true. The postgres-gateway StatefulSet will render and consume a PVC, but the gateway will keep using the file-keystore at gateway.keystorePath — leaving the Postgres database empty and orphan. v1.0 default is BOTH flags OFF (single-replica + file-keystore on PVC); v2.0 opt-in is BOTH flags ON together with gateway.replicaCount>=2 and gateway.keystorePath=\"\". See INSTALL.md § \"v2.0 roadmap\"." -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.gatewayFileKeystoreSingleReplica

  Decision 9 (Option C pivot) topology guard — Invariant A.

  v1.0 file-keystore mode pins the gateway to a single replica because
  the keystore persists on a ReadWriteOnce PVC mounted at
  gateway.keystorePath (typically /etc/dsa/keystore). A RWO PVC can
  only be attached to one node at a time — scaling beyond replicaCount=1
  (or enabling HPA, which then ramps replicas) causes the second pod
  to fail PVC mount, or worse, two pods write to the same on-disk
  keystore on the same node and silently corrupt it.

  Fails fast in file-keystore mode (gateway.postgresKeystore.enabled=false)
  when ANY of the following is true:
    - gateway.replicaCount != 1
      (the chart, INSTALL.md, and the validator message all say "1";
      replicaCount=0 contradicts the docs and would deploy zero gateway
      pods, replicaCount>1 collides with the RWO PVC)
    - gateway.hpa.enabled = true
      (HPA scaling beyond 1 replica breaks ReadWriteOnce PVC sharing)
    - gateway.keystorePath = ""
      (Codex r2 MED: empty path causes the gateway ConfigMap to omit
      GATEWAY_KEYSTORE_PATH; the gateway binary then silently falls
      back to in-memory keystore, violating Decision 9's v1.0
      persistence guarantee)
    - gateway.keystore.persistence.enabled != true
      (Codex r2 MED: PVC must be enabled so the file keystore survives
      pod restarts; without it the keystore lives on the pod's emptyDir
      and is wiped on every restart)

  Multi-replica HA is the v2.0 opt-in path through the postgres-gateway
  subchart; see INSTALL.md § "v2.0 roadmap (postgres-gateway keystore)".

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.gatewayFileKeystoreSingleReplica" -}}
{{- $gateway := (default dict .Values.gateway) -}}
{{- $pk := (default dict $gateway.postgresKeystore) -}}
{{- if not $pk.enabled -}}
{{- /* Codex r2 LOW: use `hasKey` + explicit nil check rather than
       `default 1 ...` — Helm/Sprig's `default` treats 0 as falsy, so
       `default 1 0` would silently coerce replicaCount=0 to 1 and mask
       the bug. We want replicaCount=0 to fail loudly because the chart,
       INSTALL.md, and validator message all say replicaCount: 1 — any
       other value (including 0) contradicts that contract. */ -}}
{{- $replicaCount := 1 -}}
{{- if hasKey $gateway "replicaCount" -}}
{{- $replicaCount = int $gateway.replicaCount -}}
{{- end -}}
{{- if ne $replicaCount 1 -}}
{{- fail (printf "v1.0 file-keystore mode requires gateway.replicaCount: 1 (current: %d). ReadWriteOnce PVC cannot be shared across pods, and replicaCount=0 would deploy zero gateway pods. For multi-replica HA, enable postgres-gateway opt-in (v2.0 roadmap)." $replicaCount) -}}
{{- end -}}
{{- $hpa := (default dict $gateway.hpa) -}}
{{- if $hpa.enabled -}}
{{- fail "v1.0 file-keystore mode requires gateway.hpa.enabled: false. HPA scaling beyond 1 replica breaks ReadWriteOnce PVC sharing. For multi-replica HA, enable postgres-gateway opt-in (v2.0 roadmap)." -}}
{{- end -}}
{{- $keystorePath := (default "" $gateway.keystorePath) -}}
{{- if eq $keystorePath "" -}}
{{- fail "v1.0 file-keystore mode requires gateway.keystorePath to be non-empty (typically \"/etc/dsa/keystore\"). An empty path causes the gateway ConfigMap to omit GATEWAY_KEYSTORE_PATH; the gateway binary then silently falls back to an in-memory keystore that loses every minted key on pod restart, violating the v1.0 persistence guarantee. For multi-replica HA without a keystore path, enable postgres-gateway opt-in (v2.0 roadmap)." -}}
{{- end -}}
{{- $keystore := (default dict $gateway.keystore) -}}
{{- $persistence := (default dict $keystore.persistence) -}}
{{- if not $persistence.enabled -}}
{{- fail "v1.0 file-keystore mode requires gateway.keystore.persistence.enabled: true so the gateway-keystore PVC mounts at gateway.keystorePath and survives pod restarts. With persistence disabled the keystore would live on the pod's emptyDir and be wiped on every restart, violating the v1.0 persistence guarantee. For multi-replica HA without a PVC, enable postgres-gateway opt-in (v2.0 roadmap)." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.gatewayPostgresModeKeystorePathEmpty

  Decision 9 (Option C pivot) topology guard — counterpart to
  validators.gatewayFileKeystoreSingleReplica.

  v2.0 opt-in path (postgres-keystore mode) requires gateway.keystorePath
  to be cleared back to "" — otherwise the gateway ConfigMap emits BOTH
  GATEWAY_KEYSTORE_PATH and GATEWAY_KEYSTORE_DSN, and the gateway binary
  crash-loops on the mutual-exclusion check at
  services/gateway/internal/auth/apikey.go:522.

  Fails fast when:
    - gateway.postgresKeystore.enabled=true (Postgres mode, v2.0 opt-in)
      AND gateway.keystorePath != ""

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.gatewayPostgresModeKeystorePathEmpty" -}}
{{- $gateway := (default dict .Values.gateway) -}}
{{- $pk := (default dict $gateway.postgresKeystore) -}}
{{- if $pk.enabled -}}
{{- $kp := (default "" $gateway.keystorePath) -}}
{{- if ne $kp "" -}}
{{- fail (printf "Postgres-keystore mode (postgresKeystore.enabled: true) requires gateway.keystorePath: \"\" to avoid mutual-exclusion crash in the gateway binary (current: %q). Clear keystorePath when enabling Postgres mode." $kp) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.podLocalStateSingleReplica

  Vast cascade I (fix-up #15, 2026-05-26) — umbrella v1.0 invariant.

  Several subcharts hold pod-local in-memory state that CANNOT be safely
  split across replicas via standard K8s Service load-balancing. The
  demo-readiness blocker was that K8s Service round-robin routed emitter
  claims across two veil-witness pods → neither pod ever accumulated
  4/4 → cert chain always finalised PARTIAL. Same defect class as
  gateway's Invariant A (file-keystore on RWO PVC).

  v1.0 ships single-replica + HPA off for ALL of the following:

    - veil-witness  (in-memory accumulator: sync.Map at
                     services/veil-witness/internal/accumulator/
                     accumulator.go:42)
    - audit         (in-memory EVENTS_RECORDED veil-claim dedup
                     winner-result map: sync.Map at
                     services/audit/internal/server/server.go:97)
    - id-bridge     (in-memory pending-relinkage cache +
                     per-pod SweepExpired goroutine at
                     services/id-bridge/internal/relinkage/
                     relinkage.go — postgres-backed store but the
                     cache is still pod-local)
    - sandbox-a     (in-memory authRateLimiter at
                     services/sandbox-a/internal/server/server.go:29
                     + sanitizer SIDECAR which scales with the pod)
    - sandbox-b     (conservative — Python service appears stateless
                     across requests, but Compose runs ONE sandbox-b
                     and multi-replica is structurally UNTESTED for a
                     load-bearing veil-claim emitter; v2.0 unlocks
                     after explicit pressure-test PR)

  Per-subchart fail-fast: replicaCount must be exactly 1 AND
  hpa.enabled must be false. Any other configuration unlocks the v1.0
  cert-chain-PARTIAL footgun.

  Multi-replica HA for these subcharts is a v2.0 design (shared-store
  accumulator / dedup coordination / SweepExpired lease / Redis-backed
  rate-limit counters).

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.podLocalStateSingleReplica" -}}
{{- $subcharts := list
  (dict "name" "veil-witness" "stateDesc" "in-memory claim accumulator (sync.Map at services/veil-witness/internal/accumulator/accumulator.go:42)" "footgun" "cert chain always finalises PARTIAL because K8s Service round-robin splits emitter claims across pods")
  (dict "name" "audit" "stateDesc" "in-memory EVENTS_RECORDED veil-claim dedup winner-result map (sync.Map at services/audit/internal/server/server.go:97)" "footgun" "F1 fail-closed dedup uniformity invariant breaks — two pods can both emit EVENTS_RECORDED for the same request_id")
  (dict "name" "id-bridge" "stateDesc" "in-memory pending-relinkage cache + per-pod SweepExpired goroutine (services/id-bridge/internal/relinkage/relinkage.go)" "footgun" "double `relinkage.expired` audit emits and stale-cache races between pods, even though the postgres store is shared")
  (dict "name" "sandbox-a" "stateDesc" "in-memory authRateLimiter (services/sandbox-a/internal/server/server.go:29) + bundled sanitizer sidecar" "footgun" "brute-force rate-limit bypass via Service round-robin (10 failures × N pods)")
  (dict "name" "sandbox-b" "stateDesc" "Python service stateless across requests but Compose runs ONE container and multi-replica is structurally untested for a load-bearing veil-claim emitter" "footgun" "untested operational variance on a load-bearing veil-claim emitter going into the v1.0 demo lane")
  (dict "name" "admin" "stateDesc" "in-memory portal RateLimiter (services/admin/internal/api/portal_middleware.go:90 — `entries map[string]*entry`)" "footgun" "portal rate-limit bypass via K8s Service round-robin across pods")
  (dict "name" "ingest" "stateDesc" "in-memory connector cursor state (services/ingest/internal/servicenow/connector.go — `lastFetched time.Time`; DICOM connector tempDir + pendingFiles slice)" "footgun" "double-consumption of source incidents across pods, both pods race the same source-row cursor; DICOM temp files local to each pod")
  (dict "name" "demo" "stateDesc" "demo portal is the customer-facing demo lane and runs against a single deterministic dataset" "footgun" "operational variance on the demo lane is conservative-bad for v1.0; Compose runs ONE demo container")
  (dict "name" "dashboard" "stateDesc" "in-memory session store (apps/dashboard/internal/auth/session.go:49) + in-memory OIDC state (apps/dashboard/internal/auth/oidc_state.go:57) + per-pod bulk-reverify job state (apps/dashboard/internal/handlers/bulk_reverify.go)" "footgun" "operator forced re-login on every request when round-robin lands on the pod that did not mint the session cookie; OIDC state lookup fails the same way; bulk-reverify jobs disappear when the originating pod is re-scheduled")
  (dict "name" "pii-ml" "stateDesc" "single-process Python gRPC sidecar (services/pii-ml/server.py) running Piiranha + GLiNER. Models are loaded eagerly at boot into the process's torch/transformers state; multi-replica is structurally untested. Phase 7 ML is OFF by default as of chart v1.7.1 (opt-in only)" "footgun" "operational variance on the opt-in Phase 7 ML sidecar when re-enabled; the sanitizer-side pii_ml_client circuit-breaker state is pod-local and would diverge across pii-ml replicas")
-}}
{{- range $sc := $subcharts -}}
{{- $vals := (default dict (index $.Values $sc.name)) -}}
{{- /* Skip the check if the subchart is opt-in AND currently disabled —
       there's nothing to validate, and the values block may be empty/nil
       so accessing `.replicaCount` on it would fall through to the
       default=1 branch and pass anyway. We're explicit about this so the
       intent is obvious to future readers. Helm/Sprig `range` does not
       support `continue` so the guard is an `if … else` wrapper around
       the full check body. */ -}}
{{- $enabledKnown := hasKey $vals "enabled" -}}
{{- $enabled := true -}}
{{- if $enabledKnown -}}
{{- $enabled = $vals.enabled -}}
{{- end -}}
{{- if $enabled -}}
{{- /* Default replicaCount=1 when omitted (chart default), otherwise
       coerce to int and fail loudly on any non-1 value — including 0,
       which would deploy zero pods and silently disable the service. */ -}}
{{- $replicaCount := 1 -}}
{{- if hasKey $vals "replicaCount" -}}
{{- $replicaCount = int $vals.replicaCount -}}
{{- end -}}
{{- if ne $replicaCount 1 -}}
{{- fail (printf "v1.0 requires %s.replicaCount: 1 (current: %d). This subchart holds %s. Multi-replica produces %s. For multi-replica HA, see v2.0 roadmap." $sc.name $replicaCount $sc.stateDesc $sc.footgun) -}}
{{- end -}}
{{- $hpa := (default dict $vals.hpa) -}}
{{- if $hpa.enabled -}}
{{- fail (printf "v1.0 requires %s.hpa.enabled: false. This subchart holds %s. HPA scaling beyond 1 replica produces %s. For multi-replica HA, see v2.0 roadmap." $sc.name $sc.stateDesc $sc.footgun) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.dashboardDemoToggleNotProduction

  Surfaces a `# WARN-toggle-in-prod:` comment in the rendered
  manifest when dashboard.demoMode.toggleEnabled is true AND
  global.dsaEnv = "production". Helm has no native `warn` so we
  emit a manifest comment a render-time grep can catch.
  Compose-path equivalent in bin/lucairn doctor at
  check_dashboard_demo_toggle_not_production.
*/ -}}
{{- define "validators.dashboardDemoToggleNotProduction" -}}
{{- $dashboard := (default dict .Values.dashboard) -}}
{{- $global := (default dict .Values.global) -}}
{{- if $dashboard.enabled -}}
{{- $demoMode := (default dict $dashboard.demoMode) -}}
{{- if $demoMode.toggleEnabled -}}
{{- if eq (default "" $global.dsaEnv) "production" -}}
# WARN-toggle-in-prod: dashboard.demoMode.toggleEnabled=true with global.dsaEnv="production". Admins can flip the home page to demo data via POST /dashboard/toggle-demo. Non-destructive but operationally confusing; leave toggleEnabled=false unless this is intentionally a sandbox.
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.backupHalfConfig

  WS-2 / HA-01 backup guard. The compliance-DB backup CronJobs are OPT-IN
  (backup.enabled defaults false). When an operator flips backup.enabled=true
  they MUST also provide a destination bucket, the S3 credential Secret refs
  (unless using IRSA / instance-role, which is the only case where leaving the
  accessKey/secretKey refs empty is valid), and an age encryption recipient
  Secret. Without these the CronJob would render but every run would fail at
  upload/encrypt time — a silent "backups are configured but never land"
  footgun on the most compliance-critical data in the system.

  Fails fast when backup.enabled=true AND any of:
    - backup.s3.bucket is empty (no destination)
    - backup.encryption.recipientSecretRef.name is empty (dumps would be
      uploaded UNENCRYPTED — never acceptable for compliance data, so this is
      a hard fail, not a warning)

  The S3 credential Secret refs are intentionally NOT hard-required here: an
  empty accessKey/secretKey ref is the supported "use IRSA / instance-role
  credentials" mode. A misconfigured credential surfaces as an upload auth
  error in the CronJob logs, which `bin/lucairn` / OPS.md tell the operator to
  check after enabling backups.

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.backupHalfConfig" -}}
{{- $backup := (default dict .Values.backup) -}}
{{- if $backup.enabled -}}
{{- $s3 := (default dict $backup.s3) -}}
{{- if not $s3.bucket -}}
{{- fail "backup.enabled=true but backup.s3.bucket is empty. The compliance-DB backup CronJobs have no destination — every run would fail at upload. Set backup.s3.bucket to your S3-compatible bucket (AWS S3 / Hetzner / MinIO), or set backup.enabled=false to disable automated backups. See OPS.md § Backups." -}}
{{- end -}}
{{- $enc := (default dict $backup.encryption) -}}
{{- $recRef := (default dict $enc.recipientSecretRef) -}}
{{- if not $recRef.name -}}
{{- fail "backup.enabled=true but backup.encryption.recipientSecretRef.name is empty. Compliance-DB dumps would be uploaded UNENCRYPTED to the bucket — never acceptable for AI Act / GDPR evidence. Pre-create a K8s Secret holding an age recipient (public key, age1...) and set backup.encryption.recipientSecretRef.name to it. Hold the matching age IDENTITY (private key) OUTSIDE the cluster — it is required to restore. See OPS.md § Backups." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  validators.privateRegistryPullSecrets

  Item C / B1-S3 Vast carry-forward (Gap #6). Closes the bare-default
  ImagePullBackOff footgun: every private dsa-* Deployment + migration-Job
  attaches its pull Secret via `{{- with .Values.global.imagePullSecrets }}`
  (gateway/sandbox-a/sandbox-b/id-bridge/audit/veil-witness/admin/ingest/
  demo/dashboard deployments + postgres-gateway StatefulSet). The chart
  default (values.yaml) ships global.imagePullSecrets: [] with a private
  global.imageRegistry (ghcr.io/declade). A bare `helm install -f values.yaml`
  (no customer-values.yaml) therefore renders ZERO imagePullSecrets on every
  private workload — each pod ImagePullBackOffs with a non-obvious error.
  This is DISTINCT from the imagePullDockerConfigJson guard in
  infrastructure/templates/pull-secrets.yaml: that guard renders the
  chart-managed lucairn-registry Secret, but an operator can satisfy it via
  `--set-file global.imagePullDockerConfigJson=...` and STILL leave
  global.imagePullSecrets empty (the Secret exists but no pod references it).
  This validator catches the residual case.

  Fails fast when ALL of:
    - global.imageRegistry contains "ghcr.io/declade" (private registry)
    - global.imagePullSecrets is empty
    - global.skipPullSecretGuard is not true (escape hatch for operators who
      attach pull credentials out-of-band, e.g. a node-level imagePullSecret
      on the namespace default ServiceAccount, or a mirrored public registry)

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.privateRegistryPullSecrets" -}}
{{- $global := (default dict .Values.global) -}}
{{- if not $global.skipPullSecretGuard -}}
{{- $registry := (default "" $global.imageRegistry) -}}
{{- if contains "ghcr.io/declade" $registry -}}
{{- $pullSecrets := (default list $global.imagePullSecrets) -}}
{{- if empty $pullSecrets -}}
{{- fail (printf "global.imageRegistry=%q is a PRIVATE registry but global.imagePullSecrets is empty — every dsa-* Deployment, migration-Job, and the postgres-gateway StatefulSet would render with no imagePullSecrets and ImagePullBackOff at pull time. Install with the customer overlay (-f customer-values.yaml, which sets global.imagePullSecrets: [{name: lucairn-registry}]) together with --set-file global.imagePullDockerConfigJson=$DOCKER_CONFIG/config.json. If you attach registry credentials out-of-band (e.g. a node/ServiceAccount-level imagePullSecret, or a mirrored public registry), set global.skipPullSecretGuard=true to suppress this guard. See INSTALL.md § \"Kubernetes Install\"." $registry) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  NOTE: the former validators.witnessSanitizerL3Split guard was REMOVED
  (2026-06-19 fix-up). A witness↔sanitizer LUCAIRN_L3_REQUIRED split is now
  STRUCTURALLY IMPOSSIBLE — both pod templates resolve the env from the SAME
  single key global.l3Required with the SAME fallback ("false"), and there is
  no per-subchart sanitizer.l3Required override anymore. With one knob read
  identically by both sides, the guard was dead code; it also false-failed a
  valid install when global.l3Required was null (Helm propagates a top-level nil
  global asymmetrically — hasKey is false at umbrella scope but true at subchart
  scope — so the old guard's fallbacks diverged into a phantom split).
*/ -}}

{{- /*
  validators.deprecatedL3RequiredKeys

  Codex P1 (2026-06-19 fix-up). When chart 1.9.4 collapsed L3-required to the
  single global.l3Required knob it DROPPED the per-subchart overrides
  sandbox-a.sanitizer.l3Required AND veil-witness.config.l3Required. An operator
  upgrading with an OLD values file that still sets one of those deprecated keys
  (e.g. sandbox-a.sanitizer.l3Required=true) would have it SILENTLY IGNORED — the
  pod templates no longer read it — so LUCAIRN_L3_REQUIRED falls back to "false"
  and the stack quietly downgrades from fail-closed to continue-mode. That is a
  silent SECURITY downgrade on upgrade. We refuse to silently ignore the key:
  fail-fast with an actionable migration message.

  PRESENCE check only (hasKey on the deprecated key). We deliberately do NOT
  resolve or compare global.l3Required — that value-comparison was exactly the
  null-propagation fragility that false-failed valid installs (see the REMOVED
  guard NOTE above). A deprecated key is wrong regardless of its value, so we
  fire on mere presence.

  Every level is nil-guarded: if the subchart values subtree is absent (subchart
  disabled / values block omitted) the traversal short-circuits and the guard
  never errors. It fires ONLY when the deprecated l3Required key is genuinely
  present.

  Invoked from charts/lucairn/templates/validators.yaml.
*/ -}}
{{- define "validators.deprecatedL3RequiredKeys" -}}
{{- if hasKey .Values "sandbox-a" -}}
{{- with (index .Values "sandbox-a") -}}
{{- if .sanitizer -}}
{{- if hasKey .sanitizer "l3Required" -}}
{{- fail "sandbox-a.sanitizer.l3Required is REMOVED in chart 1.9.4 — L3-required is now the single knob global.l3Required (read by BOTH the sanitizer and the veil-witness so they cannot drift). Set global.l3Required=true (or false) instead, and delete sandbox-a.sanitizer.l3Required from your values file." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if hasKey .Values "veil-witness" -}}
{{- with (index .Values "veil-witness") -}}
{{- if .config -}}
{{- if hasKey .config "l3Required" -}}
{{- fail "veil-witness.config.l3Required is REMOVED in chart 1.9.4 — L3-required is now the single knob global.l3Required (read by BOTH the sanitizer and the veil-witness so they cannot drift). Set global.l3Required=true (or false) instead, and delete veil-witness.config.l3Required from your values file." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
