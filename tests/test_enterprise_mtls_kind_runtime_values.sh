#!/usr/bin/env bash
set -euo pipefail

# Compatibility entrypoint retained for callers of the former one-file runtime
# values test. The public-overlay/private-Secret custody contract supersedes
# it: no application-secret YAML is generated or passed to Helm.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT/tests/test_enterprise_mtls_kind_custody.sh"
