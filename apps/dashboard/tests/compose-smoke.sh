#!/usr/bin/env bash
#
# Slice 1 compose smoke test for the Lucairn Enterprise Dashboard.
#
# Brings the dashboard container up under docker-compose.customer.yml +
# --profile dashboard, then exercises:
#   - GET /healthz (must return 200; readiness signal for liveness probe)
#   - GET /login   (must return 200, render the Sign-in form, AND emit
#                   the hidden CSRF input that LoginPost requires).
# Tears the container down on exit.
#
# Exits 0 on success. Designed to be runnable by CI runners that already
# have docker compose. Locally this script is what you run to confirm a
# fresh customer.env wiring will Just Work end-to-end.

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
LOCAL_TAG="${LUCAIRN_IMAGE_REGISTRY:-ghcr.io/declade}/lucairn-dashboard:${LUCAIRN_DASHBOARD_IMAGE_TAG:-0.8.0}"
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

echo "compose-smoke: hitting /login (expect 200 + HTML form + CSRF hidden input)"
LOGIN_BODY=$(curl -fsS -L http://127.0.0.1:8443/login)
if ! echo "$LOGIN_BODY" | grep -q "Sign in"; then
  echo "compose-smoke: /login did not contain 'Sign in'" >&2
  echo "$LOGIN_BODY" >&2
  exit 1
fi
# The login form renders a hidden `<input ... name="csrf" ...>` field that
# LoginPost requires; without it the form would 401 on every submit. Assert
# the field is present so a regression that drops it would fail the smoke.
if ! echo "$LOGIN_BODY" | grep -qE 'name="csrf"'; then
  echo "compose-smoke: /login form did not render the hidden CSRF input" >&2
  echo "$LOGIN_BODY" >&2
  exit 1
fi
echo "compose-smoke: /login ok"

# Slash-variant routes (Codex r1 #9). The auth-middleware allowlist (FX-17)
# accepts /healthz/ and /login/ trailing-slash forms, and the mux now registers
# 308 redirects to the canonical paths. Verify both behave as expected so a
# regression that drops either the allowlist entry OR the mux handler is
# caught by the smoke run.
echo "compose-smoke: hitting /healthz/ (expect 308 -> /healthz)"
HEALTHZ_SLASH_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/healthz/)
if [ "$HEALTHZ_SLASH_CODE" != "308" ]; then
  echo "compose-smoke: /healthz/ expected 308, got $HEALTHZ_SLASH_CODE" >&2
  exit 1
fi
HEALTHZ_SLASH_FINAL=$(curl -s -o /dev/null -w "%{http_code}" -L http://127.0.0.1:8443/healthz/)
if [ "$HEALTHZ_SLASH_FINAL" != "200" ]; then
  echo "compose-smoke: /healthz/ after redirect expected 200, got $HEALTHZ_SLASH_FINAL" >&2
  exit 1
fi
echo "compose-smoke: /healthz/ ok (308 -> 200)"

echo "compose-smoke: hitting /login/ (expect 308 -> /login)"
LOGIN_SLASH_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/login/)
if [ "$LOGIN_SLASH_CODE" != "308" ]; then
  echo "compose-smoke: /login/ expected 308, got $LOGIN_SLASH_CODE" >&2
  exit 1
fi
LOGIN_SLASH_FINAL=$(curl -s -o /dev/null -w "%{http_code}" -L http://127.0.0.1:8443/login/)
if [ "$LOGIN_SLASH_FINAL" != "200" ]; then
  echo "compose-smoke: /login/ after redirect expected 200, got $LOGIN_SLASH_FINAL" >&2
  exit 1
fi
echo "compose-smoke: /login/ ok (308 -> 200)"

# Slice 3: cert browser route. Compose smoke does not wire an audit DB
# secret (the smoke env intentionally leaves LUCAIRN_DASHBOARD_AUDIT_DB_URL
# empty so the binary boots without a Postgres dial), so /certs returns
# 302 to /login (auth gate) — the route is registered. After login the
# binary renders the "not configured" explainer, which the kind verify
# script exercises separately.
echo "compose-smoke: hitting /certs (expect 302 -> /login; route registered + auth-gated)"
CERTS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/certs)
if [ "$CERTS_CODE" != "302" ]; then
  echo "compose-smoke: /certs expected 302, got $CERTS_CODE" >&2
  exit 1
fi
CERTS_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" http://127.0.0.1:8443/certs)
case "$CERTS_LOC" in
  */login*) ;;
  *) echo "compose-smoke: /certs redirect target should be /login, got $CERTS_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: /certs ok (302 -> /login)"

# Slice 4: server-health route. /health is auth-gated like /certs; an
# unauthenticated GET should 302 to /login. The route registration
# itself (vs falling through to the catch-all 404) is what the smoke
# is checking — the rendered overview content is exercised by the
# Kind verify script when a session cookie is available.
echo "compose-smoke: hitting /health (expect 302 -> /login; route registered + auth-gated)"
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/health)
if [ "$HEALTH_CODE" != "302" ]; then
  echo "compose-smoke: /health expected 302, got $HEALTH_CODE" >&2
  exit 1
fi
HEALTH_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" http://127.0.0.1:8443/health)
case "$HEALTH_LOC" in
  */login*) ;;
  *) echo "compose-smoke: /health redirect target should be /login, got $HEALTH_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: /health ok (302 -> /login)"

# Slice 4: server-health Grafana JWT endpoint. POST /health/grafana-jwt
# is mounted UNDER the same auth-middleware chain as /health: the
# RequireSession middleware emits a 302 redirect with
# Location: /login?next=... for any unauthenticated request (regardless
# of method). The 401 inside the handler body is reachable only AFTER
# session loading — which never happens here because RequireSession
# short-circuits the chain before the handler runs.
echo "compose-smoke: hitting POST /health/grafana-jwt (expect 302 -> /login; auth-gated)"
JWT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8443/health/grafana-jwt)
if [ "$JWT_CODE" != "302" ]; then
  echo "compose-smoke: POST /health/grafana-jwt expected 302, got $JWT_CODE" >&2
  exit 1
fi
JWT_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" -X POST http://127.0.0.1:8443/health/grafana-jwt)
case "$JWT_LOC" in
  */login*) ;;
  *) echo "compose-smoke: POST /health/grafana-jwt redirect target should be /login, got $JWT_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: POST /health/grafana-jwt ok (302 -> /login)"

# Slice 5: /keys surface. Same auth-gated pattern as /health — an
# unauthenticated GET should 302 to /login regardless of role; the
# admin-only RequireRole gate fires AFTER session load and would
# return 404 to viewers (per Slice 1 RequireRole lock).
echo "compose-smoke: hitting GET /keys (expect 302 -> /login; auth-gated)"
KEYS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/keys)
if [ "$KEYS_CODE" != "302" ]; then
  echo "compose-smoke: GET /keys expected 302, got $KEYS_CODE" >&2
  exit 1
fi
KEYS_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" http://127.0.0.1:8443/keys)
case "$KEYS_LOC" in
  */login*) ;;
  *) echo "compose-smoke: GET /keys redirect target should be /login, got $KEYS_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: GET /keys ok (302 -> /login)"

echo "compose-smoke: hitting POST /keys/mint (expect 302 -> /login; auth-gated)"
MINT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8443/keys/mint)
if [ "$MINT_CODE" != "302" ]; then
  echo "compose-smoke: POST /keys/mint expected 302, got $MINT_CODE" >&2
  exit 1
fi
MINT_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" -X POST http://127.0.0.1:8443/keys/mint)
case "$MINT_LOC" in
  */login*) ;;
  *) echo "compose-smoke: POST /keys/mint redirect target should be /login, got $MINT_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: POST /keys/mint ok (302 -> /login)"

echo "compose-smoke: hitting POST /keys/some-key-id/revoke (expect 302 -> /login; auth-gated)"
REVOKE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8443/keys/some-key-id/revoke)
if [ "$REVOKE_CODE" != "302" ]; then
  echo "compose-smoke: POST /keys/some-key-id/revoke expected 302, got $REVOKE_CODE" >&2
  exit 1
fi
REVOKE_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" -X POST http://127.0.0.1:8443/keys/some-key-id/revoke)
case "$REVOKE_LOC" in
  */login*) ;;
  *) echo "compose-smoke: POST /keys/some-key-id/revoke redirect target should be /login, got $REVOKE_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: POST /keys/some-key-id/revoke ok (302 -> /login)"

echo "compose-smoke: hitting POST /keys/bulk-revoke (expect 302 -> /login; auth-gated)"
BULK_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8443/keys/bulk-revoke)
if [ "$BULK_CODE" != "302" ]; then
  echo "compose-smoke: POST /keys/bulk-revoke expected 302, got $BULK_CODE" >&2
  exit 1
fi
BULK_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" -X POST http://127.0.0.1:8443/keys/bulk-revoke)
case "$BULK_LOC" in
  */login*) ;;
  *) echo "compose-smoke: POST /keys/bulk-revoke redirect target should be /login, got $BULK_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: POST /keys/bulk-revoke ok (302 -> /login)"

# Slice 6: audit log browser routes. Compose smoke does NOT wire an
# audit-log DB secret so the surface is disabled; an unauthenticated
# GET still goes through the auth middleware and 302's to /login. The
# "not configured" explainer renders only AFTER session load when the
# operator clicks /audit.
echo "compose-smoke: hitting GET /audit (expect 302 -> /login; auth-gated)"
AUDIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/audit)
if [ "$AUDIT_CODE" != "302" ]; then
  echo "compose-smoke: GET /audit expected 302, got $AUDIT_CODE" >&2
  exit 1
fi
AUDIT_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" http://127.0.0.1:8443/audit)
case "$AUDIT_LOC" in
  */login*) ;;
  *) echo "compose-smoke: GET /audit redirect target should be /login, got $AUDIT_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: GET /audit ok (302 -> /login)"

echo "compose-smoke: hitting GET /audit/some-event-id (expect 302 -> /login; auth-gated)"
AUDIT_DETAIL_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/audit/some-event-id)
if [ "$AUDIT_DETAIL_CODE" != "302" ]; then
  echo "compose-smoke: GET /audit/some-event-id expected 302, got $AUDIT_DETAIL_CODE" >&2
  exit 1
fi
echo "compose-smoke: GET /audit/some-event-id ok (302 -> /login)"

echo "compose-smoke: hitting POST /audit/some-event-id/reveal-raw (expect 302 -> /login; auth-gated)"
REVEAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8443/audit/some-event-id/reveal-raw)
if [ "$REVEAL_CODE" != "302" ]; then
  echo "compose-smoke: POST /audit/some-event-id/reveal-raw expected 302, got $REVEAL_CODE" >&2
  exit 1
fi
echo "compose-smoke: POST /audit/some-event-id/reveal-raw ok (302 -> /login)"

echo "compose-smoke: hitting GET /audit/export.csv (expect 302 -> /login; auth-gated)"
CSV_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/audit/export.csv)
if [ "$CSV_CODE" != "302" ]; then
  echo "compose-smoke: GET /audit/export.csv expected 302, got $CSV_CODE" >&2
  exit 1
fi
echo "compose-smoke: GET /audit/export.csv ok (302 -> /login)"

echo "compose-smoke: hitting POST /audit/saved-filters (expect 302 -> /login; auth-gated)"
SF_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8443/audit/saved-filters)
if [ "$SF_CODE" != "302" ]; then
  echo "compose-smoke: POST /audit/saved-filters expected 302, got $SF_CODE" >&2
  exit 1
fi
echo "compose-smoke: POST /audit/saved-filters ok (302 -> /login)"

# Compliance PDF export. Admin-only + CSRF-gated POST. Unauthenticated
# requests get the same 302 -> /login auth gate; the role check fires
# AFTER session load and viewers see 404 (per the locked RequireRole
# pattern at apps/dashboard/internal/auth/middleware.go:77).
echo "compose-smoke: hitting GET /compliance (expect 302 -> /login; auth-gated)"
COMP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/compliance)
if [ "$COMP_CODE" != "302" ]; then
  echo "compose-smoke: GET /compliance expected 302, got $COMP_CODE" >&2
  exit 1
fi
COMP_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" http://127.0.0.1:8443/compliance)
case "$COMP_LOC" in
  */login*) ;;
  *) echo "compose-smoke: GET /compliance redirect target should be /login, got $COMP_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: GET /compliance ok (302 -> /login)"

echo "compose-smoke: hitting POST /compliance/export (expect 302 -> /login; auth-gated)"
EXP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8443/compliance/export)
if [ "$EXP_CODE" != "302" ]; then
  echo "compose-smoke: POST /compliance/export expected 302, got $EXP_CODE" >&2
  exit 1
fi
EXP_LOC=$(curl -s -o /dev/null -w "%{redirect_url}" -X POST http://127.0.0.1:8443/compliance/export)
case "$EXP_LOC" in
  */login*) ;;
  *) echo "compose-smoke: POST /compliance/export redirect target should be /login, got $EXP_LOC" >&2 ; exit 1 ;;
esac
echo "compose-smoke: POST /compliance/export ok (302 -> /login)"

echo "compose-smoke: ok"
