# Releasing the Lucairn Enterprise Deployment Kit

This doc covers two release paths:

1. **Kit distribution release** — the customer-facing kit: a clean `vX.Y.Z` tag,
   a cosign-signed tarball + Helm chart, a GitHub Release, and the signed version
   feed. See [§ Kit distribution release](#kit-distribution-release) below.
2. **Image-publish path** — republishing the `lucairn-dashboard` image (and, in
   `dual-sandbox-architecture`, the `dsa-*` images). See [§ When to publish a new
   image](#when-to-publish-a-new-image) onward.

Customer-bundle assembly is separate: `bin/lucairn bundle prepare` +
`docs/CUSTOMER_BUNDLE.md`.

## Kit distribution release

A kit release gives a self-hosted customer a canonical, signed download and a
machine-readable signal that it exists. It is cut with **`scripts/release-kit.sh`**
(or `make release-kit`). The script is **dry-run by default**: it builds and
cosign-signs the artifacts into `dist/` but does **not** tag, push, or create a
GitHub Release until you pass `--publish`.

### Prerequisites

- `cosign`, `helm`, `jq`, `git`, `tar` on `PATH`; `gh` (authenticated) for `--publish`.
- `COSIGN_KEY` pointing at the Lucairn cosign **private** key (on the release
  host at `/home/deploy/.lucairn-cosign/`). It is the private half of
  `keys/lucairn-cosign.pub` — the **same key that signs the `dsa-*` images**, so
  no new trust root. If the key is encrypted, export `COSIGN_PASSWORD` (or
  `COSIGN_PASSWORD_FILE`) the way the image-signing ceremony does. The private
  key never lives in this repo.

### Steps

1. **Bump the version identity together** (the [equality checklist](#pre-release-equality-checklist)
   must pass): `VERSION`, `README.md` "Target release", `image-manifest.yaml`
   `kit_version`, `charts/lucairn/Chart.yaml` `version` — and **`RELEASE_DATE`**
   (the kit-bundled release date, `YYYY-MM-DD`, read by `bin/lucairn doctor`'s
   staleness check and emitted as the feed's `latest.released`). Commit the bump.
2. **Curate the feed source** `release/version-feed.source.json` if this release
   changes the security floor (`minimum_secure`) or publishes an advisory
   (prepend to `advisories[]`). Keep it in lockstep with the published advisory
   on <https://lucairn.eu/security>.
3. **Dry-run** to build + sign + self-verify everything:
   ```bash
   COSIGN_KEY=/home/deploy/.lucairn-cosign/cosign.key make release-kit
   # for a security release, add: RELEASE_ARGS="--security --advisory-url https://lucairn.eu/security#LUCAIRN-YYYY-NNN"
   ```
   This writes to `dist/`: the tarball + `.sig`, the chart `.tgz` + `.sig`,
   `version-feed.json` + `.sig`, and the release notes (from `CHANGELOG.md`).
   Every signature is self-verified against `keys/lucairn-cosign.pub`.
4. **Publish** (creates + pushes the `vX.Y.Z` tag and the GitHub Release with all
   signed assets + notes):
   ```bash
   COSIGN_KEY=/home/deploy/.lucairn-cosign/cosign.key make release-kit PUBLISH=1
   ```
   Refuses to run if the working tree is dirty or the tag already exists.
5. **Update the public feed**: copy `dist/version-feed.json` + `dist/version-feed.json.sig`
   into `lucairn-website/public/.well-known/`, commit, and deploy the site
   (`ssh deploy@<host> /opt/bin/deploy-website.sh`). The customer's
   `bin/lucairn check-updates` (ships in a later kit version) fetches and
   cosign-verifies this feed; it fails closed — it never reports "up to date" on
   a missing/invalid signature.

### Tag scheme

Clean SemVer `vX.Y.Z` matching `VERSION` (e.g. `v1.9.4`) — no suffixes. (Older
suffixed tags such as `v1.6.0-stage-3-rebrand` and the `*-dashboard` tags predate
this scheme.) The Rekor transparency log is used by default, matching the
image-signing ceremony; `--no-tlog` is offline/test only.

## When to publish a new image

Publish a new `ghcr.io/declade/lucairn-dashboard:<tag>` whenever:

- the Go binary in `apps/dashboard/` changes (source under `apps/dashboard/`)
- the embedded static assets change (`apps/dashboard/static/css/dashboard.css`,
  `static/fonts/*.woff2`, `static/icons/sprite.svg`)
- the kit-root `image-manifest.yaml` changes (the dashboard embeds it for the
  compliance PDF cover page — see `apps/dashboard/Dockerfile:35-38`)

Bump `apps/dashboard/image-manifest.yaml` if the new dashboard tag is a
breaking change for customers; otherwise rolling the `:0.8` minor alias is
enough.

## Multi-arch image publish (the load-bearing step)

The kit's published image **MUST** be multi-arch (`linux/amd64,linux/arm64`).
Sim 5 (2026-05-25) found `ghcr.io/declade/lucairn-dashboard:0.8.1` had been
published as `arm64`-only — x86_64 customer hosts (the canonical install
target) crash-looped the dashboard container with `exec format error`. Same
defect class as Sim 4 Gap 5 (closed by `dual-sandbox-architecture` PR #196 for
the 8 dsa-* services).

The kit guards this regression with TWO dedicated Makefile targets +
verifier script (split into build + promote-aliases phases — closes Codex r1
BLOCKER on PR #34, mirrors DSA PR #196 r5/r6):

- **`dashboard-multiarch-build`** — builds + pushes ONLY the exact
  `:$(VERSION)` tag. Safe to run with bisect / -rc / -dev VERSIONs or
  single-arch PLATFORMS without ever touching rolling aliases.
- **`dashboard-multiarch-promote-aliases`** — copies the verified-multi-arch
  `:$(VERSION)` manifest list into `:$(MINOR_TAG)` + `:latest`. Refuses to
  run unless (a) PLATFORMS is the canonical multi-arch set, (b) VERSION
  matches release semver (no -rc / -bisect / -dev suffixes), and (c) the
  source `:$(VERSION)` tag is verified multi-arch on the registry.

This two-phase shape closes the
atomic-alias-promotion-on-single-arch-build defect class. A single buildx
invocation publishing `:VERSION` + `:MINOR` + `:latest` atomically would
have promoted an arm64-only bisect image (or an -rc tag) to `:0.8` +
`:latest` before the verifier could fire, recreating the exact
`exec format error` failure Sim 5 Gap #3 is meant to prevent.

### Prerequisites (build host)

- Docker 24+ with `buildx` (the kit pins `tonistiigi/binfmt:qemu-v10.2.1`).
- amd64 build host. arm64 hosts can run the same target but cross-build
  performance over QEMU is slower than amd64 → arm64.
- `docker login ghcr.io` with a PAT that has `write:packages` on
  `Declade/lucairn-enterprise-deployment-kit`.

### Run a release publish (two phases)

From the kit repo root, **Phase 1** publishes the exact tag only:

```bash
make dashboard-multiarch-build VERSION=0.8.2
```

What this does, in order:

1. **`dashboard-buildx-bootstrap`** — re-registers the QEMU binfmt handlers
   (idempotent, ~3 s no-op when already registered) and creates the
   `lucairn-multiarch` buildx builder if it's missing. Idempotent: safe to
   re-run.
2. **`apps/dashboard image-manifest-sync`** — copies the kit-root
   `image-manifest.yaml` into `apps/dashboard/` so the `//go:embed` directive
   in `apps/dashboard/main.go` picks up the canonical kit-wide manifest at
   compile time.
3. **Pre-flight asset check** — fails fast if `static/css/dashboard.css`,
   `static/fonts/*.woff2`, or `static/icons/sprite.svg` are missing. The
   Dockerfile re-asserts the same checks at image-build time (lines
   35-38) but failing early on the host saves ~3 minutes of QEMU compile.
4. **`docker buildx build --platform linux/amd64,linux/arm64 --push`** —
   single invocation produces a multi-arch manifest list and writes ONLY
   the exact `:$(VERSION)` tag. Does NOT touch `:MINOR_TAG` or `:latest`.
5. **Exact-tag verifier** — calls `scripts/verify-multiarch-manifests.sh`
   on `:$(VERSION)` only. If `PLATFORMS=linux/amd64,linux/arm64` and the
   manifest is single-arch, the build hard-fails. If you intentionally
   published single-arch (bisect), the verifier exit is treated as
   expected — no aliases were ever in scope to fail on.

**Phase 2** — only after confirming `:$(VERSION)` is multi-arch + the build
is release-grade — promotes the rolling aliases:

```bash
make dashboard-multiarch-promote-aliases VERSION=0.8.2 MINOR_TAG=0.8
```

What this does:

1. **Guard 1 — PLATFORMS check** — refuses promotion unless PLATFORMS
   equals `linux/amd64,linux/arm64`. Override with `FORCE_ALIAS=1`
   (emergency only — see § Emergency override). Note: only the literal
   string `1` enables the override; any other value (including `0`, `true`,
   `false`) is treated as "not set".
2. **Guard 2 — semver check** — refuses promotion unless VERSION matches
   `^[0-9]+\.[0-9]+\.[0-9]+$`. Suffixes (`-rc1`, `-bisect-amd64`, `-dev`,
   etc.) are rejected. Override with `FORCE_ALIAS=1`.
3. **Guard 3 — MINOR_TAG consistency check** — refuses promotion unless
   MINOR_TAG equals `major.minor(VERSION)`. Prevents accidentally promoting
   `:0.9.0` to `:0.8` + `:latest` (which would silently overwrite the
   wrong minor-version channel). Override with `FORCE_ALIAS=1`.
4. **Source-multi-arch verify** — calls
   `scripts/verify-multiarch-manifests.sh` against `:$(VERSION)` BEFORE
   any alias copy. **Pinned** `REQUIRED_PLATFORMS="linux/amd64 linux/arm64"`
   so an inherited env override cannot weaken the check.
5. **`docker buildx imagetools create`** — clones the multi-arch manifest
   list into `:$(MINOR_TAG)` + `:latest` in a single invocation. No
   rebuild, no layer re-upload, just a manifest copy. Both aliases either
   both advance or both fail.
6. **Post-promotion verifier** — re-asserts each alias is multi-arch.
   Same `REQUIRED_PLATFORMS` pin as step 4.

### Bisect publishes (exact tag only, aliases NEVER advance)

Bisect publishes use `dashboard-multiarch-build` ONLY — never run
`dashboard-multiarch-promote-aliases`. The build target accepts any VERSION
+ PLATFORMS combination and writes only the exact tag:

```bash
make dashboard-multiarch-build \
  VERSION=0.8.1-bisect-amd64 PLATFORMS=linux/amd64
```

This publishes `ghcr.io/declade/lucairn-dashboard:0.8.1-bisect-amd64` as a
single-arch (amd64-only) image. `:0.8` and `:latest` are NOT touched.

If you accidentally tried to promote-aliases a bisect tag, the semver
guard would refuse with a clear error before any `imagetools create`
call fires. Same for `-rc` tags.

### Emergency override: FORCE_ALIAS=1

If a release goes sideways and an operator needs to promote a non-canonical
VERSION/PLATFORMS combination (e.g. an `:0.8.2-rc3` was verified clean and
needs to roll the aliases without a fresh `:0.8.2` cut), set
`FORCE_ALIAS=1` on the promote-aliases invocation:

```bash
make dashboard-multiarch-promote-aliases \
  VERSION=0.8.2-rc3 MINOR_TAG=0.8 FORCE_ALIAS=1
```

The guards print a warning to stderr and proceed. The source-multi-arch
verifier still runs unconditionally — there is no way to promote a
single-arch manifest into the rolling aliases.

**Use sparingly.** The default flow (Phase 1 exact build → confirm clean →
Phase 2 promote) is the only audit-clean path for production releases.

## After the publish

1. Bump `image-manifest.yaml` (`optional_services.lucairn-dashboard.image_tag`)
   and `apps/dashboard/image-manifest.yaml` to point at the new tag if the
   release is breaking-change for customers. Otherwise leave the pinned tag
   alone and let the `:0.8` minor alias roll forward.
2. Open a PR with the manifest bump + run the full reviewer chain
   (bug-hunter-reviewer, kit-config-image-drift, claim-enforcement-guard,
   personal-info-leak-detector) + Codex round 1.
3. On merge, re-run BOTH publish phases from the release host if the
   manifest version changed — the embedded `//go:embed` image-manifest.yaml
   needs to match what the cover-page PDF will render at runtime:

   ```bash
   make dashboard-multiarch-build VERSION=0.8.2
   make dashboard-multiarch-promote-aliases VERSION=0.8.2 MINOR_TAG=0.8
   ```

## Version reconciliation

The kit carries TWO distinct version axes. Keep each axis internally
consistent — they drifted in the past (Sim findings INS-05: README claimed
`v1.5.1-dashboard` while `VERSION` said `1.3.0-customer-demo-data` and
`image-manifest.kit_version` said `1.3.0-customer-demo-data`, and the umbrella
chart said `1.4.0`).

### Axis 1 — kit release version (the customer-facing kit tag)

This is the single canonical string identifying a kit release. It carries the
optional `-<slug>` release suffix (e.g. `1.5.1-dashboard`). These three MUST
be byte-identical:

- `README.md` — the `Target release: vX.Y.Z-slug` line (carries the `v`
  prefix used by git tags).
- `VERSION` — the bare `X.Y.Z-slug` string (no `v` prefix).
- `image-manifest.yaml` — `kit_version: "X.Y.Z-slug"` (no `v` prefix).

The only permitted difference is the leading `v` on the README line (git-tag
convention). Strip it before comparing.

### Axis 2 — Helm chart SemVer

The umbrella `charts/lucairn/Chart.yaml` `version:` is the Helm chart's own
SemVer and MUST be clean SemVer (no `-<slug>` build-metadata suffix) so
`helm package` accepts it. It tracks the kit release version on its
`major.minor.patch` only: kit `1.5.1-dashboard` → chart `version: 1.5.1`.
The dashboard sub-chart (`charts/lucairn/charts/dashboard/Chart.yaml`)
`version`/`appVersion` track the dashboard image tag pinned at
`image-manifest.yaml` `optional_services.lucairn-dashboard.image_tag` and the
umbrella dependency `version:` for `name: dashboard`.

### Pre-release equality checklist

Before tagging a kit release, assert ALL of the following are equal (run from
the kit repo root):

```bash
# Axis 1 — kit release version: these three must match (ignoring the README 'v').
README_VER=$(grep -oE 'Target release: `v[^`]+`' README.md | sed -E 's/.*`v(.*)`/\1/')
FILE_VER=$(tr -d '[:space:]' < VERSION)
MANIFEST_VER=$(grep -E '^kit_version:' image-manifest.yaml | sed -E 's/.*"(.*)".*/\1/')
echo "README=$README_VER  VERSION=$FILE_VER  manifest=$MANIFEST_VER"
[ "$README_VER" = "$FILE_VER" ] && [ "$FILE_VER" = "$MANIFEST_VER" ] \
  && echo "kit-version OK" || { echo "kit-version MISMATCH"; exit 1; }

# Axis 2 — Helm chart SemVer = major.minor.patch of the kit version, no suffix.
CHART_VER=$(grep -E '^version:' charts/lucairn/Chart.yaml | awk '{print $2}')
KIT_MMP=${FILE_VER%%-*}
echo "Chart.yaml version=$CHART_VER  expected=$KIT_MMP"
[ "$CHART_VER" = "$KIT_MMP" ] && echo "chart-version OK" || { echo "chart-version MISMATCH"; exit 1; }

# Dashboard sub-chart appVersion must match the pinned dashboard image tag.
DASH_IMG=$(grep -A2 'lucairn-dashboard:' image-manifest.yaml | grep image_tag | sed -E 's/.*"(.*)".*/\1/')
DASH_APP=$(grep -E '^appVersion:' charts/lucairn/charts/dashboard/Chart.yaml | sed -E 's/.*"(.*)".*/\1/')
echo "dashboard image=$DASH_IMG  appVersion=$DASH_APP"
[ "$DASH_IMG" = "$DASH_APP" ] && echo "dashboard-version OK" || { echo "dashboard-version MISMATCH"; exit 1; }

# RELEASE_DATE must be this release's date (read by `bin/lucairn doctor`
# staleness + emitted as the version feed's latest.released). Bump it with VERSION.
echo "RELEASE_DATE=$(cat RELEASE_DATE)"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' RELEASE_DATE \
  && echo "release-date OK" || { echo "RELEASE_DATE missing/malformed (want YYYY-MM-DD)"; exit 1; }
```

After bumping the dashboard sub-chart version, regenerate the umbrella
`Chart.lock` so its `dashboard` entry + digest match Chart.yaml (Helm refuses
to render an out-of-sync lock):

```bash
helm dependency update charts/lucairn
```

## See also

- `apps/dashboard/Dockerfile` — multi-stage Go + distroless image definition.
- `apps/dashboard/Makefile` — local dashboard chores (proto-sync, go test,
  go build, image-manifest-sync).
- `scripts/verify-multiarch-manifests.sh` — the platform verifier, vendored
  from `dual-sandbox-architecture/scripts/`. Stays byte-identical on the
  platform-checking core so the two release paths converge.
- `dual-sandbox-architecture/Makefile` — `release-multiarch` target (the
  precedent pattern for the multi-arch image publish).
