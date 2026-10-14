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
# The install is built in a temporary folder next to the final one and moved
# into place ONLY when the binary's sha256 matches the pin (pins.sh); an
# existing install whose binary does not match is moved aside (…rejected-<time>),
# never left launchable. opencode.sh checks the same pin at every start.
# Nothing global: no `npm -g`, no PATH or shell-rc edit. Needs: node + npm.
#
# Exit: 0 usable · 1 not usable · 2 a needed tool is missing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LC_PROG="opencode/install.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=pins.sh
. "$HERE/pins.sh"

VERSION="1.19.0"
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

PLAT="$(lc_os_arch)" || exit 2
REL="node_modules/opencode-$PLAT/bin/opencode$(lc_exe)"
BIN="$BASE/$REL"
WANT="$(oc_pinned_sha256 "$PLAT")" || fail "no verified OpenCode build is recorded for $PLAT"

printf 'OpenCode install — %s (%s)\n  folder : %s\n' "$VERSION" "$PLAT" "$BASE"
STAGE=""; CACHE=""
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; if [ -n "$CACHE" ]; then rm -rf "$CACHE"; fi; return 0; }
trap cleanup EXIT

if [ -x "$BIN" ]; then
  SUM="$(lc_sha256 "$BIN" 2>/dev/null)"
  if [ "$SUM" != "$WANT" ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      fail "binary sha256 ${SUM:-unreadable} does not match the verified build $WANT — opencode.sh refuses it; run without --check to replace it"
    fi
    REJ="$BASE.rejected-$(date +%Y%m%d%H%M%S)"
    mv "$BASE" "$REJ" || fail "binary sha256 ${SUM:-unreadable} does not match the verified build, and $BASE could not be moved aside"
    fail "binary sha256 ${SUM:-unreadable} does not match the verified build $WANT — moved the install aside to $REJ (not launchable); run install.sh again"
  fi
else
  if [ "$CHECK_ONLY" -eq 1 ]; then fail "not installed: $BIN is missing (run without --check)"; fi
  lc_need npm
  PARENT="$(dirname "$BASE")"
  mkdir -p "$PARENT" || fail "cannot create $PARENT"
  # Built next to the final folder (same disk, so the final move is one rename), moved in only after the pin matched.
  STAGE="$(mktemp -d "$PARENT/.opencode-$VERSION-staging.XXXXXX")" || fail "cannot create a staging folder in $PARENT"
  cp "$HERE/package.json" "$HERE/package-lock.json" "$STAGE/" || fail "cannot copy the package pin"
  CACHE="$(mktemp -d "${TMPDIR:-/tmp}/opencode-install.XXXXXX")" || fail "cannot create a temp cache"
  ( cd "$STAGE" && npm ci --ignore-scripts --no-audit --no-fund --update-notifier=false --cache "$CACHE" --loglevel=error ) \
    || fail "npm ci failed (nothing was installed)"
  [ -x "$STAGE/$REL" ] || fail "no OpenCode binary for $PLAT in the package (nothing was installed)"
  SUM="$(lc_sha256 "$STAGE/$REL" 2>/dev/null)"
  [ "$SUM" = "$WANT" ] || fail "binary sha256 ${SUM:-unreadable} does not match the verified build $WANT (nothing was installed)"
  if [ -e "$BASE" ]; then
    OLD="$BASE.incomplete-$(date +%Y%m%d%H%M%S)"
    mv "$BASE" "$OLD" || fail "cannot move the incomplete $BASE aside"
    printf '  note   : an incomplete earlier install was moved aside to %s\n' "$OLD"
  fi
  mv "$STAGE" "$BASE" || fail "cannot move the checked install into $BASE"
  STAGE=""
fi
[ -x "$BIN" ] || fail "no OpenCode binary for $PLAT at $BIN"
printf '  sha256 : %s (matches the verified build)\n' "$SUM"

# --version from a throwaway home: OpenCode creates folders in its home even for --version.
CHK="$(mktemp -d "${TMPDIR:-/tmp}/opencode-check.XXXXXX")" || fail "cannot create a check folder"
lc_windows_env "$CHK"
GOT="$(cd "$CHK" && env -i PATH=/usr/bin:/bin ${LC_WIN_ENV[@]+"${LC_WIN_ENV[@]}"} HOME="$CHK" XDG_CONFIG_HOME="$CHK/c" XDG_DATA_HOME="$CHK/d" \
  XDG_CACHE_HOME="$CHK/k" XDG_STATE_HOME="$CHK/s" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
  "$BIN" --version 2>/dev/null | tail -n 1)"
rm -rf "$CHK"
[ "$GOT" = "$VERSION" ] || fail "\`opencode --version\` says '$GOT', want $VERSION"
printf '  version: %s\nOK opencode %s usable at %s\n' "$GOT" "$VERSION" "$BASE"
