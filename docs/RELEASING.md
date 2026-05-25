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

The kit guards this regression with a dedicated Makefile target +
verifier script: `make dashboard-multiarch-build` builds, pushes, and verifies
the manifest list in a single invocation, refusing to declare success unless
every published tag (`:VERSION`, `:MINOR`, `:latest`) contains BOTH
`linux/amd64` and `linux/arm64`.

### Prerequisites (build host)

- Docker 24+ with `buildx` (the kit pins `tonistiigi/binfmt:qemu-v10.2.1`).
- amd64 build host. arm64 hosts can run the same target but cross-build
  performance over QEMU is slower than amd64 → arm64.
- `docker login ghcr.io` with a PAT that has `write:packages` on
  `Declade/lucairn-enterprise-deployment-kit`.

### Run the publish

From the kit repo root:

```bash
make dashboard-multiarch-build VERSION=0.8.1 MINOR_TAG=0.8
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
   single invocation produces a multi-arch manifest list and writes the
   three publish tags (`:VERSION`, `:MINOR_TAG`, `:latest`) atomically. The
   buildx-native multi-tag flow avoids the alias-staleness window that a
   separate `imagetools create` step would create.
5. **`dashboard-verify-manifests`** — calls
   `scripts/verify-multiarch-manifests.sh` once per published tag. Each call
   uses `docker buildx imagetools inspect` against the remote registry (no
   pull) and greps for `linux/amd64` AND `linux/arm64`. Exits non-zero if
   either platform is missing on any tag.

### Bisect / single-arch overrides

For a single-arch bisect publish (e.g. ruling out an arch-specific bug):

```bash
make dashboard-multiarch-build \
  VERSION=0.8.1-bisect-amd64 PLATFORMS=linux/amd64
```

The kit does not auto-skip the verifier in that mode — `linux/arm64` will be
missing and the verifier will fail. That is intentional: bisect publishes are
not release-grade. Re-tag with a release semver and re-run with the default
`PLATFORMS` before declaring the release green.

## After the publish

1. Bump `image-manifest.yaml` (`optional_services.lucairn-dashboard.image_tag`)
   and `apps/dashboard/image-manifest.yaml` to point at the new tag if the
   release is breaking-change for customers. Otherwise leave the pinned tag
   alone and let the `:0.8` minor alias roll forward.
2. Open a PR with the manifest bump + run the full reviewer chain
   (bug-hunter-reviewer, kit-config-image-drift, claim-enforcement-guard,
   personal-info-leak-detector) + Codex round 1.
3. On merge, re-run `make dashboard-multiarch-build` from the release host
   if the manifest version changed — the embedded `//go:embed`
   image-manifest.yaml needs to match what the cover-page PDF will render at
   runtime.

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
