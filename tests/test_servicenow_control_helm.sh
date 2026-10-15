#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p test_servicenow_control_helm.py -v
