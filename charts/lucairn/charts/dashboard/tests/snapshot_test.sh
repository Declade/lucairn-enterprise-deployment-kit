#!/usr/bin/env bash
#
# Slice 1 Helm snapshot test for the dashboard sub-chart.
#
# Renders the top-level lucairn chart with dashboard.enabled=true (using the
# committed customer-values.yaml.example as a baseline so the witness /
# gateway / sandbox-b precondition fails do not fire), then validates every
# rendered manifest with kubeconform.
#
# Exits 0 on success, non-zero on validation failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "snapshot_test: installing kubeconform via brew (macOS) or please add it to your PATH"
  if command -v brew >/dev/null 2>&1; then
    brew install kubeconform >/dev/null
  else
    echo "snapshot_test: kubeconform missing and brew unavailable — install kubeconform manually" >&2
    exit 1
  fi
fi

# Codex r2 LOW fix: the umbrella chart now enforces a pull-secret guard at
# render time (--set-file global.imagePullDockerConfigJson=... is required
# in real installs). For the snapshot test we materialize a throwaway
# Docker config with a dummy `test:test` ghcr.io credential so the render
# completes without forcing operators to provision a real registry token
# just to run the test. The credential never reaches a real registry.
SNAPSHOT_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$SNAPSHOT_TMPDIR"' EXIT
SNAPSHOT_DOCKER_CONFIG="$SNAPSHOT_TMPDIR/dockerconfig.json"
cat > "$SNAPSHOT_DOCKER_CONFIG" <<'EOF'
{"auths":{"ghcr.io":{"auth":"dGVzdDp0ZXN0"}}}
EOF

echo "snapshot_test: helm dependency update"
helm dependency update charts/lucairn >/dev/null

echo "snapshot_test: helm template + kubeconform"
helm template lucairn charts/lucairn \
  -f customer-values.yaml.example \
  --set-file global.imagePullDockerConfigJson="$SNAPSHOT_DOCKER_CONFIG" \
  --set dashboard.enabled=true \
  | kubeconform -strict -summary -ignore-missing-schemas

# Re-render with dashboard.enabled=false to make sure the sub-chart is
# silent when opted-out. We grep for any rendered dashboard resource and
# fail if any are found.
echo "snapshot_test: confirming dashboard renders nothing when disabled"
DISABLED_RENDER="$(helm template lucairn charts/lucairn \
  -f customer-values.yaml.example \
  --set-file global.imagePullDockerConfigJson="$SNAPSHOT_DOCKER_CONFIG" \
  --set dashboard.enabled=false || true)"
if echo "$DISABLED_RENDER" | grep -q "lucairn-dashboard"; then
  echo "snapshot_test: dashboard.enabled=false STILL rendered a dashboard resource — opt-in is broken" >&2
  exit 1
fi

echo "snapshot_test: ok"
