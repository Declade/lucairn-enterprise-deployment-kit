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
- `bin/lucairn` - customer CLI with `doctor` and `support-bundle`.
- `bin/lucairn bundle create/prepare/verify` - per-customer bundle builder, agent package factory, and verifier.
- `AGENTS.md`, `CLAUDE.md` - operating contract for Codex, Claude Code, and similar agents.
- `migrations/`, `config/`, `starter-templates/` - runtime assets needed by the Compose path.
- `INSTALL.md`, `OPS.md`, `TROUBLESHOOTING.md` - day-1 and day-2 runbooks.
- `docs/` - enterprise support, SDK, mirror, clean-host rehearsal, handoff gates, and internal hygiene notes.

## Fast Path

```bash
cp customer.env.example customer.env
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
docker login ghcr.io
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

Lucairn must provide image registry access and onboarding values before a customer can install from the kit.
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
