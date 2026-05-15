# Customer Handoff Gates

This is the pre-send checklist for any Lucairn enterprise install package. It is intentionally operational, not commercial or legal.
Every handoff gate below must be satisfied before the package leaves the private engagement workspace.

## Required Inputs

- customer slug and internal engagement owner
- install owner on the customer side
- selected deployment path: Docker Compose bundle or Kubernetes values
- image delivery mode: registry, customer mirror, tar archive, or directory archive
- model runtime mode: external OpenAI-compatible endpoint or bundled self-hosted runtime profile
- exact bundle path, SHA256 checksum, and generated non-secret report
- approved delivery channel for the bundle and checksum

## Build Gate

Run from this repository:

```bash
bin/lucairn bundle prepare \
  --customer-slug acme \
  --staging-dir /secure/staging/acme \
  --output /secure/outbound/acme
```

The generated report must contain:

```text
bundle_verify=ok
customer_env=present
image_delivery=archive|directory|registry
```

If `customer_data=present`, confirm the staged data is synthetic or explicitly approved for that engagement before packaging.

## Verification Gate

Run these against the exact artifact that will be sent:

```bash
bin/lucairn bundle verify --bundle /secure/outbound/acme/lucairn-customer-bundle-acme-*.tar.gz
```

Then extract the bundle into a temporary directory and run:

```bash
bin/lucairn doctor \
  --env install/customer.env \
  --compose install/docker-compose.customer.yml \
  --offline
```

For registry delivery, run the non-offline doctor check from a host with the same registry credentials the customer will use:

```bash
bin/lucairn doctor \
  --env install/customer.env \
  --compose install/docker-compose.customer.yml
```

## Handoff Gate

Record the following in the private engagement note before sending:

- bundle filename and SHA256 checksum
- generated report filename
- image delivery mode and whether `docker load` is expected
- model runtime profile and whether model weights are bundled
- install owner and planned install window
- support contact path for redacted support bundles
- explicit note that Lucairn support does not need shell access or unredacted env files

Do not send the package if any gate is missing, if the generated report includes secrets, or if the delivery mode in the report does not match the customer install plan.
