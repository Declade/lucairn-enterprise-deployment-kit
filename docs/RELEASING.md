# Releasing the Lucairn Enterprise Deployment Kit

This doc covers the **image-publish path** for the kit. It does NOT cover
release packaging (see `scripts/package-release.sh` + `make package`) or
customer-bundle assembly (see `bin/lucairn bundle prepare` + `docs/CUSTOMER_BUNDLE.md`).

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
   (emergency only — see § Emergency override).
2. **Guard 2 — semver check** — refuses promotion unless VERSION matches
   `^[0-9]+\.[0-9]+\.[0-9]+$`. Suffixes (`-rc1`, `-bisect-amd64`, `-dev`,
   etc.) are rejected. Override with `FORCE_ALIAS=1`.
3. **Source-multi-arch verify** — calls
   `scripts/verify-multiarch-manifests.sh` against
   `:$(VERSION)` BEFORE any alias copy. Closes the "build verifier silently
   failed but alias copy ran anyway" race.
4. **`docker buildx imagetools create`** — clones the multi-arch manifest
   list into `:$(MINOR_TAG)` + `:latest` in a single invocation. No
   rebuild, no layer re-upload, just a manifest copy. Both aliases either
   both advance or both fail.
5. **Post-promotion verifier** — re-asserts each alias is multi-arch.

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

## See also

- `apps/dashboard/Dockerfile` — multi-stage Go + distroless image definition.
- `apps/dashboard/Makefile` — local dashboard chores (proto-sync, go test,
  go build, image-manifest-sync).
- `scripts/verify-multiarch-manifests.sh` — the platform verifier, vendored
  from `dual-sandbox-architecture/scripts/`. Stays byte-identical on the
  platform-checking core so the two release paths converge.
- `dual-sandbox-architecture/Makefile` — `release-multiarch` target. The
  precedent pattern.
- `Opus Advisor/specs/sim5-compose-x86-2026-05-25.md` — Sim 5 § Gap #3 (the
  original blocker this target closes).
- `Opus Advisor/specs/sim4-enterprise-end-to-end-2026-05-25.md` — Sim 4 § Gap
  5 (the original dsa-* arm64-only blocker; closed by PR #196).
