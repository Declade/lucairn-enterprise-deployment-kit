#!/usr/bin/env bash
#
# contrib/clients/openwork/install.sh — install the pinned OpenWork host
# (openwork-server 0.18.58, which runs the OpenCode 1.18.30 engine) the Lucairn
# setup was verified with.
#
#   install.sh            install if missing, then verify
#   install.sh --check    verify only: no network, nothing created
#
# One folder (override with LUCAIRN_OPENWORK_DIR):
#   ${LUCAIRN_CLIENTS_HOME:-~/.local/share/lucairn-clients}/openwork/0.18.58
# Uses `npm ci` against package-lock.json next to this script (sha512 checked),
# install scripts not run. The engine itself is fetched by the host on its
# FIRST start, from github.com (OpenCode release assets), into the profile.
# Nothing global. Needs: node >= 22.13 + npm.
#
# Exit: 0 usable · 1 not usable · 2 a needed tool is missing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LC_PROG="openwork/install.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

VERSION="0.18.58"
BASE="${LUCAIRN_OPENWORK_DIR:-$(lc_data_root)/openwork/$VERSION}"
CHECK_ONLY=0
case "${1:-}" in
  "") : ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac
fail() { printf 'openwork/install.sh: %s\n' "$*" >&2; exit 1; }
case "$BASE" in /*) : ;; *) fail "install folder must be an absolute path (got '$BASE')" ;; esac

OWS="$BASE/node_modules/openwork-server/bin/openwork-server.mjs"
printf 'OpenWork host install — openwork-server %s\n  folder : %s\n' "$VERSION" "$BASE"
if [ ! -f "$OWS" ]; then
  [ "$CHECK_ONLY" -eq 1 ] && fail "not installed: $OWS is missing (run without --check)"
  lc_need npm
  mkdir -p "$BASE" || fail "cannot create $BASE"
  cp "$HERE/package.json" "$HERE/package-lock.json" "$BASE/" || fail "cannot copy the package pin"
  CACHE="$(mktemp -d "${TMPDIR:-/tmp}/openwork-install.XXXXXX")" || fail "cannot create a temp cache"
  ( cd "$BASE" && npm ci --ignore-scripts --no-audit --no-fund --update-notifier=false --cache "$CACHE" --loglevel=error ) \
    || { rm -rf "$CACHE"; fail "npm ci failed"; }
  rm -rf "$CACHE"
fi
[ -f "$OWS" ] || fail "openwork-server missing at $OWS"
lc_need node
NODE_V="$(node --version)"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>23||(a===23&&b>=4)||(a===22&&b>=13)?0:1)' \
  || fail "node $NODE_V is too old (openwork-server needs >= 22.13)"
GOT="$(node -e 'console.log(require(process.argv[1]).version)' "$BASE/node_modules/openwork-server/package.json")"
[ "$GOT" = "$VERSION" ] || fail "installed openwork-server is $GOT, want $VERSION"
printf '  version: openwork-server %s (node %s)\nOK openwork host %s usable at %s\n' "$GOT" "$NODE_V" "$VERSION" "$BASE"
