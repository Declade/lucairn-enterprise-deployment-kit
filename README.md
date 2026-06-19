# Lucairn Enterprise Deployment Kit

Target release: `v1.9.4`

This repository contains the customer-installable Lucairn deployment kit for first enterprise self-hosted installs. The operating rule is simple: customer IT installs and operates the stack; Lucairn support never needs shell access to the customer box.

## Contents

- `charts/lucairn/` - Helm chart for Kubernetes installs.
- `customer-values.yaml.example` - annotated Helm values.
- `docker-compose.customer.yml` - Docker Compose install path using prebuilt Lucairn images.
- `docker-compose.self-hosted.yml` - self-hosted inference overlay with model runtime profiles.
- `customer.env.example` - annotated Compose env file.
- `model-manifest.example.yaml` - runtime-neutral model manifest template.
- `apps/dashboard/` - Lucairn Enterprise Dashboard (opt-in operator UI; local-admin sign-in + OIDC SSO + cert browser + cert inspector + audit-defensibility-grade live validator + bulk re-verify + server health overview with embedded Grafana panels + API key management: mint, rotate, revoke, bulk-revoke + audit log browser: filter, paginate, save filters, CSV export, admin-only raw-PII reveal with paired `audit.reveal_raw` event + compliance PDF export: AI Act 3-category structure, fail-closed banned-literal guard, per-generation audit emit).
- `bin/lucairn` - customer CLI with `doctor` and `support-bundle`.
- `bin/lucairn bundle create/prepare/verify` - per-customer bundle builder, agent package factory, and verifier.
- `bin/lucairn-init` - one-command env file generator with Ed25519 pair derivation and `--dev` / `--production` modes.
- `bin/lucairn-mint-customer` - mints first customer + `lcr_live_*` API key against a running gateway.
- `migrations/`, `config/`, `starter-templates/` - runtime assets needed by the Compose path.
- `INSTALL.md`, `OPS.md`, `TROUBLESHOOTING.md` - day-1 and day-2 runbooks.
- `docs/` - enterprise support, SDK, mirror, clean-host rehearsal, customer bundle, handoff gates, DPA, and vendor-assisted install notes.

## Fast Path

The kit supports two deployment modes — **self-hosted inference** (Sandbox B
runs as a local container alongside a model runtime) and **split deployment**
(Sandbox B runs on Lucairn-hosted infrastructure, gateway dials it per
request). Pick the right mode before running `docker compose up`; see
`INSTALL.md` § "Choose A Deployment Mode" for the decision table and the
required env vars per mode.

Split-deployment fast path:

```bash
cp customer.env.example customer.env
# Edit customer.env — every REPLACE_ME_* placeholder must be filled in before
# the live doctor pass below. The offline doctor catches placeholder values
# (intentional: that's the gate that surfaces every secret you owe).
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
# Authenticate against ghcr.io (one-time per host; see INSTALL.md § "Registry Authentication" for first-time PAT setup)
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

**Self-hosted with BYOK to a managed cloud LLM** (recommended for first install — no local GPU required, customer keeps their existing Anthropic/OpenAI/etc. account):

```bash
# license-bundle.json from Lucairn sales. Required: license_key + signing_key
# (HMAC platform license). Optional: entitlement_token + entitlement_public_key
# (Ed25519 deployment entitlement) → LUCAIRN_LICENSE_KEY + LUCAIRN_LICENSE_PUBLIC_KEY.
# {"license_key":"…","signing_key":"…","entitlement_token":"…","entitlement_public_key":"…"}
bin/lucairn-init --production --license license-bundle.json --byok --output customer.env
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
# Authenticate against ghcr.io (one-time per host; see INSTALL.md § "Registry Authentication" for first-time PAT setup)
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  -f docker-compose.self-hosted-byok.yml \
  --env-file customer.env \
  up -d
```

**Dev / evaluation install** (no license required; runs in unregistered mode):

```bash
bin/lucairn-init --dev --output customer.env
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
# Authenticate against ghcr.io (one-time per host; see INSTALL.md § "Registry Authentication" for first-time PAT setup)
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
docker compose \
  -f docker-compose.customer.yml \
  -f docker-compose.self-hosted.yml \
  --env-file customer.env \
  up -d
```

**Fully self-hosted inference** (local GPU, customer supplies model files): add `--profile "$MODEL_RUNTIME_PROFILE"` to the `docker compose up` command, where `MODEL_RUNTIME_PROFILE` is one of `llama-cpp` / `vllm` / `tgi` / `ollama` / `onnxruntime` / `triton` / `custom-runtime`. See `docker-compose.self-hosted.yml` for required model env vars.

After the stack is healthy, mint your first customer API key. The mint
binary needs the admin key from `customer.env` — export it first:

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"
./bin/lucairn-mint-customer --name "Acme GmbH" --email "ops@acme.de" --tier enterprise
```

If you intend to use `X-Upstream-Key` (BYOK to managed cloud LLM) for
inference, also load `-f docker-compose.self-hosted-byok.yml` on the
compose `up -d` line above and populate `ANTHROPIC_API_KEY` (or
`OPENAI_API_KEY`) in `customer.env` first. See `INSTALL.md` § "Self-hosted
with managed LLM (BYOK)".

**Step 0 — Registry access required first:** GHCR images are currently private. A GitHub PAT with `read:packages` scope is NOT sufficient on its own — Lucairn must GRANT your GitHub account package-pull access. Email support@lucairn.eu with your GitHub username and wait for confirmation BEFORE minting a PAT or running `docker login`. See `INSTALL.md` § "Step 0 — Registry access" for the full sequence. Save the PAT to a 0600 file (`~/.ghcr-token`) then run `docker login ghcr.io -u <github-username> --password-stdin < ~/.ghcr-token`. Override `LUCAIRN_IMAGE_REGISTRY` if you mirror into a private registry. License keys are optional (kit runs in unregistered/dev mode without them — see `bin/lucairn-init --dev`).
Before a real customer handoff, run the gates in `docs/CUSTOMER_HANDOFF_GATES.md`.

## Per-Customer Bundle

For enterprise installs with customer-specific model files, prepare one sealed bundle:

```bash
bin/lucairn bundle create \
  --customer-slug acme \
  --models-dir /secure/staging/acme/models \
  --model-manifest /secure/staging/acme/model-manifest.yaml \
  --env /secure/staging/acme/customer.env \
  --image-tar /secure/staging/acme/lucairn-images.tar \
  --output dist/customer-bundles

bin/lucairn bundle verify --bundle dist/customer-bundles/lucairn-customer-bundle-acme-*.tar.gz
```

The bundle includes model files, checksums, customer env, Compose files, runtime assets, and customer install notes. Supported runtime profiles include `llama-cpp`, `vllm`, `tgi`, `ollama`, `onnxruntime`, `triton`, and `custom-runtime`.

Codex or Claude Code can create the same package from a standard staging directory:

```bash
bin/lucairn bundle prepare \
  --customer-slug acme \
  --staging-dir /secure/staging/acme \
  --output /secure/outbound/acme
```

That command creates the bundle, verifies it, includes optional staged `customer-data/`, and writes a non-secret agent report. See `docs/AGENT_CUSTOMER_PACKAGING.md`.

For Kubernetes:

```bash
cp customer-values.yaml.example customer-values.yaml
helm dependency build charts/lucairn
helm upgrade --install lucairn charts/lucairn \
  -f customer-values.yaml \
  --set-file global.imagePullDockerConfigJson="$DOCKER_CONFIG/config.json" \
  --namespace lucairn --create-namespace
```

The `--set-file global.imagePullDockerConfigJson=...` flag is required —
the chart guards against missing pull-secret payloads and `helm` will
refuse to render without it. See `INSTALL.md` § "Kubernetes Install"
for the full prerequisite recipe (`DOCKER_CONFIG` staging, GHCR PAT,
etc.).

## Support Bundle

```bash
bin/lucairn support-bundle --env customer.env --compose docker-compose.customer.yml
```

The bundle is redacted, but the customer must review it before emailing it to Lucairn support.

## Customer Handoff Gates

No customer should receive an install package until:

- `bin/lucairn bundle verify` passes for the exact tarball being sent.
- `bin/lucairn doctor --offline` passes on the extracted bundle.
- image delivery is decided and tested as either registry, tar archive, or customer mirror.
- the model runtime mode is explicit: external OpenAI-compatible endpoint or bundled self-hosted runtime.
- the recipient, channel, checksum, and install owner are recorded in the engagement handoff note.

See `docs/CUSTOMER_HANDOFF_GATES.md` and `docs/CLEAN_HOST_REHEARSAL.md`.
