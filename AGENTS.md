# Agent Operating Contract

This repository is allowed to be operated by Codex, Claude Code, and similar coding agents for Lucairn customer-package preparation.

## Hard Rules

- Do not commit customer staging directories, customer bundles, customer model files, image archives, secrets, support bundles, or generated reports.
- Do not upload customer bundles or customer model files to GitHub releases, issues, pull requests, generic cloud drives, or logs.
- Do not SSH into, remote-control, or modify a customer machine. Customer IT installs the bundle.
- Do not read or copy files from `~/Clients/**` unless the current customer contract explicitly permits the tool being used.
- Treat every `customer.env`, model file, image tar, and generated customer bundle as customer confidential data.

## Standard Agent Workflow

Use a per-customer staging directory outside the repo:

```text
/secure/staging/[customer-slug]/
  customer.env
  models/
    model-manifest.yaml
    [customer model files]
  images/
    lucairn-images.tar
  customer-data/
    [optional synthetic or approved customer demo data]
```

Optional staging overrides:

```text
/secure/staging/[customer-slug]/
  install/
    docker-compose.customer.yml
    docker-compose.self-hosted.yml
```

Create and verify the customer package with one non-interactive command:

```bash
bin/lucairn bundle prepare \
  --customer-slug acme \
  --staging-dir /secure/staging/acme \
  --output /secure/outbound/acme
```

The command must print:

```text
bundle: /secure/outbound/acme/lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
bundle verify: ok
agent report: /secure/outbound/acme/lucairn-customer-bundle-acme-report.txt
```

Run the full repo checks before committing kit changes:

```bash
make test
```

## Sendable Artifact Rule

The sendable customer artifact is the generated `lucairn-customer-bundle-*.tar.gz` only after a human has reviewed:

- `lucairn-customer-bundle-[slug]-report.txt`
- the staged `model-manifest.yaml`
- the staged `customer.env`
- any staged `customer-data/`
- the bundle recipient and delivery channel

The agent report must never contain secret values. It records metadata, bundle checksum, image delivery mode, and verification status.
