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

