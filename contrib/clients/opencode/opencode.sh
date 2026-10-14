#!/usr/bin/env bash
#
# contrib/clients/opencode/opencode.sh — start OpenCode through the Lucairn gateway.
#
#   opencode.sh                       chat in this terminal, no tools (leave with Ctrl+C)
#   opencode.sh "Reply with OK"       one question, prints the answer
#   opencode.sh --work                chat with OpenCode's file tools (read/write/edit/glob) in the work folder
#   opencode.sh --work "task"         one file task
#   opencode.sh --web                 OpenCode's local browser page (127.0.0.1 only), stop with Ctrl+C
#   opencode.sh -- session list       any other opencode command after --  (continue a chat: -- -s <id>)
#
# Setup once: ./install.sh (pinned OpenCode), then both keys in the macOS
# Keychain or the environment (README "Keys"). This launcher:
#   - drops every inherited variable (no stray provider key, no real HOME) and
#     keeps all OpenCode state in the profile folder
#   - hands both keys to the OpenCode process environment only; the config
#     files hold {env:…} references, never a key
#   - sets the safety switches that exist ONLY as environment variables
#     (no model-list fetch, no auto-update, no sharing, no LSP download,
#     no Claude Code / external skills, no project config from parent folders)
#   - runs OpenCode inside the work folder and refuses a folder whose path holds
#     the account name (the gateway replaces a name inside file paths and file
#     work can loop; the path is also in every request's system prompt)
#
# Environment (all optional):
#   LUCAIRN_GATEWAY_URL       default https://gateway.lucairn.eu
#   LUCAIRN_API_KEY / LUCAIRN_UPSTREAM_KEY, or Keychain items LUCAIRN_KEYCHAIN_ITEM
#                             (default lucairn-api-key) / LUCAIRN_UPSTREAM_KEYCHAIN_ITEM (default lucairn-upstream-key)
#   LUCAIRN_OPENCODE_DIR      the install (default <data>/opencode/1.19.0)
#   LUCAIRN_OPENCODE_PROFILE  state folder (default <data>/opencode/profile)
#   LUCAIRN_WORK_DIR          work folder (default /Users/Shared/agent-work/opencode on macOS)
#   LUCAIRN_OPENCODE_CONFIG   your own config file instead of config/opencode*.json
#                             (e.g. a copy of config/opencode-servicenow.example.json)
#   LUCAIRN_OPENCODE_MODEL    e.g. claude-sonnet-5-5 (default: the config's model)
#   LUCAIRN_OPENCODE_WEB_PORT default 14096;  LUCAIRN_NO_BROWSER=1: --web does not open a browser
# <data> = ${LUCAIRN_CLIENTS_HOME:-~/.local/share/lucairn-clients}

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LC_PROG="opencode.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

VERSION="1.19.0"
DATA="$(lc_data_root)"
BASE="${LUCAIRN_OPENCODE_DIR:-$DATA/opencode/$VERSION}"
PROFILE="${LUCAIRN_OPENCODE_PROFILE:-$DATA/opencode/profile}"
BIN="$BASE/node_modules/opencode-$(lc_os_arch)/bin/opencode"
[ -x "$BIN" ] || lc_die "OpenCode is not installed at $BASE — run $HERE/install.sh first"
case "$PROFILE" in /*) : ;; *) lc_die "LUCAIRN_OPENCODE_PROFILE must be an absolute path" ;; esac

MODE=tui; CFG="$HERE/config/opencode.json"; MSG=""; ARGS=()
case "${1:-}" in
  --work) shift; CFG="$HERE/config/opencode-work.json" ;;
  --web) shift; MODE=web ;;
esac
if [ "${1:-}" = "--" ]; then shift; MODE=raw; ARGS=("$@")
elif [ "$MODE" != web ] && [ $# -ge 1 ]; then MODE=one; MSG="$*"; fi
CFG="${LUCAIRN_OPENCODE_CONFIG:-$CFG}"
[ -f "$CFG" ] || lc_die "config file not found: $CFG"
case "$CFG" in /*) : ;; *) CFG="$(cd "$(dirname "$CFG")" && pwd)/$(basename "$CFG")" ;; esac
MODEL="${LUCAIRN_OPENCODE_MODEL:-}"
PORT="${LUCAIRN_OPENCODE_WEB_PORT:-14096}"
NOBROWSER="${LUCAIRN_NO_BROWSER:-}"
case "$PORT" in ''|*[!0-9]*) lc_die "LUCAIRN_OPENCODE_WEB_PORT must be a number" ;; esac

WORK="$(lc_work_dir_check "${LUCAIRN_WORK_DIR:-$(lc_default_work_parent)/opencode}")" || exit 2
GW="$(lc_gateway_url)"
lc_load_keys

for d in home config data cache state tmp; do mkdir -p "$PROFILE/$d" || lc_die "cannot create $PROFILE/$d"; done
cd "$WORK" || lc_die "cannot enter $WORK"

lc_scrub_env
export HOME="$PROFILE/home" XDG_CONFIG_HOME="$PROFILE/config" XDG_DATA_HOME="$PROFILE/data"
export XDG_CACHE_HOME="$PROFILE/cache" XDG_STATE_HOME="$PROFILE/state" TMPDIR="$PROFILE/tmp/"
export OPENCODE_CONFIG="$CFG"
# Standing rule in every system prompt (configs reference it as {env:LUCAIRN_RULES_FILE}): the
# gateway's placeholders in earlier tool calls/results must not make the model redo the call.
export LUCAIRN_RULES_FILE="$HERE/../lib/placeholder-rule.md"
export OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_SHARE=1
export OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_EXTERNAL_SKILLS=1
# Keeps AGENTS.md / opencode.json / their instruction files from folders ABOVE the
# work folder away from the model. Side effect: the work folder's OWN AGENTS.md
# and opencode.json are ignored too; put instructions into the config file.
export OPENCODE_DISABLE_PROJECT_CONFIG=1
export npm_config_offline=true
export LUCAIRN_BASE_URL="$GW/v1" LUCAIRN_API_KEY="$LC_LUCAIRN_KEY" LUCAIRN_UPSTREAM_KEY="$LC_UPSTREAM_KEY"
unset LC_LUCAIRN_KEY LC_UPSTREAM_KEY

M=(); [ -n "$MODEL" ] && M=(-m "anthropic/$MODEL")
case "$MODE" in
  tui) exec "$BIN" ${M[@]+"${M[@]}"} ;;
  raw) exec "$BIN" ${ARGS[@]+"${ARGS[@]}"} ;;
  one) printf '%s\n' "$MSG" | "$BIN" run ${M[@]+"${M[@]}"}; exit "${PIPESTATUS[1]}" ;;
  web)
    DIR64="$(printf '%s' "$WORK" | /usr/bin/base64 | tr '+/' '-_' | tr -d '=\n')"
    URL="http://127.0.0.1:$PORT/$DIR64/session"
    "$BIN" serve --hostname 127.0.0.1 --port "$PORT" &
    SRV=$!
    trap 'kill "$SRV" 2>/dev/null' EXIT
    trap 'exit 130' INT TERM HUP
    printf 'opencode.sh: browser page %s (127.0.0.1 only, no password) — stop with Ctrl+C\n' "$URL" >&2
    if [ -z "$NOBROWSER" ] && command -v open >/dev/null 2>&1; then
      ( sleep 4; kill -0 "$SRV" 2>/dev/null && open "$URL" ) &
    fi
    wait "$SRV" ;;
esac
