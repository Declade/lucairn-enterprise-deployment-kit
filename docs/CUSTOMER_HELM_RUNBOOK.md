# Lucairn Enterprise — Helm install runbook (v1.0 single-replica)

**Audience:** customer IT lead deploying Lucairn to an internal Kubernetes cluster for a pilot.

**Topology:** single-replica v1.0 (every Lucairn pod runs 1 instance). Horizontal scaling (multi-replica HA) is roadmapped for v2.0 — the chart's umbrella validator will reject any attempt to scale a pod-local-state subchart beyond 1 in v1.0.

**Expected wall-clock:** ~10-15 minutes from `git clone` to first successful inference.

**Proven on:** Vast.ai Ubuntu 22.04.5 + Kind v0.24.0 + kubectl v1.31 + helm v3.21 on 2026-05-26 (cert chain `COMPLETENESS_FULL + VERDICT_VERIFIED + 4 claims, 10/10 consistency`).

---

## Prereqs (1-time)

- Kubernetes 1.27+ cluster (Kind, EKS, GKE, AKS, vanilla — single node is fine for pilot scale)
- `kubectl` configured for the cluster + access to create namespaces, ClusterRoles, NetworkPolicies
- `helm` v3.12+ installed locally
- `docker` available locally (for ghcr.io PAT setup; no Docker required on the cluster itself)
- A default StorageClass on the cluster (PVCs use it for keystore + Postgres)
- 8 GB RAM, 4 cores, 50 GB storage available
- An Anthropic API key (`sk-ant-...`) for BYOK inference
- A GitHub Personal Access Token with `read:packages` scope (for pulling Lucairn images from `ghcr.io/declade/*`)

---

## Step 1 — Clone the kit

```bash
git clone https://github.com/Declade/lucairn-enterprise-deployment-kit.git lucairn-kit
cd lucairn-kit
```

This puts you on `main` which contains the verified v1.0 release.

---

## Step 2 — Set up ghcr.io credentials in an isolated DOCKER_CONFIG

The kit's images are private. The chart-managed pull Secret needs a clean `config.json` with literal auth credentials (not a credsStore helper redirect).

```bash
# Set GHCR_USER + GHCR_PAT first
read -p "GitHub username: " GHCR_USER
read -s -p "GitHub PAT (read:packages): " GHCR_PAT
echo

# Isolated DOCKER_CONFIG to avoid host's credsStore interfering
export DOCKER_CONFIG=$(mktemp -d)
echo "$GHCR_PAT" | docker --config $DOCKER_CONFIG login ghcr.io --username "$GHCR_USER" --password-stdin

# Verify config.json has a literal auth field
cat $DOCKER_CONFIG/config.json | grep -q '"auth"' && echo "PAT OK" || echo "PAT FAILED"
```

Expected: `PAT OK`.

---

## Step 3 — Render customer-values.yaml via the canonical script

The kit ships a `scripts/render-values.sh` that generates all REPLACE_* values: AES keys, Ed25519 signing keys with derived public keys, service tokens, random passwords, etc.

```bash
bash scripts/render-values.sh customer-values.yaml
```

This writes a complete `customer-values.yaml` to your current directory. Every cryptographic placeholder is filled with a freshly-generated value. The ONLY value not auto-generated is your Anthropic API key (Step 4).

**Note on script output:** the script may print a warning like `REPLACE_WITH_CUSTOMER_KEY_ID_WHEN_CERTIFICATION_ENABLED still present`. This is expected for the default (non-certification) install — that placeholder is only filled when you enable per-customer certification mode (an optional Enterprise feature). Ignore the warning unless you are explicitly enabling certification.

---

## Step 4 — Add your Anthropic API key

`scripts/render-values.sh` writes the Anthropic key field as `anthropicApiKey: ""` (empty string). Replace the empty string with your real `sk-ant-...` key:

```bash
# Replace <your-key-here> with your real sk-ant-... key, then run:
sed -i.bak 's|anthropicApiKey: ""|anthropicApiKey: "<your-key-here>"|' customer-values.yaml
```

Verify a real key landed (does not print the key):

```bash
grep -c '^      anthropicApiKey: "sk-ant-' customer-values.yaml  # → 1
```

If this returns `0`, the sed didn't land (typo in `<your-key-here>` or key doesn't start with `sk-ant-`). Re-run with the correct key.

---

## Step 5 — Fetch chart dependencies

```bash
helm dependency update charts/lucairn
```

Expected output: `Saving N charts ... Downloading ...` then `Deleting outdated charts`. Generates `charts/lucairn/Chart.lock` + `charts/lucairn/charts/*.tgz`.

---

## Step 6 — Install Lucairn

```bash
helm install lucairn ./charts/lucairn \
  --namespace lucairn \
  --create-namespace \
  -f customer-values.yaml \
  --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
  --wait --timeout 10m
```

This takes ~3-5 minutes. Helm:
1. Creates all `dsa-*` + `lucairn` namespaces
2. Pulls all Lucairn images from ghcr.io
3. Renders + applies all StatefulSets, Deployments, Services, ConfigMaps, Secrets, NetworkPolicies
4. Runs migration Jobs for Postgres + sandbox-a + id-bridge + veil-witness
5. Waits for all pods to reach Ready

If `--wait` exits with `context deadline exceeded`, run `kubectl get pods -A` to see which pod is stuck + check its logs.

---

## Step 7 — Verify all pods are Ready

The `helm install --wait` flag already waits for Helm-managed pods to be ready. As a redundant visual check, list pods across the Lucairn namespaces:

```bash
kubectl get pods -A | grep -E 'lucairn|dsa-'
```

Expected: ~25 pods, all `Running` or `Completed` (Completed = Jobs). Pods run across these namespaces:
- `lucairn` — chart-managed Helm hooks
- `dsa-edge` — gateway
- `dsa-bridge` — id-bridge + postgres-bridge
- `dsa-identity` — sandbox-a + postgres-sandbox-a
- `dsa-ai` — sandbox-b + sanitizer
- `dsa-audit` — audit + postgres-audit
- `dsa-witness` — veil-witness + postgres-veil
- `dsa-admin` — admin portal (optional)
- `dsa-observability` — grafana, loki, tempo, prometheus (optional)
- `dsa-demo` — demo lane (optional)

If any pod is stuck `ImagePullBackOff` → re-run Step 2 and reinstall.
If any pod is stuck `CrashLoopBackOff` → check its logs (`kubectl logs -n <ns> <pod>`) — likely a missed REPLACE_* value in `customer-values.yaml`.

(If you want a wait that fails on any unready Helm-managed pod, scope to the Helm label so you don't pick up Completed Jobs + kube-system pods:
`kubectl wait --for=condition=ready pod -l app.kubernetes.io/managed-by=Helm -n lucairn --timeout=10m`.)

---

## Step 8 — Mint your first customer

Use the in-cluster admin endpoint (avoids host-network rate limits that can hit a brand-new install).

```bash
# Extract the admin key from the rendered Secret
# Secret name is "gateway-credentials" (chart name + "-credentials" suffix).
# Field is "DSA_ADMIN_KEY" (matches the gateway container env var).
ADMIN_KEY=$(kubectl get secret -n dsa-edge gateway-credentials -o jsonpath='{.data.DSA_ADMIN_KEY}' | base64 -d)
echo "Admin key (first 8 chars): ${ADMIN_KEY:0:8}..."

# Your Anthropic key (already in customer-values.yaml from Step 4)
ANTHROPIC_KEY=$(grep -E 'anthropicApiKey:' customer-values.yaml | head -1 | awk '{print $2}' | tr -d '"')

# Mint a customer via in-cluster temp pod. Note: response field is `dsa_api_key`.
CUSTOMER_KEY=$(kubectl run mint --image=curlimages/curl:latest --restart=Never --rm -i --quiet -- \
  curl -s -X POST \
    -H "x-admin-key: $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"my_first_customer","provider":"anthropic","provider_key":"'$ANTHROPIC_KEY'","tier":"enterprise"}' \
    http://gateway.dsa-edge.svc.cluster.local:8080/api/v1/admin/keys | jq -r .dsa_api_key)

echo "Customer API key: $CUSTOMER_KEY"
```

Save the `lcr_live_*` key — your application/customer uses it for inference requests. It is shown ONCE and never recoverable from the kit.

---

## Step 8.5 — Warmup sandbox-b's Ollama runtime (~35s)

On a fresh install, sandbox-b's local Ollama runtime cold-starts on the first inference, which makes that very first request sometimes land with `COMPLETENESS_PARTIAL` (the `dsa-ai` claim arrives outside the witness's 30s accumulator window). Send one warmup request first; the customer-observable request afterwards reliably produces FULL.

Port-forward the gateway first (kept open through Step 10):

```bash
kubectl port-forward -n dsa-edge svc/gateway 8080:8080 &
PF_PID=$!
sleep 3
```

Send the warmup request and discard the response:

```bash
# Warmup — discard the response
curl -s -o /dev/null \
  -H "Authorization: Bearer $CUSTOMER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":10,"messages":[{"role":"user","content":"warmup"}]}' \
  http://localhost:8080/v1/messages

# Wait for accumulator to flush + Ollama runtime to settle
sleep 35
```

Now your demo's first customer-observable request will produce a FULL cert chain.

---

## Step 9 — Send first customer-observable inference

The gateway port-forward from Step 8.5 is still open. Send a request with a realistic German clinical PII payload (matches the Compose runbook's payload, reliably produces ≥6 redactions):

```bash
RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $CUSTOMER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 150,
    "messages": [{
      "role": "user",
      "content": "Bitte fasse zusammen: Anna Schmidt, geboren am 12.03.1978, Versicherungsnummer A4501289-DE, wohnhaft Münchner Straße 42, klagt über Brustschmerzen seit gestern. Telefon 089-12345678, Email anna.schmidt@example.de. Antworte auf Deutsch in einem Satz."
    }]
  }' \
  http://localhost:8080/v1/messages)

CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -n -1)

echo "HTTP $CODE"
echo "$BODY" | jq '.metadata.dsa_compliance | {pii_in_ai, redaction_count, veil_certificate_url}'
```

Expected output:
```
HTTP 200
{
  "pii_in_ai": false,
  "redaction_count": 6,
  "veil_certificate_url": "https://lucairn.customer.example/api/v1/veil/certificate/<request_id>"
}
```

Notes:
- `redaction_count` is `≥ 6` for the payload above (name + DOB + insurance number + address + phone + email).
- The host portion of `veil_certificate_url` reflects `gateway.gatewayBaseUrl` from your `customer-values.yaml` (chart default: `https://lucairn.customer.example`). The fetch in Step 10 uses your local port-forward — it does NOT need to match the URL field.
- The URL does NOT have a `/verify` suffix; the cert endpoint is `GET /api/v1/veil/certificate/<request_id>` directly.

The customer's PII (name, DOB, Versicherungsnummer, address, phone, email) was sanitized BEFORE the prompt reached Anthropic. Anthropic returned a response based on placeholders. Lucairn then re-linked the response (mapping placeholders back to the customer's view).

---

## Step 10 — Verify the cryptographic cert chain

Every inference produces a Veil Certificate proving sanitization happened + which services participated.

```bash
# Extract the request_id from the previous response.
# veil_certificate_url ends with .../<request_id> directly (no /verify suffix),
# so $NF (last field) is the request_id.
REQ_ID=$(echo "$BODY" | jq -r '.metadata.dsa_compliance.veil_certificate_url' | awk -F/ '{print $NF}')
echo "Request ID: $REQ_ID"

# Wait ~35 seconds for the witness accumulator to finalize
# (claims from bridge + sanitizer + ai + audit each arrive within ~30 sec)
sleep 35

# Fetch the cert chain verdict.
# Endpoint: GET /api/v1/veil/certificate/<request_id>  (no /verify suffix)
CERT=$(curl -s -H "Authorization: Bearer $CUSTOMER_KEY" \
  http://localhost:8080/api/v1/veil/certificate/$REQ_ID)

echo "$CERT" | jq '{
  signatures_valid: .verification.signatures_valid,
  completeness:     .verification.completeness,
  overall_verdict:  .verification.overall_verdict,
  claims_count:     (.claims | length),
  claims_types:     [.claims[]?.claim_type],
  missing_services: .verification.missing_services
}'
```

The verification verdict fields (`signatures_valid`, `completeness`, `overall_verdict`, `missing_services`) live under `.verification`. The claim list is the top-level `.claims` array (NOT `.signed_claims` — that key doesn't exist).

Expected:
```json
{
  "signatures_valid": true,
  "completeness": "COMPLETENESS_FULL",
  "overall_verdict": "VERDICT_VERIFIED",
  "claims_count": 4,
  "claims_types": [
    "CLAIM_TYPE_TOKEN_GENERATED",
    "CLAIM_TYPE_PII_SANITIZED",
    "CLAIM_TYPE_INFERENCE_COMPLETED",
    "CLAIM_TYPE_EVENTS_RECORDED"
  ],
  "missing_services": []
}
```

This is the cryptographic proof your compliance team needs:
- **signatures_valid: true** — every claim's Ed25519 signature checks out against the published public keys
- **completeness: COMPLETENESS_FULL** — all 4 expected services participated
- **overall_verdict: VERDICT_VERIFIED** — the whole chain is verified
- **claims_count: 4** — TOKEN_GENERATED (bridge) + PII_SANITIZED (sanitizer) + INFERENCE_COMPLETED (ai) + EVENTS_RECORDED (audit)

---

## Step 11 — Enable the operator dashboard (optional)

The dashboard is a single Go binary that ships a web UI for the operator surfaces — home / KPIs, server health, compliance PDF export, audit log browser, and API key management. Compliance teams use it to inspect signed cert claims and run periodic PDF exports without curl/jq. Skip this step if engineer-grade JSON API access via Step 10 is enough.

### Pre-create the bootstrap admin Secret

The dashboard reads its bootstrap admin password from a Kubernetes Secret. Pre-create it before flipping `dashboard.enabled=true`:

```bash
DASH_PW=$(openssl rand -base64 24)
DASH_SS=$(openssl rand -hex 24)
echo "Bootstrap password: $DASH_PW"
# Capture this value — you'll log in as admin@lucairn.local with it.

kubectl -n lucairn create secret generic lucairn-dashboard-bootstrap-admin \
  --from-literal=password="$DASH_PW" \
  --from-literal=session-secret="$DASH_SS"
```

### Enable the dashboard in customer-values.yaml

Edit `customer-values.yaml` and flip the dashboard block:

```yaml
dashboard:
  enabled: true
  bootstrapAdmin:
    email: admin@lucairn.local
    passwordSecretName: lucairn-dashboard-bootstrap-admin
```

The umbrella chart already wires the dashboard sub-chart into the `lucairn` namespace and exposes a `ClusterIP` service on port 8443. The bootstrap admin Secret you pre-created supplies both the password and the session-secret env vars at pod start.

### Apply the upgrade

Use the same isolated `DOCKER_CONFIG` session pattern from Step 6 so the registry credential never leaks into the global Docker config:

```bash
DOCKER_CONFIG=$(mktemp -d)
helm get values lucairn -n lucairn -o yaml \
  | python3 -c 'import yaml,sys; d=yaml.safe_load(sys.stdin); print(d["global"]["imagePullDockerConfigJson"])' \
  > "$DOCKER_CONFIG/config.json"

helm upgrade lucairn ./charts/lucairn -n lucairn \
  -f customer-values.yaml \
  --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
  --timeout 5m --wait

rm -rf "$DOCKER_CONFIG"
```

Watch for the `lucairn-dashboard` pod to reach `Running`:

```bash
kubectl get pods -n lucairn
# NAME                                 READY   STATUS    RESTARTS   AGE
# lucairn-dashboard-58b4b478c7-ttlk5   1/1     Running   0          30s
```

### Port-forward + verify

```bash
kubectl port-forward -n lucairn svc/lucairn-dashboard 18443:8443 &
PF_PID=$!

curl -fsS http://127.0.0.1:18443/healthz
# Expect: 200 OK
```

Then open `http://127.0.0.1:18443/login` in your browser and sign in with `admin@lucairn.local` + the password you captured above. Production-grade ingress is documented in `INSTALL.md § Enable the Lucairn dashboard (optional)` — port-forward is fine for first-touch verification.

### Login + the surfaces that work today

After login, these surfaces work out of the box on a default Helm install:

- `/dashboard` — operator home with KPI tiles + 30-day sparkline + sanitizer bars
- `/health` — server health pills for every kit service (polled every 10s, in-cluster reach)
- `/certs` — **cert browser + inspector + audit-grade validator**. Dashboard 0.8.2+ ships with the cert browser surface enabled by default; the customer-values.yaml.example template wires `dashboard.auditDB.connectionStringRef` to the bundled cert log automatically. Pre-create the cert-DB Secret per the recipe below before `helm install` (the Secret name is `lucairn-dashboard-audit-db`). Each cert detail page surfaces the 4 signed claims (`TOKEN_GENERATED` + `PII_SANITIZED` + `INFERENCE_COMPLETED` + `EVENTS_RECORDED`), the witness verdict (`VERIFIED` / `PARTIAL` / `FAILED`), completeness (`FULL` / `PARTIAL`), and `signatures_valid` / `byok_exempt` / `isolation_verified` flags.
- `/compliance` — admin-only signed-claim summary PDF export (cover + image manifest + cert window)
- `/audit` — renders the "not configured" explainer until you wire `dashboard.audit.auditLogDBConnectionStringRef.name` against the `postgres-audit` database (see the dashboard sub-chart values for the wiring template)
- `/keys` — renders the "not configured" explainer until you wire `dashboard.gateway.adminURL` + `dashboard.gateway.adminTokenSecretRef.name`

### Cert browser — enabled by default in 0.8.2

Dashboard 0.8.2 (2026-05-27) rewrites the cert browser SQL to match the real `veil_certificates` schema. The earlier "not wired by default" caveat (phantom `cert_id` / `redaction_count` / `claim_count` columns) is closed.

Pre-create the cert-DB Secret in the `lucairn` namespace before `helm install`. The recommended pattern is a dedicated read-only role with `SELECT` on `veil_certificates` only:

```bash
# As the postgres-veil DB owner (inside the dsa-witness namespace):
kubectl -n dsa-witness exec -it veil-witness-postgresql-0 -- psql -U veil -d veil <<'SQL'
CREATE ROLE lucairn_dashboard_ro WITH LOGIN PASSWORD '<generate>';
GRANT CONNECT ON DATABASE veil TO lucairn_dashboard_ro;
GRANT USAGE ON SCHEMA public TO lucairn_dashboard_ro;
GRANT SELECT ON veil_certificates TO lucairn_dashboard_ro;
SQL

# Create the Secret the dashboard chart reads at runtime:
kubectl -n lucairn create secret generic lucairn-dashboard-audit-db \
  --from-literal=connection-string='postgres://lucairn_dashboard_ro:<password>@veil-witness-postgresql.dsa-witness.svc.cluster.local:5432/veil?sslmode=verify-full'
```

The `customer-values.yaml.example` ships the matching wire-up. If you prefer the over-privileged shortcut, reuse the bundled `veil_app` role instead (the dashboard binary never issues writes regardless of the DB role's grants).

### Cleanup port-forward when done

```bash
kill $PF_PID 2>/dev/null
```

---

## Verification checklist

Walk these checks after Step 10 — all should be ✓ for a successful install:

- [ ] All pods in `lucairn` + `dsa-*` namespaces report Ready (`kubectl get pods -A`)
- [ ] Customer mint returned `lcr_live_*` key
- [ ] First inference returned HTTP 200 with `pii_in_ai: false`
- [ ] `redaction_count` ≥ 4 on a payload with realistic PII (≥6 on the documented German clinical payload)
- [ ] Cert chain reports `signatures_valid: true`, `completeness: COMPLETENESS_FULL`, `overall_verdict: VERDICT_VERIFIED`
- [ ] 4 claims with types `TOKEN_GENERATED + PII_SANITIZED + INFERENCE_COMPLETED + EVENTS_RECORDED`
- [ ] No `missing_services` in the cert verdict

If all checks pass → your install is customer-ready.

---

## Cleanup port-forward when done

```bash
kill $PF_PID 2>/dev/null
unset DOCKER_CONFIG  # the temp directory will be cleaned by tmpwatch eventually
```

---

## Troubleshooting

### `helm install` times out at `--wait`

Check `kubectl get events -A --sort-by=.lastTimestamp | tail -20` for the most recent error.

Most common causes:
- `ImagePullBackOff`: GHCR PAT lacks `read:packages` scope, OR the PAT didn't land in the chart-managed Secret. Re-run Step 2 then `helm upgrade lucairn ./charts/lucairn -f customer-values.yaml --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json"`.
- `PVC Pending`: cluster has no default StorageClass. Either set one as default (`kubectl patch storageclass <name> -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`) OR override `gateway.keystore.persistence.storageClass` in `customer-values.yaml`.

### A pod is `CrashLoopBackOff`

Check its logs:
```bash
kubectl logs -n <ns> <pod-name> --tail=100
```

Most common causes:
- Missing REPLACE_* value: `customer-values.yaml` still has a `REPLACE_WITH_*` placeholder. Re-run Step 3 (`bash scripts/render-values.sh customer-values.yaml`) — but back up your edited customer-values.yaml first because render-values.sh overwrites the file.
- Invalid Anthropic key: `sk-ant-...` value is wrong. Fix in Step 4 + reinstall.

### Helm template fails with "v1.0 file-keystore mode requires gateway.replicaCount: 1"

You tried to flip a chart value that v1.0 explicitly forbids. The chart's umbrella validator enforces:
- `gateway.replicaCount`: must be 1 (multi-replica HA is v2.0)
- `gateway.hpa.enabled`: must be false
- `gateway.keystorePath`: must be non-empty
- `gateway.keystore.persistence.enabled`: must be true
- `veil-witness.replicaCount`: must be 1 (accumulator is in-memory per-pod)
- (Same for audit, id-bridge, sandbox-a, sandbox-b, admin, dashboard, ingest — every pod-local-state subchart)

Revert your flag flip and try again.

### Customer inference returns HTTP 503

Check the gateway pod logs:
```bash
kubectl logs -n dsa-edge deploy/gateway --tail=100 | grep -i error
```

Most common causes:
- Dependency probe failing: a downstream service is unhealthy. Check `/healthz` from inside the gateway pod for the JSON breakdown.
- Customer key invalid: re-check `Authorization: Bearer $CUSTOMER_KEY` header (no whitespace, no quotes).
- Anthropic API rate limit or invalid key: check upstream-side errors in `kubectl logs -n dsa-ai deploy/sandbox-b`.

### Cert chain shows `COMPLETENESS_PARTIAL`

The witness accumulator hasn't received all 4 claims yet. Causes:
- You checked too fast — wait the full 35 seconds in Step 10 before fetching the cert.
- Operator scaled a pod-local-state subchart > 1: claims split across replicas. Run `helm get values lucairn -n lucairn` and verify all `replicaCount: 1` invariants from the validator section above.

---

## v1.0 vs v2.0 (what's deferred)

This runbook ships v1.0 single-replica install. v2.0 will add:
- Multi-replica HA for gateway / witness / audit / bridge / sandbox-* (every service that currently holds pod-local state needs a shared-store refactor)
- Postgres-backed keystore via the chart's `postgres-gateway` subchart (currently opt-in via `postgres-gateway.enabled: true` + `gateway.postgresKeystore.enabled: true` + `gateway.replicaCount > 1` — but this opt-in is NOT verified for v1.0; use at your own risk)
- gRPC TLS between services via cert-manager (currently disabled — `global.grpcTlsEnabled: false`)
- Cilium NetworkPolicy enforcement (currently opt-in via `global.dnsRestriction: true` + `global.nodeIsolation: true`)

Until v2.0, do NOT flip `replicaCount > 1` on any of the pod-local-state subcharts — the chart's validator will reject the install.

---

## Pointers

- Chart: `charts/lucairn/` in this repo (main branch, merge commit `2558dbe9`)
- Render script: `scripts/render-values.sh`
- Customer-values template: `customer-values.yaml.example`
- Compose runbook (alternative install path): `docs/CUSTOMER_INSTALL_RUNBOOK.md` (if shipping the Compose option for the same pilot)

Questions / issues → file at `https://github.com/Declade/lucairn-enterprise-deployment-kit/issues`.
