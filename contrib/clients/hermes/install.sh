#!/usr/bin/env bash
#
# contrib/clients/hermes/install.sh — install the pinned Hermes Agent the
# Lucairn recipe was verified with.
#
#   install.sh            create the install if it is missing, then verify it
#   install.sh --check    verify only: no network, nothing created
#
# Everything lands in ONE folder (override with LUCAIRN_HERMES_DIR):
#   ${LUCAIRN_CLIENTS_HOME:-~/.local/share/lucairn-clients}/hermes/v2026.9.24
# Nothing global: no brew, no PATH or shell-rc edit, no Python download, and
# never the official `curl | bash` installer (it writes ~/.hermes and edits
# shell rc files). Needs: git, uv, python3.12 (LUCAIRN_HERMES_PYTHON to choose).
#
# HERMES_HOME RULE: every `hermes` call — even `--version` — creates and writes
# its home folder, ~/.hermes when HERMES_HOME is unset. This script starts
# Hermes only from an EMPTY environment with HERMES_HOME and HOME inside the
# install folder; it never reads, writes or deletes ~/.hermes.
#
# Exit: 0 usable · 1 not usable / verification failed · 2 a needed tool is missing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LC_PROG="hermes/install.sh"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

TAG="v2026.9.24"
COMMIT="f97608f178d1ffeca59860195ab7da295f7c8e5f"   # what the tag pointed at on 2026-10-13; a moved tag is refused
REPO_URL="https://github.com/NousResearch/hermes-agent.git"
EXTRAS="anthropic,mcp"
RECIPE="$HERE/config.yaml"
BASE="${LUCAIRN_HERMES_DIR:-$(lc_data_root)/hermes/$TAG}"

CHECK_ONLY=0
case "${1:-}" in
  "") : ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

fail() { printf 'hermes/install.sh: %s\n' "$*" >&2; exit 1; }

case "$BASE" in /*) : ;; *) fail "install folder must be an absolute path (got '$BASE')" ;; esac
case "$BASE" in "$HOME/.hermes"|"$HOME/.hermes/"*) fail "refusing to use ~/.hermes as the install folder" ;; esac
[ -f "$RECIPE" ] || fail "recipe missing: $RECIPE"

CACHE=""
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { [ -n "$CACHE" ] && [ -d "$CACHE" ] && rm -rf "$CACHE"; return 0; }
trap cleanup EXIT

# run_hermes <args…> — empty environment, both homes inside the install folder,
# no gateway key: only for --version / tools list.
run_hermes() {
  local hh="$BASE/setup-check/home" sh="$BASE/setup-check/sandbox-home" wd="$BASE/setup-check/work"
  mkdir -p "$hh" "$sh" "$wd" || fail "cannot create $BASE/setup-check"
  cp "$RECIPE" "$hh/config.yaml" || fail "cannot copy the recipe into the check home"
  ( cd "$wd" && env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin USER="$(id -un)" LOGNAME="$(id -un)" \
      LANG=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}" HOME="$sh" HERMES_HOME="$hh" \
      LUCAIRN_GATEWAY_URL="$(lc_gateway_url)" \
      "$BASE/.venv/bin/hermes" "$@" )
}

printf 'Hermes install — tag %s\n  folder : %s\n' "$TAG" "$BASE"

if [ ! -d "$BASE/src/.git" ]; then
  [ "$CHECK_ONLY" -eq 1 ] && fail "not installed: $BASE/src is missing (run without --check)"
  lc_need git
  printf '  clone  : cloning %s (about 290 MB)\n' "$TAG"
  mkdir -p "$BASE" || fail "cannot create $BASE"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$REPO_URL" "$BASE/src" || fail "git clone failed"
fi
lc_need git
HEAD_NOW="$(git -C "$BASE/src" rev-parse HEAD 2>/dev/null)"
[ "$HEAD_NOW" = "$COMMIT" ] || fail "clone is at ${HEAD_NOW:-unknown}, pinned commit is $COMMIT (tag moved or wrong checkout) — refusing"
printf '  commit : %s (matches the pin)\n' "$HEAD_NOW"

if [ ! -x "$BASE/.venv/bin/hermes" ]; then
  [ "$CHECK_ONLY" -eq 1 ] && fail "not installed: $BASE/.venv/bin/hermes is missing (run without --check)"
  lc_need uv
  PY="${LUCAIRN_HERMES_PYTHON:-$(command -v python3.12 2>/dev/null || true)}"
  if ! { [ -n "$PY" ] && [ -x "$PY" ]; }; then printf 'hermes/install.sh: no python3.12 found (set LUCAIRN_HERMES_PYTHON; nothing is downloaded for you)\n' >&2; exit 2; fi
  CACHE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-install.XXXXXX")" || fail "cannot create a temp cache folder"
  printf '  venv   : creating with %s\n' "$PY"
  UV_CACHE_DIR="$CACHE/uv" UV_PYTHON_DOWNLOADS=never uv venv --quiet --python "$PY" "$BASE/.venv" || fail "uv venv failed"
  # Editable on purpose: Hermes refuses a wheel build.
  UV_CACHE_DIR="$CACHE/uv" UV_PYTHON_DOWNLOADS=never uv pip install --quiet --python "$BASE/.venv/bin/python" \
    -e "$BASE/src[$EXTRAS]" || fail "uv pip install failed"
fi
[ -x "$BASE/.venv/bin/hermes" ] || fail "$BASE/.venv/bin/hermes is missing after install"

VERSION_LINE="$(run_hermes --version 2>&1 | head -n 1)"
case "$VERSION_LINE" in
  *"(${TAG#v})"*) : ;;
  *) fail "version line does not name the pinned tag ${TAG#v}: $VERSION_LINE" ;;
esac
printf '  version: %s\n' "$VERSION_LINE"

# Under the recipe, web must be disabled and file the only built-in toolset on.
TOOLS_OUT="$(run_hermes tools list 2>&1)" || fail "\`hermes tools list\` failed"
printf '%s\n' "$TOOLS_OUT" | grep -Eq 'disabled[[:space:]]+web[[:space:]]' \
  || fail "the recipe does not leave the web toolset disabled — refusing"
ENABLED="$(printf '%s\n' "$TOOLS_OUT" | grep -E '✓ enabled' | awk '{print $3}' | tr '\n' ' ')"
[ "$ENABLED" = "file " ] || fail "unexpected enabled toolsets under the recipe: '${ENABLED}' (want: file)"
printf '  tools  : web disabled, enabled = %s\n' "$ENABLED"
printf 'OK hermes %s usable at %s\n' "$TAG" "$BASE"
