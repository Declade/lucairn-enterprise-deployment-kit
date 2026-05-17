#!/usr/bin/env bash
#
# Slice 1 compose smoke test for the Lucairn Enterprise Dashboard.
#
# Brings the dashboard container up under docker-compose.customer.yml +
# --profile dashboard, hits /healthz and /login, then tears down.
#
# Exits 0 on success. Designed to be runnable by CI runners that already
# have docker compose. Locally this script is what you run to confirm a
# fresh customer.env wiring will Just Work.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

if ! docker compose version >/dev/null 2>&1; then
  echo "compose-smoke: docker compose unavailable" >&2
  exit 1
fi

# Build (or rebuild) the dashboard image locally so the compose service has
# something to pull from. The compose config references the GHCR-tagged
# image; we tag the local build to that exact name so docker compose finds
# it without going to the network.
LOCAL_TAG="${LUCAIRN_IMAGE_REGISTRY:-ghcr.io/declade}/lucairn-dashboard:${LUCAIRN_DASHBOARD_IMAGE_TAG:-0.1.0}"
echo "compose-smoke: building image as ${LOCAL_TAG}"
docker build -t "${LOCAL_TAG}" -f apps/dashboard/Dockerfile apps/dashboard >/dev/null

# Build a temporary env file from the example so the heavy gateway/witness
# preconditions in the base compose are satisfied. We append the dashboard
# bootstrap password (required when --profile dashboard is active).
TMP_ENV="$(mktemp)"
trap 'docker compose -f docker-compose.customer.yml --env-file "$TMP_ENV" --profile dashboard down >/dev/null 2>&1 || true; rm -f "$TMP_ENV"' EXIT

cp customer.env.example "$TMP_ENV"
{
  echo ""
  echo "LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=compose-smoke-pass-1234"
  echo "LUCAIRN_DASHBOARD_BOOTSTRAP_EMAIL=admin@lucairn.local"
} >> "$TMP_ENV"

echo "compose-smoke: docker compose up -d lucairn-dashboard"
docker compose -f docker-compose.customer.yml --env-file "$TMP_ENV" --profile dashboard up -d lucairn-dashboard

# Wait up to 30s for the container's health probe to flip to healthy.
echo "compose-smoke: waiting for /healthz to return 200"
deadline=$((SECONDS + 30))
while [ $SECONDS -lt $deadline ]; do
  if curl -fsS http://127.0.0.1:8443/healthz >/dev/null 2>&1; then
    echo "compose-smoke: /healthz ok"
    break
  fi
  sleep 1
done

if ! curl -fsS http://127.0.0.1:8443/healthz; then
  echo "compose-smoke: /healthz never returned 200 within 30s" >&2
  docker compose -f docker-compose.customer.yml --env-file "$TMP_ENV" --profile dashboard logs lucairn-dashboard | tail -50 >&2
  exit 1
fi
echo ""

echo "compose-smoke: hitting /login (expect 200 + HTML form)"
LOGIN_BODY=$(curl -fsS -L http://127.0.0.1:8443/login)
if ! echo "$LOGIN_BODY" | grep -q "Sign in"; then
  echo "compose-smoke: /login did not contain 'Sign in'" >&2
  echo "$LOGIN_BODY" >&2
  exit 1
fi
echo "compose-smoke: /login ok"

echo "compose-smoke: ok"
