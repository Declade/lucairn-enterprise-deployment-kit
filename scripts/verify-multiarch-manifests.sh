#!/usr/bin/env bash
# verify-multiarch-manifests.sh — regression guard for Sim 4 Gap 5 +
# Sim 5 Gap 3 (dashboard arm64-only).
#
# Asserts that every published Lucairn image contains BOTH linux/amd64 AND
# linux/arm64 in its multi-arch manifest list. Exits non-zero on the first
# mismatch — release pipeline (Makefile `dashboard-multiarch-build`) treats
# this as a blocking gate.
#
# Background:
# - Sim 4 (2026-05-25) found `ghcr.io/declade/dsa-*:0.4.0` were arm64-only
#   single-arch manifests. Every x86_64 customer hit `exec /bin/sh: exec format
#   error` at healthcheck time. See
#   `Opus Advisor/specs/sim4-enterprise-end-to-end-2026-05-25.md` § Gap 5.
#   Closed by `dual-sandbox-architecture` PR #196.
# - Sim 5 (2026-05-25) found the same defect class re-surfaced on
#   `ghcr.io/declade/lucairn-dashboard:0.8.1` (also arm64-only). This kit-side
#   copy of the verifier was vendored alongside the
#   `dashboard-multiarch-build` Makefile target. See
#   `Opus Advisor/specs/sim5-compose-x86-2026-05-25.md` § Gap #3.
# - This script enforces "multi-arch or fail loudly" for every future publish.
#
# Vendored from `dual-sandbox-architecture/scripts/verify-multiarch-manifests.sh`
# (PR #196). The two copies stay BYTE-IDENTICAL on the platform-checking core —
# only the comment header differs. When the DSA-side script changes, port the
# functional diff here.
#
# Usage:
#   verify-multiarch-manifests.sh <registry> <version> "<space-separated services>"
#
# Examples:
#   verify-multiarch-manifests.sh ghcr.io/declade 0.4.1 "dsa-audit dsa-gateway ..."
#   verify-multiarch-manifests.sh ghcr.io/declade 0.8.1 "lucairn-dashboard"
#
# Required platforms for any published image (override via REQUIRED_PLATFORMS):
#   linux/amd64 linux/arm64

set -euo pipefail

REGISTRY="${1:?usage: $0 <registry> <version> <services>}"
VERSION="${2:?usage: $0 <registry> <version> <services>}"
SERVICES="${3:?usage: $0 <registry> <version> <services>}"

REQUIRED_PLATFORMS="${REQUIRED_PLATFORMS:-linux/amd64 linux/arm64}"

# `docker buildx imagetools inspect` works against a remote registry without
# pulling the layers (vs `docker manifest inspect` which has been deprecated in
# Docker 23+). It also handles both OCI image-index and legacy Docker manifest-
# list formats transparently. If buildx is missing, fall back to `docker
# manifest inspect` (legacy path).
inspect_platforms() {
	local image="$1"
	if docker buildx imagetools inspect "$image" >/dev/null 2>&1; then
		# Filter `unknown/unknown` entries — those are buildx provenance
		# attestation manifests (appear by default since buildx 0.13) and
		# pollute the operator-facing "Published platforms" summary even
		# though they don't break the required-platforms check itself.
		docker buildx imagetools inspect "$image" \
			| awk '/^[[:space:]]*Platform:/ && $2 != "unknown/unknown" {print $2}' \
			| sort -u
	else
		# Fallback: requires `experimental: enabled` in docker config.
		docker manifest inspect "$image" 2>/dev/null \
			| python3 -c '
import json, sys
m = json.load(sys.stdin)
manifests = m.get("manifests") or []
for entry in manifests:
    plat = entry.get("platform", {})
    os_ = plat.get("os", "")
    arch = plat.get("architecture", "")
    if os_ and arch and arch != "unknown":
        print(f"{os_}/{arch}")
' | sort -u
	fi
}

failed=0
total=0
echo "Verifying multi-arch manifests for $REGISTRY at tag $VERSION"
echo "Required platforms: $REQUIRED_PLATFORMS"
echo ""

for service in $SERVICES; do
	total=$((total + 1))
	image="$REGISTRY/$service:$VERSION"
	printf "  %s ... " "$image"

	platforms="$(inspect_platforms "$image" || true)"

	if [ -z "$platforms" ]; then
		echo "FAIL (no manifest found — image may not exist or registry auth failed)"
		failed=$((failed + 1))
		continue
	fi

	missing=""
	for required in $REQUIRED_PLATFORMS; do
		if ! echo "$platforms" | grep -qxF "$required"; then
			missing="${missing}${required} "
		fi
	done

	if [ -n "$missing" ]; then
		# Squash newlines for one-line summary.
		all_platforms="$(echo "$platforms" | tr '\n' ',' | sed 's/,$//')"
		echo "FAIL (missing: $missing| found: $all_platforms)"
		failed=$((failed + 1))
	else
		all_platforms="$(echo "$platforms" | tr '\n' ',' | sed 's/,$//')"
		echo "OK ($all_platforms)"
	fi
done

echo ""
if [ "$failed" -gt 0 ]; then
	echo "FAIL: $failed of $total images missing required platforms."
	echo "This is the Sim 4 Gap 5 regression. Re-run 'make push-images' with the"
	echo "default PLATFORMS=linux/amd64,linux/arm64 before tagging the release."
	exit 1
fi

echo "PASS: all $total images contain $REQUIRED_PLATFORMS."
