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
- 8 GB RAM, 4 vCPUs, 50 GB disk free.
- Outbound HTTPS to:
  - `ghcr.io` (one-time image pull, ~3 GB across 13 images).
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

Write your GHCR PAT to a 0600 file and `docker login` once:

```bash
umask 077
printf '%s' '<YOUR_GHCR_READ_PACKAGES_PAT>' > ~/.ghcr-token
docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin < ~/.ghcr-token
```

Expected output: `Login Succeeded`. If you see `denied: permission_denied`, your PAT does not yet have package-pull access — contact Lucairn support with your GitHub username.

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

This pulls 13 images (~3 GB first time, cached thereafter) and starts the full pilot stack. Compose returns when containers are started; healthchecks take another ~30 s to settle.

Wait for everything to report `(healthy)`:

```bash
docker compose -p compose-demo \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  ps --format 'table {{.Name}}\t{{.Status}}'
```

You should see 13 containers, all `Up X seconds (healthy)`:

```
compose-demo-audit-1                Up (healthy)
compose-demo-gateway-1              Up (healthy)
compose-demo-id-bridge-1            Up (healthy)
compose-demo-postgres-audit-1       Up (healthy)
compose-demo-postgres-bridge-1      Up (healthy)
compose-demo-postgres-sandbox-a-1   Up (healthy)
compose-demo-postgres-veil-1        Up (healthy)
compose-demo-redis-ai-1             Up (healthy)
compose-demo-redis-sanitizer-1      Up (healthy)
compose-demo-sandbox-a-1            Up (healthy)
compose-demo-sandbox-b-1            Up (healthy)
compose-demo-sanitizer-1            Up (healthy)
compose-demo-veil-witness-1         Up (healthy)
```

If any container is `unhealthy` or `restarting`, see § Troubleshooting.

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

Expected output:

```
signatures_valid:  True
completeness:      COMPLETENESS_FULL
overall_verdict:   VERDICT_VERIFIED
byok_exempt:       True
claims_signed:     4
```

That is your end-to-end PASS gate. Four services (bridge, sanitizer, AI, audit) each signed their own claim. The witness assembled and signed the chain. Every signature verifies against the deployed Ed25519 keypairs.

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
