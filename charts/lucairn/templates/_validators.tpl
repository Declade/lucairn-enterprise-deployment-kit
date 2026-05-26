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
