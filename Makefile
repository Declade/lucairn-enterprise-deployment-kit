.PHONY: test package customer-bundle clean \
        dashboard-buildx-bootstrap dashboard-multiarch-build \
        dashboard-multiarch-promote-aliases \
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
# `dual-sandbox-architecture/Makefile` (PR #196 r5/r6). The kit publishes ONE
# image (`lucairn-dashboard`) on an independent cadence from the dsa-* services,
# so the kit gets its own dedicated target rather than sharing DSA's
# `PUBLISH_SERVICES` matrix.
#
# TWO-PHASE PUBLISH (Codex r1 BLOCKER on PR #34 — fix-up r1):
#
#   Phase 1 — `dashboard-multiarch-build`: builds + pushes ONLY the exact
#     `:$(VERSION)` tag. Does NOT touch `:$(MINOR_TAG)` or `:latest`. Safe to
#     run with any VERSION + PLATFORMS combination including single-arch
#     bisect runs and -rc/-bisect/-dev suffixes — rolling aliases are never
#     affected.
#
#   Phase 2 — `dashboard-multiarch-promote-aliases`: copies the exact-VERSION
#     manifest list into `:$(MINOR_TAG)` + `:latest` via
#     `docker buildx imagetools create`. Refuses to run unless:
#       (a) PLATFORMS equals the canonical multi-arch set
#           (linux/amd64,linux/arm64), AND
#       (b) VERSION matches release semver (^[0-9]+\.[0-9]+\.[0-9]+$ — no
#           -rc/-bisect/-dev suffixes), AND
#       (c) the source `:$(VERSION)` tag is already verified multi-arch on
#           the remote registry.
#     `FORCE_ALIAS=1` overrides (a) + (b) for emergency operator use only.
#
# This split closes the atomic-alias-promotion-on-single-arch-build defect
# class: a single buildx invocation publishing `:VERSION` + `:MINOR` +
# `:latest` atomically would have promoted an arm64-only bisect image (or an
# -rc tag) to `:0.8` + `:latest` before the verifier could fire, recreating
# the exact `exec format error` failure Sim 5 Gap #3 is meant to prevent.
#
# Default arguments are the production release values; override at the
# command line for bisect / staging runs:
#
#   make dashboard-multiarch-build                                  # exact tag only, multi-arch
#   make dashboard-multiarch-build VERSION=0.8.2                    # exact :0.8.2 only
#   make dashboard-multiarch-build VERSION=0.8.1-bisect-amd64 PLATFORMS=linux/amd64
#                                                                   # bisect: exact tag only, NEVER aliases
#   make dashboard-multiarch-promote-aliases VERSION=0.8.2 MINOR_TAG=0.8
#                                                                   # promote :0.8.2 -> :0.8 + :latest
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

# Phase 1: build the multi-arch dashboard image and push ONLY the exact
# :$(VERSION) tag. Re-uses the canonical `apps/dashboard/Dockerfile` which is
# multi-stage Go + distroless and cross-compiles cleanly under QEMU (CGO
# disabled).
#
# Does NOT touch `:$(MINOR_TAG)` or `:latest`. Rolling alias promotion is a
# SEPARATE target (`dashboard-multiarch-promote-aliases`) so bisect and -rc
# publishes can never advance the rolling aliases. Closes Codex r1 BLOCKER on
# PR #34 (mirrors DSA PR #196 r5/r6).
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
	@echo "Exact tag ONLY — :$(MINOR_TAG) + :latest aliases are NOT touched by this target."
	@echo "Run \`make dashboard-multiarch-promote-aliases VERSION=$(VERSION) MINOR_TAG=$(MINOR_TAG)\` to advance aliases when ready."
	docker buildx build \
		--builder $(BUILDX_BUILDER) \
		--platform $(PLATFORMS) \
		--tag $(REGISTRY)/lucairn-dashboard:$(VERSION) \
		--build-arg VERSION=$(VERSION) \
		--push \
		apps/dashboard/
	@echo ""
	@echo "Verifying $(REGISTRY)/lucairn-dashboard:$(VERSION) was published with the expected platforms ($(PLATFORMS)) ..."
	@bash scripts/verify-multiarch-manifests.sh $(REGISTRY) $(VERSION) "$(DASHBOARD_PUBLISH_SERVICES)" \
		|| (echo "  WARNING: verifier expects linux/amd64 + linux/arm64; PLATFORMS=$(PLATFORMS) may have intentionally published single-arch (bisect)." >&2; \
		    if [ "$(PLATFORMS)" = "linux/amd64,linux/arm64" ]; then echo "  PLATFORMS is the canonical multi-arch set — failing." >&2 && exit 1; \
		    else echo "  Non-canonical PLATFORMS — treating verifier exit as expected." >&2; fi)
	@echo ""
	@echo "Phase 1 (exact-tag build) complete: $(REGISTRY)/lucairn-dashboard:$(VERSION) ($(PLATFORMS))"

# Phase 2: promote the exact `:$(VERSION)` tag into rolling `:$(MINOR_TAG)` +
# `:latest` aliases. Uses `docker buildx imagetools create` to COPY the
# multi-arch manifest list — no rebuild, no layer re-upload, just a manifest
# clone. Both alias tags are written in a single invocation so they either
# both advance or both fail.
#
# GUARDS (fail-closed):
#   1. PLATFORMS must equal the canonical multi-arch set
#      (linux/amd64,linux/arm64). Single-arch / bisect runs skip alias copy
#      unless `FORCE_ALIAS=1` is set explicitly.
#   2. VERSION must match the release semver regex (^[0-9]+\.[0-9]+\.[0-9]+$).
#      Any suffix (-bisect-amd64, -rc1, -dev, etc.) skips alias copy unless
#      `FORCE_ALIAS=1` is set explicitly.
#   3. Source `:$(VERSION)` tag MUST be verified multi-arch on the remote
#      registry BEFORE any `imagetools create` call — closes the "build
#      verifier silently failed but alias copy ran anyway" race.
#   4. After alias promotion, each alias is re-verified multi-arch.
#
# FORCE_ALIAS=1 is documented in `docs/RELEASING.md` § "Emergency override".
# Use sparingly — exists only so an operator can recover from a botched
# release without manual GHCR tag surgery.
#
# IMPLEMENTATION NOTE: the entire guard recipe runs in a SINGLE shell
# invocation (one long `\\`-continued block) because each Makefile recipe
# line is a separate sub-shell — `exit 0` in an earlier line only ends that
# line's sub-shell, NOT the whole target. Without the single-shell structure,
# the "Skipping" branches would print their warning and then fall through
# into the imagetools step anyway, defeating the guard. Same shape as DSA
# `push-alias-tags` in `dual-sandbox-architecture/Makefile`.
dashboard-multiarch-promote-aliases:
	@set -e; \
	if [ "$(PLATFORMS)" != "linux/amd64,linux/arm64" ] && [ "$(FORCE_ALIAS)" != "1" ]; then \
		echo "REFUSING alias promotion: PLATFORMS=$(PLATFORMS) is not the required multi-arch set (linux/amd64,linux/arm64)." >&2; \
		echo "Re-invoke with FORCE_ALIAS=1 to override (emergency only — see docs/RELEASING.md)." >&2; \
		exit 1; \
	fi; \
	if ! echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		if [ "$(FORCE_ALIAS)" != "1" ]; then \
			echo "REFUSING alias promotion: VERSION=$(VERSION) is not a release semver (X.Y.Z)." >&2; \
			echo "Any -rc, -bisect, or -dev suffix is rejected. Re-invoke with FORCE_ALIAS=1 to override (emergency only)." >&2; \
			exit 1; \
		else \
			echo "FORCE_ALIAS=1 set — proceeding with alias copy for non-semver VERSION=$(VERSION)." >&2; \
		fi; \
	fi; \
	expected_minor=$$(echo "$(VERSION)" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/'); \
	if [ "$(MINOR_TAG)" != "$$expected_minor" ] && [ "$(FORCE_ALIAS)" != "1" ]; then \
		echo "REFUSING alias promotion: MINOR_TAG=$(MINOR_TAG) does not match major.minor of VERSION=$(VERSION) (expected $$expected_minor)." >&2; \
		echo "Promoting :$(VERSION) to :$(MINOR_TAG) would silently overwrite the wrong minor-version channel." >&2; \
		echo "Re-invoke with MINOR_TAG=$$expected_minor (or FORCE_ALIAS=1 for emergency only)." >&2; \
		exit 1; \
	fi; \
	echo "Verifying $(REGISTRY)/lucairn-dashboard:$(VERSION) is multi-arch on the registry before promoting aliases..."; \
	REQUIRED_PLATFORMS="linux/amd64 linux/arm64" bash scripts/verify-multiarch-manifests.sh $(REGISTRY) $(VERSION) "$(DASHBOARD_PUBLISH_SERVICES)"; \
	echo ""; \
	echo "Promoting $(REGISTRY)/lucairn-dashboard:$(VERSION) -> :$(MINOR_TAG) + :latest..."; \
	docker buildx imagetools create \
		--tag $(REGISTRY)/lucairn-dashboard:$(MINOR_TAG) \
		--tag $(REGISTRY)/lucairn-dashboard:latest \
		$(REGISTRY)/lucairn-dashboard:$(VERSION); \
	echo ""; \
	echo "Verifying every alias is multi-arch (Sim 5 Gap 3 regression guard) ..."; \
	REQUIRED_PLATFORMS="linux/amd64 linux/arm64" bash scripts/verify-multiarch-manifests.sh $(REGISTRY) $(MINOR_TAG) "$(DASHBOARD_PUBLISH_SERVICES)"; \
	REQUIRED_PLATFORMS="linux/amd64 linux/arm64" bash scripts/verify-multiarch-manifests.sh $(REGISTRY) latest "$(DASHBOARD_PUBLISH_SERVICES)"; \
	echo ""; \
	echo "Alias promotion complete: :$(MINOR_TAG) + :latest now point at :$(VERSION)."

# Regression guard for Sim 5 Gap 3. Asserts that every published dashboard tag
# (exact / minor / latest) contains BOTH `linux/amd64` and `linux/arm64` in its
# manifest list. Re-uses `scripts/verify-multiarch-manifests.sh` (vendored from
# dual-sandbox-architecture PR #196). Operator-facing convenience that checks
# all three tags at once; individual targets call the script directly with
# only the tags they actually touched.
dashboard-verify-manifests:
	@bash scripts/verify-multiarch-manifests.sh $(REGISTRY) $(VERSION) "$(DASHBOARD_PUBLISH_SERVICES)"
	@bash scripts/verify-multiarch-manifests.sh $(REGISTRY) $(MINOR_TAG) "$(DASHBOARD_PUBLISH_SERVICES)"
	@bash scripts/verify-multiarch-manifests.sh $(REGISTRY) latest "$(DASHBOARD_PUBLISH_SERVICES)"

clean:
	rm -rf dist support-bundles
