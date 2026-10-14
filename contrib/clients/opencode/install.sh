#!/usr/bin/env bash
#
# contrib/clients/opencode/install.sh — install the pinned OpenCode (1.19.0)
# the Lucairn setup was verified with.
#
#   install.sh            install if missing, then verify
#   install.sh --check    verify only: no network, nothing created
#
# One folder (override with LUCAIRN_OPENCODE_DIR):
#   ${LUCAIRN_CLIENTS_HOME:-~/.local/share/lucairn-clients}/opencode/1.19.0
# Uses `npm ci` against the package-lock.json next to this script, so every
# package is checked against its recorded sha512. Install scripts are NOT run
# (--ignore-scripts); the launcher starts the platform binary directly.
# Nothing global: no `npm -g`, no PATH or shell-rc edit. Needs: node + npm.
#
# Exit: 0 usable · 1 not usable · 2 a needed tool is missing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LC_PROG="opencode/install.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

VERSION="1.19.0"
# Verified build (macOS arm64); other platforms print their hash for your records.
SHA256_DARWIN_ARM64="476151a6c8b56e084d223d71a9312479e3b95547f8d8649b3489577059f9c5b4"
BASE="${LUCAIRN_OPENCODE_DIR:-$(lc_data_root)/opencode/$VERSION}"

CHECK_ONLY=0
case "${1:-}" in
  "") : ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac
fail() { printf 'opencode/install.sh: %s\n' "$*" >&2; exit 1; }
case "$BASE" in /*) : ;; *) fail "install folder must be an absolute path (got '$BASE')" ;; esac

PLAT="$(lc_os_arch)"
BIN="$BASE/node_modules/opencode-$PLAT/bin/opencode"

printf 'OpenCode install — %s (%s)\n  folder : %s\n' "$VERSION" "$PLAT" "$BASE"
if [ ! -x "$BIN" ]; then
  [ "$CHECK_ONLY" -eq 1 ] && fail "not installed: $BIN is missing (run without --check)"
  lc_need npm
  mkdir -p "$BASE" || fail "cannot create $BASE"
  cp "$HERE/package.json" "$HERE/package-lock.json" "$BASE/" || fail "cannot copy the package pin"
  CACHE="$(mktemp -d "${TMPDIR:-/tmp}/opencode-install.XXXXXX")" || fail "cannot create a temp cache"
  ( cd "$BASE" && npm ci --ignore-scripts --no-audit --no-fund --update-notifier=false --cache "$CACHE" --loglevel=error ) \
    || { rm -rf "$CACHE"; fail "npm ci failed"; }
  rm -rf "$CACHE"
fi
[ -x "$BIN" ] || fail "no OpenCode binary for $PLAT at $BIN"

SUM="$(shasum -a 256 "$BIN" 2>/dev/null | awk '{print $1}')"
if [ "$PLAT" = darwin-arm64 ]; then
  [ "$SUM" = "$SHA256_DARWIN_ARM64" ] || fail "binary sha256 $SUM does not match the verified build $SHA256_DARWIN_ARM64"
  printf '  sha256 : %s (matches the verified build)\n' "$SUM"
else
  printf '  sha256 : %s (no recorded hash for %s — not the verified platform)\n' "$SUM" "$PLAT"
fi

# --version from a throwaway home: OpenCode creates folders in its home even for --version.
CHK="$(mktemp -d "${TMPDIR:-/tmp}/opencode-check.XXXXXX")" || fail "cannot create a check folder"
GOT="$(cd "$CHK" && env -i PATH=/usr/bin:/bin HOME="$CHK" XDG_CONFIG_HOME="$CHK/c" XDG_DATA_HOME="$CHK/d" \
  XDG_CACHE_HOME="$CHK/k" XDG_STATE_HOME="$CHK/s" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
  "$BIN" --version 2>/dev/null | tail -n 1)"
rm -rf "$CHK"
[ "$GOT" = "$VERSION" ] || fail "\`opencode --version\` says '$GOT', want $VERSION"
printf '  version: %s\nOK opencode %s usable at %s\n' "$GOT" "$VERSION" "$BASE"
