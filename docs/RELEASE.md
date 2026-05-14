# Release Process

Current customer-bundle tag line: `v1.1.0-enterprise-customer-bundle`

## Local Verification

```bash
make test
make package
```

## Tag

```bash
git tag -a v1.1.0-enterprise-customer-bundle -m "Lucairn enterprise customer bundle v1.1.0"
git push origin main --tags
```

## GitHub Release

Attach:

- `dist/lucairn-enterprise-deployment-kit-1.1.0-enterprise-customer-bundle.tar.gz`
- Helm chart package from `dist/` when Helm is installed.

Release notes must include:

- Supported install paths.
- Required customer-provided secrets.
- Known limitations.
- Support-bundle workflow.
- Customer-bundle workflow when model files or offline image delivery are included.
