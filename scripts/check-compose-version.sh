#!/usr/bin/env bash
# check-compose-version.sh — preflight for the v2.20.0 Docker Compose floor.
#
# Board T-243 / PRD prd-2026-07-28-split-evidence-plane.md follow-up.
#
# WHY THIS EXISTS
# ----------------
# docker-compose.self-hosted.yml declares
# `depends_on.veil-witness.required: false` on `sandbox-b` (see the comment
# block at that key). `required:` was added to the Compose Spec in v2.20.0.
# Older clients do NOT ignore the unknown key — the schema is
# additionalProperties:false there, so they refuse the WHOLE FILE:
#
#   validating docker-compose.self-hosted.yml:
#     services.sandbox-b.depends_on.veil-witness Additional property required is not allowed
#
# Measured 2026-07-28 on real binaries: v2.19.1 fails with exactly that
# message; v2.20.0, v2.20.3, and v5.1.0 all accept the file. This affects the
# STOCK full on-prem set (docker-compose.customer.yml +
# docker-compose.self-hosted.yml) — no overlay required to hit it.
#
# WHY THE FIX ISN'T IN docker-compose.self-hosted.yml OR THE OVERLAY
# --------------------------------------------------------------------
# The `required: false` key is what lets `customer + self-hosted +
# witness-central` render at all (see the long comment at that key: without
# it, sandbox-b's hard depends_on a witness that the witness-central overlay
# has profiled out makes the whole project invalid). Moving the relaxation
# into contrib/witness-central/docker-compose.witness-central.yml was tried
# and measured NOT to work: that overlay is also applied WITHOUT
# docker-compose.self-hosted.yml (customer + witness-central, no AI plane),
# and any top-level `sandbox-b:` key in the overlay — even an override-only
# block with no `image:` — creates a new, imageless service in THAT cell and
# breaks it instead:
#
#   service "sandbox-b" has neither an image nor a build context specified: invalid compose project
#
# So the key stays, and this script is the mitigation: a loud, readable,
# config-time check an operator (or a doc) can run BEFORE `docker compose up`
# fails with the opaque schema error above.
#
# NOT WIRED INTO `bin/lucairn doctor` YET. That file is collision-locked by
# kit PR #99 at the time this script was written. Giving `doctor` this same
# check is a follow-up — until then, run this script directly, or read the
# version floor called out in INSTALL.md / docs/CUSTOMER_INSTALL_RUNBOOK.md /
# docs/CLEAN_HOST_REHEARSAL.md.
#
# TESTABILITY
# -----------
# COMPOSE_VERSION_CMD overrides how this script asks for the installed
# version, so it can be pointed at any `docker compose`-shaped binary/wrapper
# without touching PATH — used by tests/test_witness_central_profile.sh to
# mutation-prove this check against a REAL v2.19.1 binary, not a synthetic
# string.

set -euo pipefail

REQUIRED_STR="2.20.0"

: "${COMPOSE_VERSION_CMD:=docker compose version --short}"

if ! raw="$(eval "$COMPOSE_VERSION_CMD" 2>&1)"; then
  echo "FATAL: could not run '$COMPOSE_VERSION_CMD':" >&2
  echo "$raw" >&2
  exit 1
fi

# `--short` gives e.g. "2.19.1" on every binary we tested (v2.19.1 through
# v5.1.0). Be defensive about a stray "Docker Compose version v" prefix from
# an odd/older invocation and take the last non-empty line, in case the
# command also prints warnings on earlier lines.
ver="$(printf '%s\n' "$raw" | tail -n1 | sed -E 's/^.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/')"

if ! printf '%s' "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "FATAL: could not parse a Docker Compose version number out of:" >&2
  echo "$raw" >&2
  exit 1
fi

if [ "$ver" = "$REQUIRED_STR" ]; then
  meets_floor=1
else
  lowest="$(printf '%s\n%s\n' "$ver" "$REQUIRED_STR" | sort -V | head -n1)"
  if [ "$lowest" = "$REQUIRED_STR" ]; then
    meets_floor=1
  else
    meets_floor=0
  fi
fi

if [ "$meets_floor" -ne 1 ]; then
  cat >&2 <<MSG
FATAL: Docker Compose ${ver} detected; this kit requires v${REQUIRED_STR} or newer.

docker-compose.self-hosted.yml declares
depends_on.veil-witness.required: false on sandbox-b. The 'required:' key
was added to the Compose Spec in v${REQUIRED_STR} -- older clients do not
ignore it, they refuse the whole file:

  validating docker-compose.self-hosted.yml:
    services.sandbox-b.depends_on.veil-witness Additional property required is not allowed

Upgrade Docker Compose to v${REQUIRED_STR} or newer and re-run. See
docs/CUSTOMER_INSTALL_RUNBOOK.md and INSTALL.md "Pre-Requisites".
MSG
  exit 1
fi

echo "OK: Docker Compose ${ver} meets the v${REQUIRED_STR} floor."
