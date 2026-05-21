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

## Rotating the gateway admin token

The dashboard's `/keys` surface authenticates against the gateway
admin HTTP API using the same bearer token the gateway validates
constant-time (`DSA_ADMIN_KEY`). Rotation is a two-step:

1. Mint a fresh 32-byte (or longer) random token: `openssl rand -hex 32`.
2. Update the gateway's `DSA_ADMIN_KEY` AND the dashboard's
   `LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN` to the new value, in
   any order.

The dashboard holds the token in process memory (read once from
the env var or mounted secret at boot) and includes it on every
admin call. To pick up the rotated value the dashboard container
itself must restart (compose: `docker compose ... up -d --force-
recreate lucairn-dashboard`; Helm: rolling restart of the
`lucairn-dashboard` Deployment). The gateway likewise picks up
its new `DSA_ADMIN_KEY` on its own restart. A brief mismatch window
(≤ rolling-restart duration) is acceptable — clients of the
dashboard's `/keys` surface see a temporary `502` and retry on
next page reload.

### Compose path

```bash
NEW_TOKEN="$(openssl rand -hex 32)"

# 1) Update both env values atomically in customer.env.
sed -i.bak \
  -e "s|^DSA_ADMIN_KEY=.*|DSA_ADMIN_KEY=${NEW_TOKEN}|" \
  -e "s|^LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN=.*|LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN=${NEW_TOKEN}|" \
  customer.env

# 2) Recreate both containers.
docker compose -f docker-compose.customer.yml \
  --env-file customer.env up -d --force-recreate gateway

docker compose -f docker-compose.customer.yml \
  --env-file customer.env --profile dashboard \
  up -d --force-recreate lucairn-dashboard

# 3) Verify doctor sees the new token end-to-end.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

### Kubernetes path

```bash
NEW_TOKEN="$(openssl rand -hex 32)"

# 1) Rotate the Secret carrying DSA_ADMIN_KEY on the gateway side
#    (typically named `lucairn-gateway-admin`).
kubectl -n lucairn create secret generic lucairn-gateway-admin \
  --from-literal=admin-key="${NEW_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Rotate the dashboard-side mirror Secret.
kubectl -n lucairn create secret generic lucairn-dashboard-gateway-admin \
  --from-literal=admin-token="${NEW_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3) Roll both Deployments so they re-read the Secret values.
kubectl -n lucairn rollout restart deploy/gateway
kubectl -n lucairn rollout restart deploy/lucairn-dashboard

# 4) Verify the dashboard's pre-flight passes.
DOCTOR_INCLUDE_DASHBOARD=1 bin/lucairn doctor --env customer.env \
  --compose docker-compose.customer.yml
```

When to rotate:

- Day-1 after first successful `/keys` page load (replace any
  bootstrap value the kit shipped with).
- Whenever a dashboard admin user leaves the team.
- On the same cadence as the rest of the kit's bearer tokens.

## Bulk-revoking API keys via the dashboard

The `/keys` page supports bulk revoke via row checkboxes + the
"Revoke selected" toolbar button. Every key in the bulk selection
emits its own `key.revoke_requested` audit event (NOT one
aggregate `key.bulk_revoke_requested`) so the audit stream stays
joinable with single-revoke entries.

Operational bounds the dashboard enforces against the gateway
admin surface:

- Worker pool size = 5 concurrent `DeleteKey` RPCs per bulk job.
- Process-wide rate limit = 10 RPC/s (shared across all
  in-flight bulk jobs).
- Max keys per single bulk submission = 100 (oversize requests
  receive HTTP 413).

Operators who need to revoke more than 100 keys in one motion
submit multiple bulk jobs back-to-back. The gateway's per-IP
admin rate limit (60/min) is the harder ceiling — the
dashboard's 10 RPC/s stays well under it.



## Rotating the audit log DB credentials

The dashboard's `/audit` surface connects to `postgres-audit` as the
`audit_app` role (default) or a custom role you wired via
`LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL`. Rotate on the same cadence as
the other audit-DB credentials in the kit.

Step 1 — rotate `audit_app`'s password in `postgres-audit`:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env \
  exec postgres-audit psql -U dsa -d audit \
  -c "ALTER USER audit_app WITH PASSWORD '<NEW_PASSWORD>';"
```

Step 2 — update the dashboard env var (Compose) OR Secret (K8s):

```bash
# Compose path: edit customer.env
LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL=postgres://audit_app:<NEW_PASSWORD>@postgres-audit:5432/audit?sslmode=disable

# K8s path: rotate the Secret
kubectl -n lucairn create secret generic lucairn-dashboard-audit-log \
  --from-literal=url="postgres://audit_app:<NEW_PASSWORD>@postgres-audit:5432/audit?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Step 3 — rolling-restart the dashboard so it re-reads the env var:

```bash
# Compose:
docker compose -f docker-compose.customer.yml --env-file customer.env --profile dashboard up -d --force-recreate lucairn-dashboard

# K8s:
kubectl -n lucairn rollout restart deploy/lucairn-dashboard
```

Step 4 — verify `bin/lucairn doctor` returns green for the
`dashboard audit-log` section:

```bash
./bin/lucairn doctor
```

If saved filters share the same role (the default), the rotation
above is sufficient. If you wired a separate
`LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL` with a dedicated
`dashboard_app` role, rotate that role + URL identically.

### `migrations/audit/000003_least_privilege_role.up.sql.tmpl` is a template

Note for operators applying migrations manually: the
`migrations/audit/000003_least_privilege_role.up.sql.tmpl` file is
NOT plain SQL — the `${AUDIT_APP_PASSWORD}` placeholder is substituted
at deploy time by `scripts/render-migrations.sh` (invoked from the
`prep-migrations` compose service). Running `migrate up` against the
raw `.tmpl` file would INSERT a literal `${AUDIT_APP_PASSWORD}`
string into the role's password and the next dashboard restart would
fail authentication.

If you need to apply this migration manually:

```bash
# Render via the same script the compose pipeline uses.
AUDIT_APP_PASSWORD='<password>' VEIL_APP_PASSWORD='<password>' \
  SRC_ROOT=./migrations OUT_ROOT=/tmp/rendered \
  scripts/render-migrations.sh

# Then run the RENDERED .up.sql file (not the .up.sql.tmpl original).
psql "$AUDIT_DB_URL" -f /tmp/rendered/audit/000003_least_privilege_role.up.sql
```

The script fails-closed when `$AUDIT_APP_PASSWORD` or
`$VEIL_APP_PASSWORD` is unset (exit 2) so a forgotten env var
surfaces immediately rather than silently corrupting the migration.
Slice 6 fix-up r1 DRIFT-003.

## Audit log: reveal raw payload + CSV export with PII

The admin "Reveal raw" button on the `/audit/{event_id}` detail
page returns the unredacted payload to the browser AND emits a
paired `audit.reveal_raw` event into `audit_events`. The event
captures:

- `actor` — the admin's email
- `target_event_id` — the event the admin unmasked
- `target_event_type`, `target_source`, `target_request_id`,
  `target_payload_type` — context for the auditor

A future `audit.reveal_raw` audit (the meta-audit) is therefore
fully self-describing.

The CSV export endpoint `/audit/export.csv?reveal=true` is also
admin-only. It emits one `audit.csv_export_with_reveal` event
BEFORE the stream starts (so the audit trail records the bulk
reveal even if the operator's browser drops mid-stream). The
event payload captures the operator + the filter query the
export used.

Default (no `?reveal=true`) CSV export streams REDACTED payloads
to anyone with dashboard access; no audit event is emitted (the
operator-visible state of the redacted browser is exactly what
they see in the file).
