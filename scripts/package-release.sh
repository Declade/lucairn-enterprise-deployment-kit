#!/usr/bin/env bash
set -euo pipefail

# pwd -P canonicalizes symlinks so the git toplevel compare below is exact.
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION="$(cat "$ROOT/VERSION")"
DIST="$ROOT/dist"
ARCHIVE_NAME="lucairn-enterprise-deployment-kit-${VERSION}.tar.gz"

mkdir -p "$DIST"

if command -v helm >/dev/null 2>&1; then
  helm package "$ROOT/charts/lucairn" --destination "$DIST"
else
  echo "warn: helm not found; skipping Helm chart package" >&2
fi

# Build the kit tarball from TRACKED files only (`git archive HEAD`) so untracked
# / gitignored material — secrets, *.env, .certs/, private keys/* — can never be
# bundled and published, while the exempted public files (keys/lucairn-cosign.pub,
# keys/image-digests-*.txt) are still shipped. Require $ROOT to be the git TOPLEVEL
# (not merely inside some parent repo's work tree) so we archive the kit's own HEAD,
# never a surrounding repo's. There is no filesystem-tar fallback: it could neither
# honour the .gitignore `keys/*` + `!keys/lucairn-cosign.pub` negation nor exclude
# secrets safely.
TOPLEVEL="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ "$TOPLEVEL" != "$ROOT" ]; then
  echo "error: package-release.sh must run from the kit's git checkout (it archives tracked files only, to avoid bundling secrets). ROOT=$ROOT toplevel=${TOPLEVEL:-<none>}" >&2
  exit 1
fi
git -C "$ROOT" archive --format=tar.gz -o "$DIST/$ARCHIVE_NAME" HEAD

echo "$DIST/$ARCHIVE_NAME"

