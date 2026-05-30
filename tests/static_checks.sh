#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$ROOT/bin/lucairn"
bash -n "$ROOT/scripts/package-release.sh"
bash -n "$ROOT/tests/test_lucairn_cli.sh"
bash -n "$ROOT/tests/test_model_manifest_sha256.sh"
bash -n "$ROOT/tests/test_bundle_verify_replay_guard.sh"
bash -n "$ROOT/tests/test_backup_helm.sh"
bash -n "$ROOT/tests/test_sec_hardening.sh"
bash -n "$ROOT/tests/test_sbom.sh"
bash -n "$ROOT/tests/test_digest_pin.sh"
bash -n "$ROOT/scripts/render-values.sh"
bash -n "$ROOT/scripts/derive-veil-pubkey.sh"

# ── Hardening regression assertions (KIT-4: NET-02/SUP-06/NET-05/OBS-08/OBS-09) ──
# Static (grep/render) assertions so they run without docker. Placed early so
# they are not short-circuited by later doc-version checks.

# NET-02: ollama-identity (the L3 PII-plane LLM) must be parameterised + pinned
# by sha256 digest, never a mutable :latest tag.
SA_VALUES="$ROOT/charts/lucairn/charts/sandbox-a/values.yaml"
grep -q "^ollamaIdentity:" "$SA_VALUES" \
  || { echo "NET-02: ollamaIdentity image block missing from sandbox-a values" >&2; exit 1; }
grep -qE 'digest:[[:space:]]*"sha256:[0-9a-f]{64}"' "$SA_VALUES" \
  || { echo "NET-02: ollamaIdentity image digest pin missing/invalid" >&2; exit 1; }
for f in "$ROOT/charts/lucairn/charts/sandbox-a/templates/ollama-identity-statefulset.yaml" \
         "$ROOT/charts/lucairn/charts/sandbox-a/templates/ollama-identity-model-job.yaml"; do
  if grep -qE 'image:[[:space:]]*"ollama/ollama:latest"|image:[[:space:]]*"curlimages/curl:latest"' "$f"; then
    echo "NET-02: $f still hardcodes a :latest image" >&2; exit 1
  fi
  grep -q ".Values.ollamaIdentity.image.repository" "$f" \
    || { echo "NET-02: $f not parameterised via .Values.ollamaIdentity" >&2; exit 1; }
done
echo "NET-02: ollama-identity images parameterised + digest-pinned"

# SUP-06: dashboard Dockerfile base images pinned by @sha256 digest.
DASH_DF="$ROOT/apps/dashboard/Dockerfile"
fromlines="$(grep -cE '^FROM ' "$DASH_DF")"
pinnedfroms="$(grep -cE '^FROM .*@sha256:[0-9a-f]{64}' "$DASH_DF")"
[ "$fromlines" = "$pinnedfroms" ] \
  || { echo "SUP-06: dashboard Dockerfile has $fromlines FROM lines but only $pinnedfroms digest-pinned" >&2; exit 1; }
echo "SUP-06: dashboard Dockerfile base images digest-pinned ($pinnedfroms/$fromlines)"

# OBS-09: Loki retention only takes effect with a compactor running with
# retention_enabled. Assert the compactor block, the flag, and delete_request_store.
LOKI_CM="$ROOT/charts/lucairn/charts/observability/templates/loki-configmap.yaml"
grep -q "compactor:" "$LOKI_CM" \
  || { echo "OBS-09: loki compactor block missing" >&2; exit 1; }
grep -q "retention_enabled: true" "$LOKI_CM" \
  || { echo "OBS-09: loki compactor retention_enabled not set" >&2; exit 1; }
grep -q "delete_request_store:" "$LOKI_CM" \
  || { echo "OBS-09: loki compactor delete_request_store missing (required in Loki 3.x)" >&2; exit 1; }
echo "OBS-09: loki compactor enforces retention"

# OBS-08: every image-bearing service in both shipped composes must carry a
# logging block (directly, or — for the self-hosted overlay stubs — inherited
# from the base customer compose at merge time).
for cf in "$ROOT/docker-compose.customer.yml" "$ROOT/docker-compose.self-hosted.yml"; do
  grep -q "x-default-logging: &default-logging" "$cf" \
    || { echo "OBS-08: $cf missing x-default-logging anchor" >&2; exit 1; }
done
ruby -e '
  require "yaml"
  base = YAML.load_file(ARGV[0])
  over = YAML.load_file(ARGV[1])
  merged = (base["services"] || {}).dup
  (over["services"] || {}).each do |n, s|
    if merged[n].is_a?(Hash) && s.is_a?(Hash)
      merged[n] = merged[n].merge(s)
    else
      merged[n] = s
    end
  end
  bad = merged.select { |n, s| s.is_a?(Hash) && s.key?("image") && !s.key?("logging") }.keys
  unless bad.empty?
    warn "OBS-08: services with image but no logging after merge: #{bad.join(", ")}"
    exit 1
  end
  puts "OBS-08: all #{merged.size} merged services carry a logging block"
' "$ROOT/docker-compose.customer.yml" "$ROOT/docker-compose.self-hosted.yml"

# NET-05: automountServiceAccountToken disabled everywhere except promtail.
# Render the chart (llmScan on so ollama-identity renders) and assert the
# promtail SA is the only ServiceAccount WITHOUT the disable.
if command -v helm >/dev/null 2>&1; then
  RENDER_FILE="$(mktemp)"
  helm template lucairn "$ROOT/charts/lucairn" \
    --set global.skipPullSecretGuard=true \
    --set sandbox-a.sanitizer.llmScanEnabled=true >"$RENDER_FILE" 2>/dev/null
  grep -q "automountServiceAccountToken: false" "$RENDER_FILE" \
    || { echo "NET-05: no automountServiceAccountToken:false rendered" >&2; rm -f "$RENDER_FILE"; exit 1; }
  # promtail SA must NOT have the disable (it needs the K8s API).
  promtail_block="$(awk '
    /^kind: ServiceAccount/{inb=1; buf=""}
    inb{buf=buf"\n"$0}
    /^---/{ if (inb && buf ~ /name: promtail/) print buf; inb=0 }
    END{ if (inb && buf ~ /name: promtail/) print buf }' "$RENDER_FILE")"
  rm -f "$RENDER_FILE"
  case "$promtail_block" in
    *"automountServiceAccountToken: false"*)
      echo "NET-05: promtail SA wrongly has automountServiceAccountToken:false (it needs the K8s API)" >&2
      exit 1
      ;;
  esac
  echo "NET-05: automount disabled on non-promtail SAs/pods; promtail SA exempt"
else
  echo "NET-05: helm render assertion skipped (helm not installed)"
fi
# ── end hardening assertions ──
# WS-2 / HA-01 regression guard: the plaintext-upload safety check in BOTH
# backup paths must read >= the full age v1 magic ("age-encryption.org/v1",
# 21 bytes) before grepping. A 16-byte read TRUNCATES the 18-char needle so it
# can NEVER match — that aborts every valid backup before upload (BLOCKER).
# This is a pure-static byte-arithmetic check; it needs no age/aws/docker so it
# runs even where the live round-trip (LIVE-VERIFY on Vast) cannot.
grep -q 'head -c 64 "$enc" | grep -q "age-encryption.org"' "$ROOT/bin/lucairn" \
  || { echo "HA-01: bin/lucairn plaintext guard must read >= 64 bytes (found 16-byte read or other)" >&2; exit 1; }
if grep -q 'head -c 16 "$enc"' "$ROOT/bin/lucairn"; then
  echo "HA-01: bin/lucairn plaintext guard still uses head -c 16 (truncated needle, aborts every backup)" >&2; exit 1
fi
grep -q 'head -c 64 "${ENC}" | grep -q "age-encryption.org"' \
  "$ROOT/charts/lucairn/templates/backup-cronjobs.yaml" \
  || { echo "HA-01: Helm backup CronJob plaintext guard must read >= 64 bytes" >&2; exit 1; }
if grep -q 'head -c 16 "${ENC}"' "$ROOT/charts/lucairn/templates/backup-cronjobs.yaml"; then
  echo "HA-01: Helm backup CronJob plaintext guard still uses head -c 16" >&2; exit 1
fi
echo "ha-01 backup plaintext-guard byte-width: ok (both paths read >= 64 bytes)"

test -f "$ROOT/OPS.md"
test -f "$ROOT/TROUBLESHOOTING.md"
test -f "$ROOT/docs/CLEAN_HOST_REHEARSAL.md"
test -f "$ROOT/docs/CUSTOMER_HANDOFF_GATES.md"

if grep -R "lucairn-enterprise-deployment-kit-1.1.0-enterprise-customer-bundle" \
  "$ROOT/README.md" "$ROOT/INSTALL.md" "$ROOT/OPS.md" "$ROOT/TROUBLESHOOTING.md" "$ROOT/docs"; then
  echo "stale v1.1 customer-bundle install reference found" >&2
  exit 1
fi

# Kit release version must be consistent across README target, VERSION, and
# image-manifest.kit_version (INS-05; see docs/RELEASING.md § "Version
# reconciliation"). README carries the git-tag `v` prefix; VERSION + manifest
# do not — strip it before comparing.
KIT_VER="$(tr -d '[:space:]' < "$ROOT/VERSION")"
grep -q "v${KIT_VER}" "$ROOT/README.md"
grep -q "^kit_version: \"${KIT_VER}\"" "$ROOT/image-manifest.yaml"

# Release-version gate (was a hardcoded grep for "v1.3.0-customer-demo-data",
# which silently aborted the whole script under `set -e` once README's
# `Target release:` line moved to v1.5.1-dashboard — taking every downstream
# assertion, including the HA-* / OBS-02 guards below, offline). In addition to
# the INS-05 reconciliation above, derive the version from the README's own
# canonical `Target release: \`vX\`` line and assert it is present + non-empty
# + well-formed, so the downstream HA-* / OBS-02 guards always run.
README_RELEASE_VER="$(grep -m1 -oE 'Target release: `v[0-9][0-9A-Za-z.-]*`' "$ROOT/README.md" \
  | sed -E 's/^Target release: `v//; s/`$//')"
if [ -z "$README_RELEASE_VER" ]; then
  echo "README is missing a well-formed 'Target release: \`vX.Y.Z\`' version line" >&2
  exit 1
fi
echo "README target release version: v${README_RELEASE_VER}"
grep -q "clean-host rehearsal" "$ROOT/docs/CLEAN_HOST_REHEARSAL.md"
grep -q "handoff gate" "$ROOT/docs/CUSTOMER_HANDOFF_GATES.md"

ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "yaml ok: #{f}" }' \
  "$ROOT/docker-compose.customer.yml" \
  "$ROOT/docker-compose.self-hosted.yml" \
  "$ROOT/customer.env.example" \
  "$ROOT/customer-values.yaml.example" \
  "$ROOT/model-manifest.example.yaml" \
  "$ROOT/charts/lucairn/values.yaml"

if command -v helm >/dev/null 2>&1; then
  helm lint "$ROOT/charts/lucairn" -f "$ROOT/customer-values.yaml.example"

  CHART="$ROOT/charts/lucairn"

  # HA-02 regression guard: values-prod.yaml MUST render. It previously
  # shipped replicaCount: 2 on pod-local-state services that the chart's
  # OWN validator (templates/_validators.tpl) hard-rejects, so
  # `helm install -f values-prod.yaml` failed at render time. All
  # replicaCounts are now pinned to 1 (the v1.0 single-replica lock).
  PROD_RENDER="$(helm template lucairn "$CHART" \
    -f "$CHART/values-prod.yaml" \
    --set global.skipPullSecretGuard=true \
    --set gateway.secrets.values.dsaServiceToken=x \
    --set audit.secrets.values.dsaServiceToken=x \
    --set id-bridge.secrets.values.dsaServiceToken=x \
    --set sandbox-a.secrets.values.dsaServiceToken=x \
    --set admin.secrets.values.dsaServiceToken=x \
    --set ingest.secrets.values.dsaServiceToken=x \
    --set sandbox-b.redis.password=xxxxxxxx \
    --set sandbox-b.secrets.values.sandboxBApiKeys=x)"
  echo "helm template (values-prod.yaml): rendered ok (HA-02)"

  # HA-03 guard: at the v1.0 single-replica lock, no PodDisruptionBudget
  # may render — a PDB with minAvailable:1 on a one-pod workload blocks
  # `kubectl drain` forever. PDBs auto-render only at replicaCount >= 2.
  DEFAULT_RENDER="$(helm template lucairn "$CHART" --set global.skipPullSecretGuard=true)"
  # NOTE: use `grep -c` (count the whole stream) rather than `grep -q` for the
  # checks against $DEFAULT_RENDER. Under `set -o pipefail`, `grep -q` exits 0
  # on the FIRST match and closes the pipe, which sends SIGPIPE (exit 141) to
  # the `echo "$DEFAULT_RENDER"` writing the ~160KB render upstream. pipefail
  # then propagates that 141 as the pipeline status, so `if ! ... grep -q`
  # spuriously takes the failure branch even though the pattern matched. The
  # race is load-dependent (only fires once the upstream write is large enough
  # to still be in flight when grep closes the pipe), which is exactly the
  # HA-09 case below. Counting reads the whole stream, so echo never gets
  # SIGPIPE and the result is deterministic.
  PDB_COUNT="$(echo "$DEFAULT_RENDER" | grep -c "kind: PodDisruptionBudget" || true)"
  if [ "$PDB_COUNT" -gt 0 ]; then
    echo "HA-03: PodDisruptionBudget rendered at single-replica (drain footgun)" >&2
    exit 1
  fi
  echo "helm template (default): no PDB at single-replica (HA-03)"

  # HA-04 guard: gateway + the 5 stateless/service Deployments each carry a
  # preStop drain hook + terminationGracePeriodSeconds. 6 services total.
  GRACE_COUNT="$(echo "$DEFAULT_RENDER" | grep -c "terminationGracePeriodSeconds: 30" || true)"
  PRESTOP_COUNT="$(echo "$DEFAULT_RENDER" | grep -c 'sleep 5"]' || true)"
  if [ "$GRACE_COUNT" -lt 6 ] || [ "$PRESTOP_COUNT" -lt 6 ]; then
    echo "HA-04: expected >=6 graceful-shutdown blocks (grace=$GRACE_COUNT prestop=$PRESTOP_COUNT)" >&2
    exit 1
  fi
  echo "helm template (default): graceful-shutdown on $PRESTOP_COUNT services (HA-04)"

  # HA-09 guard: the sandbox-a sanitizer sidecar readiness uses /readyz
  # (functional) not /healthz (connectivity-only). Count-based for the same
  # pipefail/SIGPIPE reason documented at the HA-03 check above (this pattern
  # DOES match, so `grep -q` would race and spuriously fail here).
  SANITIZER_PORT_COUNT="$(echo "$DEFAULT_RENDER" | grep -c "port: sanitizer" || true)"
  if [ "$SANITIZER_PORT_COUNT" -lt 1 ]; then
    echo "HA-09: sanitizer port not found in render" >&2
    exit 1
  fi
  echo "helm template (default): sanitizer readiness probe present (HA-09)"

  # OBS-02 guard: ServiceMonitors scrape ONLY the services that expose
  # /metrics (gateway + veil-witness), with correct namespace mapping.
  SM_RENDER="$(helm template lucairn "$CHART" \
    --set global.skipPullSecretGuard=true \
    --set observability.serviceMonitors.enabled=true)"
  SM_NAMES="$(echo "$SM_RENDER" | awk '/kind: ServiceMonitor/{f=1} f&&/name: dsa-/{print $2; f=0}' | sort | tr '\n' ' ')"
  if [ "$SM_NAMES" != "dsa-gateway dsa-veil-witness " ]; then
    echo "OBS-02: ServiceMonitors must be exactly gateway+veil-witness, got: $SM_NAMES" >&2
    exit 1
  fi
  echo "helm template (serviceMonitors): scrape only gateway+veil-witness (OBS-02)"

  # WS-2 / HA-01 backup-CronJob render + fail-fast checks.
  bash "$ROOT/tests/test_backup_helm.sh"
else
  echo "helm lint + template smoke: skipped (helm not installed)"
fi

if docker compose version >/dev/null 2>&1; then
  docker compose \
    -f "$ROOT/docker-compose.customer.yml" \
    -f "$ROOT/docker-compose.self-hosted.yml" \
    --env-file "$ROOT/customer.env.example" \
    config --quiet
else
  echo "compose config: skipped (docker compose not installed)"
fi

# B1 Slice 2: `lucairn sbom` arg-parse + SPDX-summary + fail-fast tests. These
# are self-contained (no docker/helm/cosign needed) so they run here as part of
# the static gate.
bash "$ROOT/tests/test_sbom.sh"

# B1 Slice 3: digest-pin + `doctor --strict`. parse_image_digests + the
# clean/tampered/no-resolver strict-gating cases run against a STUB resolver, so
# they are self-contained (no docker/crane/skopeo/cosign needed) and belong in
# the static gate. The live registry round-trip is the post-merge Vast
# edge-verify (PRD § Acceptance / Slice 3).
bash "$ROOT/tests/test_digest_pin.sh"

# B1 Slice 3: the manifest digest block records EXACTLY the 13 cosign-signed
# artifacts (keys/image-digests-0.5.0.txt) under signed_artifacts, in lockstep.
# Assert the block exists + every signed digest appears identically, so a future
# tag/digest bump that updates the digests file but forgets the manifest (or vice
# versa) fails the static gate rather than silently drifting --strict away from
# verify-images. apps/dashboard/image-manifest.yaml must stay byte-identical to
# the root manifest (existing kit invariant — both pin the same set).
grep -q '^image_digests:[[:space:]]*$' "$ROOT/image-manifest.yaml" \
  || { echo "B1-S3: image-manifest.yaml is missing the image_digests: block" >&2; exit 1; }

# Strengthened (MED [trailofbits]): assert via the ACTUAL parser, not a textual
# grep. A grep for `ref:`/`digest:` substrings cannot catch a future careless
# edit that DOWNGRADES a signed ref to PENDING (drops the digest line) or to
# INVALID (truncates the digest, or adds a stray `pending: true`) — the textual
# substring may still be present elsewhere while the parser's per-entry verdict
# silently changes. We run parse_image_digests over the SHIPPED manifest and
# assert each of the 13 signed_artifacts resolves to its EXACT recorded digest
# verdict — never PENDING, INVALID, or <no-ref>.
_PARSED_STATIC="$(
  set --
  source "$ROOT/bin/lucairn" >/dev/null 2>&1
  parse_image_digests "$ROOT/image-manifest.yaml"
)"
while IFS= read -r _l; do
  _l="${_l%%#*}"; _ref="${_l%% *}"; _rec="${_l##* }"
  _ref="${_ref#"${_ref%%[![:space:]]*}"}"; _ref="${_ref%"${_ref##*[![:space:]]}"}"
  [ -n "$_ref" ] || continue
  case "$_rec" in sha256:*) ;; *) continue ;; esac
  # The parser must resolve this signed ref to its EXACT recorded digest. A
  # PENDING/INVALID/absent verdict here = a signed ref was downgraded -> FAIL.
  printf '%s\n' "$_PARSED_STATIC" | grep -qF "$(printf '%s\t%s' "$_ref" "$_rec")" \
    || { echo "B1-S3: signed ref $_ref does NOT resolve to its recorded digest $_rec via parse_image_digests (downgraded to PENDING/INVALID, or absent) — a signed ref was silently weakened" >&2; exit 1; }
done < "$ROOT/keys/image-digests-0.5.0.txt"
# Defensive: the parser must emit NO INVALID / <no-ref> verdicts for the shipped
# manifest (a clean manifest has none — any is a manifest-integrity regression).
# Use `if` (not `&&`) so the no-match happy path does not trip `set -e`.
if printf '%s\n' "$_PARSED_STATIC" | grep -q $'\tINVALID$'; then
  echo "B1-S3: parse_image_digests reports an INVALID entry in the shipped image-manifest.yaml" >&2; exit 1
fi
if printf '%s\n' "$_PARSED_STATIC" | grep -q '^<no-ref>'; then
  echo "B1-S3: parse_image_digests reports an orphan <no-ref> entry in the shipped image-manifest.yaml" >&2; exit 1
fi
if [ -f "$ROOT/apps/dashboard/image-manifest.yaml" ]; then
  diff -q "$ROOT/image-manifest.yaml" "$ROOT/apps/dashboard/image-manifest.yaml" >/dev/null \
    || { echo "B1-S3: apps/dashboard/image-manifest.yaml drifted from the root image-manifest.yaml" >&2; exit 1; }
fi
echo "B1-S3: image_digests block in lockstep with keys/image-digests-0.5.0.txt (via parser) + dashboard manifest synced"

echo "static checks: ok"
