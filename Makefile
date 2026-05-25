.PHONY: test package customer-bundle clean \
        dashboard-buildx-bootstrap dashboard-multiarch-build \
        dashboard-verify-manifests

test:
	bash tests/test_lucairn_cli.sh
	bash tests/static_checks.sh

package:
	bash scripts/package-release.sh

customer-bundle:
	@test -n "$(CUSTOMER_SLUG)" || (echo "CUSTOMER_SLUG is required" >&2; exit 1)
	@test -n "$(STAGING_DIR)" || (echo "STAGING_DIR is required" >&2; exit 1)
	bin/lucairn bundle prepare --customer-slug "$(CUSTOMER_SLUG)" --staging-dir "$(STAGING_DIR)" --output "$(or $(OUTPUT_DIR),dist/customer-bundles)"

# ----------------------------------------------------------------------------
# Multi-arch dashboard image publish (Sim 5 Gap 3 fix).
# ----------------------------------------------------------------------------
#
# Mirrors the `release-multiarch` pattern from
# `dual-sandbox-architecture/Makefile` (PR #196). The kit publishes ONE image
# (`lucairn-dashboard`) on an independent cadence from the dsa-* services, so
# the kit gets its own dedicated target rather than sharing DSA's
# `PUBLISH_SERVICES` matrix.
#
# Default arguments are the production release values; override at the
# command line for bisect / staging runs:
#
#   make dashboard-multiarch-build                          # release defaults
#   make dashboard-multiarch-build VERSION=0.8.2 MINOR_TAG=0.8
#   make dashboard-multiarch-build PLATFORMS=linux/amd64 VERSION=0.8.1-bisect-amd64
#
# Sim 5 (2026-05-25) found `ghcr.io/declade/lucairn-dashboard:0.8.1` was
# arm64-only — same `exec format error` failure mode that closed Sim 4 Gap 5
# for the 8 dual-sandbox-architecture core services. See
# `Opus Advisor/specs/sim5-compose-x86-2026-05-25.md` § Gap #3.

REGISTRY ?= ghcr.io/declade
VERSION  ?= 0.8.1
# Minor-version alias derived from VERSION (e.g. 0.8.1 -> 0.8). Used to clone
# the just-pushed multi-arch manifest into the `:MINOR` rolling tag so
# operators can pin to `:0.8` and roll forward inside the minor without
# editing their compose / Helm values.
MINOR_TAG := $(shell echo $(VERSION) | cut -d. -f1-2)
PLATFORMS ?= linux/amd64,linux/arm64
BUILDX_BUILDER ?= lucairn-multiarch

# tonistiigi/binfmt pinned to qemu-v10.2.1 by manifest-list digest. binfmt is
# run --privileged, so a registry compromise or tag-move on the upstream image
# would give the attacker arbitrary code on the release host (which also has
# GHCR push creds). Digest pin makes that supply-chain link immutable —
# operators must opt-in to bumping the pin instead of silently picking up
# whatever the mutable `latest` tag points at on release day. Matches the
# pinned digest in dual-sandbox-architecture/Makefile so the two build hosts
# converge on the same QEMU binary.
#
# To rotate: cross-check the new digest against
# https://hub.docker.com/v2/repositories/tonistiigi/binfmt/tags
# AND the GitHub release at https://github.com/tonistiigi/binfmt/releases
# before bumping.
BINFMT_IMAGE ?= tonistiigi/binfmt:qemu-v10.2.1@sha256:d3b963f787999e6c0219a48dba02978769286ff61a5f4d26245cb6a6e5567ea3

# Single service for the kit (the dsa-* image set lives in the
# dual-sandbox-architecture repo). Kept as a variable so a future
# kit-published image (e.g. a future cert-portal) just appends here.
DASHBOARD_PUBLISH_SERVICES := lucairn-dashboard

# Bootstrap the QEMU binfmt handlers + dedicated buildx builder. Idempotent:
# safe to re-run. Linux host reboots clear binfmt_misc kernel registrations
# even though the buildx builder context persists, so binfmt registration
# runs UNCONDITIONALLY on every invocation.
dashboard-buildx-bootstrap:
	@echo "Ensuring QEMU binfmt handlers are registered (idempotent)..."
	@echo "Using pinned binfmt image: $(BINFMT_IMAGE)"
	docker run --privileged --rm $(BINFMT_IMAGE) --install all >/dev/null
	@if ! docker buildx ls | grep -q '^$(BUILDX_BUILDER)'; then \
		echo "Bootstrapping buildx builder $(BUILDX_BUILDER)..."; \
		docker buildx create --name $(BUILDX_BUILDER) --driver docker-container --use --bootstrap; \
	else \
		echo "Buildx builder $(BUILDX_BUILDER) already exists — selecting it."; \
		docker buildx use $(BUILDX_BUILDER); \
	fi
	docker buildx inspect --bootstrap | grep -E 'Platforms|Status'

# Build the multi-arch dashboard image and push it to GHCR. One buildx
# invocation produces a manifest list and writes the three publish tags
# (exact / minor / latest) atomically. Re-uses the canonical
# `apps/dashboard/Dockerfile` which is multi-stage Go + distroless and
# cross-compiles cleanly under QEMU (CGO disabled).
dashboard-multiarch-build: dashboard-buildx-bootstrap
	@echo "Pre-flight: copy kit-root image-manifest.yaml into apps/dashboard/ ..."
	$(MAKE) -C apps/dashboard image-manifest-sync
	@echo ""
	@echo "Pre-flight: verify pre-built static assets exist (Dockerfile hard-fails otherwise) ..."
	@test -f apps/dashboard/static/css/dashboard.css \
		|| (echo "  MISSING: apps/dashboard/static/css/dashboard.css — run tailwindcss before build" >&2 && exit 1)
	@test -f "apps/dashboard/static/fonts/Geist[wght].woff2" \
		|| (echo "  MISSING: apps/dashboard/static/fonts/Geist[wght].woff2 — run apps/dashboard/scripts/fetch-fonts.sh" >&2 && exit 1)
	@test -f "apps/dashboard/static/fonts/GeistMono[wght].woff2" \
		|| (echo "  MISSING: apps/dashboard/static/fonts/GeistMono[wght].woff2 — run apps/dashboard/scripts/fetch-fonts.sh" >&2 && exit 1)
	@test -f "apps/dashboard/static/fonts/BricolageGrotesque[wght].woff2" \
		|| (echo "  MISSING: apps/dashboard/static/fonts/BricolageGrotesque[wght].woff2 — run apps/dashboard/scripts/fetch-fonts.sh" >&2 && exit 1)
	@test -f apps/dashboard/static/icons/sprite.svg \
		|| (echo "  MISSING: apps/dashboard/static/icons/sprite.svg" >&2 && exit 1)
	@echo "  OK: static/css, static/fonts/*.woff2, static/icons/sprite.svg, apps/dashboard/image-manifest.yaml all present."
	@echo ""
	@echo "Building + pushing $(REGISTRY)/lucairn-dashboard:$(VERSION) for platforms: $(PLATFORMS) ..."
	@echo "Also publishing :$(MINOR_TAG) + :latest aliases."
	docker buildx build \
		--builder $(BUILDX_BUILDER) \
		--platform $(PLATFORMS) \
		--tag $(REGISTRY)/lucairn-dashboard:$(VERSION) \
		--tag $(REGISTRY)/lucairn-dashboard:$(MINOR_TAG) \
		--tag $(REGISTRY)/lucairn-dashboard:latest \
		--build-arg VERSION=$(VERSION) \
		--push \
		apps/dashboard/
	@echo ""
	@echo "Verifying every pushed tag is multi-arch (Sim 5 Gap 3 regression guard) ..."
	$(MAKE) dashboard-verify-manifests REGISTRY=$(REGISTRY) VERSION=$(VERSION) MINOR_TAG=$(MINOR_TAG)
	@echo ""
	@echo "Multi-arch release complete: $(REGISTRY)/lucairn-dashboard $(VERSION) ($(PLATFORMS))"

# Regression guard for Sim 5 Gap 3. Asserts that every published dashboard tag
# (exact / minor / latest) contains BOTH `linux/amd64` and `linux/arm64` in its
# manifest list. Re-uses `scripts/verify-multiarch-manifests.sh` (vendored from
# dual-sandbox-architecture PR #196).
dashboard-verify-manifests:
	@bash scripts/verify-multiarch-manifests.sh $(REGISTRY) $(VERSION) "$(DASHBOARD_PUBLISH_SERVICES)"
	@bash scripts/verify-multiarch-manifests.sh $(REGISTRY) $(MINOR_TAG) "$(DASHBOARD_PUBLISH_SERVICES)"
	@bash scripts/verify-multiarch-manifests.sh $(REGISTRY) latest "$(DASHBOARD_PUBLISH_SERVICES)"

clean:
	rm -rf dist support-bundles
