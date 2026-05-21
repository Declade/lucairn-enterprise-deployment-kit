# Lucairn Enterprise Deployment Kit

Target release: `v1.3.0-customer-demo-data`

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
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
docker login ghcr.io
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

**Self-hosted with BYOK to a managed cloud LLM** (recommended for first install — no local GPU required, customer keeps their existing Anthropic/OpenAI/etc. account):

```bash
# license-bundle.json contains {"license_key":"…","signing_key":"…"} from Lucairn sales
bin/lucairn-init --production --license license-bundle.json --byok --output customer.env
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
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

GHCR images are private — `docker login ghcr.io` is required with the GHCR PAT Lucairn provides at customer-handoff (or mirror the images into your own registry and override `LUCAIRN_IMAGE_REGISTRY`). See `INSTALL.md` step 3. License keys are optional (kit runs in unregistered/dev mode without them — see `bin/lucairn-init --dev`).
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
helm upgrade --install lucairn charts/lucairn -f customer-values.yaml --namespace lucairn --create-namespace
```

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
