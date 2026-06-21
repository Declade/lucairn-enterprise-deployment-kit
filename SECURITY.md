# Security Policy

This document explains how to report a vulnerability in the Lucairn Enterprise
Deployment Kit, how Lucairn handles disclosure, and where security advisories and
fixes are published.

## Reporting a vulnerability

Email **security@lucairn.eu** with:

- a description of the issue and the impact you believe it has,
- the kit version (`cat VERSION`) and image tag (`LUCAIRN_IMAGE_TAG`) affected,
- steps to reproduce — a proof-of-concept, logs, or a minimal example, and
- any suggested remediation, if you have one.

Please report privately — do **not** open a public GitHub issue, pull request,
or social-media post for a suspected vulnerability. If you need to share
sensitive material and want to encrypt it, say so in your first email and we
will arrange a channel.

Lucairn does **not** run a paid bug-bounty program. Reports are handled under
coordinated disclosure (below). Reporters who wish to be named will be credited
in the resulting advisory.

## What to expect (coordinated disclosure)

1. **Acknowledgement** — we aim to acknowledge your report within **3 business
   days**.
2. **Triage** — we confirm the issue, assess its severity, and tell you whether
   it is in scope and which components are affected.
3. **Fix** — we develop and test a fix or mitigation. For confirmed issues we
   aim to ship a fix and coordinate public disclosure within **90 days** of the
   report; complex issues may take longer, and we will keep you informed.
4. **Advisory** — when a fix is available we publish an advisory (see below),
   ship the fixed images and chart, and update the kit so operators can apply
   it.

We will coordinate the public-disclosure date with you. Please give us a
reasonable window to ship a fix before disclosing publicly.

## Scope

In scope:

- this deployment kit (`bin/lucairn`, the Helm charts, the Compose files,
  `config/`, `scripts/`, and the docs);
- the `dsa-*` service images referenced by `image-manifest.yaml` /
  `LUCAIRN_IMAGE_TAG`;
- the optional Lucairn Enterprise Dashboard (`apps/dashboard/`).

Out of scope:

- issues that require a compromised host, root on the deployment node, or a
  malicious operator — these are outside the kit's trust boundary;
- findings against software you have modified locally;
- operator-owned configuration that the runbooks already document as your
  responsibility (network policy, secret storage, certificate material). Report
  these only if a documented step is itself wrong or unsafe.

## Supported versions

Security fixes are delivered in the **latest released kit version**. Run the
latest `1.9.x` kit — see [`CHANGELOG.md`](CHANGELOG.md) for the current release —
and apply security releases promptly. The upgrade procedure is in
[`OPS.md`](OPS.md#upgrade); after upgrading, confirm the published images with
`bin/lucairn verify-images --tag <LUCAIRN_IMAGE_TAG>` (e.g. `--tag 0.5.4`).

## Where advisories and fixes are published

- **Security advisories:** <https://lucairn.eu/security>
- **Machine-readable contact (RFC 9116):** <https://lucairn.eu/.well-known/security.txt>
- **Release history:** [`CHANGELOG.md`](CHANGELOG.md) in this kit, and the
  per-version notes in [`INSTALL.md`](INSTALL.md#release-notes).

The kit never phones home: there is no automatic outbound update check, and
applying an update is always operator-initiated. Watch
<https://lucairn.eu/security> (and the kit releases) for security
announcements.

## Contact

- Security reports: **security@lucairn.eu**
- General support: see [`docs/SUPPORT_TIERS.md`](docs/SUPPORT_TIERS.md).
