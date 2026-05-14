# Release Process

Current customer-bundle tag line: `v1.3.0-customer-demo-data`

## Local Verification

```bash
make test
make package
```

## Tag

```bash
git tag -a v1.3.0-customer-demo-data -m "Lucairn enterprise customer demo data v1.3.0"
git push origin main --tags
```

## GitHub Release

Attach:

- `dist/lucairn-enterprise-deployment-kit-1.3.0-customer-demo-data.tar.gz`
- Helm chart package from `dist/` when Helm is installed.

Release notes must include:

- Supported install paths.
- Required customer-provided secrets.
- Known limitations.
- Support-bundle workflow.
- Customer-bundle workflow when model files or offline image delivery are included.
- Agent package factory workflow for Codex and Claude Code.
- Optional staged customer demo data included in verified bundles.
