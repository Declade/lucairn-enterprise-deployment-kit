# TROUBLESHOOTING

## Compose Refuses to Start

Run:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env config --quiet
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
```

Common causes:

- Missing `DSA_SERVICE_TOKEN`.
- `GATEWAY_KEYSTORE_KEY` is not base64 32 bytes.
- A required Veil key is blank.
- Host port 8080 or 8085 is already in use.
- GHCR images fail to pull. The default `ghcr.io/declade/*` Lucairn images are private — a 401 / `unauthorized` from `docker pull` means either you have not yet authenticated, OR your GitHub account has not been granted package-pull access by Lucairn. First contact support@lucairn.eu with the GitHub username you will use for the install if you have not already; Lucairn provisions package access typically within one business day. Then mint a GitHub PAT with the `read:packages` scope, save it to a 0600 file (`umask 077; cat > ~/.ghcr-token <<'EOF' ... EOF; chmod 600 ~/.ghcr-token`), and run `docker login ghcr.io -u <github-username> --password-stdin < ~/.ghcr-token`; see `INSTALL.md` § "Registry Authentication". If the install uses a private mirror, `docker login` against the mirror credentials and set `LUCAIRN_IMAGE_REGISTRY` to the mirror prefix. Transient pull failures (TCP timeout / EOF) usually mean network egress restriction on the host rather than auth. If kubectl pods fail with `ImagePullBackOff` after a successful `docker login`, you likely missed replicating the `lucairn-registry` Secret into every workload namespace — see `INSTALL.md` § "Kubernetes Install" step 1 for the canonical namespace loop.

## Docker / OrbStack: "All Predefined Address Pools Have Been Fully Subnetted"

If `docker compose up -d` fails with `Error response from daemon: all predefined address pools have been fully subnetted` (or hangs creating networks), Docker has exhausted its bridge-network subnet pool. This is most common on macOS / OrbStack where many transient compose stacks accumulate during development, but it can also bite Linux hosts running Docker Engine with the default address pool (defaults to 30 networks).

Diagnose:

```bash
docker network ls | wc -l   # >> 20 strongly suggests pool pressure
docker network ls | grep -E '_default$'   # list compose-project leftovers
```

Recover (prunes networks with no active containers; safe):

```bash
docker network prune -f
```

If the prune doesn't free enough subnets (rare — only on Linux with very small `default-address-pools` config), expand the pool in `/etc/docker/daemon.json`:

```json
{
  "default-address-pools": [
    {"base": "172.17.0.0/12", "size": 24}
  ]
}
```

Restart the daemon (`sudo systemctl restart docker` on Linux; OrbStack handles this automatically on relaunch). Re-run `docker compose up -d`.

## Sandbox B Refuses Insecure Port / Gateway Sandbox B Health-Check TLS Handshake Failure

If sandbox-b crash-loops with `CRITICAL sandbox-b GRPC_TLS_ENABLED=true (with cert/key) is required when DSA_ENV=production; refusing insecure port`, or the gateway's `/healthz` shows `sandbox_b: status=fail` with `tls: first record does not look like a TLS handshake`, the stack is running in production-env defaults without real TLS certs.

This is the dev-mode boot sequence — the kit's `customer.env.example` ships with `DSA_ENV=production` and `GRPC_TLS_ENABLED=true` so production installs are safe by default, but local-laptop / sandbox / acceptance-test installs need three env flips to start cleanly without provisioning certificates:

```
DSA_ENV=development
GRPC_TLS_ENABLED=false
DSA_LICENSE_KEY=
DSA_LICENSE_SIGNING_KEY=
```

The first two relax the production-only gRPC mTLS gate (sandbox-b's `inference_server.py` refuses an insecure port when `DSA_ENV=production`). The last two engage the gateway's dev-mode license bypass (see next section). After flipping all four, recreate the affected services:

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --env-file customer.env \
  up -d --force-recreate sandbox-a sandbox-b id-bridge audit veil-witness sanitizer gateway
```

For a production install, leave the four defaults alone and provision real Lucairn-signed license + gRPC mTLS material instead.

## Gateway Restart-Loops On Invalid License Key

If the gateway log shows `invalid license key: malformed license key` and the container is restart-looping, `DSA_LICENSE_KEY` in `customer.env` is set to a non-empty value that does not validate against `DSA_LICENSE_SIGNING_KEY`.

Two valid states:

- **Empty (`DSA_LICENSE_KEY=`):** the gateway enters dev mode (no license enforcement; a `WARNING: no license key configured — running in unregistered/dev mode` line is logged on boot). Intended for local sandbox / development. Pair with `DSA_ENV=development` in `customer.env` so the production-only env gates (mTLS, readiness bundle) also relax.
- **Lucairn-provisioned signed token:** the production path. Get this from Lucairn at customer-onboarding time; pair with `DSA_LICENSE_SIGNING_KEY` (also provided by Lucairn). The gateway validates the token and enforces tier limits, expiry, and feature flags.

Placeholder strings like `REPLACE_WITH_LICENSE_KEY` or `DEMO_LICENSE_NEEDS_LUCAIRN_PROVISIONED` are the **worst case** — non-empty enough to skip the dev-mode bypass, but not a real signed token, so HMAC validation rejects them. Either leave the field empty (dev mode) or set a real Lucairn-provisioned value (prod mode).

## App-Role Password Authentication Fails (`audit_app`, `veil_app`)

If `audit` or `veil-witness` containers crash-loop with `pq: password authentication failed for user "audit_app" (28P01)` (or the equivalent for `veil_app`), the database role's password is out of sync with the application connection string.

This is usually a customer.env vs migration mismatch. The kit's compose connection strings read from `AUDIT_APP_PASSWORD` / `VEIL_APP_PASSWORD` (customer.env). The role passwords are set at migration-prep time by `scripts/render-migrations.sh` (invoked by the `prep-migrations` compose service), which materializes `migrations/<tree>/000NNN_*.up.sql.tmpl` into the `rendered-migrations` named volume with the runtime password substituted.

Confirm the prep service ran:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env logs prep-migrations
```

Expected: `render-migrations: audit rendered to /migrations-rendered/audit` ... `render-migrations: done`. If the volume is stale (left over from a pre-fix deploy), force a clean re-run:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env down
docker volume rm "$(docker compose -f docker-compose.customer.yml --env-file customer.env config --volumes | grep -E '^rendered-migrations$' || echo rendered-migrations)" || true
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

If `prep-migrations` itself failed (look for `AUDIT_APP_PASSWORD is empty` or `contains a single quote`), fix the corresponding env var in `customer.env` (alphanumeric + URL-safe special chars only; no `'` and no `\`) and re-run.

## Gateway Unhealthy

Check:

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 gateway
curl -v http://127.0.0.1:8085/healthz
curl -v http://127.0.0.1:8085/readyz
```

Likely causes:

- Bridge or Sandbox A is not ready.
- Remote Sandbox B endpoint is unreachable.
- License values are missing.
- Witness manifest path is configured but the file is not mounted.

## Gateway fatals on a missing witness-signed manifest (production Helm)

If the gateway exits with `cannot read witness-signed manifest` at
`/certs/witness-signed-manifest.json`, do not disable Veil, blank the path, or
substitute JSON. Production startup verifies a witness signature over the
active public-key roster.

Complete the ceremony in `docs/KEY_CEREMONY_RUNBOOK.md` §6, then create (or
atomically replace) only its signed output in the dedicated gateway Secret:

```bash
kubectl -n dsa-edge create secret generic lucairn-witness-signed-manifest \
  --from-file=witness-signed-manifest.json=/secure/ceremony/witness-signed-manifest.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dsa-edge rollout restart deployment/gateway
kubectl -n dsa-edge rollout status deployment/gateway --timeout=6m
```

The complete customer values contract is:

```yaml
gateway:
  veilWitnessSignedManifestPath: /certs/witness-signed-manifest.json
  witnessSignedManifest:
    existingSecret: lucairn-witness-signed-manifest
    secretKey: witness-signed-manifest.json
    mountPath: /certs
    fileName: witness-signed-manifest.json
```

Run `bin/lucairn doctor --values charts/lucairn/values-prod.yaml --values customer-production-values.yaml --offline`
before retrying. The order must match Helm: parent production values first,
then the customer overlay. In production with Veil enabled, Helm rejects a missing or
partial block and any projected-path mismatch before it contacts the cluster.

## `/healthz` Returns 200 But `/readyz` Returns 503

This is the most common "deployed but unusable" failure mode on a fresh install.
`/healthz` returns 200 as soon as the gateway process is listening on its port —
even if upstream service-link circuit breakers (sanitizer, witness, audit,
sandbox-b, bridge, identity) are open. Only `/readyz` reflects the full readiness
state. A `docker compose ps` row showing `(healthy)` therefore is not sufficient
evidence the gateway can actually serve traffic.

`bin/lucairn doctor` now probes both endpoints after the pre-deploy checks and
surfaces a 503 readyz with the specific recovery commands. To make doctor exit
non-zero on a 503 (e.g. in CI), pass `--strict-runtime`.

Common root causes on a fresh deploy:

- `SANDBOX_B_REMOTE_ENDPOINT` defaults to `https://inference.lucairn.example`,
  which is DNS-resolvable but never reachable. Split-deployment customers must
  set this to a Lucairn-provisioned endpoint. Self-hosted-inference customers
  must load `docker-compose.self-hosted.yml` so `SANDBOX_B_REMOTE_ENDPOINT` is
  blanked and the local `sandbox-b` container is added to the stack.
- Sanitizer config references recognizers not present in the deployed image
  (image-version drift). The sanitizer container crash-loops and the gateway's
  sanitizer circuit breaker opens.
- Bridge or witness signing keys are mismatched, so claim verification fails
  during the first request that hits each path.

## Sanitizer Slow to Become Ready

The sanitizer can take longer on first boot while models load.

```bash
docker compose -f docker-compose.customer.yml --env-file customer.env logs --tail 300 sanitizer
```

If memory pressure appears, raise the container memory limit. The Compose kit defaults to 2 GB for sanitizer.

## pii-ml Sidecar Slow to Become Ready After Enabling Phase 7

> **Only applies if you have OPTED IN to Phase 7 ML.** Phase 7 is
> **disabled by default** as of chart v1.7.1 — a default install does not
> deploy the pii-ml sidecar and the sanitizer starts in seconds with no
> ML dependency. This section is relevant only after you re-enable Phase 7
> (Helm `pii-ml.enabled: true` + sanitizer flags, or Compose
> `--profile phase7`).

Symptom: after enabling Phase 7, `docker compose --profile phase7 ps`
(Compose) or `kubectl get pods -n dsa-identity` (Helm) shows the
**`pii-ml` sidecar** in `Created` / `(starting)` / `(not ready)` for
3-8 minutes on its first cold-cache boot while it downloads and loads the
ML model weights. The **sanitizer itself stays up and `(healthy)`** during
this window — it does NOT block on the sidecar — and the gateway's
`/readyz` returns 200. Phase 7 ML scans fail-OPEN (circuit-open degrade)
until the sidecar finishes loading; the deterministic L1+L2 layers run the
whole time, so PII is still redacted and certs are still anchored.

Cause: Phase 7 ML PII scanners (Piiranha + GLiNER) shipped at PR #240 as
a dedicated `pii-ml` gRPC sidecar (opt-in as of v1.7.1). On first
cold-cache boot, the sidecar downloads ~1.6GB of HuggingFace model
weights (Piiranha ~110MB, GLiNER primary ~1.5GB) and eager-loads both
into memory. The sanitizer has **no hard dependency on pii-ml on either
path** — there is no `depends_on: pii-ml` on the Compose `sanitizer`
service and no readiness gate against the sidecar on the Helm `sandbox-a`
Deployment, so the sanitizer starts independently in seconds. It dials the
sidecar lazily at request time; its `pii_ml_client` circuit breaker returns
a circuit-open degrade until the sidecar's own `/readyz` flips to 200. The
pii-ml compose healthcheck `start_period` covers a warm-cache boot;
cold-cache first-install can run to 5-8 minutes on constrained network
egress — but only the **sidecar** is affected, never the sanitizer.

Diagnose:

```bash
# Compose path — watch HF weight downloads stream into the named volume.
# pii-ml is gated behind the `phase7` profile (v1.7.1), so the profile must
# be active for these commands to target it.
docker compose --profile phase7 -f docker-compose.customer.yml --env-file customer.env \
  logs -f pii-ml | grep -E 'booting|loading|ready|error'

# Helm path — same markers from the kubelet log stream
kubectl logs -n dsa-identity deploy/pii-ml --tail=200 -f \
  | grep -E 'booting|loading|ready|error'

# Look for these markers in order:
#   "pii-ml booting"           — startup begin
#   "loading piiranha @ <SHA>" — HF fetch + model load (~5-30s warm, 1-3 min cold)
#   "loading gliner @ <SHA>"   — HF fetch + model load (~30-90s warm, 3-6 min cold)
#   "ready"                    — both loaded, readyz flipped to 200
```

If logs stall on `loading piiranha @ <SHA>` for > 5 minutes, check
network egress to `huggingface.co` from the sidecar container/pod —
operators with restrictive corporate proxies need to allowlist
`huggingface.co` + `cdn-lfs.huggingface.co`.

If the pii-ml container exits and restart-loops with `sys.exit(2)` or
`sys.exit(3)`, the HF cache is corrupted or the weights download was
interrupted mid-write. Recover by removing the named volume + bringing
the stack back up to re-download from scratch:

```bash
# Compose path (pii-ml is profile-gated — keep --profile phase7 active)
docker compose --profile phase7 -f docker-compose.customer.yml --env-file customer.env stop pii-ml
docker volume rm "$(docker compose --profile phase7 -f docker-compose.customer.yml --env-file customer.env config --volumes | grep pii-ml-hf-cache || echo pii-ml-hf-cache)"
docker compose --profile phase7 -f docker-compose.customer.yml --env-file customer.env up -d pii-ml

# Helm path: delete the pod (the emptyDir cache vanishes with it)
kubectl delete pod -n dsa-identity -l app.kubernetes.io/name=pii-ml
```

On air-gapped sites where huggingface.co is unreachable: see
`OPS.md` § "pii-ml sidecar — HF cache PVC" for the pre-staged-weights
recipe.

Drop back to the default profile: if a re-enabled Phase 7 is causing
operational problems and you need to return to the default L1+L2(+L3)
configuration, see `OPS.md` § "Phase 7 is OFF by default (chart v1.7.1)"
for the both-gates-off recipe.

## Certificate Errors

Run:

```bash
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
bin/lucairn doctor \
  --values charts/lucairn/values-prod.yaml \
  --values customer-production-values.yaml \
  --offline
openssl x509 -noout -subject -issuer -dates -in path/to/cert.pem
```

Common causes:

- Wrong CA bundle for remote Sandbox B.
- Client cert and key do not match.
- Cert expires within 30 days.
- Witness mTLS files are mounted into the wrong directory.
- A production Helm identity Secret is missing one of `ca.crt`, `tls.crt`, or
  `tls.key`. The Pod must stay unready; do not bypass the projected Secret with
  a plaintext or legacy-TLS override.
- The leaf SAN does not match its identity (`dsa-audit`, `dsa-id-bridge`,
  `dsa-sandbox-a`, `dsa-sanitizer`, `dsa-sandbox-b`, or
  `dsa-veil-witness`). Reissue the leaf; do not disable server verification.

## Image / Config Version Drift

The kit ships a single pinned set of container image versions plus matching
config files (sanitizer recognizers, witness manifest paths, signing-key
formats). `image-manifest.yaml` records the known-good combination this kit
release was tested against.

Symptoms of drift:

- Sanitizer container crash-loops on `ValueError: Unknown recognizer '...'`
  during boot. The kit's `config/default-sanitizer.yaml` references a
  recognizer the deployed sanitizer image does not ship. Either roll the
  sanitizer image forward to a tag that supports the recognizer, or remove
  the unsupported recognizer from `config/default-sanitizer.yaml`.
- Gateway returns 401 from upstream LLM despite a known-good API key. The
  gateway image's BYOK forwarding adapter changed shape between releases.
  Roll the gateway image to a tag the kit was tested against.
- Witness rejects every claim with `canonical_payload mismatch`. Signing
  keys are correct but the canonical-payload byte order changed between
  image versions (rare, only after a major-version bump).

Diagnose:

```bash
# Read what the kit expects
cat image-manifest.yaml

# Compare with what is actually deployed. Use `docker compose` (with the same
# -f / --env-file flags you ran `up` with) so the lookup is independent of the
# project-name prefix Compose derives from your install directory — hardcoded
# container names like `deploy-gateway-1` only match if your directory happened
# to be named `deploy`.
docker compose -f docker-compose.customer.yml --env-file customer.env images gateway sanitizer
```

`bin/lucairn doctor` warns when `LUCAIRN_IMAGE_TAG` in `customer.env` differs
from the manifest's `default_lucairn_image_tag`. The warning is non-blocking:
operators can intentionally roll images forward or back, but the warning
ensures they know they are off the tested combination.

## Mint Rejects `byok_per_request` On Pre-0.4.x Gateway Images

If `bin/lucairn-mint-customer --byok-per-request` returns `HTTP 400 invalid_field: Field 'provider_key' has an invalid value: required when managed_ai is false`, the gateway image in use is pre-Stage-3 (image tag `<0.4.0`) and does not yet honor the BYOK-per-request short-circuit. The mint payload requires a non-empty `provider_key` whenever `managed_ai` is false on those images.

Three working paths:

- Re-run with `--provider-key "<placeholder-or-real-upstream-key>"`. The placeholder is a non-secret marker — the gateway treats it as the stored upstream-key slot, and per-request BYOK still works at the SDK layer when the customer supplies their real key in the request.
- Re-run with `--tier enterprise --managed-ai` for the Lucairn-managed-LLM Enterprise path (Pro-tier rejects `--managed-ai`).
- Re-run with `--provider ollama` for a local-Ollama runtime (no upstream key required).

The script prints the same three options inline whenever it sees this error. Upgrading to a gateway image at or after `0.4.0` removes the workaround.

## Sandbox B Cannot Reach `api.anthropic.com` (Or Other Managed-LLM Endpoint)

Symptom: Sandbox B logs `Connection refused` / `name resolution failed` /
`connect: network is unreachable` when calling Anthropic / OpenAI /
Mistral / Gemini / Azure OpenAI / etc.

Cause: the base `docker-compose.self-hosted.yml` overlay attaches Sandbox B
only to `internal: true` bridges. That is correct for a local-model
runtime but blocks all outbound egress, including managed-LLM calls.

Fix: load the BYOK overlay on top of the customer + self-hosted overlays.

```bash
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  --profile "$MODEL_RUNTIME_PROFILE" \
  up -d
```

Populate the managed-LLM block in `customer.env` first (see
`customer.env.example`). Required: `LUCAIRN_LLM_EGRESS_ALLOWLIST` plus at
least one provider key (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …).

Verify outbound reach from inside the container. A 401 is the expected
pass — name resolution + TCP both worked, only the dummy key was rejected:

```bash
# Use `docker compose exec <service>` (with the same -f / --env-file flags you
# ran `up` with) rather than a hardcoded container name like
# `lucairn-sandbox-b-1` — Compose derives the container-name prefix from your
# install directory, so the hardcoded name only matches a `lucairn`-named dir.
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  exec sandbox-b \
  curl -sS -o /dev/null -w "%{http_code}\n" \
  https://api.anthropic.com/v1/messages
# Expect: 401  (NOT 0 / NXDOMAIN / connection refused)
```

If you still see 0 / NXDOMAIN after loading the BYOK overlay, your host
firewall or DNS layer (Cilium / forward proxy / iptables) is dropping the
traffic — that is the operator-side enforcement working as designed.
Adjust the operator's network policy allowlist to match
`LUCAIRN_LLM_EGRESS_ALLOWLIST` in `customer.env`.

The BYOK overlay opens the topology; the operator enforces which FQDNs
are reachable. See INSTALL.md § "Self-hosted with managed LLM (BYOK)" for
the responsibility split.

## `lucairn doctor` Reports `identity networks: failed`

Symptom: `doctor` exits non-zero with a line like
`identity networks: failed (dsa-identity, dsa-audit-identity not internal:true)`.

Cause: an operator (or merge conflict) removed `internal: true` from one
or more identity-plane bridge networks in `docker-compose.customer.yml`.

Threat model: Sandbox A holds the raw-PII-to-pseudonym mapping. The
architectural claim "no raw identity data leaves your environment" is
enforced at two layers:

1. **Code-level air-tightness.** `services/sandbox-a/` and
   `services/id-bridge/` originate zero outbound HTTP calls — verified by
   `grep -RIn -E "(http|requests|httpx|urllib|fetch|aiohttp)"` against
   the upstream source. The only outbound HTTP client in Sandbox A
   dials `sanitizer:8086` (intra-network, reachable via internal-only
   `dsa-identity`).
2. **Network-level lockdown.** The bridges those services join are
   declared `internal: true` so the Docker bridge driver refuses to
   route packets between the bridge and the host network namespace.
   This is defence-in-depth: a future code regression that introduced
   an outbound dialer would still be blocked by the network layer.

Restoring `internal: true` on the named networks closes the gap. The
required-internal list lives in `bin/lucairn` (`check_identity_networks_internal`)
and currently covers `dsa-identity`, `dsa-audit-identity`, and
`dsa-certification`. The other bridges (`dsa-bridge`, `dsa-witness-edge`)
intentionally stay non-internal because the gateway needs outbound to
the remote Sandbox B endpoint (split deployment), TSA (FreeTSA), Rekor
(Sigstore), and the optional Supabase / Lucairn control-plane endpoints.

If you have a legitimate reason to allow outbound from an identity-plane
bridge — e.g. a sidecar that needs to call an external KMS — DO NOT
remove `internal: true` from the named bridge. Instead:

- Move that sidecar onto its own non-internal bridge with documented
  FQDN allowlist enforcement (mirror the `dsa-egress` pattern from the
  BYOK overlay).
- Document the operator-side enforcement responsibility in the deploy
  runbook so the compliance team can sign off.

## Generating a Support Bundle

```bash
bin/lucairn support-bundle --env customer.env --compose docker-compose.customer.yml
```

The generated archive includes:

- Version metadata.
- Redacted env file.
- Redacted compose file and resolved compose config when available.
- Container status.
- Logs.
- Certificate validity report.
- Schema-version placeholder or available schema notes.

Review the archive before sending it to Lucairn support.
