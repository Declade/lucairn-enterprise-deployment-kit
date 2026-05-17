#!/usr/bin/env bash
#
# Fetch + write the dashboard's self-hosted webfont binaries into
# apps/dashboard/static/fonts/. Idempotent: re-running it overwrites the
# woff2 binaries with fresh copies but leaves fonts.css alone.
#
# Sources (all GDPR-friendly — bundled, NOT delivered from a 3rd-party CDN
# at user runtime):
#   Geist (variable woff2):           vercel/geist-font GitHub release zip
#   Geist Mono (variable woff2):      vercel/geist-font GitHub release zip
#   Bricolage Grotesque (variable):   Google Fonts (downloaded once and
#                                     committed; users never hit fonts.gstatic.com)
#
# Usage:
#   bash apps/dashboard/scripts/fetch-fonts.sh
#
# Requires: curl + unzip + a network connection. The script fails the
# workstream if any download fails — Slice 1 must ship with fonts present.

set -euo pipefail

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/static/fonts"
TMP_DIR="$(mktemp -d -t lucairn-fonts.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$OUT_DIR"

GEIST_VERSION="${GEIST_VERSION:-1.8.0}"
GEIST_ZIP_URL="https://github.com/vercel/geist-font/releases/download/${GEIST_VERSION}/geist-font-${GEIST_VERSION}.zip"

echo "fetch-fonts: writing into $OUT_DIR"

# 1) Geist + Geist Mono — release zip ships variable woff2 files.
echo "fetch-fonts: downloading Geist ${GEIST_VERSION} release zip"
curl -fsSL --retry 3 -o "$TMP_DIR/geist.zip" "$GEIST_ZIP_URL"
unzip -q -o "$TMP_DIR/geist.zip" -d "$TMP_DIR/geist-unpacked"

GEIST_WGHT="$TMP_DIR/geist-unpacked/geist-font-${GEIST_VERSION}/fonts/Geist/webfonts/Geist[wght].woff2"
GEIST_MONO_WGHT="$TMP_DIR/geist-unpacked/geist-font-${GEIST_VERSION}/fonts/GeistMono/webfonts/GeistMono[wght].woff2"

[ -f "$GEIST_WGHT" ] || { echo "fetch-fonts: missing Geist[wght].woff2 in zip" >&2; exit 1; }
[ -f "$GEIST_MONO_WGHT" ] || { echo "fetch-fonts: missing GeistMono[wght].woff2 in zip" >&2; exit 1; }

cp "$GEIST_WGHT" "$OUT_DIR/Geist[wght].woff2"
cp "$GEIST_MONO_WGHT" "$OUT_DIR/GeistMono[wght].woff2"

# 2) Bricolage Grotesque — parse the woff2 URL out of Google's css2 response,
# then fetch the binary. The downloaded binary is self-hosted from
# /static/fonts/ at runtime; no part of this URL is ever requested by an
# end user's browser once shipped.
echo "fetch-fonts: resolving Bricolage Grotesque woff2 via Google Fonts CSS API"
BRICOLAGE_CSS=$(curl -fsSL \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15" \
  "https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:wght@400;500;600;700&display=swap")
BRICOLAGE_URL=$(echo "$BRICOLAGE_CSS" | grep -oE "https://fonts.gstatic.com/s/bricolagegrotesque/[^)]*\.woff2" | head -1)
if [ -z "$BRICOLAGE_URL" ]; then
  echo "fetch-fonts: could not extract Bricolage woff2 URL from Google Fonts response" >&2
  exit 1
fi
curl -fsSL --retry 3 -o "$OUT_DIR/BricolageGrotesque[wght].woff2" "$BRICOLAGE_URL"

echo "fetch-fonts: ok"
ls -lh "$OUT_DIR"
