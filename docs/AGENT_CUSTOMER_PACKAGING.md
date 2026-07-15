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
  customer.env.runtime-profile.yaml  # required beside an S1-generated env
  customer.env.image-manifest.yaml   # recorded init-time manifest; required beside S1 env
  models/
    model-manifest.yaml
    [model files referenced by model-manifest.yaml]
  images/
    lucairn-images.tar
  customer-data/
    [optional synthetic or approved customer demo data]
```

If the customer will pull images from a registry, omit `images/lucairn-images.tar`; the report will mark `image_delivery=registry`.

The runtime-profile sidecar and recorded image-manifest snapshot are non-secret
and required for an S1-generated install. Do not drop either while staging: a
marker-bearing env without either fails closed. A genuinely pre-S1 env without
sidecars is legacy-only until explicit profile adoption. For local-runtime,
ensure its declared model name and file agree with `models/model-manifest.yaml`;
the canonical bundle `MODEL_PATH` is `.` for the delivered `models/` mount.
This is an operator declaration, not availability verification. `bundle prepare`
rejects symlinks/special objects in staged source trees and performs the later
model-manifest/file gate.

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
customer_data=present|absent
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
- `customer_data=present` is expected when demo data should travel with the package,
- the delivery channel is approved for confidential customer files.

## Customer Install Summary

On the trusted packaging/handoff station, `bundle prepare` verifies the exact
tarball before transfer. That validates the S1 payload contract but does not
complete publisher authentication. The customer receives the tarball plus its
SHA256 checksum through the approved authenticated handoff channel, compares
that external checksum before raw extraction, then follows
`INSTALL-CUSTOMER.md` inside the bundle:

```bash
shasum -a 256 lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
# Match the printed digest to the separately supplied handoff checksum.
tar -xzf lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ.tar.gz
cd lucairn-customer-bundle-acme-YYYYMMDDTHHMMSSZ
bin/lucairn bundle verify --bundle .
# Follow the generated mode-specific command in INSTALL-CUSTOMER.md.
```

The in-archive CLI cannot authenticate an unverified archive. After the
external checksum and extracted-bundle checks, do not substitute a fixed
Compose command: split bundles exclude self-hosted files and managed-BYOK
requires its additional overlay. Archive delivery names its actual image
archive; registry delivery skips `docker load`; directory delivery follows the
authenticated handoff instructions for the files provided. The generated note
also requires a provider key before doctor for BYOK. For S1 bundles it uses
`bin/lucairn up|status|logs|pull|down --env install/customer.env --compose install/docker-compose.customer.yml` so the
recorded overlays/profile, rather than a copied Compose command, control every
lifecycle action. A split bundle must have been initialized with the
Lucairn-issued remote credential file; endpoint plus license alone is not a
usable remote-auth configuration.

For registry-based delivery, they skip `docker load` and pull directly from `ghcr.io/declade/*` after authenticating with a GitHub PAT (`read:packages` scope) — Lucairn-default GHCR images are currently private; see `INSTALL.md` § "Registry Authentication". Lucairn does not provision per-customer GHCR credentials; the customer's own GitHub account or service-account PAT is sufficient. Customer-side private mirrors need their own mirror credentials.

## Agent Failure Handling

If `bundle prepare` fails:

- fix missing staging files instead of editing generated bundle contents,
- rerun `bundle prepare`,
- do not manually patch the tarball,
- do not weaken `bundle verify`,
- record the failure and fix in the Obsidian project log.
