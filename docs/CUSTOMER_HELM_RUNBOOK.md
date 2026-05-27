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

---

## Step 4 — Add your Anthropic API key

Open `customer-values.yaml` and find the line containing `REPLACE_WITH_YOUR_ANTHROPIC_KEY`. Replace with your real `sk-ant-...` key.

```bash
# Replace REPLACE_WITH_YOUR_ANTHROPIC_KEY with your real key:
sed -i.bak 's|REPLACE_WITH_YOUR_ANTHROPIC_KEY|sk-ant-XXXXXXX...|' customer-values.yaml
```

(Replace `sk-ant-XXXXXXX...` with your actual key.)

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

```bash
kubectl wait --for=condition=ready pod --all -A --timeout=10m
```

Expected: `condition met` for ~25 pods. Pods run across these namespaces:
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

## Step 9 — Send first inference

Port-forward the gateway so your local `curl` can reach it:

```bash
kubectl port-forward -n dsa-edge svc/gateway 8080:8080 &
PF_PID=$!
sleep 3
```

Send a request with realistic PII payload:

```bash
RESP=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer $CUSTOMER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-haiku-4-5",
    "max_tokens": 100,
    "messages": [{
      "role": "user",
      "content": "Patient Anna Schmidt, geb. 12.03.1978, Versicherungsnummer A4501289-DE, leidet an Hypertonie und Diabetes Typ 2."
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
  "redaction_count": 4,
  "veil_certificate_url": "http://localhost:8080/api/v1/veil/certificate/<request_id>/verify"
}
```

The customer's PII (name, DOB, Versicherungsnummer) was sanitized BEFORE the prompt reached Anthropic. Anthropic returned a response based on placeholders. Lucairn then re-linked the response (mapping placeholders back to the customer's view).

---

## Step 10 — Verify the cryptographic cert chain

Every inference produces a Veil Certificate proving sanitization happened + which services participated.

```bash
# Extract the request_id from the previous response
REQ_ID=$(echo "$BODY" | jq -r '.metadata.dsa_compliance.veil_certificate_url' | awk -F/ '{print $(NF-1)}')
echo "Request ID: $REQ_ID"

# Wait ~35 seconds for the witness accumulator to finalize
# (claims from bridge + sanitizer + ai + audit each arrive within ~30 sec)
sleep 35

# Fetch the cert chain verdict
CERT=$(curl -s -H "Authorization: Bearer $CUSTOMER_KEY" \
  http://localhost:8080/api/v1/veil/certificate/$REQ_ID/verify)

echo "$CERT" | jq '{
  signatures_valid,
  completeness,
  overall_verdict,
  claims_count: (.signed_claims | length),
  claims_types: [.signed_claims[]?.claim_type],
  missing_services
}'
```

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

## Verification checklist

Walk these checks after Step 10 — all should be ✓ for a successful install:

- [ ] All pods in `lucairn` + `dsa-*` namespaces report Ready (`kubectl get pods -A`)
- [ ] Customer mint returned `lcr_live_*` key
- [ ] First inference returned HTTP 200 with `pii_in_ai: false`
- [ ] `redaction_count` ≥ 4 on a payload with realistic PII
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
