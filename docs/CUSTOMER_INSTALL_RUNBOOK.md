# Customer Install Runbook — Lucairn Enterprise Compose (v1.0)

**Audience:** Customer IT lead deploying Lucairn Enterprise for an internal pilot or design-partner engagement on a single Linux VM.
**Deployment mode:** Self-hosted with managed LLM (BYOK Anthropic / OpenAI / Mistral / Gemini).
**Verified from a fresh Ubuntu 22.04 x86_64 box on 2026-05-26.** Wall-clock: `git clone` → first successful `POST /v1/messages` ≈ 2 min 21 s.
**Companion document:** `INSTALL.md` is the long-form install reference; this runbook is the copy-pasteable 10-minute fast path.

---

## 1. Pre-requisites (one-time per host)

You will need:

- Ubuntu 22.04+ x86_64 (Debian 12, RHEL 9, AL2023 also tested) with `sudo`.
- Docker Engine 24+ and Docker Compose v2 (`docker compose version` reports `v2.x`).
- 16 GB RAM recommended (4 vCPUs, 50 GB disk free). ~8 GB is feasible for this pilot topology **because the L3 deep PII shield is off by default** (`LUCAIRN_L3_REQUIRED=false`) — the `ollama-identity` container runs but loads no `qwen2.5:7b` model, so it idles at a few hundred MB instead of the ~5 GB resident a loaded model needs. If you later stage the L3 model and set `LUCAIRN_L3_REQUIRED=true`, provision the full 16 GB. (INSTALL.md states 16 GB recommended for the L3-on default; the two figures are reconciled by whether the L3 model is loaded.)
- Outbound HTTPS to:
  - `ghcr.io` — the 12 Lucairn `dsa-*` images (`dsa-gateway`, `dsa-sandbox-a`, `dsa-sandbox-b`, `dsa-sanitizer`, `dsa-veil-witness`, `dsa-audit`, `dsa-id-bridge`, `dsa-reid-guard`, `dsa-admin`, `dsa-demo`, `dsa-ingest`, `dsa-llm-auditor`) are pulled from the private `ghcr.io/declade/*` namespace. **Lucairn must grant your GitHub account package-pull access BEFORE running `docker login`** — contact support@lucairn.eu with your GitHub username and wait for confirmation before attempting any docker pull step.
  - `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` — the public base images (`postgres:16-alpine`, `redis:7-alpine`, `alpine:3.20`, `migrate/migrate:v4.17.0`, `ollama/ollama`) are pulled from Docker Hub. A host that allowlists only `ghcr.io` will authenticate to GHCR successfully but fail `docker compose up` when Docker attempts to pull these base images. **`LUCAIRN_IMAGE_REGISTRY` does not redirect these pulls** — it only prefixes the Lucairn `dsa-*` images (`dsa-gateway`, `dsa-sandbox-a`, `dsa-audit`, and the other `ghcr.io/declade/*` images). The base images are hardcoded in the compose files and are not registry-templated. If your policy prohibits direct Docker Hub access, configure a **registry pull-through mirror / cache** for `registry-1.docker.io` (the standard approach); alternatively, mirror those specific image tags and edit the `image:` lines in the compose files.
  - The managed-LLM provider you intend to BYOK (`api.anthropic.com` by default).
- A managed-LLM API key for one of: Anthropic, OpenAI, Mistral, Gemini.
- A GitHub account that Lucairn has granted `read:packages` access to the `Declade/lucairn-enterprise-deployment-kit` GHCR namespace, plus a Personal Access Token (PAT) with `read:packages` scope.
- Python 3 with the `cryptography` library installed (Ubuntu 22.04: `sudo apt install -y python3-cryptography`; usually already present on 22.04+).

Verify in one command:

```bash
docker --version && docker compose version && \
  python3 -c 'import cryptography; print("cryptography OK")' && \
  echo "PREREQS OK"
```

If any line fails, fix that prerequisite before continuing.

---

## 2. Authenticate to the Lucairn image registry (one-time per host)

> **Grant required BEFORE this step.** A self-minted GitHub PAT alone is NOT
> sufficient. Lucairn must first GRANT your GitHub account package-pull access
> to the `ghcr.io/declade/*` registry. Email **support@lucairn.eu** with your
> GitHub username and wait for confirmation (typically one business day) BEFORE
> proceeding. Attempting `docker login` without the grant will succeed (GitHub
> accepts valid PATs), but `docker pull` will immediately fail with `denied:
> permission_denied`.

Write your GHCR PAT to a 0600 file and `docker login` once:

```bash
umask 077
printf '%s' '<YOUR_GHCR_READ_PACKAGES_PAT>' > ~/.ghcr-token
docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin < ~/.ghcr-token
```

Expected output: `Login Succeeded`. If you see `denied: permission_denied` on a subsequent `docker pull`, the grant has not yet been applied — contact Lucairn support with your GitHub username.

If you mirror Lucairn images to your own internal registry instead, skip the `docker login` step and set `LUCAIRN_IMAGE_REGISTRY=<your-mirror-prefix>` in `customer.env` after step 4.

---

## 3. Clone the kit

```bash
git clone https://github.com/Declade/lucairn-enterprise-deployment-kit.git
cd lucairn-enterprise-deployment-kit
```

Verify you are on `main`:

```bash
git log -1 --oneline
git branch --show-current  # → main
```

---

## 4. Generate `customer.env` (one command, dev + BYOK mode)

```bash
./bin/lucairn-init --dev --byok
```

This writes a fully-populated, doctor-passing `customer.env` (mode 0600). It generates:

- 5 Ed25519 service signing keypairs.
- Hex32 service secrets (admin key, JWT secret, encryption keys).
- Postgres passwords for the 4 internal databases.
- Dev-mode defaults (`DSA_ENV=development`, `GATEWAY_BASE_URL=http://localhost:8080`, `GRPC_TLS_ENABLED=false`).
- `LUCAIRN_LLM_EGRESS_ALLOWLIST=api.anthropic.com,api.openai.com` (the BYOK overlay's egress allowlist).

Expected output ends with a `BYOK mode enabled` banner reminding you to add host-firewall rules.

For production (TLS + license bundle), see `INSTALL.md § Choose A Deployment Mode` and run `./bin/lucairn-init --production --license <path>` instead.

---

## 5. Inject your managed-LLM API key

`bin/lucairn-init --byok` already wrote an uncommented but empty `ANTHROPIC_API_KEY=` line into `customer.env`. Replace the empty value with your real `sk-ant-...` key:

```bash
# Replace <your-key-here> with your real sk-ant-... key, then run:
sed -i.bak 's|^ANTHROPIC_API_KEY=.*$|ANTHROPIC_API_KEY=<your-key-here>|' customer.env

# Or just open the file in your editor and set the right line:
#   ANTHROPIC_API_KEY=sk-ant-...
#   OPENAI_API_KEY=sk-...
#   MISTRAL_API_KEY=...
#   GEMINI_API_KEY=...
```

Verify a real key is present (does not print the key):

```bash
grep -c '^ANTHROPIC_API_KEY=sk-ant-' customer.env  # → 1
```

If this returns `0`, the sed didn't land (typo in `<your-key-here>`, key didn't start with `sk-ant-`, or you used a non-Anthropic provider). Re-run step 5 with the correct key.

If you have keys for multiple providers, add multiple lines. The Sandbox B adapter only registers providers whose env var is set.

---

## 6. Bring up the stack

```bash
docker compose -p compose-demo \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  up -d
```

The `-p compose-demo` flag pins the Docker Compose project name so container names start with `compose-demo-*` regardless of the directory name on disk. Without it, Compose defaults the project name to the current directory name (`lucairn-enterprise-deployment-kit-*`).

This pulls 12 distinct images (~3 GB first time, cached thereafter — 7 Lucairn `dsa-*` images from `ghcr.io` for this demo overlay, plus `postgres`, `redis`, `alpine`, `migrate`, and `ollama` from Docker Hub; the full kit ships 12 `dsa-*` images but only 7 are active in this topology) and starts the full pilot stack: 15 long-running containers (see below). Compose returns when containers are started; healthchecks take another ~30 s to settle.

Wait for everything to report `(healthy)`:

```bash
docker compose -p compose-demo \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  ps --format 'table {{.Name}}\t{{.Status}}'
```

You should see 15 containers. All report `Up X seconds (healthy)` except
`ollama-identity`, which has no Compose healthcheck (the image ships no shell,
and its L3 model is not staged by default — see § 1 and INSTALL.md) and so
reports `Up X seconds` with no `(healthy)` suffix. That bare `Up` is expected,
not a failure:

```
compose-demo-audit-1                  Up (healthy)
compose-demo-gateway-1                Up (healthy)
compose-demo-id-bridge-1              Up (healthy)
compose-demo-ollama-identity-1        Up
compose-demo-postgres-audit-1         Up (healthy)
compose-demo-postgres-bridge-1        Up (healthy)
compose-demo-postgres-sandbox-a-1     Up (healthy)
compose-demo-postgres-veil-1          Up (healthy)
compose-demo-redis-ai-1               Up (healthy)
compose-demo-redis-sanitizer-1        Up (healthy)
compose-demo-redis-sanitizer-cache-1  Up (healthy)
compose-demo-sandbox-a-1              Up (healthy)
compose-demo-sandbox-b-1              Up (healthy)
compose-demo-sanitizer-1              Up (healthy)
compose-demo-veil-witness-1           Up (healthy)
```

(The one-shot `prep-migrations` + `migrate-*` jobs run once and exit, so they
do not appear in steady-state `ps`. `ollama-identity` is the always-on L3
PII-shield runtime: it runs but holds no model until you stage one — with
`LUCAIRN_L3_REQUIRED=false` (the kit default) the stack runs L1+L2 and does not
block on it.)

If any container is `unhealthy` or `restarting`, see § Troubleshooting.

> **L3 deep PII shield is OFF by default for now.** Both `lucairn-init` and
> the bare `customer.env.example` (manual `cp customer.env.example customer.env`
> path) set `LUCAIRN_L3_REQUIRED=false`, so the stack runs the
> L1 (deterministic regex/dictionary) + L2 (sandbox-a) PII layers and does **not**
> require the optional L3 model (`qwen2.5:7b`) to be staged before your first
> inference. With L3 off, the request proceeds on L1+L2 and the verification
> certificate is honestly downgraded to **PARTIAL** (the witness omits
> `llm_pii_scan` from `layers_active`); you do **not** get a `503
> l3_scrubber_unavailable` on the first request.
>
> **To re-enable L3 later:** pre-stage the `qwen2.5:7b` model into the
> `ollama-identity` volume (the air-gap-preserving throwaway-container procedure
> is in INSTALL.md, the "Pre-stage the L3 deep PII-shield model" section), then set
> `LUCAIRN_L3_REQUIRED=true` in `customer.env`, re-run `bin/lucairn doctor`, and
> restart the stack. Provision the full 16 GB RAM (§ 1) when you do.

---

## 7. Mint your first customer + API key

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"

./bin/lucairn-mint-customer \
  --name "Acme GmbH" \
  --email "ops@acme.de" \
  --tier enterprise
```

Output ends with `raw_key: lcr_live_…` — **capture this value once**. It is never displayed again.

Persist it to a 0600 file:

```bash
umask 077
printf '%s' 'lcr_live_…paste_here…' > ~/.lucairn-customer-key
```

---

## 8. Verify end-to-end (a real PII round-trip)

This sends a German clinical payload through the full sanitize → sandbox → managed-LLM → witness → audit pipeline, then fetches the cryptographic verification certificate.

```bash
CUSTOMER_KEY=$(cat ~/.lucairn-customer-key)
ANTHROPIC_KEY=$(grep '^ANTHROPIC_API_KEY=' customer.env | cut -d= -f2-)

RESP=$(curl -sS -X POST http://localhost:8080/v1/messages \
  -H "x-api-key: $CUSTOMER_KEY" \
  -H "X-Upstream-Key: $ANTHROPIC_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 150,
    "messages": [{"role": "user", "content": "Bitte fasse zusammen: Anna Schmidt, geboren am 12.03.1978, Versicherungsnummer A4501289-DE, wohnhaft Münchner Straße 42, klagt über Brustschmerzen seit gestern. Telefon 089-12345678, Email anna.schmidt@example.de. Antworte auf Deutsch in einem Satz."}]
  }')

echo "$RESP" | python3 -c 'import sys, json; d=json.loads(sys.stdin.read()); m=d["metadata"]["dsa_compliance"]; print("pii_in_ai:", m["pii_in_ai"]); print("redaction_count:", m["redaction_count"]); print("cert_url:", m["veil_certificate_url"])'
```

Expected output:

```
pii_in_ai: False
redaction_count: 6
cert_url: http://localhost:8080/api/v1/veil/certificate/<request_id>
```

`pii_in_ai: False` is the headline invariant: the managed LLM never saw the patient's name, DOB, insurance number, address, phone, or email. The Sandbox B prompt contained only opaque placeholders.

Fetch the verification certificate (this is the cryptographic proof you can hand to compliance / auditors):

```bash
CERT_URL=$(echo "$RESP" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read())["metadata"]["dsa_compliance"]["veil_certificate_url"])')

curl -sS "$CERT_URL" -H "x-api-key: $CUSTOMER_KEY" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
v = d["verification"]
print("signatures_valid: ", v["signatures_valid"])
print("completeness:     ", v["completeness"])
print("overall_verdict:  ", v["overall_verdict"])
print("byok_exempt:      ", v["byok_exempt"])
print("claims_signed:    ", len(d["claims"]))
'
```

Expected output (default L3-off install):

```
signatures_valid:  True
completeness:      COMPLETENESS_PARTIAL
overall_verdict:   VERDICT_VERIFIED
byok_exempt:       True
claims_signed:     4
```

**PASS gate:** `signatures_valid: True` and `overall_verdict: VERDICT_VERIFIED`
are the mandatory signals. `completeness: COMPLETENESS_PARTIAL` is **correct and
expected** with the default `LUCAIRN_L3_REQUIRED=false` config — it means the
L1+L2 PII layers are active and the chain is fully signed; the L3 deep PII
shield is simply not loaded, so `llm_pii_scan` is absent from `layers_active`.
This is NOT a failure. Do not confuse PARTIAL completeness with a broken stack.

`completeness: COMPLETENESS_FULL` is expected ONLY if you have re-enabled L3:
pre-staged the `qwen2.5:7b` model into the `ollama-identity` volume AND set
`LUCAIRN_L3_REQUIRED=true` in `customer.env` (see INSTALL.md §
"Pre-stage the L3 deep PII-shield model"). If you see FULL without having done
both of those steps, open a support ticket.

Four services (bridge, sanitizer, AI, audit) each signed their own claim. The
witness assembled and signed the chain. Every signature verifies against the
deployed Ed25519 keypairs.

---

## 9. Repeat-shape verification (recommended: 10 sequential requests)

To confirm the stack is stable, not just first-request-lucky:

```bash
for i in 1 2 3 4 5 6 7 8 9 10; do
  CODE=$(curl -sS -X POST http://localhost:8080/v1/messages \
    -H "x-api-key: $CUSTOMER_KEY" \
    -H "X-Upstream-Key: $ANTHROPIC_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -o /tmp/lucairn-req-$i.json \
    -w "%{http_code}" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":150,"messages":[{"role":"user","content":"Bitte fasse zusammen: Anna Schmidt, geboren am 12.03.1978, Versicherungsnummer A4501289-DE, wohnhaft Münchner Straße 42, klagt über Brustschmerzen seit gestern. Telefon 089-12345678, Email anna.schmidt@example.de. Antworte auf Deutsch in einem Satz."}]}')
  RC=$(python3 -c "import json; print(json.load(open('/tmp/lucairn-req-$i.json'))['metadata']['dsa_compliance']['redaction_count'])" 2>/dev/null)
  echo "req $i: HTTP=$CODE redaction_count=$RC"
done
```

Expected: 10/10 `HTTP=200 redaction_count=6` (or higher; varies by payload).

---

## 10. (Production) Put the gateway behind TLS

For production, terminate HTTPS at the customer's reverse proxy (Caddy / Nginx / Traefik / enterprise ingress) and forward to `127.0.0.1:8080`. Set `GATEWAY_TRUSTED_PROXY_CIDRS` in `customer.env` to the proxy source CIDRs, then re-run `bin/lucairn doctor`.

This runbook intentionally stops at `http://localhost:8080` for the dev / pilot install. Add the TLS step before exposing the gateway to anyone outside the host.

---

## 11. Enable the operator dashboard (optional)

The dashboard is a single Go binary that ships a web UI for the operator surfaces — home / KPIs, server health, compliance PDF export, audit log browser, and API key management. Compliance teams use it to inspect signed cert claims and run periodic PDF exports without curl/jq. Skip this step if engineer-grade JSON API access via Step 10 is enough.

### Generate dashboard secrets

```bash
DASH_PW=$(openssl rand -base64 24)
DASH_SS=$(openssl rand -hex 24)
echo "Bootstrap password: $DASH_PW"
# Capture this value — you'll log in as admin@lucairn.local with it.
```

### Append dashboard env vars to customer.env

```bash
cat >> customer.env <<EOF

# ── Dashboard (optional; --profile dashboard) ──
LUCAIRN_DASHBOARD_ENABLED=true
LUCAIRN_DASHBOARD_BOOTSTRAP_EMAIL=admin@lucairn.local
LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD=$DASH_PW
LUCAIRN_DASHBOARD_SESSION_SECRET=$DASH_SS
EOF
```

### Bring up the dashboard alongside the running stack

```bash
docker compose -p compose-demo \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --profile dashboard \
  --env-file customer.env \
  up -d
```

The `--profile dashboard` flag opts the `lucairn-dashboard` service into the rendered Compose project. Without it the dashboard service is filtered out (the rest of the stack is unaffected). The dashboard container is wired to the `dsa-witness` and `dsa-witness-certification` networks so it can reach the witness service when the cert browser is enabled (see below).

### Verify

```bash
curl -fsS http://127.0.0.1:8443/healthz
# Expect: 200 OK
```

Then open `http://127.0.0.1:8443/login` in your browser (or behind your front proxy as documented in Step 10) and sign in with `admin@lucairn.local` + the password you captured above.

### Login + the surfaces that work today

After login, these surfaces work out of the box on a default Compose install:

- `/dashboard` — operator home with KPI tiles + 30-day sparkline + sanitizer bars
- `/health` — server health pills for every kit service (polled every 10s)
- `/certs` — **cert browser + inspector + audit-grade validator**. The Compose stack wires `LUCAIRN_DASHBOARD_AUDIT_DB_URL` to the bundled `postgres-veil` cert log automatically (dashboard 0.8.2+), so the compliance team can browse the cert chain immediately after login. Each cert detail page surfaces the 4 signed claims (`TOKEN_GENERATED` + `PII_SANITIZED` + `INFERENCE_COMPLETED` + `EVENTS_RECORDED`), the witness verdict (`VERIFIED` / `PARTIAL` / `FAILED`), completeness (`FULL` / `PARTIAL`), and `signatures_valid` / `byok_exempt` / `isolation_verified` flags.
- `/compliance` — admin-only signed-claim summary PDF export (cover + image manifest + cert window)
- `/audit` — renders the "not configured" explainer until you wire `LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL` against the `postgres-audit` database (see customer.env.example for the wiring template)
- `/keys` — renders the "not configured" explainer until you wire `LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL` + `LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN`

### Cert browser — enabled by default in 0.8.2

Dashboard 0.8.2 (2026-05-27) rewrites the cert browser SQL to match the real `veil_certificates` schema and wires the database connection by default. The earlier "not wired by default" caveat (phantom `cert_id` / `redaction_count` / `claim_count` columns) is closed.

The default wiring uses the `veil_app` role on `postgres-veil` (the cert log database). The role has SELECT on `veil_certificates` (the dashboard's only read path), plus the unused INSERT + UPDATE(attestation_raw) grants the witness writer needs. The dashboard binary never issues INSERT/UPDATE/DELETE — defence in depth keeps the cert log effectively read-only from the dashboard's perspective.

To use a dedicated read-only role instead, pre-create one and override the env var:

```bash
# As the postgres-veil DB owner:
psql -h postgres-veil -U veil -d veil <<'SQL'
CREATE ROLE lucairn_dashboard_ro WITH LOGIN PASSWORD '<generate>';
GRANT CONNECT ON DATABASE veil TO lucairn_dashboard_ro;
GRANT USAGE ON SCHEMA public TO lucairn_dashboard_ro;
GRANT SELECT ON veil_certificates TO lucairn_dashboard_ro;
SQL

echo "LUCAIRN_DASHBOARD_AUDIT_DB_URL=postgres://lucairn_dashboard_ro:<password>@postgres-veil:5432/veil?sslmode=disable" >> customer.env
docker compose -p compose-demo -f docker-compose.customer.yml -f docker-compose.self-hosted.yml --profile dashboard --env-file customer.env up -d --force-recreate lucairn-dashboard
```

### Cosmetic healthcheck note

The dashboard image is `gcr.io/distroless/static-debian12:nonroot` — it contains only the dashboard binary, no shell or `wget`. The Compose `healthcheck` block is intentionally disabled (`healthcheck: { disable: true }`) so `docker compose ps` doesn't false-flag the container as `unhealthy`. The actual liveness check is `curl -fsS http://127.0.0.1:8443/healthz` from the host. The Helm path is unaffected — kubelet performs `httpGet` probes natively.

---

## Troubleshooting

### `Login Succeeded` did not appear after step 2

Your PAT lacks `read:packages` scope OR your GitHub account has not been granted access to the `Declade` GHCR namespace. Email Lucairn support with your GitHub username; they grant package-pull access manually.

### A container is `unhealthy` or `restarting` after step 6

Inspect the logs for the unhealthy container:

```bash
docker compose -p compose-demo -f docker-compose.customer.yml -f docker-compose.self-hosted.yml -f docker-compose.self-hosted-byok.yml --env-file customer.env logs <service> --tail 100
```

Common causes:

- **`gateway` won't start, complains about `SANDBOX_B_REMOTE_ENDPOINT`** — you forgot `-f docker-compose.self-hosted.yml` (the second overlay). Re-run step 6 with all three overlays.
- **`sandbox-b` exits with `LUCAIRN_LLM_EGRESS_ALLOWLIST is empty`** — you skipped the BYOK overlay (`-f docker-compose.self-hosted-byok.yml`) OR you cleared the allowlist in `customer.env`.
- **`postgres-*` containers won't start, complain about volume permissions** — Docker volume driver permission issue. `docker compose down -v` and retry; if persistent, your host's Docker daemon has SELinux / AppArmor restrictions; consult `OPS.md § Volume permissions`.

### `redaction_count: 0` on step 8

The sanitizer didn't find any PII. Check that you sent the German clinical payload verbatim — names + DOB + insurance number + address + phone + email together should produce `redaction_count ≥ 6`. If the payload is correct, check:

```bash
docker compose -p compose-demo -f docker-compose.customer.yml -f docker-compose.self-hosted.yml -f docker-compose.self-hosted-byok.yml --env-file customer.env logs sanitizer --tail 50
```

### `signatures_valid: False` on step 8 cert verify

A service signing keypair is misconfigured. Re-run `bin/lucairn doctor --env customer.env --offline` and fix any reported errors. If doctor passes but signatures still fail, capture the cert JSON and send to Lucairn support — this should not happen on a fresh kit clone.

### `POST /v1/messages` returns 401 `{"error":"invalid_api_key"}`

The customer key you minted in step 7 may have been wiped by a gateway restart. The Compose path uses an on-disk file keystore at `gateway-data` volume, so this only happens if you `docker compose down -v` (which removes named volumes). Mint a new key (step 7) and capture the new `lcr_live_…` value.

### `POST /v1/messages` returns 502 / sandbox-b timeout

The managed-LLM provider call timed out. Verify outbound reach:

```bash
docker compose -p compose-demo -f docker-compose.customer.yml -f docker-compose.self-hosted.yml -f docker-compose.self-hosted-byok.yml --env-file customer.env exec sandbox-b \
  curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/v1/messages
# Expect: 401 (the dummy x-api-key was rejected, but TCP + DNS worked).
```

If you see `0` or `Could not resolve host`, the box can't reach the provider. Fix host networking / DNS / firewall. If you see `403`, your host IP is blocked by the provider — contact them.

### How do I tear down?

```bash
docker compose -p compose-demo -f docker-compose.customer.yml -f docker-compose.self-hosted.yml -f docker-compose.self-hosted-byok.yml --env-file customer.env down
# Add -v to also remove the persistent Postgres + gateway volumes (DESTROYS DATA):
docker compose -p compose-demo -f docker-compose.customer.yml -f docker-compose.self-hosted.yml -f docker-compose.self-hosted-byok.yml --env-file customer.env down -v
```

---

## Next steps

- Review `INSTALL.md` § Choose A Deployment Mode for production / split-deployment.
- Review `OPS.md` for day-2 operations (backup, log rotation, image upgrades).
- Review `TROUBLESHOOTING.md` for the long-form troubleshooting reference.
- Review `docs/CUSTOMER_HANDOFF_GATES.md` for what Lucairn signs off on before declaring a customer "live."

For vendor-assisted install (Lucairn engineer joining a screen-share), see `docs/VENDOR_ASSISTED_INSTALL.md`.
