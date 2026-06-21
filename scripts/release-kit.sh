#!/usr/bin/env bash
#
# release-kit.sh — cut a Lucairn Enterprise Deployment Kit release.
#
# Pipeline:
#   1. assert version identity (VERSION == README target == image-manifest
#      kit_version == Chart.yaml version; dashboard appVersion == pinned image)
#   2. build the kit tarball + `helm package` the chart  (reuses package-release.sh)
#   3. cosign-sign the tarball + chart .tgz + the version feed (detached .sig)
#   4. emit dist/version-feed.json from VERSION + image-manifest + RELEASE_DATE
#      + release/version-feed.source.json (minimum_secure + advisories)
#   5. self-verify every signature with keys/lucairn-cosign.pub
#   6. with --publish: create the clean `vX.Y.Z` tag, push it, and create the
#      GitHub Release carrying the signed assets + notes (from CHANGELOG.md)
#
# DRY-RUN BY DEFAULT: steps 1–5 only — builds + signs into dist/, never tags,
# pushes, or creates a release. Pass --publish to do step 6.
#
# The cosign PRIVATE key never lives in this repo. Point COSIGN_KEY at it (on the
# release host at /home/deploy/.lucairn-cosign/<key>). If the key is encrypted,
# export COSIGN_PASSWORD (or COSIGN_PASSWORD_FILE) the way the image-signing
# ceremony does. The PUBLIC half is the customer-trusted keys/lucairn-cosign.pub
# — the same key that signs the dsa-* images, so no new trust root.
#
# Usage:
#   COSIGN_KEY=/home/deploy/.lucairn-cosign/cosign.key scripts/release-kit.sh            # dry-run
#   COSIGN_KEY=...                                       scripts/release-kit.sh --publish # real release
# Flags:
#   --publish          create + push the tag and the GitHub Release (off by default)
#   --key PATH         cosign private key (else $COSIGN_KEY)
#   --security         mark this release as a security release in the feed (latest.security=true)
#   --advisory-url URL set latest.advisory in the feed (the headline advisory for this release)
#   --no-tlog          sign/verify without the Rekor transparency log (offline / test only)
#   -h, --help         this help
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PUBLISH=0
# cosign binary. The release host keeps a pinned cosign v2.x binary off-PATH
# (the image-signing ceremony uses v2.4.1) — point COSIGN_BIN at it. The kit's
# verify path (bin/lucairn verify-images) requires cosign >= v2.0.
COSIGN_BIN="${COSIGN_BIN:-cosign}"
COSIGN_KEY="${COSIGN_KEY:-}"
# Public key the self-verify checks against. Defaults to the customer-trusted
# key — overriding it is for testing only (e.g. a throwaway dry-run keypair).
COSIGN_PUB="${COSIGN_PUB:-keys/lucairn-cosign.pub}"
SECURITY=false
ADVISORY_URL=""
TLOG=1

die() { echo "release-kit: $*" >&2; exit 1; }
note() { echo "release-kit: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --key) COSIGN_KEY="${2:?--key needs a path}"; shift ;;
    --security) SECURITY=true ;;
    --advisory-url) ADVISORY_URL="${2:?--advisory-url needs a URL}"; shift ;;
    --no-tlog) TLOG=0 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

for tool in helm jq git tar; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
command -v "$COSIGN_BIN" >/dev/null 2>&1 || die "cosign not found ($COSIGN_BIN). Set COSIGN_BIN to the pinned cosign v2.x binary (the release host keeps a v2.4.1 binary off-PATH)."
[ "$PUBLISH" = 1 ] && { command -v gh >/dev/null 2>&1 || die "--publish needs the gh CLI"; }
[ -n "$COSIGN_KEY" ] || die "set COSIGN_KEY=/path/to/cosign private key (the Lucairn key; on the release host at /home/deploy/.lucairn-cosign/)"
[ -f "$COSIGN_KEY" ] || die "cosign key not found at: $COSIGN_KEY"
[ -f "$COSIGN_PUB" ] || die "missing public verification key: $COSIGN_PUB"

VERSION="$(tr -d '[:space:]' < VERSION)"
[ -n "$VERSION" ] || die "VERSION is empty"
TAG="v${VERSION}"
DIST="$ROOT/dist"

# --- 1. version-identity equality (mirrors docs/RELEASING.md § Pre-release checklist) ---
README_VER=$(grep -oE 'Target release: `v[^`]+`' README.md | sed -E 's/.*`v(.*)`/\1/')
MANIFEST_VER=$(grep -E '^kit_version:' image-manifest.yaml | sed -E 's/.*"(.*)".*/\1/')
CHART_VER=$(grep -E '^version:' charts/lucairn/Chart.yaml | awk '{print $2}')
KIT_MMP=${VERSION%%-*}
[ "$README_VER" = "$VERSION" ] || die "version mismatch: README 'Target release' v$README_VER != VERSION $VERSION"
[ "$MANIFEST_VER" = "$VERSION" ] || die "version mismatch: image-manifest kit_version $MANIFEST_VER != VERSION $VERSION"
[ "$CHART_VER" = "$KIT_MMP" ] || die "version mismatch: Chart.yaml version $CHART_VER != $KIT_MMP (major.minor.patch of VERSION)"
# Anchored to the optional_services block ('^  lucairn-dashboard:' = 2-space
# indent); the digest-pins block is 4-space indented + has no image_tag, so this
# never picks the wrong entry.
DASH_IMG=$(awk '/^  lucairn-dashboard:/{f=1;next} f&&/image_tag:/{print;exit}' image-manifest.yaml | sed -E 's/.*"(.*)".*/\1/')
DASH_APP=$(grep -E '^appVersion:' charts/lucairn/charts/dashboard/Chart.yaml | sed -E 's/.*"(.*)".*/\1/')
[ "$DASH_IMG" = "$DASH_APP" ] || die "dashboard mismatch: image-manifest tag $DASH_IMG != dashboard Chart.yaml appVersion $DASH_APP"
note "version identity OK: kit=$VERSION chart=$CHART_VER dashboard=$DASH_APP tag=$TAG"

# --- release date (bundled, read by `bin/lucairn doctor` staleness; feed latest.released) ---
[ -f RELEASE_DATE ] || die "missing RELEASE_DATE (bump it with VERSION on every release)"
RELEASE_DATE=$(tr -d '[:space:]' < RELEASE_DATE)
echo "$RELEASE_DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "RELEASE_DATE must be YYYY-MM-DD (got: $RELEASE_DATE)"

IMAGE_TAG=$(grep -E '^default_lucairn_image_tag:' image-manifest.yaml | sed -E 's/.*"(.*)".*/\1/')
[ -n "$IMAGE_TAG" ] || die "could not read default_lucairn_image_tag from image-manifest.yaml"

# --- publish-only safety gates ---
if [ "$PUBLISH" = 1 ]; then
  # A real release MUST be Rekor-logged and MUST self-verify against the
  # customer-trusted public key. The weakening overrides are dry-run/offline only.
  echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || die "--publish requires a clean SemVer VERSION (got '$VERSION'); the kit tag scheme is vX.Y.Z with no suffix"
  [ "$TLOG" = 1 ] || die "--no-tlog cannot be combined with --publish (a real release must be Rekor-logged)"
  [ "$COSIGN_PUB" = "keys/lucairn-cosign.pub" ] || die "--publish must self-verify against keys/lucairn-cosign.pub (the COSIGN_PUB override is dry-run only)"
  [ -z "$(git status --porcelain)" ] || die "working tree is dirty (incl. untracked files) — commit the version bump before --publish"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally — bump VERSION or delete the stale tag"
  git ls-remote --tags origin "refs/tags/$TAG" | grep -q . && die "tag $TAG already exists on origin"
fi

# --- cosign tlog flags (Rekor by default, matching the image-signing ceremony) ---
SIGN_TLOG=(); VERIFY_TLOG=()
if [ "$TLOG" = 0 ]; then
  SIGN_TLOG=(--tlog-upload=false)
  VERIFY_TLOG=(--insecure-ignore-tlog=true)
  note "Rekor transparency log DISABLED (--no-tlog) — offline/test mode only"
fi

sign_blob() {  # sign_blob <file>  -> writes <file>.sig
  local f="$1"
  # ${arr[@]+"${arr[@]}"} is the set -u-safe empty-array expansion (works on bash 3.2).
  "$COSIGN_BIN" sign-blob --yes ${SIGN_TLOG[@]+"${SIGN_TLOG[@]}"} --key "$COSIGN_KEY" --output-signature "$f.sig" "$f" >/dev/null
  "$COSIGN_BIN" verify-blob ${VERIFY_TLOG[@]+"${VERIFY_TLOG[@]}"} --key "$COSIGN_PUB" --signature "$f.sig" "$f" >/dev/null \
    || die "self-verify FAILED for $f — the signature does not match $COSIGN_PUB"
  note "signed + self-verified: $(basename "$f")"
}

# --- 2. build the bundle (tarball + helm chart .tgz) ---
rm -f "$DIST/version-feed.json" "$DIST/version-feed.json.sig"
ARCHIVE="$(bash scripts/package-release.sh | tail -1)"
[ -f "$ARCHIVE" ] || die "package-release.sh did not produce a tarball"
CHART_TGZ="$DIST/lucairn-${KIT_MMP}.tgz"
[ -f "$CHART_TGZ" ] || die "helm package did not produce $CHART_TGZ (is helm installed + Chart.lock in sync?)"

# --- 3+4. emit the version feed, then sign all three artifacts ---
GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg kit "$VERSION" --arg img "$IMAGE_TAG" --arg tag "$TAG" \
  --arg released "$RELEASE_DATE" --argjson security "$SECURITY" \
  --arg advisory "$ADVISORY_URL" --arg generated "$GENERATED" \
  --slurpfile src release/version-feed.source.json \
  '{
     schema: 1,
     generated: $generated,
     latest: {
       kit_version: $kit, image_tag: $img, tag: $tag, released: $released,
       security: $security,
       advisory: (if $advisory == "" then null else $advisory end)
     },
     minimum_secure: $src[0].minimum_secure,
     advisories: $src[0].advisories
   }' > "$DIST/version-feed.json"
jq -e . "$DIST/version-feed.json" >/dev/null || die "generated version-feed.json is not valid JSON"

sign_blob "$ARCHIVE"
sign_blob "$CHART_TGZ"
sign_blob "$DIST/version-feed.json"

# --- 5. release notes from CHANGELOG.md ---
NOTES="$DIST/release-notes-${TAG}.md"
CHANGELOG_BODY="$(awk -v v="$VERSION" '
  BEGIN { hdr = "## [" v "]" }
  index($0, hdr) == 1 { inb = 1; print; next }
  /^## \[/ && inb { exit }
  inb { print }
' CHANGELOG.md)"
# Require real notes under the [VERSION] heading — not just the header line.
# Count-based (grep -c reads all input) to avoid grep -q's early-exit + pipefail interaction.
BODY_LINES=$(printf '%s\n' "$CHANGELOG_BODY" | grep -vE '^## \[' | grep -cvE '^[[:space:]]*$' || true)
[ "${BODY_LINES:-0}" -gt 0 ] || die "no release notes under [$VERSION] in CHANGELOG.md — add them before releasing"
{
  printf '%s\n' "$CHANGELOG_BODY"
  cat <<EOF

---

### Verify this release

\`\`\`bash
cosign verify-blob --key lucairn-cosign.pub \\
  --signature lucairn-enterprise-deployment-kit-${VERSION}.tar.gz.sig \\
  lucairn-enterprise-deployment-kit-${VERSION}.tar.gz
\`\`\`

The signing key (\`keys/lucairn-cosign.pub\`) is the same key that signs the
\`dsa-*\` images. Security advisories: https://lucairn.eu/security
EOF
} > "$NOTES"

echo "----------------------------------------------------------------------"
echo "artifacts in $DIST:"
for f in "$ARCHIVE" "$ARCHIVE.sig" "$CHART_TGZ" "$CHART_TGZ.sig" \
         "$DIST/version-feed.json" "$DIST/version-feed.json.sig" "$NOTES"; do
  printf '  %s\n' "${f#$ROOT/}"
done
echo "----------------------------------------------------------------------"

# --- 6. publish ---
if [ "$PUBLISH" = 0 ]; then
  note "DRY-RUN complete. Review the artifacts above, then re-run with --publish to tag + release."
  note "After publishing: copy dist/version-feed.json + .sig into lucairn-website/public/.well-known/ and deploy the site."
  exit 0
fi

git tag -a "$TAG" -m "Lucairn Enterprise Deployment Kit $TAG"
git push origin "$TAG"
gh release create "$TAG" \
  --title "Lucairn Enterprise Deployment Kit $TAG" \
  --notes-file "$NOTES" \
  "$ARCHIVE" "$ARCHIVE.sig" \
  "$CHART_TGZ" "$CHART_TGZ.sig" \
  "$DIST/version-feed.json" "$DIST/version-feed.json.sig"
note "published $TAG."
note "NEXT: copy dist/version-feed.json + dist/version-feed.json.sig into"
note "  lucairn-website/public/.well-known/ and deploy the site so check-updates sees this release."
