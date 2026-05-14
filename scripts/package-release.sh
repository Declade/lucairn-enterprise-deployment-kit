#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
DIST="$ROOT/dist"
ARCHIVE_NAME="lucairn-enterprise-deployment-kit-${VERSION}.tar.gz"

mkdir -p "$DIST"

if command -v helm >/dev/null 2>&1; then
  helm package "$ROOT/charts/lucairn" --destination "$DIST"
else
  echo "warn: helm not found; skipping Helm chart package" >&2
fi

tar \
  --exclude='.git' \
  --exclude='dist' \
  --exclude='support-bundles' \
  --exclude='customer.env' \
  -czf "$DIST/$ARCHIVE_NAME" \
  -C "$ROOT" .

echo "$DIST/$ARCHIVE_NAME"

