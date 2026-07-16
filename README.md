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
- `bin/lucairn-init` - one-command env and runtime-profile generator with Ed25519 pair derivation.
- `bin/lucairn-mint-customer` - mints first customer + `lcr_live_*` API key against a running gateway.
- `migrations/`, `config/`, `starter-templates/` - runtime assets needed by the Compose path.
- `INSTALL.md`, `OPS.md`, `TROUBLESHOOTING.md` - day-1 and day-2 runbooks.
- `CHANGELOG.md` - per-release notes (kit version ↔ image tag).
- `SECURITY.md` - how to report a vulnerability + where security advisories are published.
- `docs/` - enterprise support, SDK, mirror, clean-host rehearsal, customer bundle, handoff gates, DPA, and vendor-assisted install notes.

## Fast Path

The kit supports three explicit runtime modes: **split-remote** (Sandbox B runs
on Lucairn-hosted infrastructure), **managed-byok** (Sandbox B calls a
customer-managed cloud provider), and **local-runtime** (Sandbox B runs beside
a named local model runtime). Pick the mode before running `docker compose up`; see
`INSTALL.md` § "Choose A Deployment Mode" for the decision table and the
required env vars per mode.

Split-deployment fast path:

```bash
bin/lucairn-init --production --runtime-mode split-remote \
  --remote-endpoint https://inference.customer.example \
  --remote-credentials /secure/lucairn-issued-remote-credentials.env \
  --license license-bundle.json --output customer.env
# Init also writes customer.env.runtime-profile.yaml and the recorded
# customer.env.image-manifest.yaml. Keep both beside customer.env.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
# Authenticate against ghcr.io (one-time per host; see INSTALL.md § "Registry Authentication" for first-time PAT setup)
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
bin/lucairn up --env customer.env
```

**Self-hosted with BYOK to a managed cloud LLM** (recommended for first install — no local GPU required, customer keeps their existing Anthropic/OpenAI/etc. account):

```bash
# license-bundle.json from Lucairn sales. Required: license_key + signing_key
# (HMAC platform license). Optional: entitlement_token + entitlement_public_key
# (Ed25519 deployment entitlement) → LUCAIRN_LICENSE_KEY + LUCAIRN_LICENSE_PUBLIC_KEY.
# {"license_key":"…","signing_key":"…","entitlement_token":"…","entitlement_public_key":"…"}
bin/lucairn-init --production --runtime-mode managed-byok \
  --license license-bundle.json --output customer.env
# Init intentionally leaves provider keys empty and skips doctor. Set at least
# one provider key in customer.env before running doctor (for example,
# ANTHROPIC_API_KEY, OPENAI_API_KEY, MISTRAL_API_KEY, or GEMINI_API_KEY).
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
# Authenticate against ghcr.io (one-time per host; see INSTALL.md § "Registry Authentication" for first-time PAT setup)
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
bin/lucairn up --env customer.env
```

**Dev / evaluation install** (no license required; runs in unregistered mode):

```bash
# Lucairn does not ship weights: stage a licensed compatible GGUF first.
mkdir -p models
cp /secure/models/customer-model-q4.gguf models/customer-model-q4.gguf
bin/lucairn-init --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name customer-model --model-file customer-model-q4.gguf --model-path . \
  --output customer.env
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
# Authenticate against ghcr.io (one-time per host; see INSTALL.md § "Registry Authentication" for first-time PAT setup)
docker login ghcr.io -u <your-github-username> --password-stdin < ~/.ghcr-token
bin/lucairn up --env customer.env
```

**Fully self-hosted inference** (local GPU, customer supplies model files): select the named runtime during init with `--runtime-mode local-runtime --local-runtime <name>`, stage the required weights yourself, then use `bin/lucairn up --env customer.env`. Lucairn does not ship model weights. Supported names are `llama-cpp`, `vllm`, `tgi`, `ollama`, `onnxruntime`, `triton`, and `custom-runtime`. Init writes the non-secret `customer.env.runtime-profile.yaml` manifest and `customer.env.image-manifest.yaml` recorded snapshot; its model inventory is operator-declared and `required-not-verified` until later model-completeness checks, so it does not claim that a model file was supplied. `doctor`, lifecycle wrappers, support bundles, backup, and restore read its fixed overlay order and recorded image snapshot.

For every S1-generated Compose install, keep `customer.env.runtime-profile.yaml`
and `customer.env.image-manifest.yaml` beside `customer.env`. A marker-bearing
env without either sidecar fails closed;
only genuinely pre-S1 installs without the marker are legacy installs until an
operator explicitly adopts the profile. The kit is operated from supported
Linux/macOS shells with Docker Compose or Kubernetes. It is not a Windows
client installer; that end-user surface belongs to WP5.

For S1 installs, use `bin/lucairn up|down|status|logs|pull --env customer.env`
instead of hand-writing Compose flags. They replay the recorded overlay/profile
set; `down` never deletes volumes and `logs` accepts only a bounded numeric
tail plus an optional safe service name. `pull` then `up` is the profile-bound
upgrade fetch/apply path. Exact release rollback and restore history remain
WP4 S4 work; S1 does not claim them complete.

After the stack is healthy, mint your first customer API key. The mint
binary needs the admin key from `customer.env` — export it first:

```bash
export LUCAIRN_ADMIN_KEY="$(grep '^DSA_ADMIN_KEY=' customer.env | cut -d= -f2-)"
./bin/lucairn-mint-customer --name "Acme GmbH" --email "ops@acme.de" --tier enterprise
```

Store the printed key in an existing mode-0600 file (for example
`/secure/lucairn-customer.key`) and then run the post-start full doctor. For
`split-remote` and `managed-byok`, supply the exact operator-selected model;
`local-runtime` uses only the one recorded model name from the S1 inventory.

```bash
# Add --model <selected-model> for split-remote or managed-byok only.
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml \
  --customer-key-file /secure/lucairn-customer.key
```

`doctor --offline` is configuration-only and ends with `doctor: preflight ok
(offline)`. Health/readiness remain diagnostics; `doctor: ok` means the
authenticated inference, certificate, and limited witness-verification journey
completed (anchors are not checked).

If you intend to use `X-Upstream-Key` (BYOK to managed cloud LLM) for
inference, also load `-f docker-compose.self-hosted-byok.yml` on the
compose `up -d` line above and populate `ANTHROPIC_API_KEY` (or
`OPENAI_API_KEY`) in `customer.env` first. See `INSTALL.md` § "Self-hosted
with managed LLM (BYOK)".

**Step 0 — Registry access required first:** GHCR images are currently private. A GitHub PAT with `read:packages` scope is NOT sufficient on its own — Lucairn must GRANT your GitHub account package-pull access. Email support@lucairn.eu with your GitHub username and wait for confirmation BEFORE minting a PAT or running `docker login`. See `INSTALL.md` § "Step 0 — Registry access" for the full sequence. Save the PAT to a 0600 file (`~/.ghcr-token`) then run `docker login ghcr.io -u <github-username> --password-stdin < ~/.ghcr-token`. Override `LUCAIRN_IMAGE_REGISTRY` if you mirror into a private registry. License keys are optional (kit runs in unregistered/dev mode without them — see the development runtime-mode command above).
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

For an S1-generated staging directory, place
`customer.env.runtime-profile.yaml` and `customer.env.image-manifest.yaml`
beside `customer.env`. For local-runtime, the declared name and file must agree
with `models/model-manifest.yaml`, and bundle `MODEL_PATH` must be `.` for the
canonical `models/` mount; that declaration is not model-availability verification. Bundle preparation
performs the later manifest/file gate.

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

- the trusted packaging/handoff station runs `bin/lucairn bundle verify` for
  the exact tarball being sent; the customer separately verifies the supplied
  SHA256 checksum through the approved authenticated handoff channel before
  raw extraction (S1 does not yet complete publisher authentication).
- `bin/lucairn doctor --offline` passes on the extracted bundle.
- image delivery is decided and tested as either registry, tar archive, or customer mirror.
- the model runtime mode is explicit: external OpenAI-compatible endpoint or bundled self-hosted runtime.
- the recipient, channel, checksum, and install owner are recorded in the engagement handoff note.

See `docs/CUSTOMER_HANDOFF_GATES.md` and `docs/CLEAN_HOST_REHEARSAL.md`.
