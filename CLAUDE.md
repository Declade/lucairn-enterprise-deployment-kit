# Claude Code Instructions

Follow `AGENTS.md` exactly for customer-package work.

Claude Code may run the Lucairn package factory when the customer-specific inputs are already staged outside this repository:

```bash
bin/lucairn bundle prepare \
  --customer-slug acme \
  --staging-dir /secure/staging/acme \
  --output /secure/outbound/acme
```

Never add customer model files, `customer.env`, generated bundles, support bundles, image archives, or agent reports to git. If work involves a real customer directory under `~/Clients/**`, stop unless the contract explicitly permits Claude Code access to that customer data.
