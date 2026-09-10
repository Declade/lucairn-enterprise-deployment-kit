#!/usr/bin/env bash
#
# Run the Lucairn for Now Assist adapter unit tests as part of the kit's
# `make test`.
#
# WHY THIS SCRIPT EXISTS RATHER THAN A BARE `node --test` LINE
# ------------------------------------------------------------
# A test lane that cannot run must FAIL LOUDLY, not pass quietly. If Node is
# absent on the machine running `make test`, a bare `node --test` line either
# breaks the build with a confusing "command not found" or — worse, if anyone
# ever softens it with `|| true` — reports success for tests that never
# executed. A skipped job reads as a pass (T-577), and the whole point of these
# tests is the fail-closed behaviour they guard.
#
# So: no Node, no coverage, EXIT 1, with the reason on stdout.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "==> Lucairn for Now Assist adapter tests"

if ! command -v node >/dev/null 2>&1; then
    echo "FAIL: NOT RUN — node is not on PATH."
    echo "      The adapter unit tests cover the fail-closed decision, the"
    echo "      evidence-row precondition and the diagnostic-leak canaries."
    echo "      Not running them is not the same as passing them."
    echo "      Install Node 18 or newer, then re-run 'make test'."
    exit 1
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 18 ]; then
    echo "FAIL: NOT RUN — node $(node --version) is too old; node --test needs 18 or newer."
    exit 1
fi

echo "    node $(node --version)"
node --test "test/*.test.js"
