# Lucairn Enterprise Deployment Kit

Target release: `v1.0-enterprise-deployment-kit`

This repository contains the customer-installable Lucairn deployment kit for first enterprise self-hosted installs. The operating rule is simple: customer IT installs and operates the stack; Lucairn support never needs shell access to the customer box.

## Contents

- `charts/lucairn/` - Helm chart for Kubernetes installs.
- `customer-values.yaml.example` - annotated Helm values.
- `docker-compose.customer.yml` - Docker Compose install path using prebuilt Lucairn images.
- `customer.env.example` - annotated Compose env file.
- `bin/lucairn` - customer CLI with `doctor` and `support-bundle`.
- `migrations/`, `config/`, `starter-templates/` - runtime assets needed by the Compose path.
- `INSTALL.md`, `OPS.md`, `TROUBLESHOOTING.md` - day-1 and day-2 runbooks.
- `docs/` - enterprise support, SDK, DPA, mirror, and internal hygiene notes.

## Fast Path

```bash
cp customer.env.example customer.env
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml --offline
docker login ghcr.io
bin/lucairn doctor --env customer.env --compose docker-compose.customer.yml
docker compose -f docker-compose.customer.yml --env-file customer.env up -d
```

Lucairn must provide image registry access and onboarding values before a customer can install from the kit.

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
