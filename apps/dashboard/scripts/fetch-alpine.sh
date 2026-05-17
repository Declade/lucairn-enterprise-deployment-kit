#!/usr/bin/env bash
#
# Fetch the Alpine.js standalone CDN build and stash it under
# apps/dashboard/static/js/alpine.min.js. Run once before docker build
# so the image embeds Alpine without any runtime CDN dependency. CI
# also runs this on a Linux runner before image build.
#
# Pin: Alpine 3.14.x — the standalone CDN build is wire-stable across
# 3.x. Bumping to 4.x is an API break + must be a separate slice.
#
# Hash check: a hardcoded sha256 below catches a registry-side swap
# without bumping the version pin. Update both when bumping versions.

set -euo pipefail

VERSION="${ALPINE_VERSION:-3.14.9}"
URL="https://unpkg.com/alpinejs@${VERSION}/dist/cdn.min.js"
OUT_DIR="$(cd "$(dirname "$0")/../static/js" && pwd)"
OUT_FILE="${OUT_DIR}/alpine.min.js"

# Known-good sha256 for the pinned version. CI ratchets this when the
# pin moves.
EXPECTED_SHA256="${ALPINE_SHA256:-}"

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

mkdir -p "$OUT_DIR"

echo "fetch-alpine: downloading $URL"

# Prefer curl, fall back to wget.
if have_cmd curl; then
  curl -fsSL "$URL" -o "$OUT_FILE"
elif have_cmd wget; then
  wget -q -O "$OUT_FILE" "$URL"
else
  echo "fetch-alpine: need curl or wget to download Alpine.js" >&2
  exit 1
fi

# Sanity check the download is non-trivial — bad CDNs sometimes hand
# out 0-byte files.
if [ ! -s "$OUT_FILE" ]; then
  echo "fetch-alpine: downloaded file is empty: $OUT_FILE" >&2
  exit 1
fi

# Hash check (when EXPECTED_SHA256 is set in the env).
if [ -n "$EXPECTED_SHA256" ]; then
  if have_cmd shasum; then
    GOT="$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')"
  elif have_cmd sha256sum; then
    GOT="$(sha256sum "$OUT_FILE" | awk '{print $1}')"
  else
    echo "fetch-alpine: no shasum/sha256sum available; skipping hash check" >&2
    GOT=""
  fi
  if [ -n "$GOT" ] && [ "$GOT" != "$EXPECTED_SHA256" ]; then
    echo "fetch-alpine: sha256 mismatch (got $GOT want $EXPECTED_SHA256)" >&2
    exit 1
  fi
fi

echo "fetch-alpine: wrote $OUT_FILE ($(wc -c <"$OUT_FILE") bytes)"
