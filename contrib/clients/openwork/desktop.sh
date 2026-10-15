#!/usr/bin/env bash
#
# contrib/clients/openwork/desktop.sh — the OpenWork DESKTOP app (dev build from a
# source checkout at tag v0.18.58) through the Lucairn gateway. macOS.
#
#   desktop.sh            start it (returns once the window shows the Lucairn model)
#   desktop.sh stop       close it and wipe the app's browser storage
#
# Needs OPENWORK_SRC = a clone of https://github.com/different-ai/openwork at tag
# v0.18.58 (commit 258218b9) with its dependencies installed once:
#   git clone --depth 1 --branch v0.18.58 https://github.com/different-ai/openwork.git <dir>
#   cd <dir> && pnpm install --frozen-lockfile        (about 3.5 GB)
# The signed OpenWork installer is NOT what was verified.
#
# What this launcher does on top of openwork.sh's settings (same keys, same config writer):
#   - refuses a checkout that is not exactly the verified commit (git required; a
#     moved tag or changed tracked files are refused)
#   - storage wipe on EVERY start and EVERY stop (and when the window is closed):
#     the interface caches the provider list in its browser storage
#   - the app's own Electron profile lives in the Lucairn profile folder; macOS
#     Keychain access of the app is replaced by its mock store
#     (OPENWORK_ELECTRON_USE_MOCK_KEYCHAIN=1), no system-wide link handler
#   - the "OpenWork Cloud" address points at a dead local address
#     (OPENWORK_DESKTOP_BOOTSTRAP_PATH), so no sign-in / cloud model is offered
#   - the app's workspace folder = the work folder (path without the account name)
#   - runs the app's build steps and its interface dev server WITHOUT the keys;
#     only the app itself (pnpm dev → Electron → host → engine) gets them
#   - preselects "Claude … via Lucairn" through the app's local debug port
#     (127.0.0.1 only, open while the app runs): no config setting exists for the
#     starting model, and a wiped storage would start on a hosted model
#   - `stop` signals only a process group it can prove is this app (start time of
#     the saved process, or a member running from the OpenWork checkout)
#
# Environment: as openwork.sh, plus OPENWORK_SRC (required), LUCAIRN_PNPM
# (default: pnpm on PATH), LUCAIRN_BUN (default: bun on PATH; the app's build needs it), LUCAIRN_OPENWORK_DEBUG_PORT (default 19823),
# LUCAIRN_OPENWORK_DESKTOP_REBUILD=1 (run the app's build steps again).

set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "$HERE" && pwd)"
LC_PROG="openwork/desktop.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"   # takes both keys out of the environment at once
if lc_is_windows; then lc_die "the desktop app launcher is not verified on Windows (macOS only) — use openwork.sh"; fi

TAG="v0.18.58"
COMMIT="258218b9b69c91e3d5020488fe1d14ff767679e9"   # what the tag pointed at on 2026-10-14; a moved tag is refused
UI_PORT=15173
DATA="$(lc_data_root)"
PROFILE="${LUCAIRN_OPENWORK_PROFILE:-$DATA/openwork/profile}"
case "$PROFILE" in /*) : ;; *) lc_die "LUCAIRN_OPENWORK_PROFILE must be an absolute path" ;; esac
mkdir -p "$PROFILE" || lc_die "cannot create the profile $PROFILE"
PROFILE="$(cd "$PROFILE" && pwd -P)" || lc_die "cannot enter the profile"
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

# Saved process ids are only signalled when they are provably still ours: a saved id
# can belong to another program after a crash or a restart.
#   desktop.pgid = 3 lines: process group id · start time of its first process · the checkout path
#   watcher.pid  = 2 lines: process id · its start time
_start_time() { ps -o lstart= -p "$1" 2>/dev/null; }
# owned_group — prints the saved process group id if that group is this app.
owned_group() {
  local pg="" lst="" src="" now
  { IFS= read -r pg; IFS= read -r lst; IFS= read -r src; } < "$ST/desktop.pgid" 2>/dev/null || return 1
  case "$pg" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$lst" ] || [ -z "$src" ]; then return 1; fi
  now="$(_start_time "$pg")"
  if [ -n "$now" ]; then
    # the first process still runs: ours only with the same start time
    if [ "$now" = "$lst" ]; then printf '%s\n' "$pg"; return 0; fi
    return 1
  fi
  # the first process is gone (its id cannot be reused while its group lives): ours only
  # if a member of that group runs from the OpenWork checkout
  if ps -A -o pgid= -o command= 2>/dev/null | awk -v g="$pg" -v s="$src/" '$1 == g && index($0, s) { f = 1 } END { exit !f }'; then
    printf '%s\n' "$pg"; return 0
  fi
  return 1
}
# owned_watcher — prints the saved watcher process id if it is still that process.
owned_watcher() {
  local w="" lst="" now
  { IFS= read -r w; IFS= read -r lst; } < "$ST/watcher.pid" 2>/dev/null || return 1
  case "$w" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$lst" ] || return 1
  now="$(_start_time "$w")"
  if [ -n "$now" ] && [ "$now" = "$lst" ]; then printf '%s\n' "$w"; return 0; fi
  return 1
}

stop_app() {  # $1 = 1 when called by the watcher (it must not signal itself)
  : > "$ST/stopped"
  local pg w
  if [ -f "$ST/desktop.pgid" ]; then
    if pg="$(owned_group)"; then
      kill -INT -"$pg" 2>/dev/null
      for _ in 1 2 3 4 5 6; do kill -0 -"$pg" 2>/dev/null || break; sleep 1; done
      kill -TERM -"$pg" 2>/dev/null; sleep 2; kill -KILL -"$pg" 2>/dev/null
    else
      lc_say "the saved process group is not (or no longer) this app — nothing signalled"
    fi
  fi
  if [ "${1:-0}" != 1 ] && [ -f "$ST/watcher.pid" ]; then
    if w="$(owned_watcher)"; then kill "$w" 2>/dev/null; fi
  fi
  rm -f "$ST/desktop.pgid" "$ST/watcher.pid"
  sleep 1
  wipe
  lc_say "stopped (app browser storage wiped)"
}

case "${1:-}" in
  stop) if [ "${2:-}" = --from-watcher ]; then stop_app 1; else stop_app 0; fi; exit 0 ;;
  ""|start) : ;;
  *) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

[ "$(uname -s)" = Darwin ] || lc_die "the desktop launcher is verified on macOS only"
SRC="${OPENWORK_SRC:-}"
case "$SRC" in /*) : ;; *) lc_die "OPENWORK_SRC must be an absolute path to an OpenWork source clone at $TAG" ;; esac
SRC="$(cd "$SRC" && pwd -P)" || lc_die "cannot enter OPENWORK_SRC"
if ! { [ -n "$SRC" ] && [ -f "$SRC/package.json" ] && [ -d "$SRC/apps/desktop" ]; }; then lc_die "set OPENWORK_SRC to an OpenWork source clone at $TAG (see the header of this file)"; fi
# The checkout must be exactly the verified source: git is required (no check = no start).
command -v git >/dev/null 2>&1 || lc_die "git not found: needed to check that OPENWORK_SRC is the verified source ($TAG, commit $COMMIT). Nothing was started."
GOT_COMMIT="$(git -C "$SRC" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null || true)"
if [ "$GOT_COMMIT" != "$COMMIT" ]; then
  lc_die "OPENWORK_SRC is at commit '${GOT_COMMIT:-unknown}', the verified build is $TAG = commit $COMMIT (a moved tag or another checkout is refused). Nothing was started."
fi
if ! git -C "$SRC" diff --quiet HEAD -- 2>/dev/null; then
  lc_die "OPENWORK_SRC has changed tracked files (git diff HEAD is not empty) — not the verified source. Nothing was started."
fi
[ -d "$SRC/node_modules" ] || lc_die "OPENWORK_SRC has no node_modules — run 'pnpm install --frozen-lockfile' in it once"
NODE="${LUCAIRN_NODE:-$(command -v node 2>/dev/null || true)}"
PNPM="${LUCAIRN_PNPM:-$(command -v pnpm 2>/dev/null || true)}"
BUN="${LUCAIRN_BUN:-$(command -v bun 2>/dev/null || true)}"
if ! { [ -n "$NODE" ] && [ -x "$NODE" ]; }; then lc_die "node not found (set LUCAIRN_NODE)"; fi
if ! { [ -n "$PNPM" ] && [ -x "$PNPM" ]; }; then lc_die "pnpm not found (set LUCAIRN_PNPM)"; fi
if ! { [ -n "$BUN" ] && [ -x "$BUN" ]; }; then lc_die "bun not found (the app's build step needs it; set LUCAIRN_BUN)"; fi
NODE_DIR="$(cd "$(dirname "$NODE")" && pwd)"; PNPM_DIR="$(cd "$(dirname "$PNPM")" && pwd)"; BUN_DIR="$(cd "$(dirname "$BUN")" && pwd)"

if [ -s "$ST/desktop.pgid" ]; then
  if owned_group >/dev/null; then lc_die "already running — stop it first: $0 stop"; fi
  rm -f "$ST/desktop.pgid"   # a stale record of an earlier run: never signalled
fi
MODEL="${LUCAIRN_OPENWORK_MODEL:-claude-sonnet-5-5}"
MCP="${LUCAIRN_OPENWORK_MCP:-}"
[ -z "$MCP" ] || [ -f "$MCP" ] || lc_die "LUCAIRN_OPENWORK_MCP file not found: $MCP"
REBUILD="${LUCAIRN_OPENWORK_DESKTOP_REBUILD:-}"
SELF="$HERE/${0##*/}"
lc_gateway_url                                                                # sets LC_GW, or stops
lc_work_dir_check "${LUCAIRN_WORK_DIR:-$(lc_default_work_parent)/openwork}"   # sets LC_WORK, or stops
lc_load_keys                                                                  # shell variables only
lc_scrub_env                    # from here on: no inherited variable reaches any program
export LUCAIRN_OPENWORK_PROFILE="$PROFILE"   # for `desktop.sh stop` started from here (watcher, failed start)

rm -f "$ST/stopped"
wipe
# Engine config (no key in it), in both places the dev build reads it from.
CFG_ARGS=("model=$MODEL" files); if [ -n "$MCP" ]; then CFG_ARGS+=("mcp=$MCP"); fi
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
fs.writeFileSync(f, JSON.stringify(d, null, 2));' "$EP/openwork-workspaces.json" "$LC_WORK" || lc_die "could not set the workspace folder"
printf '{"baseUrl":"http://127.0.0.1:9","requireSignin":false}\n' > "$ST/desktop-bootstrap.json"

SKIP=1; if [ -n "$REBUILD" ] || [ ! -f "$ST/built-$TAG" ]; then SKIP=0; fi
umask 077
# The app runs in its own process group (set -m), so `stop` can end all of it. Inside: the
# app's own build steps (what its dev script would run) and its interface dev server start
# WITHOUT the keys; lc_exec_client then hands them to `pnpm dev` (→ Electron → host → engine)
# only, with the dev script's build steps switched off.
set -m
(
  cd "$SRC" || exit 3
  export PATH="$NODE_DIR:$PNPM_DIR:$BUN_DIR:$PATH"
  export HOME="$ST/home" USERPROFILE="$ST/home" CFFIXED_USER_HOME="$ST/home" TMPDIR="$ST/tmp/"
  export XDG_CONFIG_HOME="$ST/xdg/config" XDG_DATA_HOME="$ST/xdg/data" XDG_CACHE_HOME="$ST/xdg/cache" XDG_STATE_HOME="$ST/xdg/state"
  export COREPACK_HOME="$ST/corepack" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 DO_NOT_TRACK=1
  export OPENWORK_DEV_MODE=1 OPENWORK_ELECTRON_REMOTE_DEBUG_PORT="$DEBUG_PORT" PORT="$UI_PORT"
  export OPENWORK_DATA_DIR="$ST/home/.openwork/openwork-server-dev"
  export OPENWORK_ELECTRON_USERDATA="$EP" OPENWORK_ELECTRON_USE_MOCK_KEYCHAIN=1 OPENWORK_ELECTRON_DISABLE_PROTOCOL_REGISTRATION=1
  export OPENWORK_DISABLE_FREE_INFERENCE=1 OPENWORK_NO_UPDATE_CHECK=1 OPENCODE_DISABLE_MODELS_FETCH=1
  export OPENCODE_DISABLE_EXTERNAL_SKILLS=1 OPENCODE_DISABLE_CLAUDE_CODE=1
  export OPENWORK_DESKTOP_BOOTSTRAP_PATH="$ST/desktop-bootstrap.json"
  if [ "$SKIP" = 0 ]; then
    echo "[desktop.sh] build steps (no keys)"
    ( cd apps/desktop && "$NODE" scripts/prepare-sidecar.mjs --force --outdir "$SRC/apps/desktop/resources/sidecars" ) || exit 4
    "$PNPM" --filter @openwork/headless-threads build || exit 4
    "$PNPM" --filter @openwork/remote-sessions build || exit 4
    "$PNPM" --filter openwork-server build || exit 4
  fi
  "$PNPM" --filter @openwork/desktop run rebuild:electron-native || exit 4
  echo "[desktop.sh] interface dev server on 127.0.0.1:$UI_PORT (no keys)"
  "$PNPM" -w dev:ui &
  up=0
  for _ in $(seq 1 120); do
    if curl -s -o /dev/null -m 2 "http://localhost:$UI_PORT/"; then up=1; break; fi
    sleep 1
  done
  if [ "$up" != 1 ]; then echo "[desktop.sh] the interface dev server did not come up"; exit 5; fi
  export OPENWORK_ELECTRON_SKIP_SHARED_PREPARE=1 OPENWORK_ELECTRON_SKIP_WORKSPACE_BUILD=1 OPENWORK_ELECTRON_SKIP_NATIVE_REBUILD=1
  export LUCAIRN_BASE_URL="$LC_GW/v1"
  lc_exec_client "$PNPM" dev
) > "$ST/desktop.log" 2>&1 &
PG=$!
set +m
unset LC_LUCAIRN_KEY LC_UPSTREAM_KEY
printf '%s\n%s\n%s\n' "$PG" "$(_start_time "$PG")" "$SRC" > "$ST/desktop.pgid"
sleep 3

# Watcher: when the app is gone (window closed, crash), run the stop routine = wipe on exit.
(
  while kill -0 "$PG" 2>/dev/null; do sleep 2; done
  [ -f "$ST/stopped" ] || "$SELF" stop --from-watcher >/dev/null 2>&1
) >/dev/null 2>&1 &
W=$!
printf '%s\n%s\n' "$W" "$(_start_time "$W")" > "$ST/watcher.pid"

lc_say "starting the desktop app$([ "$SKIP" = 0 ] && echo ' (first start: building the app, several minutes)') — log $ST/desktop.log"
ok=0
for _ in $(seq 1 300); do
  kill -0 "$PG" 2>/dev/null || break
  if curl -s -m 2 "http://127.0.0.1:$DEBUG_PORT/json" 2>/dev/null | grep -q '"type": "page"'; then ok=1; break; fi
  sleep 2
done
if [ "$ok" != 1 ]; then lc_say "the desktop app did not come up — see $ST/desktop.log"; "$SELF" stop; exit 1; fi
: > "$ST/built-$TAG"
sleep 6
# Preselect the Lucairn model (the page reloads once), then wait until the reloaded page shows it.
CDP=("$NODE" "$HERE/lib/cdp.mjs" "$DEBUG_PORT")
"${CDP[@]}" eval "(() => { localStorage.setItem('openwork.defaultModel', 'lucairn/$MODEL'); localStorage.setItem('openwork.modelChoice.explicit', '1'); setTimeout(() => location.reload(), 300); return localStorage.getItem('openwork.defaultModel'); })()" >/dev/null 2>&1 \
  || lc_say "note: could not preselect the model — pick 'via Lucairn' under the text box before the first message"
shown=0
for _ in $(seq 1 30); do sleep 2; if "${CDP[@]}" text 2>/dev/null | grep -q "via Lucairn"; then shown=1; break; fi; done
[ "$shown" = 1 ] || lc_say "note: the Lucairn model name is not shown under the text box yet — check before the first message"
lc_say "started; model lucairn/$MODEL; work folder $LC_WORK. Stop with: $0 stop"
