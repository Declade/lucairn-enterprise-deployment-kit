# syntax=docker/dockerfile:1.6
#
# Lucairn Enterprise Dashboard image. Multi-stage:
#   1) golang:1.23-alpine builder  → produces a statically-linked binary
#   2) gcr.io/distroless/static-debian12:nonroot runtime
#
# Final image MUST stay under 100MB.
#
# The Tailwind output dashboard.css ships pre-built in static/css/. We do
# NOT run Tailwind during the Docker build because the standalone binary is
# OS-specific and that would force a Node toolchain into the runtime image.
# `bash apps/dashboard/scripts/fetch-fonts.sh` and the Tailwind build are
# host-side prep steps; CI re-runs them on a Linux runner before docker
# build to catch drift.

# Base images pinned by sha256 digest (SUP-06 supply-chain hardening) so the
# build cannot silently float to a re-tagged upstream. Bump the digest
# alongside the tag when intentionally upgrading.
FROM golang:1.23-alpine@sha256:383395b794dffa5b53012a212365d40c8e37109a626ca30d6151c8348d380b5f AS builder
WORKDIR /src

# Pre-cache the module graph.
COPY go.mod go.sum* ./
RUN go mod download

# Bring the rest of the dashboard source.
COPY . .

# Verify fonts + CSS + image-manifest are present BEFORE compiling. The
# Go build embeds them via //go:embed; a missing file silently produces
# a 0-byte asset, so we fail-fast at image-build time instead.
#
# The image-manifest.yaml is copied from the kit root into apps/dashboard/
# by the kit's image-build target. When missing the compliance PDF cover
# falls back to "Image manifest unavailable" copy — non-fatal but the
# customer-evidence chain loses the kit-version+image-digest footer, so
# treat as a build-time hard fail.
RUN test -f static/css/dashboard.css || (echo "missing static/css/dashboard.css — run tailwindcss before docker build" >&2 && exit 1) && \
    test -f "static/fonts/Geist[wght].woff2" || (echo "missing fonts — run scripts/fetch-fonts.sh before docker build" >&2 && exit 1) && \
    test -f static/icons/sprite.svg || (echo "missing icons sprite" >&2 && exit 1) && \
    test -f image-manifest.yaml || (echo "missing image-manifest.yaml — copy from kit root before docker build" >&2 && exit 1)

# Static, stripped, no-CGO, locked compile flags.
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION}" \
    -o /out/lucairn-dashboard .

FROM gcr.io/distroless/static-debian12:nonroot@sha256:d093aa3e30dbadd3efe1310db061a14da60299baff8450a17fe0ccc514a16639
COPY --from=builder /out/lucairn-dashboard /lucairn-dashboard

# OCI image labels — Slice 4 fold-in. Locks GHCR package metadata to the
# kit repo so the auto-generated GHCR package page links back to source
# (closes the carry-forward Marc-action of "Make the package public" via
# making the package self-documenting + the visibility toggle a one-time
# step rather than per-release). org.opencontainers.image.source MUST
# match the kit's HTTPS clone URL byte-for-byte for GHCR's auto-link to
# fire correctly.
LABEL org.opencontainers.image.source="https://github.com/Declade/lucairn-enterprise-deployment-kit"
LABEL org.opencontainers.image.description="Lucairn Enterprise Dashboard — operator UI for cert browser, server health, audit log, compliance PDF, API key management"
LABEL org.opencontainers.image.licenses="BSL-1.1"
LABEL org.opencontainers.image.url="https://lucairn.eu"
LABEL org.opencontainers.image.vendor="Lucairn UG (in Gründung)"

# Distroless runs as uid 65532 (nonroot) by default; ports >1024 are fine.
EXPOSE 8443
ENTRYPOINT ["/lucairn-dashboard"]
