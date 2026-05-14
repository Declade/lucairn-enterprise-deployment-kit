#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$ROOT/bin/lucairn"
bash -n "$ROOT/scripts/package-release.sh"
bash -n "$ROOT/tests/test_lucairn_cli.sh"

ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f); puts "yaml ok: #{f}" }' \
  "$ROOT/docker-compose.customer.yml" \
  "$ROOT/customer.env.example" \
  "$ROOT/customer-values.yaml.example" \
  "$ROOT/charts/lucairn/values.yaml"

if command -v helm >/dev/null 2>&1; then
  helm lint "$ROOT/charts/lucairn" -f "$ROOT/customer-values.yaml.example"
else
  echo "helm lint: skipped (helm not installed)"
fi

echo "static checks: ok"

