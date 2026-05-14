# Release Process

Current customer-bundle tag line: `v1.2.0-agent-package-factory`

## Local Verification

```bash
make test
make package
```

## Tag

```bash
git tag -a v1.2.0-agent-package-factory -m "Lucairn enterprise agent package factory v1.2.0"
git push origin main --tags
```

## GitHub Release

Attach:

- `dist/lucairn-enterprise-deployment-kit-1.2.0-agent-package-factory.tar.gz`
- Helm chart package from `dist/` when Helm is installed.

Release notes must include:

- Supported install paths.
- Required customer-provided secrets.
- Known limitations.
- Support-bundle workflow.
- Customer-bundle workflow when model files or offline image delivery are included.
- Agent package factory workflow for Codex and Claude Code.
