#!/usr/bin/env bash
#
# contrib/clients/openwork/openwork.sh — run OpenWork (its host + OpenCode engine) through the Lucairn gateway.
#
#   openwork.sh ask "question"                one message in a new chat, prints the answer
#   openwork.sh ask "first" "second"          several messages in ONE chat
#   openwork.sh ask --continue "next"         continue the most recent chat
#   openwork.sh ask --work "file task"        with the engine's file tools (read, write, edit) in the work folder
#   openwork.sh list                          stored chats (no model call)
#   openwork.sh web                           the OpenWork web page on http://127.0.0.1:18787 (Ctrl+C stops it)
#   ./desktop.sh                              the desktop app (separate launcher, see README)
#
# Setup once: ./install.sh, then both keys in the macOS Keychain or the
# environment (README "Keys"). This launcher:
#   - writes the engine config from lib/config.mjs: Lucairn the ONLY provider,
#     title request off, every tool denied unless named, standing instructions
#     (plugin/lucairn-rules.md) — and NO key in it: the key helper
#     (plugin/lucairn-keys-from-env.js) adds both keys from the engine's
#     environment on gateway requests only, so they never reach the
#     interface's storage
#   - drops every inherited variable before it runs anything (the config writer
#     and the chat helper never see the keys); all state lives in the profile
#     folder; the keys go into the host's environment only
#   - sets OPENWORK_DISABLE_FREE_INFERENCE / OPENWORK_NO_UPDATE_CHECK and the
#     engine switches (no model-list fetch, no auto-update, no external skills)
#   - runs in the work folder, refusing a folder whose path holds the account name
#
# Environment (all optional):
#   LUCAIRN_GATEWAY_URL        default https://gateway.lucairn.eu
#   LUCAIRN_API_KEY / LUCAIRN_UPSTREAM_KEY, or Keychain items LUCAIRN_KEYCHAIN_ITEM
#                              (default lucairn-api-key) / LUCAIRN_UPSTREAM_KEYCHAIN_ITEM (default lucairn-upstream-key)
#   LUCAIRN_OPENWORK_DIR       the install (default <data>/openwork/0.18.58)
#   LUCAIRN_OPENWORK_PROFILE   state folder (default <data>/openwork/profile)
#   LUCAIRN_WORK_DIR           work folder (default /Users/Shared/agent-work/openwork on macOS)
#   LUCAIRN_OPENWORK_MODEL     claude-haiku-4-5 (default) | claude-sonnet-5-5 (default with --work)
#   LUCAIRN_OPENWORK_MCP       a JSON file {"mcp": {...}, "allow": [tool names]} to add MCP tools
#   LUCAIRN_OPENWORK_PORT      host port, default 18787
#   LUCAIRN_NODE               node binary (default: node on PATH; needs >= 22.13)
# <data> = ${LUCAIRN_CLIENTS_HOME:-~/.local/share/lucairn-clients}

set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "$HERE" && pwd)"
LC_PROG="openwork.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"   # takes both keys out of the environment at once

VERSION="0.18.58"
DATA="$(lc_data_root)"
BASE="${LUCAIRN_OPENWORK_DIR:-$DATA/openwork/$VERSION}"
PROFILE="${LUCAIRN_OPENWORK_PROFILE:-$DATA/openwork/profile}"
OWS="$BASE/node_modules/openwork-server/bin/openwork-server.mjs"
[ -f "$OWS" ] || lc_die "OpenWork host is not installed at $BASE — run $HERE/install.sh first"
case "$PROFILE" in /*) : ;; *) lc_die "LUCAIRN_OPENWORK_PROFILE must be an absolute path" ;; esac
NODE="${LUCAIRN_NODE:-$(command -v node 2>/dev/null || true)}"
if ! { [ -n "$NODE" ] && [ -x "$NODE" ]; }; then lc_die "node not found (set LUCAIRN_NODE)"; fi
PORT="${LUCAIRN_OPENWORK_PORT:-18787}"
case "$PORT" in ''|*[!0-9]*) lc_die "LUCAIRN_OPENWORK_PORT must be a number" ;; esac

CMD="${1:-}"; [ $# -gt 0 ] && shift
FILES=0; CONT=0; LIST=0
case "$CMD" in
  ask)
    while :; do case "${1:-}" in
      --work) FILES=1; shift ;;
      --continue) CONT=1; shift ;;
      *) break ;; esac; done
    [ $# -ge 1 ] || lc_die "ask needs at least one message" ;;
  list) LIST=1 ;;
  web) : ;;
  *) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
MODEL="${LUCAIRN_OPENWORK_MODEL:-$([ "$FILES" = 1 ] && echo claude-sonnet-5-5 || echo claude-haiku-4-5)}"
MCP="${LUCAIRN_OPENWORK_MCP:-}"
[ -z "$MCP" ] || [ -f "$MCP" ] || lc_die "LUCAIRN_OPENWORK_MCP file not found: $MCP"

NODE_DIR="$(cd "$(dirname "$NODE")" && pwd)"
lc_gateway_url                                                                # sets LC_GW, or stops
lc_work_dir_check "${LUCAIRN_WORK_DIR:-$(lc_default_work_parent)/openwork}"   # sets LC_WORK, or stops
lc_load_keys                                                                  # shell variables only
lc_scrub_env                    # from here on: no inherited variable reaches any program

for d in home xdg/config/opencode xdg/data xdg/cache xdg/state tmp; do mkdir -p "$PROFILE/$d" || lc_die "cannot create $PROFILE/$d"; done
CFG_ARGS=("model=$MODEL"); if [ "$FILES" = 1 ]; then CFG_ARGS+=(files); fi; if [ -n "$MCP" ]; then CFG_ARGS+=("mcp=$MCP"); fi
"$NODE" "$HERE/lib/config.mjs" "$PROFILE/xdg/config/opencode/opencode.json" "$HERE/plugin" "${CFG_ARGS[@]}" \
  || lc_die "could not write the engine config"

LOG="$PROFILE/tmp/host-$$.log"
cd "$LC_WORK" || lc_die "cannot enter $LC_WORK"
export PATH="$NODE_DIR:$PATH"
export HOME="$PROFILE/home" USERPROFILE="$PROFILE/home" CFFIXED_USER_HOME="$PROFILE/home"
export XDG_CONFIG_HOME="$PROFILE/xdg/config" XDG_DATA_HOME="$PROFILE/xdg/data"
export XDG_CACHE_HOME="$PROFILE/xdg/cache" XDG_STATE_HOME="$PROFILE/xdg/state" TMPDIR="$PROFILE/tmp/"
lc_windows_homes "$PROFILE/home" "$PROFILE/tmp"
export npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false OPENWORK_PACKAGE_ROOT=""
export OPENWORK_DISABLE_FREE_INFERENCE=1 OPENWORK_NO_UPDATE_CHECK=1
export OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_AUTOUPDATE=1
export OPENCODE_DISABLE_EXTERNAL_SKILLS=1 OPENCODE_DISABLE_CLAUDE_CODE=1
export LUCAIRN_BASE_URL="$LC_GW/v1"

start_host() {  # the keys enter the environment here, for the host (and its engine) only
  lc_exec_client "$NODE" "$OWS" web --port "$PORT" --host 127.0.0.1 --no-log-requests
}

if [ "$CMD" = web ]; then
  printf 'openwork.sh: OpenWork web page on http://127.0.0.1:%s (127.0.0.1 only), model lucairn/%s — Ctrl+C stops it.\n' "$PORT" "$MODEL" >&2
  printf 'openwork.sh: the page keeps its provider list in your browser storage; with the key helper that list holds a placeholder, not a key. Still, use a separate browser profile.\n' >&2
  start_host
fi

umask 077
start_host > "$LOG" 2>&1 &
SRV=$!
unset LC_LUCAIRN_KEY LC_UPSTREAM_KEY
# shellcheck disable=SC2317,SC2329  # invoked via the EXIT trap
stop_host() {
  kill "$SRV" 2>/dev/null
  for _ in 1 2 3 4 5; do kill -0 "$SRV" 2>/dev/null || break; sleep 1; done
  kill -9 "$SRV" 2>/dev/null
  rm -f "$LOG"
  return 0
}
trap stop_host EXIT
trap 'exit 130' INT TERM HUP

URL=""
for _ in $(seq 1 120); do
  URL="$(sed -n 's/.*OpenWork web UI: \(http:[^ ]*\).*/\1/p' "$LOG" 2>/dev/null | head -n 1 | tr -d '\r')"
  [ -n "$URL" ] && break
  kill -0 "$SRV" 2>/dev/null || { sed -E 's/(token): [A-Za-z0-9]{20,}/\1: <redacted>/I' "$LOG" >&2; lc_die "the OpenWork host stopped during start"; }
  sleep 1
done
[ -n "$URL" ] || lc_die "the OpenWork host did not start within 120 s"

OW_URL="$URL" OW_TOKENS="$HOME/.openwork/openwork-server/web-tokens.json" OW_MODEL="lucairn/$MODEL" \
  OW_CONTINUE="$CONT" OW_LIST="$LIST" "$NODE" "$HERE/lib/ask.mjs" "$@"
rc=$?
exit "$rc"
