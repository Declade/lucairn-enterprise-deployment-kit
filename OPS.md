# OPS

## Customer Lifecycle

Mint a new customer + first API key with `bin/lucairn-mint-customer` (run after `bin/lucairn doctor` reports `ok`). The script targets the gateway's `POST /api/v1/admin/keys` endpoint, applies tier defaults (Free / Pro / Enterprise) server-side, and prints the raw key once. See `bin/lucairn-mint-customer --help` for flag reference, env-var auth precedence (`LUCAIRN_ADMIN_KEY` preferred), and `--dry-run` to inspect the resolved payload before firing.

Tier promotion and key revocation are exposed by the gateway as `PATCH /api/v1/admin/keys/tier` and `DELETE /api/v1/admin/customers/{cid}/keys/{key_id}`. A future v2 of `bin/lucairn-mint-customer` will surface these as `--promote-tier` and `--revoke` subcommands.

## Monitoring

Minimum alerts:

- Gateway `/healthz` or `/readyz` non-200 for more than 5 minutes.
- Any service restart loop.
- Postgres volume above 80 percent.
- Certificate expiry under 30 days.
- Support bundle generation failure.
- Audit or Veil Witness write errors.

Kubernetes installs should also alert on unavailable replicas, HPA maxed out for more than 15 minutes, and denied network-policy traffic that indicates unexpected cross-zone access.

## Logs

Docker Compose:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 gateway
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 sanitizer
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 veil-witness
```

Kubernetes:

```bash
kubectl logs -n dsa-edge deploy/gateway --tail=300
kubectl logs -n dsa-identity deploy/sandbox-a --tail=300
kubectl logs -n dsa-witness deploy/veil-witness --tail=300
```

## Backups

Back up these volumes or databases:

- `pg-audit-data`
- `pg-bridge-data`
- `pg-sandbox-a-data`
- `postgres-veil-data`
- `gateway-data`
- `cert-store` when certification is enabled

Recommended minimum:

- Nightly encrypted database backups.
- 30-day retention.
- Quarterly restore test.
- Backup encryption key held outside the Lucairn host.

## Key Rotation

Rotate in this order:

1. Upstream provider keys.
2. Gateway API keys.
3. Internal service token.
4. Database passwords.
5. Veil signing keys with a planned verification window.
6. `GATEWAY_KEYSTORE_KEY` only with a coordinated re-encryption migration.

Do not rotate all Veil keys at once. Keep retired public keys available through the witness-signed manifest retention window.

## Scaling

Scale stateless services first:

- Gateway
- Sanitizer
- Sandbox B workers for full self-hosted Kubernetes deployments

Scale databases vertically before sharding. For Compose installs, move to Kubernetes before adding multi-host complexity.

## Upgrade

1. Read release notes.
2. Take database backups.
3. Run `bin/lucairn doctor`.
4. Pull images or update Helm values.
5. Apply the release.
6. Confirm `/healthz`, `/readyz`, and one synthetic inference request.
7. Generate a support bundle and archive it internally as upgrade evidence.

## Dashboard: bootstrap admin + rotate credentials

The Lucairn Enterprise Dashboard (opt-in; see `INSTALL.md` §
"Enable the Lucairn dashboard") ships with a single bootstrap admin
account so the operator can sign in the first time. Rotate this
credential as a day-1 task and again on a defined schedule.

### Compose path

Rotation is a single env edit + container restart:

```bash
# 1) Generate a fresh password.
NEW_PASS="$(openssl rand -base64 24)"

# 2) Patch customer.env in place. Keep the file at mode 0600.
sed -i.bak \
  "s|^LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=.*|LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=${NEW_PASS}|" \
  customer.env

# 3) Recreate the dashboard container so it reads the new env.
docker compose \
  -f docker-compose.customer.yml \
  --env-file customer.env \
  --profile dashboard \
  up -d --force-recreate lucairn-dashboard

# 4) Confirm the new password works.
curl -fsS http://127.0.0.1:8443/healthz
```

Active sessions are revoked on restart (in-memory session store).

### Kubernetes path

The Helm chart provisions a Secret named `lucairn-dashboard-bootstrap-admin`
at install time (random 32-char password). Rotation replaces the Secret
and bounces the dashboard Deployment:

```bash
NEW_PASS="$(openssl rand -base64 24)"
NEW_SESSION="$(openssl rand -hex 24)"

kubectl -n lucairn create secret generic lucairn-dashboard-bootstrap-admin \
  --from-literal=password="${NEW_PASS}" \
  --from-literal=session-secret="${NEW_SESSION}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n lucairn rollout status deploy/lucairn-dashboard
```

Customers who pre-create their own Secret can keep using their existing
rotation tooling — set `dashboard.bootstrapAdmin.passwordSecretName` to
the Secret name in `customer-values.yaml` and the chart skips its own
random-password Secret on subsequent installs.

### When to rotate

- Day-1, after the first successful login from each operator.
- Whenever an operator with the bootstrap credential leaves the team.
- After incident response involving the dashboard host.
- On the same schedule as the rest of the kit's secrets (per the
  "Key Rotation" section above).

### Dashboard: rotating the OIDC client secret

When OIDC SSO is enabled (`dashboard.oidc.enabled: true`), the client
secret is the credential the dashboard uses to authenticate to the IdP's
token endpoint. Rotate on the same cadence as any other shared credential
between the dashboard and the IdP — typically quarterly or on operator
departure.

The rotation flow is "rotate at the IdP first, then push to the kit":

1. Generate a new client secret at your IdP. Consult your IdP's documentation
   for the "regenerate secret" procedure in its client/app admin page.
2. Update the kit:

#### Compose path

```bash
NEW_SECRET="<value from the IdP>"
sed -i.bak \
  "s|^LUCAIRN_DASHBOARD_OIDC_CLIENT_SECRET=.*|LUCAIRN_DASHBOARD_OIDC_CLIENT_SECRET=${NEW_SECRET}|" \
  customer.env
docker compose \
  -f docker-compose.customer.yml \
  --env-file customer.env \
  --profile dashboard \
  up -d --force-recreate lucairn-dashboard
curl -fsS http://127.0.0.1:8443/healthz
```

#### Kubernetes path

```bash
NEW_SECRET="<value from the IdP>"
kubectl -n lucairn create secret generic lucairn-dashboard-oidc \
  --from-literal=client-secret="${NEW_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n lucairn rollout status deploy/lucairn-dashboard
```

Active sessions are unaffected by client_secret rotation (sessions are
local to the dashboard). Users do NOT have to re-authenticate. The next
OIDC sign-in attempt picks up the new secret transparently.

## Dashboard: rotating audit DB credentials

The cert browser + inspector + audit-defensibility-grade validator
reach the customer's audit Postgres through a dedicated read-only role
(see `INSTALL.md` § "Audit DB + Witness wiring"). Rotate the role's
password on the same cadence as the rest of the kit's secrets.

Compose path:

```bash
# 1) Rotate at Postgres first. Connect as the audit DB owner (the kit's
#    `dsa` superuser by default) and ALTER the role:
psql -h postgres-bridge -U dsa -d dsa -c \
  "ALTER ROLE lucairn_dashboard_ro WITH PASSWORD '<new-password>';"

# 2) Patch customer.env in place. Keep the file at mode 0600.
NEW_DB_URL="postgres://lucairn_dashboard_ro:<new-password>@postgres-bridge:5432/dsa?sslmode=require"
sed -i.bak \
  "s|^LUCAIRN_DASHBOARD_AUDIT_DB_URL=.*|LUCAIRN_DASHBOARD_AUDIT_DB_URL=${NEW_DB_URL}|" \
  customer.env

# 3) Recreate the dashboard container so it reads the new env.
docker compose \
  -f docker-compose.customer.yml \
  --env-file customer.env \
  --profile dashboard \
  up -d --force-recreate lucairn-dashboard

# 4) Confirm health.
curl -fsS http://127.0.0.1:8443/healthz
```

Kubernetes path:

```bash
# 1) Rotate at Postgres first (same ALTER ROLE as above).

# 2) Replace the Secret with the new connection string.
kubectl -n lucairn create secret generic lucairn-dashboard-audit-db \
  --from-literal=connection-string='postgres://lucairn_dashboard_ro:<new-password>@postgres-bridge:5432/dsa?sslmode=verify-full' \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) Bounce the Deployment so the pod picks up the new Secret value.
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n lucairn rollout status deploy/lucairn-dashboard
```

Active dashboard sessions are NOT invalidated by this rotation — sessions
are local to the dashboard process and the audit DB has no view of them.
The next cert-browser page request after the bounce dials the DB with
the new credentials transparently.

When to rotate:

- Day-1, after the first successful cert-browser page load.
- Whenever an operator with the audit DB password leaves the team.
- On the same schedule as the rest of the kit's secrets (per the
  "Key Rotation" section above).

## Rotating the Grafana JWT shared secret

The Grafana embed handoff uses an HS256 shared secret (≥32 chars).
The dashboard pod reads it via `LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET`;
the Grafana pod reads the same value via `GF_AUTH_JWT_KEY_FILE`
(mounted from the same Secret as `/etc/grafana/jwt/shared-secret`).

Tokens have a 60-second TTL — any token in flight at rotation time
expires within one minute, so the rotation order is non-critical
provided both pods restart within ~60s of the Secret edit.

### Compose path

```bash
NEW_SECRET="$(openssl rand -hex 24)"  # 48-char hex

# 1) Update customer.env atomically.
sed -i.bak "s|^LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET=.*|LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET=${NEW_SECRET}|" customer.env

# 2) Update the Grafana container's mounted secret-file (if your
#    Grafana config reads the shared secret from a file, update the
#    file in lockstep). For the bundled compose stack with Grafana
#    as a side-deployment, the simplest pattern is a Docker Compose
#    `secrets:` mount that points at a host file; update + recreate.

# 3) Recreate the dashboard container.
docker compose -f docker-compose.customer.yml \
  --env-file customer.env --profile dashboard \
  up -d --force-recreate lucairn-dashboard
# 4) Restart your Grafana container so it re-reads the shared-secret
#    file (the customer brings their own Grafana — the bundled compose
#    does NOT ship a `grafana` service). Run the equivalent of:
#    `docker compose -f <your-grafana-compose>.yml up -d --force-recreate <your-grafana-service>`
#    or `docker restart <your-grafana-container>` depending on how the
#    customer fronts Grafana.
```

### Kubernetes path

```bash
NEW_SECRET="$(openssl rand -hex 24)"

# 1) Update the Secret in BOTH namespaces. The dashboard sub-chart's
#    secret-grafana-jwt.yaml auto-renders the Secret into both
#    `lucairn` AND `dsa-observability` on `helm upgrade`, with a
#    lookup-precedence that re-reads existing values. Rotation is
#    therefore a two-step:
kubectl -n lucairn create secret generic lucairn-dashboard-grafana-jwt \
  --from-literal=shared-secret="${NEW_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dsa-observability create secret generic lucairn-dashboard-grafana-jwt \
  --from-literal=shared-secret="${NEW_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Bounce both Deployments so they re-read the Secret. Order does
#    not matter — the 60s JWT TTL bounds any in-flight token's
#    lifetime so even a brief mismatch window heals automatically.
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
kubectl -n dsa-observability rollout restart deploy/grafana
```

When to rotate:

- On a customer-defined cadence (90 days is typical for HMAC secrets).
- Whenever an operator with cluster Secret read access leaves the team.
- After any Grafana-side incident response that suspects key compromise.

