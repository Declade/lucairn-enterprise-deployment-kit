# Agent Customer Packaging Runbook

This runbook lets Codex, Claude Code, or another agent create a customer-ready Lucairn bundle end to end from already staged customer inputs.

## Goal

An agent should be able to run one command that:

- reads a staged customer package directory,
- copies the required kit files,
- includes customer model files and optional image archives,
- creates a tarball,
- verifies the tarball checksums and manifest,
- writes a non-secret audit report.

The agent never installs on customer hardware and never touches customer infrastructure.

## Required Staging Layout

Stage customer inputs outside this repository:

```text
/secure/staging/[customer-slug]/
  customer.env
  models/
    model-manifest.yaml
    [model files referenced by model-manifest.yaml]
  images/
    lucairn-images.tar
```

If the customer will pull images from a registry, omit `images/lucairn-images.tar`; the report will mark `image_delivery=registry`.

Optional Compose overrides:

```text
/secure/staging/[customer-slug]/
  install/
    docker-compose.customer.yml
    docker-compose.self-hosted.yml
```

## Prepare Package

```bash
bin/lucairn bundle prepare \
  --customer-slug acme \
  --staging-dir /secure/staging/acme \
  --output /secure/outbound/acme
```

Expected output:

```text
bundle: /secure/outbound/acme/lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
bundle verify: ok
agent report: /secure/outbound/acme/lucairn-customer-bundle-acme-report.txt
```

## Report Contract

The report is safe to review in the repo context because it must not contain secret values. It contains:

```text
agent_contract=lucairn-customer-package-v1
customer_slug=acme
kit_version=...
bundle_path=...
bundle_sha256=...
bundle_verify=ok
customer_env=present
model_name=...
model_format=...
model_runtime=...
image_delivery=archive|directory|registry
human_review_required=true
customer_files_committed_to_git=false
```

If a report contains API keys, signing keys, passwords, tokens, model file contents, or customer data, delete the report and treat it as an incident.

## Human Review Before Sending

Before the bundle goes to the customer, a human must confirm:

- the slug matches the customer,
- `bundle_verify=ok`,
- `bundle_sha256` has been recorded,
- the model manifest matches the customer-approved model,
- the image delivery mode matches the customer install plan,
- the delivery channel is approved for confidential customer files.

## Customer Install Summary

The customer extracts the tarball and follows `INSTALL-CUSTOMER.md` inside the bundle:

```bash
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
docker load -i images/lucairn-images.tar
bin/lucairn bundle verify --bundle .
bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --skip-image-check
docker compose \
  -f install/docker-compose.customer.yml \
  -f install/docker-compose.self-hosted.yml \
  --env-file install/customer.env \
  --profile "${MODEL_RUNTIME_PROFILE:-custom-runtime}" \
  up -d
```

For registry-based delivery, they skip `docker load` and use the registry credentials supplied by Lucairn.

## Agent Failure Handling

If `bundle prepare` fails:

- fix missing staging files instead of editing generated bundle contents,
- rerun `bundle prepare`,
- do not manually patch the tarball,
- do not weaken `bundle verify`,
- record the failure and fix in the Obsidian project log.
