#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$ROOT/bin/lucairn"
bash -n "$ROOT/scripts/package-release.sh"
bash -n "$ROOT/tests/test_lucairn_cli.sh"

test -f "$ROOT/OPS.md"
test -f "$ROOT/TROUBLESHOOTING.md"
test -f "$ROOT/docs/CLEAN_HOST_REHEARSAL.md"
test -f "$ROOT/docs/CUSTOMER_HANDOFF_GATES.md"

if grep -R "lucairn-enterprise-deployment-kit-1.1.0-enterprise-customer-bundle" \
  "$ROOT/README.md" "$ROOT/INSTALL.md" "$ROOT/OPS.md" "$ROOT/TROUBLESHOOTING.md" "$ROOT/docs"; then
  echo "stale v1.1 customer-bundle install reference found" >&2
  exit 1
fi

grep -q "v1.3.0-customer-demo-data" "$ROOT/README.md"
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
