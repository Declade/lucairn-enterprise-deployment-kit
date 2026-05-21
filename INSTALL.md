# INSTALL

Goal: a competent platform engineer should complete a standard install in about 3 hours without a vendor call.

## Quickstart (30 seconds, dev mode)

```
git clone https://github.com/Declade/lucairn-enterprise-deployment-kit && cd lucairn-enterprise-deployment-kit
./bin/lucairn-init --dev
docker compose -f docker-compose.customer.yml -f docker-compose.self-hosted.yml --env-file customer.env up -d
```

That's it. `bin/lucairn-init --dev` writes a fully-populated, doctor-passing
`customer.env` (5 Ed25519 keypairs, hex32 service secrets, postgres
passwords, sensible dev-mode defaults) and runs `bin/lucairn doctor` against
it before exiting. Use `bin/lucairn-mint-customer` once the stack is healthy
to provision your first customer.

For production deployment with a Lucairn-issued license, see "Choose A
Deployment Mode" below and use `./bin/lucairn-init --production --license
<path>`. For managed-LLM mode (BYOK Anthropic, OpenAI, etc.) add `--byok` and
populate the provider key before `docker compose up`. The
`bin/lucairn-init --help` lists every flag.

## Pre-Requisites

For Docker Compose:

- Linux host with Docker Engine and Docker Compose v2.
- 4 vCPU, 16 GB RAM minimum for customer-side split deployment.
- TLS-terminating reverse proxy such as Caddy, Nginx, Traefik, or an enterprise ingress proxy.
- Outbound HTTPS to Lucairn-provided remote Sandbox B endpoint if using split deployment.

For Kubernetes:

- Kubernetes 1.28 or newer.
- Helm 3.13 or newer.
- Ingress controller with TLS.
- NetworkPolicy-capable CNI. Cilium is preferred for DNS controls and WireGuard encryption.
- Secret manager integration, or permission to create Kubernetes native secrets.

## Choose A Deployment Mode

Before running `docker compose up`, decide which inference-side topology the
deployment uses. The two modes differ in whether Sandbox B (the
inference-isolation boundary that calls the LLM upstream) runs on the
customer's own host or on Lucairn-hosted infrastructure.

| Mode | Sandbox B runs on | Compose overlays | Required Lucairn-provisioned values | Outbound network from customer host |
|---|---|---|---|---|
| **Self-hosted inference (local model)** | Customer's host (local container plus model runtime) | `docker-compose.customer.yml` plus `docker-compose.self-hosted.yml` | `DSA_LICENSE_KEY`, `DSA_LICENSE_SIGNING_KEY` only | None to Lucairn at request time. Model runtime fetched once at install. |
| **Self-hosted inference (managed LLM / BYOK)** | Customer's host (local container; LLM call goes out to operator-declared FQDNs) | `docker-compose.customer.yml` plus `docker-compose.self-hosted.yml` plus `docker-compose.self-hosted-byok.yml` | Same as self-hosted local-model **plus** `LUCAIRN_LLM_EGRESS_ALLOWLIST` and provider key(s) (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …) | HTTPS to operator-declared LLM FQDNs only. Sandbox A / ID Bridge / Sanitizer / Audit / Witness stay on internal-only networks. |
| **Split deployment** | Lucairn-hosted | `docker-compose.customer.yml` only | All of the self-hosted list **plus** `SANDBOX_B_REMOTE_ENDPOINT`, `SANDBOX_B_API_KEY`, `VEIL_SANDBOX_B_PUBLIC_KEY`, optional mTLS material (`SANDBOX_B_CLIENT_CERT` etc.) | HTTPS to Lucairn-provided endpoint per request. |

Pick **self-hosted inference (local model)** when:

- Compliance forbids per-request egress to *any* external endpoint.
- The customer wants a fully on-premise deploy (sandbox / proof-of-value /
  air-gapped or DMZ-only network) and owns GPU/CPU model runtime
  operations.
- Development, simulation, or acceptance-test environments. The
  `docker-compose.self-hosted.yml` overlay is always the right starting point
  on a laptop or single-host VM.

Pick **self-hosted inference (managed LLM / BYOK)** when:

- The customer wants Sandbox A / Sanitizer / ID Bridge / Audit / Witness to
  run on-premise (so identity data never leaves their network), but is OK
  with the LLM call itself going to a managed cloud provider (Anthropic,
  OpenAI, Mistral, Gemini, Azure OpenAI, AWS Bedrock, internal LLM
  gateway).
- The compliance team will enforce the FQDN allowlist at their existing
  network policy layer (host firewall + DNS allowlist, Cilium
  NetworkPolicy with `toFQDNs:`, or a transparent forward proxy). See the
  "Self-hosted with managed LLM (BYOK)" section below for the
  responsibility split between the kit and the operator.

Pick **split deployment** when:

- Production traffic and the customer has signed the standard Lucairn
  inference-tenancy contract that provides the remote Sandbox B endpoint.
- The customer does not want to own model runtime operations (GPU
  procurement, model updates, weight licensing) or manage their own
  upstream-LLM contracts.

If neither column matches the customer's profile, contact Lucairn before
proceeding. Mixing modes is not supported.

The bare `customer.env.example` ships **split-deployment defaults**: the
license / signing / remote-endpoint slots are placeholder strings that the
operator must replace with Lucairn-provisioned values before the gateway will
start outside dev mode. For a self-hosted-inference install, replace
`SANDBOX_B_REMOTE_ENDPOINT` with an empty string (the self-hosted overlay
ignores it) and follow the model runtime steps in the `docker-compose.self-hosted.yml`
overlay (`MODEL_RUNTIME_PROFILE`, `MODEL_NAME`, `MODEL_PATH`, etc.).

## Docker Compose Install

1. Unpack the release bundle.

```bash
tar -xzf lucairn-enterprise-deployment-kit-1.3.0-customer-demo-data.tar.gz
cd lucairn-enterprise-deployment-kit
```

2. Create the customer env file.

```bash
cp customer.env.example customer.env
chmod 600 customer.env
```

3. Log in to the private image registry.

Lucairn provides a GHCR username/token or mirrors the images into the customer's registry.

```bash
docker login ghcr.io
```

If the customer uses an internal registry mirror, set `LUCAIRN_IMAGE_REGISTRY` in `customer.env`.

4. Replace every `REPLACE_*` value in `customer.env`.

Generate random values:

```bash
openssl rand -hex 32       # 32-byte random as 64 hex chars (signing keys, tokens)
openssl rand -base64 32    # 32-byte random as base64           (GATEWAY_KEYSTORE_KEY)
```

**WARNING — DO NOT use `openssl rand -hex 32` for `VEIL_*_PUBLIC_KEY` slots.**
The public key MUST be derived from the corresponding private key (the
`VEIL_*_SIGNING_KEY` of the same service). Filling the public-key slots
with independently-generated random hex yields a key that does NOT match
the signing key, and every certificate claim the service signs will be silently
rejected by the witness verifier — the stack will look healthy but no
certificates will validate.

### 4a. Generate Ed25519 signing keypairs

Operator-generated keypairs (always required):

| Signing-key slot              | Public-key slot              |
|-------------------------------|------------------------------|
| `VEIL_AUDIT_SIGNING_KEY`      | `VEIL_AUDIT_PUBLIC_KEY`      |
| `VEIL_BRIDGE_SIGNING_KEY`     | `VEIL_BRIDGE_PUBLIC_KEY`     |
| `VEIL_SANITIZER_SIGNING_KEY`  | `VEIL_SANITIZER_PUBLIC_KEY`  |
| `VEIL_WITNESS_SIGNING_KEY`    | `VEIL_WITNESS_PUBLIC_KEY`    |
| `VEIL_GATEWAY_SIGNING_KEY`    | `VEIL_GATEWAY_PUBLIC_KEY`    |

For self-hosted-inference modes (`docker-compose.self-hosted.yml` or
the BYOK overlay), also generate the Sandbox B pair locally — sandbox-b
runs on the customer host in those modes, signs `CLAIM_TYPE_INFERENCE_GENERATED`
with `VEIL_SANDBOX_B_SIGNING_KEY` at boot, and the witness verifies
those claims against `VEIL_SANDBOX_B_PUBLIC_KEY`:

| Signing-key slot              | Public-key slot              | Modes        |
|-------------------------------|------------------------------|--------------|
| `VEIL_SANDBOX_B_SIGNING_KEY`  | `VEIL_SANDBOX_B_PUBLIC_KEY`  | self-hosted (local model or BYOK) |

In **split deployment** the Sandbox B signing key lives on the
Lucairn-hosted Sandbox B fleet; Lucairn issues the matching public key
during onboarding. Do not regenerate `VEIL_SANDBOX_B_PUBLIC_KEY` in
split-deployment mode — use whatever value Lucairn provides.

For each pair generate the signing-key seed with `openssl rand -hex 32`,
then derive the matching public key using the bundled helper at
`scripts/derive-veil-pubkey.sh`. Bash one-liner — fills both slots for
one service in two lines of output you can paste into `customer.env`:

```bash
SEED=$(openssl rand -hex 32)
echo "VEIL_AUDIT_SIGNING_KEY=$SEED"
echo "VEIL_AUDIT_PUBLIC_KEY=$(scripts/derive-veil-pubkey.sh "$SEED")"
```

Repeat for `BRIDGE`, `SANITIZER`, `WITNESS`, `GATEWAY`, and (for
self-hosted modes) `SANDBOX_B`.

`VEIL_MANIFEST_SIGNING_KEY` (no matching `_PUBLIC_KEY` slot) is the
manifest-only signing key and only needs the `openssl rand -hex 32`
step.

The helper requires Python 3 with the `cryptography` package (preferred)
or `pynacl`. Both are pure-Python wheels; install with
`pip install cryptography` if either is missing.

5. Run offline validation before network checks.

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
```

6. Run live validation.

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

The live validation checks whether the configured Lucairn images are pullable. If it fails with `container images: failed`, fix registry access before continuing.

7. Start the stack.

For **split deployment**:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

For **self-hosted inference**, load the self-hosted overlay so the local
Sandbox B container + model runtime profile come up alongside the customer
stack:

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --env-file customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

If you omit the self-hosted overlay on a self-hosted-inference install, the
gateway will start but `/readyz` will return 503 because the placeholder
`SANDBOX_B_REMOTE_ENDPOINT=https://inference.lucairn.example` is unreachable.
See `TROUBLESHOOTING.md` § "`/healthz` Returns 200 But `/readyz` Returns 503".

### Self-hosted with managed LLM (BYOK Anthropic, OpenAI, etc.)

When the customer wants the Lucairn control + identity plane on-premise but
is OK with the LLM call itself going to a managed cloud provider (Anthropic,
OpenAI, Mistral, Gemini, Azure OpenAI, AWS Bedrock, internal LLM gateway),
load the BYOK overlay on top of the customer + self-hosted overlays:

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

In `customer.env`, uncomment and populate the managed-LLM block:

```
LUCAIRN_LLM_EGRESS_ALLOWLIST=api.anthropic.com,api.openai.com
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
```

What the overlay does:

- Adds a new non-internal bridge network `dsa-egress` and joins **only
  Sandbox B** to it. Sandbox A, ID Bridge, Sanitizer, Audit, Witness, and
  all Postgres instances stay on their internal-only networks.
- Wires the provider API keys into Sandbox B so it can register the
  matching adapters (Anthropic, OpenAI, Mistral, Gemini). Unset providers
  are simply not wired; only adapters with a key present register.
- Fails fast at `docker compose config` time if
  `LUCAIRN_LLM_EGRESS_ALLOWLIST` is empty.

What the overlay does **NOT** do (operator responsibility):

- It does **not** enforce FQDN-level egress restrictions on the
  `dsa-egress` network. The Docker bridge driver does not support FQDN
  policy. Enforcing the allowlist is the operator's responsibility and
  belongs in the operator's existing network policy layer. Pick whichever
  matches the customer's stack:
  - Host firewall (iptables / nftables) + a DNS allowlist (dnsmasq /
    Pi-hole / Unbound forwarding only the declared FQDNs).
  - Cilium NetworkPolicy with FQDN selector (`toFQDNs:`) — the
    production-grade option for Kubernetes / k3s deployments.
  - Transparent forward proxy (squid, mitmproxy in transparent mode,
    tinyproxy) with an FQDN allowlist; route Sandbox B's egress through
    the proxy via `HTTPS_PROXY` env.

The compliance team should sign off on the chosen enforcement layer **and**
the contents of `LUCAIRN_LLM_EGRESS_ALLOWLIST` before this overlay is
loaded in production. Declaring the intended allowlist keeps the operator
intent close to the running compose state; `bin/lucairn doctor` surfaces
that the BYOK overlay is in effect so the compliance team can audit it.

Smoke-verify outbound reach from inside Sandbox B (a 401 from the LLM
provider is the expected pass — name resolution + TCP both worked, only
the dummy API key was rejected):

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  exec sandbox-b \
  curl -sS -o /dev/null -w "%{http_code}\n" \
  https://api.anthropic.com/v1/messages
# Expect: 401  (NOT 0 / NXDOMAIN / connection refused)
```

8. Confirm health.

```bash
curl -fsS http://127.0.0.1:8085/healthz
curl -fsS http://127.0.0.1:8085/readyz
```

9. Put the gateway behind TLS.

Terminate HTTPS at the customer reverse proxy and forward to `127.0.0.1:8080`. If the proxy is local or containerized, set `GATEWAY_TRUSTED_PROXY_CIDRS` to the proxy source CIDRs and rerun `bin/lucairn doctor`.

10. Mint your first customer.

Once `bin/lucairn doctor` reports `ok`, mint your first Lucairn customer + API key:

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"

./bin/lucairn-mint-customer \
  --name "Acme GmbH" \
  --email "ops@acme.de" \
  --tier enterprise
```

The script prints the raw API key **once** — capture it to a 0600 file. Smoke with `curl -H "x-api-key: <raw_key>" $GATEWAY_BASE_URL/api/v1/usage`. See `./bin/lucairn-mint-customer --help` for all flags including `--byok-per-request`, `--managed-ai`, `--provider-key`, `--dry-run`, and `--verbose`.

## Kubernetes Install

1. Create the image pull secret.

```bash
kubectl create namespace lucairn
kubectl create secret docker-registry lucairn-registry \
  --namespace lucairn \
  --docker-server ghcr.io \
  --docker-username "$GHCR_USERNAME" \
  --docker-password "$GHCR_TOKEN"
```

2. Prepare values.

```bash
cp customer-values.yaml.example customer-values.yaml
```

3. Replace every `REPLACE_*` value. Prefer an external secret manager for production.

4. Build chart dependencies and render once.

```bash
helm dependency build charts/lucairn
helm template lucairn charts/lucairn -f customer-values.yaml --namespace lucairn >/tmp/lucairn-rendered.yaml
```

5. Install.

```bash
helm upgrade --install lucairn charts/lucairn \
  -f customer-values.yaml \
  --namespace lucairn \
  --create-namespace
```

6. Watch rollout.

```bash
kubectl get pods -A -l app.kubernetes.io/part-of=dsa
kubectl rollout status deployment/gateway -n dsa-edge
```

## Support Bundle

If installation fails, generate a bundle:

```bash
bin/lucairn support-bundle --env customer.env --compose docker-compose.customer.yml
```

Review the archive before emailing it to Lucairn support.

## Customer Bundle Install

Use this path when Lucairn has prepared a customer-specific bundle with model files and image archives.

1. Unpack the bundle.

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
```

2. Verify checksums.

```bash
bin/lucairn bundle verify --bundle .
```

3. Load images when the bundle contains an archive.

```bash
docker load -i images/lucairn-images.tar
```

If `images/lucairn-images.tar` is absent, this handoff uses registry or customer-mirror delivery. Log in to the configured registry, keep `LUCAIRN_IMAGE_REGISTRY` and `LUCAIRN_IMAGE_TAG` aligned with the handoff note, and skip `docker load`.

4. Run pre-flight checks.

```bash
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --skip-image-check
```

5. Start the selected model runtime profile.

```bash
docker compose \
  -f install/docker-compose.customer.yml \
  -f install/docker-compose.self-hosted.yml \
  --env-file install/customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

6. Confirm health.

```bash
curl -fsS http://127.0.0.1:8085/healthz
curl -fsS http://127.0.0.1:8085/readyz
```

## Clean-Host Rehearsal

Before sending a first customer bundle, repeat the customer-bundle path on a clean Linux host or VM that has no repo checkout, no local Docker images, and no copied secrets except the exact handoff bundle and registry credentials. Record the transcript against `docs/CLEAN_HOST_REHEARSAL.md`.

## Enable the Lucairn dashboard (optional)

The Lucairn Enterprise Dashboard is an opt-in operator UI that ships
alongside the core stack. It is **not required to operate the kit** — every
day-2 task can still be driven from `bin/lucairn` and Grafana. Operators
who want a first-party UI for cert workflows, server health, audit log
inspection, compliance PDF export, and API key management can enable it.

Bundled in this kit version: dashboard auth + shell foundation +
optional OIDC SSO + cert browser, cert inspector, audit-defensibility-grade
live validator, server health overview, embedded Grafana dashboards, AND
API key management. Audit log browser and compliance PDF arrive in
subsequent kit releases.

### Compose path

1. Set the dashboard env vars in `customer.env` (uncomment the
   `LUCAIRN_DASHBOARD_*` block at the end of `customer.env.example` and
   populate `LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD` with a 12+ character
   secret you generated locally via `openssl rand -base64 24`).
2. Run `bin/lucairn doctor` — the dashboard pre-flight check exits with a
   clear error if the bootstrap password is missing or too short.
3. Start the dashboard container alongside the core stack:

   ```bash
   docker compose \
     -f docker-compose.customer.yml \
     -f docker-compose.self-hosted.yml \
     --env-file customer.env \
     --profile dashboard \
     up -d lucairn-dashboard
   ```

   (Add `-f docker-compose.self-hosted-byok.yml` when running with the
   BYOK overlay.)

4. Confirm health: `curl -fsS http://127.0.0.1:8443/healthz` returns
   `{"status":"ok","version":"..."}`. The container binds only to
   loopback; front it with your TLS-terminating reverse proxy (Caddy /
   Nginx / Traefik) before exposing it externally.

5. First login: open `https://<your-front-proxy>/login`, enter the
   bootstrap email + the password you set in step 1.

### Kubernetes path

1. Set `dashboard.enabled: true` in your `customer-values.yaml` (or
   `--set dashboard.enabled=true` on the install command).
2. Apply: `helm upgrade --install lucairn charts/lucairn -f
   customer-values.yaml --namespace lucairn --create-namespace`.
3. Retrieve the bootstrap password (Helm-generated random 32-char):

   ```bash
   kubectl -n lucairn get secret lucairn-dashboard-bootstrap-admin \
     -o jsonpath='{.data.password}' | base64 -d
   ```

4. Port-forward + login:

   ```bash
   kubectl -n lucairn port-forward svc/lucairn-dashboard 8443:8443
   ```

   Open `https://localhost:8443/login`. The default email is
   `admin@lucairn.local` (override with
   `dashboard.bootstrapAdmin.email`).

5. Run the dashboard-specific doctor check via the kit CLI:

   ```bash
   DOCTOR_INCLUDE_DASHBOARD=1 bin/lucairn doctor \
     --env customer.env \
     --compose docker-compose.customer.yml --offline
   ```

### Rotating the bootstrap password

See `OPS.md` § "Dashboard: bootstrap admin + rotate credentials".

### Optional: enable OIDC SSO

OIDC single sign-on is opt-in. When enabled, the dashboard renders a
"Sign in with SSO" button on `/login` next to the local-admin form.
Local-admin sign-in continues to work for bootstrap + IdP-outage
scenarios — there is no way to disable it in this release.

Group → role mapping (LOCKED):

- User in the admin group → `RoleAdmin` (full access).
- User in the viewer group → `RoleViewer` (read-only).
- User in BOTH groups → `RoleAdmin` wins.
- User in NEITHER group → rejected with HTTP 401. Customers must
  explicitly authorize identities at the IdP. The dashboard does NOT
  auto-grant viewer to arbitrary directory users.

#### Compose path

1. Populate the `LUCAIRN_DASHBOARD_OIDC_*` block in `customer.env`. At
   minimum set `LUCAIRN_DASHBOARD_OIDC_ENABLED=true` and the issuer URL,
   client ID, client secret, admin group, viewer group, and public URL.
2. Recreate the dashboard container:

   ```bash
   docker compose \
     -f docker-compose.customer.yml \
     --env-file customer.env \
     --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

3. Verify: open `https://<your-front-proxy>/login`. The "Sign in with
   SSO" button should appear below the local form. Click it; you are
   redirected to the IdP, complete the sign-in, and land on
   `/dashboard`.

The dashboard runs OIDC discovery against the issuer URL at startup. If
the IdP is unreachable, the container fails-fast — the readiness probe
flips to unready and the operator sees the discovery error in the
container logs. This is the locked failure mode (no silently-broken
SSO).

#### Kubernetes path

1. Pre-create the OIDC client_secret Secret in the lucairn namespace:

   ```bash
   kubectl -n lucairn create secret generic lucairn-dashboard-oidc \
     --from-literal=client-secret='<your-idp-client-secret>'
   ```

2. Add the OIDC block to your `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     oidc:
       enabled: true
       issuerURL: "https://idp.example.com/realms/lucairn"
       clientID: "lucairn-dashboard"
       clientSecretRef:
         name: lucairn-dashboard-oidc
         key: client-secret
       adminGroup: lucairn-admins
       viewerGroup: lucairn-viewers
       groupsClaim: groups        # optional; default "groups"
       publicURL: "https://dashboard.customer.example"
       # callbackURL: ""           # pin explicitly when the registered URL differs
   ```

3. Apply: `helm upgrade --install lucairn charts/lucairn -f
   customer-values.yaml --namespace lucairn --create-namespace`.

4. Confirm the rollout: `kubectl -n lucairn rollout status deploy/lucairn-dashboard`
   completes within 60s once OIDC discovery succeeds. The OIDC button is
   live as soon as the pod is Ready.

#### Rotating the OIDC client secret

See `OPS.md` § "Dashboard: rotating the OIDC client secret".

### Audit DB + Witness wiring (cert browser + inspector)

The cert browser, cert inspector, and audit-defensibility-grade live
validator are OPT-IN. When the audit DB and witness gRPC endpoint are
unset, the cert pages render a "not configured" explainer and the rest
of the dashboard (auth + shell + OIDC) keeps working. To enable the
cert surface, pre-create a read-only Postgres role + (Kubernetes only)
a Secret holding the libpq URL, then point the dashboard at it.

Locked posture:

- Dashboard never writes to the audit DB.
- The DB user holds SELECT on `veil_certificates` ONLY. No INSERT,
  UPDATE, DELETE, DDL.
- Both admin and viewer roles can browse + re-verify certs.
  (Cert-browser role differentiation is reserved for a future kit
  release; the `/keys` API key management surface is admin-only in
  this release.)
- Bulk re-verify caps each job at 100 certs and rate-limits the
  witness gRPC channel to 10 calls per second.

#### Pre-create the read-only Postgres role

Run as the audit DB owner (the kit's `dsa` superuser via Compose, or
your DBA via Kubernetes):

```sql
CREATE ROLE lucairn_dashboard_ro WITH LOGIN PASSWORD '<generate>';
GRANT CONNECT ON DATABASE dsa TO lucairn_dashboard_ro;
GRANT USAGE ON SCHEMA public TO lucairn_dashboard_ro;
GRANT SELECT ON veil_certificates TO lucairn_dashboard_ro;
```

#### Compose path

1. Add the cert browser env block to `customer.env` (the
   `LUCAIRN_DASHBOARD_AUDIT_DB_URL` + `LUCAIRN_DASHBOARD_WITNESS_ENDPOINT`
   block at the end of `customer.env.example`):

   ```bash
   LUCAIRN_DASHBOARD_AUDIT_DB_URL=postgres://lucairn_dashboard_ro:<password>@postgres-bridge:5432/dsa?sslmode=require
   LUCAIRN_DASHBOARD_WITNESS_ENDPOINT=veil-witness:50058
   ```

2. Run `bin/lucairn doctor` — the new `dashboard certs:` pre-flight
   check exits with a clear error if the DB URL scheme is wrong, the
   witness endpoint is missing a port, or only one of the pair is set.

3. Recreate the dashboard container:

   ```bash
   docker compose \
     -f docker-compose.customer.yml \
     --env-file customer.env \
     --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

4. Verify: open `https://<your-front-proxy>/certs`. The browser lists
   the certs that match the empty filter (most recent first).

#### Kubernetes path

1. Pre-create the audit DB Secret:

   ```bash
   kubectl -n lucairn create secret generic lucairn-dashboard-audit-db \
     --from-literal=connection-string='postgres://lucairn_dashboard_ro:<password>@postgres-bridge:5432/dsa?sslmode=verify-full'
   ```

2. Wire the cert surface in `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     auditDB:
       connectionStringRef:
         name: lucairn-dashboard-audit-db
         key: connection-string
     witness:
       endpoint: "veil-witness.dsa-witness.svc.cluster.local:50058"
   ```

3. Apply: `helm upgrade --install lucairn charts/lucairn -f customer-values.yaml --namespace lucairn`.

4. Confirm the rollout: `kubectl -n lucairn rollout status deploy/lucairn-dashboard`.
   Cert browser is live as soon as the pod is Ready.

#### Rotating the audit DB credentials

See `OPS.md` § "Dashboard: rotating audit DB credentials".

### Enable server health + Grafana embedding

The dashboard's `/health` surface is ALWAYS-ON by default — it polls
the 12 standard kit services every 10 seconds and renders a card
grid with per-service status pills (Healthy / Degraded / Down /
Polling…). Operators who want a custom service list set
`LUCAIRN_DASHBOARD_HEALTH_SERVICES` (or the matching Helm value)
to a comma-separated `name=url` spec; see
`apps/dashboard/internal/health/services.go` for the bundled
default + URL syntax (`http://`, `https://`, `tcp://`).

Embedded Grafana panels are OPT-IN. When enabled, the dashboard
signs a fresh HS256 JWT (60-second TTL) per panel-render request
and the iframe authenticates via the documented Grafana
[`auth.jwt`] mechanism (`auth_token` URL-login query parameter).
The SAME shared secret is consumed by both the dashboard pod
(via `LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET`) and the Grafana pod
(mounted as `/etc/grafana/jwt/shared-secret` + read via
`GF_AUTH_JWT_KEY_FILE`).

> **Both sides must be flipped together.** Setting
> `dashboard.grafana.endpoint` (or `LUCAIRN_DASHBOARD_GRAFANA_URL`)
> WITHOUT also enabling `observability.grafana.auth.jwt.enabled` on
> the Helm path (or configuring `[auth.jwt]` in Grafana on the
> Compose path) causes the embedded iframe to land on Grafana's
> login screen instead of authenticating via the signed JWT. The
> Helm path catches this at render time with a `fail` template
> guard. The Compose path is
> validated by `bin/lucairn doctor`'s `dashboard grafana:` probe
> + the soft `/api/datasources/proxy/*` reachability check.

#### Compose path

1. Add the server health + Grafana block to `customer.env`:

   ```bash
   LUCAIRN_DASHBOARD_GRAFANA_URL=https://grafana.lucairn.local
   LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET=$(openssl rand -hex 24)  # 48-char hex
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_GATEWAY_THROUGHPUT_UID=<uid>
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_SANITIZER_HIT_RATES_UID=<uid>
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_WITNESS_VERIFY_RATE_UID=<uid>
   LUCAIRN_DASHBOARD_GRAFANA_PANEL_AUDIT_LOG_VOLUME_UID=<uid>
   ```

   Panel UIDs come from Grafana → Edit Dashboard → Share → UID.
   Empty UIDs render a "panel not configured" placeholder in the
   side drawer without breaking the rest of `/health`.

2. Configure Grafana with `[auth.jwt]`. A minimal `grafana.ini`
   block (mount as a ConfigMap or set via env vars):

   ```ini
   [security]
   allow_embedding = true

   [auth.jwt]
   enabled = true
   url_login = true
   key_file = /etc/grafana/jwt/shared-secret
   username_claim = email
   email_claim = email
   auto_sign_up = true
   expect_claims = {"iss": "lucairn-dashboard", "aud": "grafana"}
   ```

   Mount the same shared secret as a single-line file at
   `/etc/grafana/jwt/shared-secret`.

3. Run `bin/lucairn doctor` — the new `dashboard grafana:` pre-flight
   surfaces invalid URL schemes, sub-32-character secrets, and
   reachability problems.

4. Recreate the dashboard container:

   ```bash
   docker compose -f docker-compose.customer.yml \
     --env-file customer.env --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

5. Verify: open `/health` while logged in. Click any service card →
   side drawer opens → embedded Grafana panel renders without a
   Grafana login screen.

#### Kubernetes path

1. (Optional — recommended) Set `dashboard.grafana.jwt.secretName`
   empty so Helm generates a 48-char shared secret in a Secret
   named `lucairn-dashboard-grafana-jwt`. The `lookup` pattern in
   the template preserves the value across `helm upgrade`.

   The dashboard sub-chart auto-renders the SAME Secret in BOTH the
   dashboard namespace (`dashboard.namespace`, default `lucairn`)
   AND the observability namespace (`global.observabilityNamespace`,
   default `dsa-observability`). K8s Secrets are namespace-scoped,
   so without the cross-namespace mirror the Grafana pod would
   crashloop with `CreateContainerConfigError: secret
   "lucairn-dashboard-grafana-jwt" not found`. Customers running a
   non-default observability namespace MUST set
   `global.observabilityNamespace` to match. Operators who supply
   their own Secret (set `dashboard.grafana.jwt.secretName`) take
   over the cross-namespace duplication themselves.

2. Wire Grafana embedding + the observability sub-chart's JWT mode
   in `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     grafana:
       endpoint: "https://grafana.lucairn.local"
       panels:
         gatewayThroughputUID: "<uid>"
         sanitizerHitRatesUID: "<uid>"
         witnessVerifyRateUID: "<uid>"
         auditLogVolumeUID: "<uid>"

   observability:
     enabled: true
     grafana:
       auth:
         jwt:
           enabled: true
           secretRef:
             # Match the dashboard sub-chart's auto-generated Secret name.
             name: lucairn-dashboard-grafana-jwt
             key: shared-secret
   ```

3. Apply: `helm upgrade --install lucairn charts/lucairn \
   -f customer-values.yaml --namespace lucairn`.

4. Confirm both rollouts: `kubectl -n lucairn rollout status
   deploy/lucairn-dashboard` + `kubectl -n dsa-observability
   rollout status deploy/grafana`.

5. Verify same as Compose step 5 above.

#### Rotating the Grafana JWT shared secret

See `OPS.md` § "Rotating the Grafana JWT shared secret".

### Enable API key management

The dashboard's `/keys` surface lets an admin operator mint,
rotate, revoke, and bulk-revoke `lcr_live_*` API keys against the
gateway's existing admin HTTP API. The endpoint lives on the same
gateway listener as the data plane (mounted under
`/api/v1/admin/`) and is authenticated with the gateway's
`DSA_ADMIN_KEY` constant-time-compared bearer token.

> **`/keys` is admin-only.** Viewers reach the route only via direct
> URL typing and receive a `404 Not Found` (the dashboard's
> `RequireRole` middleware deliberately returns 404 rather than 403
> to avoid disclosing route existence to non-admin sessions; see
> `apps/dashboard/internal/auth/middleware.go`). Plaintext keys
> are shown ONCE on the post-mint modal with
> `Cache-Control: no-store + Pragma: no-cache + Referrer-Policy:
> no-referrer` headers so the value never enters intermediary caches,
> browser back-button history, or referrer logs.

#### Compose path

1. Add the API key management block to `customer.env`:

   ```bash
   LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL=http://gateway:8080
   LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN=<your DSA_ADMIN_KEY value>
   ```

   The dashboard container resolves `http://gateway:8080` via the
   compose DNS network — no host-side ingress is required.

2. Run `bin/lucairn doctor` — the new `dashboard keys:` pre-flight
   surfaces invalid URL schemes, placeholder tokens, gateway
   unreachability, and admin-token rejection (`401`).

3. Recreate the dashboard container:

   ```bash
   docker compose -f docker-compose.customer.yml \
     --env-file customer.env --profile dashboard \
     up -d --force-recreate lucairn-dashboard
   ```

4. Verify: log into the dashboard as admin → click the
   "API keys" sidebar entry → mint a test key → copy the plaintext
   from the modal → exchange the key against the gateway with
   `curl -H "X-API-Key: <minted-key>" https://<gateway-host>/v1/messages …`.

#### Kubernetes path

1. Pre-create the Secret carrying the admin token. The Secret name +
   key the dashboard sub-chart consumes are
   `lucairn-dashboard-gateway-admin` + `admin-token` by default;
   override via `dashboard.gateway.adminTokenSecretRef.{name,key}`.

   ```bash
   kubectl -n lucairn create secret generic lucairn-dashboard-gateway-admin \
     --from-literal=admin-token='<gateway DSA_ADMIN_KEY value>'
   ```

2. Wire `dashboard.gateway.*` in `customer-values.yaml`:

   ```yaml
   dashboard:
     enabled: true
     gateway:
       adminURL: "http://gateway.lucairn.svc.cluster.local:8080"
       adminTokenSecretRef:
         name: lucairn-dashboard-gateway-admin
         key: admin-token
   ```

   The umbrella chart's render-time validator catches the half-wired
   case (URL set, secretRef.name empty) at `helm install/upgrade`
   time so the dashboard pod never boots into a 401-rain state.

3. Apply: `helm upgrade --install lucairn charts/lucairn -f
   customer-values.yaml --namespace lucairn`.

4. Confirm the rollout + the new env vars are injected:

   ```bash
   kubectl -n lucairn rollout status deploy/lucairn-dashboard
   kubectl -n lucairn exec deploy/lucairn-dashboard -- env | \
     grep LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL
   ```

5. Verify same as Compose step 4 above.

#### Bootstrapping the first customer

If the gateway keystore has zero customers, the `/keys` page renders
an empty-state pointing here. Mint your first customer via the
kit's helper:

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"
./bin/lucairn-mint-customer --name "Acme GmbH" --email "ops@acme.de" --tier enterprise
```

Reload `/keys` and the new customer appears in the auto-detected
selector (single-customer installs hide the selector entirely).

#### Rotating the gateway admin token

See `OPS.md` § "Rotating the gateway admin token".

### Enable audit log browser

The dashboard's `/audit` surface is OPT-IN. When enabled, both viewer
and admin roles can filter / page / save filters / export the audit
event stream from the customer-side `postgres-audit` instance. PII is
redacted in the default render; an admin can "Reveal raw" per event,
which emits a paired `audit.reveal_raw` event into the same audit log.

**IMPORTANT**: this connection points at `postgres-audit` (the audit
EVENT log), NOT `postgres-bridge` (the cert log that
`LUCAIRN_DASHBOARD_AUDIT_DB_URL` configures for the cert browser).
The two are independent databases with independent Postgres roles.
The dashboard reads both at runtime through DISTINCT env vars:

- `LUCAIRN_DASHBOARD_AUDIT_DB_URL`     → cert browser (Slice 3)
- `LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL` → audit log browser (Slice 6)

#### Saved-filter table migration (required for per-user dropdowns)

The audit-log browser persists per-user filter dropdowns in a new
`dashboard_saved_filters` table. Apply the migration BEFORE enabling
the surface (or after, if you don't mind the surface rendering an
"apply the migration" banner until you do):

```bash
psql 'postgres://dsa:dsa@127.0.0.1:5433/audit' \
  < apps/dashboard/migrations/000001_create_saved_filters.up.sql
```

The migration grants INSERT/SELECT/UPDATE/DELETE on the new table to
the existing `audit_app` role (the same role the dashboard connects
as for reading `audit_events`). Operators uncomfortable widening the
role can instead pre-create a separate `dashboard_app` role with
grants on `dashboard_saved_filters` only and wire its connection
string via `LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL`.

#### Compose path

Edit `customer.env`:

```bash
LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL=postgres://audit_app:CHANGE_ME@postgres-audit:5432/audit?sslmode=disable
# Optional — separate role for saved filters:
# LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL=postgres://dashboard_app:...@postgres-audit:5432/audit
```

Restart the dashboard container:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env --profile dashboard up -d --force-recreate lucairn-dashboard
```

Verify `bin/lucairn doctor` returns green for `dashboard audit-log`:

```bash
./bin/lucairn doctor
```

#### Kubernetes path

Pre-create the Secret holding the libpq connection string:

```bash
kubectl -n lucairn create secret generic lucairn-dashboard-audit-log \
  --from-literal=url='postgres://audit_app:REAL_PASSWORD@postgres-audit:5432/audit?sslmode=disable'
```

Then update `customer-values.yaml`:

```yaml
dashboard:
  enabled: true
  audit:
    auditLogDBConnectionStringRef:
      name: lucairn-dashboard-audit-log
      key: url
```

Apply with `helm upgrade --install lucairn ./charts/lucairn -f customer-values.yaml`.

#### Rotating the audit log DB credentials

See `OPS.md` § "Rotating the audit log DB credentials".

#### Reveal raw audit event payload

The admin "Reveal raw" button on the `/audit/{event_id}` detail page
returns the unredacted payload AND emits a paired
`audit.reveal_raw` event into the same `audit_events` table. The
event payload identifies the operator who clicked, the target event,
the target's source service, and the target's `request_id`. This
closes the compliance loop — auditors can answer "who unmasked
event X" by filtering for `event_type=audit.reveal_raw` with the
target_event_id matching.

The CSV export endpoint also supports `?reveal=true` for admins. The
endpoint emits an `audit.csv_export_with_reveal` event BEFORE the
stream begins so the audit trail captures bulk reveals even if the
client disconnects mid-stream.

