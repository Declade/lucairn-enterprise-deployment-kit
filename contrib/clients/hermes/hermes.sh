#!/usr/bin/env bash
#
# contrib/clients/hermes/hermes.sh — start Hermes Agent through the Lucairn gateway.
#
#   hermes.sh -z "your question"            one question, prints the answer
#   hermes.sh                               interactive chat in this terminal (leave with /exit)
#   hermes.sh --resume <id> -z "next"       continue a chat (ids: hermes.sh sessions list)
#   hermes.sh --reset-config                put the Lucairn recipe back (keeps chats)
#   hermes.sh <any other hermes arguments>
#
# Setup once: ./install.sh (pinned Hermes), then put both keys in the macOS
# Keychain or the environment (README "Keys"). This launcher:
#   - starts Hermes from an EMPTY environment: only the gateway address, the two
#     keys (process environment only, never a file or the command line), and
#     the profile paths reach it — no stray provider key, no ~/.hermes. The keys
#     leave the environment the moment the launcher starts; the helpers it runs
#     (the config check, Hermes' own first --version) never see them
#   - copies the recipe (config.yaml) into a fresh profile, and REFUSES to start
#     when the profile's config no longer has the load-bearing lines (web search
#     off, retries and recovery limits, toolsets, gateway transport, key from the
#     environment) or when the profile's .env file holds a typed-in key
#   - runs Hermes inside the work folder (file tools act there), refusing a
#     folder whose path holds the account name
#
# Environment (all optional):
#   LUCAIRN_GATEWAY_URL     default https://gateway.lucairn.eu (your own gateway: its https address)
#   LUCAIRN_API_KEY / LUCAIRN_UPSTREAM_KEY, or Keychain items
#                           LUCAIRN_KEYCHAIN_ITEM (default lucairn-api-key) /
#                           LUCAIRN_UPSTREAM_KEYCHAIN_ITEM (default lucairn-upstream-key)
#   LUCAIRN_HERMES_DIR      the install (default <data>/hermes/v2026.9.24, see install.sh)
#   LUCAIRN_HERMES_PROFILE  the Hermes profile = HERMES_HOME (default <data>/hermes/profile)
#   LUCAIRN_WORK_DIR        work folder (default /Users/Shared/agent-work/hermes on macOS)
# <data> = ${LUCAIRN_CLIENTS_HOME:-~/.local/share/lucairn-clients}

set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd "$HERE" && pwd)"
LC_PROG="hermes.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"   # takes both keys out of the environment at once

TAG="v2026.9.24"
DATA="$(lc_data_root)"
BASE="${LUCAIRN_HERMES_DIR:-$DATA/hermes/$TAG}"
if ! lc_is_abs "$BASE"; then lc_die "LUCAIRN_HERMES_DIR must be an absolute path"; fi
BASE="$(cd "$BASE" && pwd -P)" || lc_die "cannot enter the hermes install folder — run $HERE/install.sh first"
PROFILE="${LUCAIRN_HERMES_PROFILE:-$DATA/hermes/profile}"
if ! lc_is_abs "$PROFILE"; then lc_die "LUCAIRN_HERMES_PROFILE must be an absolute path"; fi
case "$PROFILE" in "$LC_HOME/.hermes"|"$LC_HOME/.hermes/"*) lc_die "refusing to use ~/.hermes as the profile" ;; esac
mkdir -p "$PROFILE" || lc_die "cannot create the profile $PROFILE"
PROFILE="$(cd "$PROFILE" && pwd -P)" || lc_die "cannot enter the profile"
RECIPE="$HERE/config.yaml"
BIN="$BASE/.venv/$(lc_venv_bin)/hermes$(lc_exe)"
PY="$BASE/.venv/$(lc_venv_bin)/python$(lc_exe)"

case "$PROFILE" in "$LC_HOME/.hermes"|"$LC_HOME/.hermes/"*) lc_die "refusing to use ~/.hermes as the profile" ;; esac
[ -x "$BIN" ] || lc_die "Hermes is not installed at $BASE — run $HERE/install.sh first"
HH="$PROFILE/hermes-home"

if [ "${1:-}" = "--reset-config" ]; then
  mkdir -p "$HH" || lc_die "cannot create the profile $PROFILE"
  if [ -f "$HH/config.yaml" ]; then cp "$HH/config.yaml" "$HH/config.yaml.replaced-$(date +%Y%m%d%H%M%S)"; fi
  cp "$RECIPE" "$HH/config.yaml" || lc_die "cannot write $HH/config.yaml"
  lc_say "recipe restored into $HH/config.yaml (previous file kept next to it)"
  exit 0
fi

lc_gateway_url                                                              # sets LC_GW, or stops
lc_work_dir_check "${LUCAIRN_WORK_DIR:-$(lc_default_work_parent)/hermes}"   # sets LC_WORK, or stops
lc_load_keys                                                                # shell variables only
lc_scrub_env                    # from here on: no inherited variable reaches any program

mkdir -p "$HH" "$PROFILE/home" "$PROFILE/tmp" || lc_die "cannot create the profile $PROFILE"
[ -f "$HH/config.yaml" ] || { cp "$RECIPE" "$HH/config.yaml" || lc_die "cannot write $HH/config.yaml"; lc_say "new profile: recipe copied into $HH/config.yaml"; }

# Guard 1: the load-bearing lines of the recipe must still be there. The
# settings form's Save rewrites config.yaml (drops `transport`, can swap
# `key_env`), which turns one refused message into 3 requests.
GUARD_OUT="$("$PY" -I - "$HH/config.yaml" <<'PY' 2>&1
import sys, yaml
c = yaml.safe_load(open(sys.argv[1])) or {}
bad = []
web = c.get("web") or {}
ag = c.get("agent") or {}
if web.get("keyless_fallback") is not False: bad.append("web.keyless_fallback must be false")
if web.get("keyless_rescue") is not False: bad.append("web.keyless_rescue must be false")
dt = ag.get("disabled_toolsets")
if not (isinstance(dt, list) and "web" in dt): bad.append("agent.disabled_toolsets must contain web")
if (c.get("platform_toolsets") or {}).get("cli") != ["file"]: bad.append("platform_toolsets.cli must be [file]")
r = ag.get("api_max_retries")
if not (type(r) is int and 0 <= r <= 1): bad.append("agent.api_max_retries must be 0 or 1")
rc = ag.get("auto_recovery_cycles")
if not (type(rc) is int and rc == 0): bad.append("agent.auto_recovery_cycles must be 0")
if (c.get("model") or {}).get("provider") != "lucairn-anthropic": bad.append("model.provider must be lucairn-anthropic")
p = (c.get("providers") or {}).get("lucairn-anthropic") or {}
if p.get("api") != "${LUCAIRN_GATEWAY_URL}": bad.append("providers.lucairn-anthropic.api must be ${LUCAIRN_GATEWAY_URL}")
if p.get("transport") != "anthropic_messages": bad.append("providers.lucairn-anthropic.transport must be anthropic_messages")
if p.get("key_env") != "LUCAIRN_API_KEY": bad.append("providers.lucairn-anthropic.key_env must be LUCAIRN_API_KEY")
if "base_url" in p: bad.append("providers.lucairn-anthropic.base_url is set (written by the settings form)")
if (p.get("extra_headers") or {}).get("X-Upstream-Key") != "${LUCAIRN_UPSTREAM_KEY}": bad.append("X-Upstream-Key header must be ${LUCAIRN_UPSTREAM_KEY}")
if ((c.get("security") or {}).get("allow_lazy_installs")) is not False: bad.append("security.allow_lazy_installs must be false")
mt = ag.get("max_turns")
if not (type(mt) is int and 0 < mt <= 200): bad.append("agent.max_turns must be a number between 1 and 200")
if (((c.get("auxiliary") or {}).get("title_generation") or {}).get("model_upgrade_enabled")) is not False: bad.append("auxiliary.title_generation.model_upgrade_enabled must be false")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
)" || {
  printf '%s\n' "$GUARD_OUT" | sed 's/^/  - /' >&2
  lc_die "the profile config no longer matches the Lucairn recipe ($HH/config.yaml). Nothing was started. Restore it with: $0 --reset-config"
}

# Guard 2: a key typed into the settings form lands in clear text in <profile>/.env.
if [ -f "$HH/.env" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(API_KEY|_TOKEN|UPSTREAM_KEY)[[:space:]]*=[[:space:]]*[^[:space:]#]' "$HH/.env"; then
  lc_die "$HH/.env holds a key in clear text (typed into the Hermes settings form?). Remove that line, then start again. Keys belong in the Keychain or the environment, never in the form."
fi

# Standing rule appended once to the profile's SOUL.md (Hermes reads it into every system prompt):
# the gateway's placeholders in earlier tool calls/results must not make the model redo the call.
SOUL="$HH/SOUL.md"
if [ ! -f "$SOUL" ]; then  # let Hermes seed its own default SOUL.md first (no keys, no network call)
  # shellcheck disable=SC2030  # deliberately local to this subshell
  ( export HOME="$PROFILE/home" HERMES_HOME="$HH" TMPDIR="$PROFILE/tmp/"; lc_windows_homes "$PROFILE/home" "$PROFILE/tmp"
    if lc_is_windows; then export PYTHONUTF8=1; fi; "$BIN" --version >/dev/null 2>&1 )
fi
if ! grep -q "Lucairn privacy placeholders" "$SOUL" 2>/dev/null; then
  { printf '\n'; cat "$HERE/../lib/placeholder-rule.md"; } >> "$SOUL" || lc_die "cannot write $SOUL"
fi

cd "$LC_WORK" || lc_die "cannot enter $LC_WORK"
# shellcheck disable=SC2031  # the subshell above did not change these here; set them now
export HOME="$PROFILE/home" HERMES_HOME="$HH" TMPDIR="$PROFILE/tmp/"
lc_windows_homes "$PROFILE/home" "$PROFILE/tmp"
# shellcheck disable=SC2031  # UTF-8 console output on Windows
if lc_is_windows; then export PYTHONUTF8=1; fi
export LUCAIRN_GATEWAY_URL="$LC_GW"
lc_exec_client "$BIN" "$@"   # the keys enter the environment here, for Hermes only
