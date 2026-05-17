#!/usr/bin/env bash
#
# Slice 2 OIDC end-to-end verify against a real IdP, run by the
# orchestrator post-merge. Spins up a Kind cluster + Keycloak, configures
# a realm + client + groups + admin & viewer test users, deploys the
# dashboard sub-chart with oidc.enabled=true, and exercises the round
# trip with a headless curl-driven flow.
#
# This is a SKELETON in Slice 2 — bash -n syntax-clean, with TODOs that
# the orchestrator fills before running the live verify. The skeleton
# keeps the script structure / dependency list / cleanup discipline
# anchored so the live run is reproducible.
#
# Required CLI tools (orchestrator-side):
#   - kind             >= 0.20
#   - kubectl          >= 1.28
#   - helm             >= 3.13
#   - jq               (response parsing)
#   - curl             (round-trip driver)
#
# Inputs (env):
#   KIND_CLUSTER_NAME       default: lucairn-dashboard-slice2
#   DASHBOARD_IMAGE         default: ghcr.io/declade/lucairn-dashboard:0.2.0
#   KEYCLOAK_REALM          default: lucairn
#   KEYCLOAK_CLIENT_ID      default: lucairn-dashboard
#   KEYCLOAK_ADMIN_USER     default: keycloak-admin
#   KEYCLOAK_ADMIN_PASS     default: <random>
#   TEST_ADMIN_USER         default: alice@lucairn.test
#   TEST_VIEWER_USER        default: bob@lucairn.test
#
# Exit codes:
#   0  all gates pass
#   1  setup failed (kind / helm install / Keycloak not ready)
#   2  OIDC discovery failed (dashboard couldn't reach IdP)
#   3  admin-group login round-trip failed
#   4  viewer-group login round-trip failed
#   5  neither-group rejection failed (user got through when they should
#      not have)

set -euo pipefail

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-lucairn-dashboard-slice2}"
DASHBOARD_IMAGE="${DASHBOARD_IMAGE:-ghcr.io/declade/lucairn-dashboard:0.2.0}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-lucairn}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-lucairn-dashboard}"
TEST_ADMIN_USER="${TEST_ADMIN_USER:-alice@lucairn.test}"
TEST_VIEWER_USER="${TEST_VIEWER_USER:-bob@lucairn.test}"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT"

# ── Preflight ───────────────────────────────────────────────────────────
echo "oidc-kind-verify: preflight"
for cmd in kind kubectl helm jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "oidc-kind-verify: missing required CLI: $cmd" >&2
    exit 1
  fi
done

# ── Bring up Kind ───────────────────────────────────────────────────────
echo "oidc-kind-verify: creating Kind cluster ${KIND_CLUSTER_NAME}"
# TODO(orchestrator): use the existing slice 1 kind-config.yaml when
# present at apps/dashboard/tests/kind-config.yaml; fall back to a
# default 3-node config otherwise.
kind create cluster --name "${KIND_CLUSTER_NAME}" --wait 60s

trap 'echo "oidc-kind-verify: cleaning up"; kind delete cluster --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true' EXIT

# ── Install Keycloak ────────────────────────────────────────────────────
echo "oidc-kind-verify: installing Keycloak via bitnami chart"
# TODO(orchestrator): pin keycloak chart version + image @sha256: digest.
# The realm import config goes in via the bitnami chart's
# `keycloakConfigCli.configuration[]` field. Realm payload:
#   - realm: ${KEYCLOAK_REALM}
#   - client: ${KEYCLOAK_CLIENT_ID} with redirect-uri matching the
#     dashboard's publicURL/auth/oidc/callback
#   - groups: lucairn-admins, lucairn-viewers
#   - users: ${TEST_ADMIN_USER} ∈ admins, ${TEST_VIEWER_USER} ∈ viewers,
#     and one unaffiliated user for the rejection test
#
# helm repo add bitnami https://charts.bitnami.com/bitnami
# helm install keycloak bitnami/keycloak --namespace keycloak \
#   --create-namespace --wait \
#   --set auth.adminUser=keycloak-admin \
#   --set auth.adminPassword="$(openssl rand -base64 24)" \
#   --set service.type=ClusterIP
#
# kubectl -n keycloak wait pod -l app.kubernetes.io/name=keycloak --for=condition=Ready --timeout=180s

# ── Deploy dashboard sub-chart ──────────────────────────────────────────
echo "oidc-kind-verify: deploying dashboard with oidc.enabled=true"
# TODO(orchestrator): set values via --set; pre-create the
# lucairn-dashboard-oidc Secret with the Keycloak client secret.
#
# kubectl -n lucairn create namespace lucairn
# kubectl -n lucairn create secret generic lucairn-dashboard-oidc \
#   --from-literal=client-secret="${KEYCLOAK_CLIENT_SECRET}"
#
# helm install lucairn charts/lucairn \
#   --namespace lucairn \
#   --set dashboard.enabled=true \
#   --set dashboard.image.repository=ghcr.io/declade/lucairn-dashboard \
#   --set dashboard.image.tag=0.2.0 \
#   --set dashboard.oidc.enabled=true \
#   --set dashboard.oidc.issuerURL="http://keycloak.keycloak.svc.cluster.local/realms/${KEYCLOAK_REALM}" \
#   --set dashboard.oidc.clientID="${KEYCLOAK_CLIENT_ID}" \
#   --set dashboard.oidc.clientSecretRef.name=lucairn-dashboard-oidc \
#   --set dashboard.oidc.adminGroup=lucairn-admins \
#   --set dashboard.oidc.viewerGroup=lucairn-viewers \
#   --set dashboard.oidc.publicURL=http://lucairn-dashboard.lucairn.svc.cluster.local:8443

# kubectl -n lucairn wait pod -l app.kubernetes.io/name=lucairn-dashboard --for=condition=Ready --timeout=120s

# ── End-to-end round trip ───────────────────────────────────────────────
echo "oidc-kind-verify: smoke test — /login renders SSO button"
# TODO(orchestrator): port-forward + curl + grep for the
# "Sign in with SSO" string in the rendered HTML.

echo "oidc-kind-verify: admin round trip"
# TODO(orchestrator): drive a headless OIDC flow as ${TEST_ADMIN_USER}.
# The flow is:
#   1) GET /login → extract csrf token
#   2) POST /auth/oidc/login with csrf → 302 to Keycloak authorize
#   3) Follow Keycloak's login form (POST username + password)
#   4) Follow the consent screen (POST)
#   5) Land on /auth/oidc/callback?code=...&state=... → 302 to /dashboard
#   6) GET /dashboard with the new cookie → 200 with admin email rendered
#
# A pure-curl path can do this if the Keycloak realm is configured to
# skip the consent screen for the test client (a common test-realm
# config). Alternatively, use python-requests + BeautifulSoup as a
# bash-companion if the orchestrator already has it.

echo "oidc-kind-verify: viewer round trip"
# TODO(orchestrator): same flow as admin, but as ${TEST_VIEWER_USER}.
# Assert that GET /keys (API key mgmt — future slice; today this is a
# 404) does NOT 200, and that the API-keys sidebar link is absent.

echo "oidc-kind-verify: neither-group rejection"
# TODO(orchestrator): drive the flow as a user in NEITHER group. The
# callback must return 401 with a generic flash. The dashboard logs
# must show oidc_callback: rejected — user not in admin or viewer group.

echo "oidc-kind-verify: ok"
