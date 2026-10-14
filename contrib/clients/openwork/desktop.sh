#!/usr/bin/env bash
#
# contrib/clients/openwork/desktop.sh — the OpenWork DESKTOP app (dev build from a
# source checkout at tag v0.18.58) through the Lucairn gateway. macOS.
#
#   desktop.sh            start it (returns once the window shows the Lucairn model)
#   desktop.sh stop       close it and wipe the app's browser storage
#
# Needs OPENWORK_SRC = a clone of https://github.com/different-ai/openwork at tag
# v0.18.58 with its dependencies installed once:
#   git clone --depth 1 --branch v0.18.58 https://github.com/different-ai/openwork.git <dir>
#   cd <dir> && pnpm install --frozen-lockfile        (about 3.5 GB)
# The signed OpenWork installer is NOT what was verified.
#
# What this launcher does on top of openwork.sh's settings (same keys, same config writer):
#   - storage wipe on EVERY start and EVERY stop (and when the window is closed):
#     the interface caches the provider list in its browser storage
#   - the app's own Electron profile lives in the Lucairn profile folder; macOS
#     Keychain access of the app is replaced by its mock store
#     (OPENWORK_ELECTRON_USE_MOCK_KEYCHAIN=1), no system-wide link handler
#   - the "OpenWork Cloud" address points at a dead local address
#     (OPENWORK_DESKTOP_BOOTSTRAP_PATH), so no sign-in / cloud model is offered
#   - the app's workspace folder = the work folder (path without the account name)
#   - preselects "Claude … via Lucairn" through the app's local debug port
#     (127.0.0.1 only, open while the app runs): no config setting exists for the
#     starting model, and a wiped storage would start on a hosted model
#
# Environment: as openwork.sh, plus OPENWORK_SRC (required), LUCAIRN_PNPM
# (default: pnpm on PATH), LUCAIRN_BUN (default: bun on PATH; the app's build needs it), LUCAIRN_OPENWORK_DEBUG_PORT (default 19823),
# LUCAIRN_OPENWORK_DESKTOP_REBUILD=1 (run the app's build steps again).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LC_PROG="openwork/desktop.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

TAG="v0.18.58"
DATA="$(lc_data_root)"
PROFILE="${LUCAIRN_OPENWORK_PROFILE:-$DATA/openwork/profile}"
case "$PROFILE" in /*) : ;; *) lc_die "LUCAIRN_OPENWORK_PROFILE must be an absolute path" ;; esac
ST="$PROFILE/desktop"
EP="$ST/electron"
DEBUG_PORT="${LUCAIRN_OPENWORK_DEBUG_PORT:-19823}"
case "$DEBUG_PORT" in ''|*[!0-9]*) lc_die "LUCAIRN_OPENWORK_DEBUG_PORT must be a number" ;; esac
mkdir -p "$ST" "$EP" || lc_die "cannot create $ST"

wipe() {  # the interface's browser storage (where it caches the provider list)
  local d
  for d in "Local Storage" "Session Storage" "IndexedDB" "Cache" "Code Cache" "GPUCache" "Service Worker" \
           "blob_storage" "WebStorage" "Shared Dictionary" "DawnGraphiteCache" "DawnWebGPUCache" "shared_proto_db" "databases"; do
    rm -rf "${EP:?}/$d"
  done
}

stop_app() {
  : > "$ST/stopped"
  local pg w
  pg="$(cat "$ST/desktop.pgid" 2>/dev/null || true)"
  if [ -n "$pg" ]; then
    kill -INT -"$pg" 2>/dev/null
    for _ in 1 2 3 4 5 6; do kill -0 -"$pg" 2>/dev/null || break; sleep 1; done
    kill -TERM -"$pg" 2>/dev/null; sleep 2; kill -KILL -"$pg" 2>/dev/null
  fi
  if [ "${LC_FROM_WATCHER:-0}" != 1 ]; then
    w="$(cat "$ST/watcher.pid" 2>/dev/null || true)"; [ -n "$w" ] && kill "$w" 2>/dev/null
  fi
  rm -f "$ST/desktop.pgid" "$ST/watcher.pid"
  sleep 1
  wipe
  lc_say "stopped (app browser storage wiped)"
}

case "${1:-}" in
  stop) stop_app; exit 0 ;;
  ""|start) : ;;
  *) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

[ "$(uname -s)" = Darwin ] || lc_die "the desktop launcher is verified on macOS only"
SRC="${OPENWORK_SRC:-}"
if ! { [ -n "$SRC" ] && [ -f "$SRC/package.json" ] && [ -d "$SRC/apps/desktop" ]; }; then lc_die "set OPENWORK_SRC to an OpenWork source clone at $TAG (see the header of this file)"; fi
SRC="$(cd "$SRC" && pwd -P)"
if command -v git >/dev/null 2>&1; then
  GOT_TAG="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
  [ "$GOT_TAG" = "$TAG" ] || lc_die "OPENWORK_SRC is at '${GOT_TAG:-no tag}', the verified build is $TAG"
fi
[ -d "$SRC/node_modules" ] || lc_die "OPENWORK_SRC has no node_modules — run 'pnpm install --frozen-lockfile' in it once"
NODE="${LUCAIRN_NODE:-$(command -v node 2>/dev/null || true)}"
PNPM="${LUCAIRN_PNPM:-$(command -v pnpm 2>/dev/null || true)}"
BUN="${LUCAIRN_BUN:-$(command -v bun 2>/dev/null || true)}"
if ! { [ -n "$NODE" ] && [ -x "$NODE" ]; }; then lc_die "node not found (set LUCAIRN_NODE)"; fi
if ! { [ -n "$PNPM" ] && [ -x "$PNPM" ]; }; then lc_die "pnpm not found (set LUCAIRN_PNPM)"; fi
if ! { [ -n "$BUN" ] && [ -x "$BUN" ]; }; then lc_die "bun not found (the app's build step needs it; set LUCAIRN_BUN)"; fi
NODE_DIR="$(cd "$(dirname "$NODE")" && pwd)"; PNPM_DIR="$(cd "$(dirname "$PNPM")" && pwd)"; BUN_DIR="$(cd "$(dirname "$BUN")" && pwd)"

if [ -s "$ST/desktop.pgid" ] && kill -0 "$(cat "$ST/desktop.pgid")" 2>/dev/null; then
  lc_die "already running — stop it first: $0 stop"
fi
MODEL="${LUCAIRN_OPENWORK_MODEL:-claude-sonnet-5-5}"
MCP="${LUCAIRN_OPENWORK_MCP:-}"
[ -z "$MCP" ] || [ -f "$MCP" ] || lc_die "LUCAIRN_OPENWORK_MCP file not found: $MCP"
REBUILD="${LUCAIRN_OPENWORK_DESKTOP_REBUILD:-}"
WORK="$(lc_work_dir_check "${LUCAIRN_WORK_DIR:-$(lc_default_work_parent)/openwork}")" || exit 2
GW="$(lc_gateway_url)"
lc_load_keys

rm -f "$ST/stopped"
wipe
# Engine config (no key in it), in both places the dev build reads it from.
CFG_ARGS=("model=$MODEL" files); [ -n "$MCP" ] && CFG_ARGS+=("mcp=$MCP")
mkdir -p "$EP/openwork-dev-data/xdg/config/opencode" "$ST/xdg/config/opencode" "$ST/home" "$ST/tmp" "$ST/corepack"
"$NODE" "$HERE/lib/config.mjs" "$ST/xdg/config/opencode/opencode.json" "$HERE/plugin" "${CFG_ARGS[@]}" || lc_die "could not write the engine config"
cp "$ST/xdg/config/opencode/opencode.json" "$EP/openwork-dev-data/xdg/config/opencode/opencode.json"
# Workspace folder = the work folder.
"$NODE" -e '
const fs = require("fs"); const [f, w] = process.argv.slice(1);
let d;
if (fs.existsSync(f)) { d = JSON.parse(fs.readFileSync(f, "utf8")); for (const x of d.workspaces || []) { x.path = w; } }
else { const id = "ws_" + require("crypto").randomBytes(6).toString("hex");
  d = { selectedId: id, watchedId: id, activeId: id, selectedWorkspaceId: id, watchedWorkspaceId: id,
        workspaces: [{ id, name: "Lucairn work", path: w, preset: "starter", workspaceType: "local", baseUrl: null, directory: null,
                       displayName: "Lucairn work", sandboxBackend: null, sandboxRunId: null, sandboxContainerName: null }] }; }
fs.writeFileSync(f, JSON.stringify(d, null, 2));' "$EP/openwork-workspaces.json" "$WORK" || lc_die "could not set the workspace folder"
printf '{"baseUrl":"http://127.0.0.1:9","requireSignin":false}\n' > "$ST/desktop-bootstrap.json"

SKIP=1; { [ -n "$REBUILD" ] || [ ! -f "$ST/built-$TAG" ]; } && SKIP=0
umask 077
(
  cd "$SRC" || exit 3
  lc_scrub_env
  export PATH="$NODE_DIR:$PNPM_DIR:$BUN_DIR:$PATH"
  export HOME="$ST/home" USERPROFILE="$ST/home" CFFIXED_USER_HOME="$ST/home" TMPDIR="$ST/tmp/"
  export XDG_CONFIG_HOME="$ST/xdg/config" XDG_DATA_HOME="$ST/xdg/data" XDG_CACHE_HOME="$ST/xdg/cache" XDG_STATE_HOME="$ST/xdg/state"
  export COREPACK_HOME="$ST/corepack" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 DO_NOT_TRACK=1
  export OPENWORK_DEV_MODE=1 OPENWORK_ELECTRON_REMOTE_DEBUG_PORT="$DEBUG_PORT" PORT=15173
  export OPENWORK_ELECTRON_USERDATA="$EP" OPENWORK_ELECTRON_USE_MOCK_KEYCHAIN=1 OPENWORK_ELECTRON_DISABLE_PROTOCOL_REGISTRATION=1
  export OPENWORK_DISABLE_FREE_INFERENCE=1 OPENWORK_NO_UPDATE_CHECK=1 OPENCODE_DISABLE_MODELS_FETCH=1
  export OPENCODE_DISABLE_EXTERNAL_SKILLS=1 OPENCODE_DISABLE_CLAUDE_CODE=1
  export OPENWORK_DESKTOP_BOOTSTRAP_PATH="$ST/desktop-bootstrap.json"
  if [ "$SKIP" = 1 ]; then export OPENWORK_ELECTRON_SKIP_SHARED_PREPARE=1 OPENWORK_ELECTRON_SKIP_WORKSPACE_BUILD=1; fi
  export LUCAIRN_BASE_URL="$GW/v1" LUCAIRN_API_KEY="$LC_LUCAIRN_KEY" LUCAIRN_UPSTREAM_KEY="$LC_UPSTREAM_KEY"
  exec perl -e 'setpgrp(0,0); exec @ARGV' "$PNPM" dev
) > "$ST/desktop.log" 2>&1 &
echo "$!" > "$ST/desktop.pgid"
unset LC_LUCAIRN_KEY LC_UPSTREAM_KEY
PG="$(cat "$ST/desktop.pgid")"
sleep 3

# Watcher: when the app is gone (window closed, crash), run the stop routine = wipe on exit.
(
  while kill -0 "$PG" 2>/dev/null; do sleep 2; done
  [ -f "$ST/stopped" ] || LC_FROM_WATCHER=1 "$0" stop >/dev/null 2>&1
) >/dev/null 2>&1 &
echo "$!" > "$ST/watcher.pid"

lc_say "starting the desktop app$([ "$SKIP" = 0 ] && echo ' (first start: building the app, several minutes)') — log $ST/desktop.log"
ok=0
for _ in $(seq 1 300); do
  kill -0 "$PG" 2>/dev/null || break
  if curl -s -m 2 "http://127.0.0.1:$DEBUG_PORT/json" 2>/dev/null | grep -q '"type": "page"'; then ok=1; break; fi
  sleep 2
done
[ "$ok" = 1 ] || { lc_say "the desktop app did not come up — see $ST/desktop.log"; "$0" stop; exit 1; }
: > "$ST/built-$TAG"
sleep 6
# Preselect the Lucairn model (the page reloads once), then wait until the reloaded page shows it.
CDP=("$NODE" "$HERE/lib/cdp.mjs" "$DEBUG_PORT")
"${CDP[@]}" eval "(() => { localStorage.setItem('openwork.defaultModel', 'lucairn/$MODEL'); localStorage.setItem('openwork.modelChoice.explicit', '1'); setTimeout(() => location.reload(), 300); return localStorage.getItem('openwork.defaultModel'); })()" >/dev/null 2>&1 \
  || lc_say "note: could not preselect the model — pick 'via Lucairn' under the text box before the first message"
shown=0
for _ in $(seq 1 30); do sleep 2; "${CDP[@]}" text 2>/dev/null | grep -q "via Lucairn" && { shown=1; break; }; done
[ "$shown" = 1 ] || lc_say "note: the Lucairn model name is not shown under the text box yet — check before the first message"
lc_say "started; model lucairn/$MODEL; work folder $WORK. Stop with: $0 stop"
