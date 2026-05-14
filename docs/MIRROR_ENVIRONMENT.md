# Vendor-Side Mirror Environment

Purpose: reproduce customer issues without accessing customer infrastructure.

## Hosting

- Dedicated Hetzner box, approximately EUR 20 per month.
- Same release kit version as the customer.
- No customer access.
- No real customer data.

## Data

Use anonymized fixtures only. If a customer sends a support bundle, replay only relevant configuration after the customer has reviewed the bundle.

## Workflow

1. Customer runs `bin/lucairn support-bundle`.
2. Customer reviews the archive.
3. Customer emails the archive to Lucairn support.
4. Lucairn replays relevant redacted config on the mirror.
5. Lucairn reproduces the issue.
6. Lucairn returns diagnosis, patch, or runbook change.

## Boundary

The customer never has visibility into this environment. The mirror exists only for Lucairn support diagnosis and release hardening.

