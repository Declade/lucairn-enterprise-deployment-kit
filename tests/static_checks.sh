#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$ROOT/bin/lucairn"
bash -n "$ROOT/scripts/package-release.sh"
bash -n "$ROOT/tests/test_lucairn_cli.sh"
bash -n "$ROOT/tests/test_model_manifest_sha256.sh"
bash -n "$ROOT/tests/test_bundle_verify_replay_guard.sh"

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
else
  echo "helm lint: skipped (helm not installed)"
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

echo "static checks: ok"
