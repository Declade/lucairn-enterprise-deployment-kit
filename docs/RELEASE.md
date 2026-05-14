# Release Process

Target tag: `v1.0-enterprise-deployment-kit`

## Local Verification

```bash
make test
make package
```

## Tag

```bash
git tag -a v1.0-enterprise-deployment-kit -m "Lucairn enterprise deployment kit v1.0"
git push origin main --tags
```

## GitHub Release

Attach:

- `dist/lucairn-enterprise-deployment-kit-1.0.0-enterprise-deployment-kit.tar.gz`
- Helm chart package from `dist/` when Helm is installed.

Release notes must include:

- Supported install paths.
- Required customer-provided secrets.
- Known limitations.
- Support-bundle workflow.

