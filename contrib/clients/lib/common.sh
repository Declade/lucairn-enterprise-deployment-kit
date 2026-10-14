# shellcheck shell=bash
#
# contrib/clients/lib/common.sh — shared helpers for the Lucairn client launchers
# (hermes/, opencode/, openwork/). SOURCE it; it is not a program.
#
# What lives here, and why it is shared:
#   - key loading: environment first, then the macOS Keychain BY ITEM NAME.
#     Keys are held in shell variables and handed to the client's process
#     environment only — never written to a file, never put on a command line.
#   - the work-folder rule: a work folder whose full path holds the account
#     name breaks file tasks through the gateway (the sanitizer replaces the
#     name inside file paths and the model loses track of its own files).
#   - one place for the gateway address (hosted default, or your own gateway).
#   - Windows: the launchers run under Git Bash (Git for Windows); the clients
#     themselves run as native Windows programs. lc_is_windows and the
#     lc_windows_* helpers hold every Windows difference.
#
# Nothing in this file contacts the network.

LC_DEFAULT_GATEWAY_URL="https://gateway.lucairn.eu"

lc_die() { printf '%s: %s\n' "${LC_PROG:-lucairn-client}" "$*" >&2; exit 2; }
lc_say() { printf '%s: %s\n' "${LC_PROG:-lucairn-client}" "$*" >&2; }

# lc_is_windows — true under Git Bash / MSYS2 on Windows.
lc_is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
# lc_exe — ".exe" on Windows, nothing elsewhere.  lc_venv_bin — a Python venv's program folder.
lc_exe() { if lc_is_windows; then printf '.exe'; fi; }
lc_venv_bin() { if lc_is_windows; then printf 'Scripts'; else printf 'bin'; fi; }

lc_need() {
  command -v "$1" >/dev/null 2>&1 || lc_die "missing tool: $1 (nothing is installed for you)"
}

# lc_os_arch — prints e.g. "darwin-arm64" / "linux-x64".
lc_os_arch() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) lc_die "unsupported operating system: $(uname -s) (macOS, Linux, Windows with Git Bash)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
    *) lc_die "unsupported CPU: $(uname -m)" ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

# lc_data_root — where installs and profiles go unless overridden.
lc_data_root() {
  printf '%s\n' "${LUCAIRN_CLIENTS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/lucairn-clients}"
}

# lc_gateway_url — the gateway address without a trailing slash, https only
# (http only for a loopback address, e.g. a local test gateway).
lc_gateway_url() {
  local url="${LUCAIRN_GATEWAY_URL:-$LC_DEFAULT_GATEWAY_URL}"
  url="${url%/}"
  case "$url" in
    https://?*) : ;;
    http://127.0.0.1:*|http://localhost:*) : ;;
    *) lc_die "LUCAIRN_GATEWAY_URL must start with https:// (got '$url')" ;;
  esac
  printf '%s\n' "$url"
}

# _lc_keychain <service> — prints the secret of a macOS Keychain generic
# password item (account = LUCAIRN_KEYCHAIN_ACCOUNT, default the login name),
# or nothing. The value goes to stdout for a command substitution only.
_lc_keychain() {
  [ "$(uname -s)" = Darwin ] || return 0
  [ -x /usr/bin/security ] || return 0
  /usr/bin/security find-generic-password -s "$1" -a "${LUCAIRN_KEYCHAIN_ACCOUNT:-$(id -un)}" -w 2>/dev/null || true
}

# lc_load_keys — sets LC_LUCAIRN_KEY and LC_UPSTREAM_KEY (shell variables, not
# exported). Sources, in order:
#   LUCAIRN_API_KEY      env, else Keychain item ${LUCAIRN_KEYCHAIN_ITEM:-lucairn-api-key}
#   LUCAIRN_UPSTREAM_KEY env, else Keychain item ${LUCAIRN_UPSTREAM_KEYCHAIN_ITEM:-lucairn-upstream-key}
# The provider ("upstream") key travels to the gateway in the X-Upstream-Key
# header. Both are required: the verified setup is the API-key lane.
lc_load_keys() {
  LC_LUCAIRN_KEY="${LUCAIRN_API_KEY:-}"
  LC_UPSTREAM_KEY="${LUCAIRN_UPSTREAM_KEY:-}"
  [ -n "$LC_LUCAIRN_KEY" ] || LC_LUCAIRN_KEY="$(_lc_keychain "${LUCAIRN_KEYCHAIN_ITEM:-lucairn-api-key}")"
  [ -n "$LC_UPSTREAM_KEY" ] || LC_UPSTREAM_KEY="$(_lc_keychain "${LUCAIRN_UPSTREAM_KEYCHAIN_ITEM:-lucairn-upstream-key}")"
  [ -n "$LC_LUCAIRN_KEY" ] || lc_die "no Lucairn API key: set LUCAIRN_API_KEY, or store it in the macOS Keychain as item '${LUCAIRN_KEYCHAIN_ITEM:-lucairn-api-key}' (see README)"
  [ -n "$LC_UPSTREAM_KEY" ] || lc_die "no provider key: set LUCAIRN_UPSTREAM_KEY, or store it in the macOS Keychain as item '${LUCAIRN_UPSTREAM_KEYCHAIN_ITEM:-lucairn-upstream-key}' (see README)"
  case "$LC_LUCAIRN_KEY$LC_UPSTREAM_KEY" in
    *[[:space:]]*) lc_die "a key contains whitespace — check the Keychain item / variable" ;;
  esac
}

# lc_work_dir_check <dir> — the work-folder rule. Creates the folder, prints its
# physical path, refuses (exit 2) when the path holds the account name or the
# home folder's name. Override at your own cost: LUCAIRN_ALLOW_NAMED_WORKDIR=1.
lc_work_dir_check() {
  local w="$1" me home_name
  [ -n "$w" ] || lc_die "internal: empty work folder"
  mkdir -p "$w" 2>/dev/null || lc_die "cannot create the work folder $w"
  w="$(cd "$w" && pwd -P)" || lc_die "cannot enter the work folder"
  me="$(id -un | tr '[:upper:]' '[:lower:]')"; home_name="$(basename "$HOME" | tr '[:upper:]' '[:lower:]')"
  if [ "${LUCAIRN_ALLOW_NAMED_WORKDIR:-}" != 1 ]; then
    # compared in lower case: macOS and Windows file names ignore case
    case "$(printf '%s/' "$w" | tr '[:upper:]' '[:lower:]')" in
      *"/$me/"*|*"/$home_name/"*)
        lc_say "the work folder path contains the account name: $w"
        lc_die "file tools through Lucairn need a work folder whose full path holds no person's or account name (the gateway replaces such a path and file work can loop). Use e.g. LUCAIRN_WORK_DIR=$(lc_default_work_parent)/<project>. Nothing was started."
        ;;
    esac
  fi
  printf '%s\n' "$w"
}

# lc_scrub_env — unset EVERY exported variable of this shell (stray provider
# keys, a real HOME, …) except the proxy settings (HTTPS_PROXY, HTTP_PROXY,
# NO_PROXY, NODE_USE_ENV_PROXY) and, on Windows, the system variables every
# Windows program needs (SYSTEMROOT, WINDIR, …), so the client starts with
# only what the launcher exports afterwards. Values are never put on a command
# line (an `env -i KEY=value` call would show them in the process list).
lc_scrub_env() {
  local v keep_https="${HTTPS_PROXY:-${https_proxy:-}}" keep_http="${HTTP_PROXY:-${http_proxy:-}}"
  local keep_no="${NO_PROXY:-${no_proxy:-}}" keep_term="${TERM:-xterm-256color}" keep_lang="${LANG:-en_US.UTF-8}"
  local keep_nodeproxy="${NODE_USE_ENV_PROXY:-}" keep_win="" path="/usr/bin:/bin:/usr/sbin:/sbin"
  if lc_is_windows; then
    for v in SYSTEMROOT WINDIR COMSPEC PATHEXT SYSTEMDRIVE PROCESSOR_ARCHITECTURE NUMBER_OF_PROCESSORS OS; do
      if [ -n "${!v:-}" ]; then keep_win="$keep_win$v=${!v}"$'\n'; fi
    done
    # System32 + Windows PowerShell: OpenCode unpacks its ripgrep download with powershell.exe; without
    # it on PATH the unpack fails and every start downloads ripgrep again (measured 2026-10-14)
    if [ -n "${SYSTEMROOT:-}" ]; then
      local sr; sr="$(cygpath -u "$SYSTEMROOT")"
      path="$path:$sr/System32:$sr:$sr/System32/WindowsPowerShell/v1.0"
    fi
  fi
  for v in $(compgen -e); do unset "$v" 2>/dev/null || true; done
  export PATH="$path" TERM="$keep_term" LANG="$keep_lang"
  export USER="$LC_USER" LOGNAME="$LC_USER"
  if [ -n "$keep_https" ]; then export HTTPS_PROXY="$keep_https" https_proxy="$keep_https"; fi
  if [ -n "$keep_http" ]; then export HTTP_PROXY="$keep_http" http_proxy="$keep_http"; fi
  if [ -n "$keep_no" ]; then export NO_PROXY="$keep_no" no_proxy="$keep_no"; fi
  if [ -n "$keep_nodeproxy" ]; then export NODE_USE_ENV_PROXY="$keep_nodeproxy"; fi
  while IFS= read -r v; do if [ -n "$v" ]; then export "${v%%=*}=${v#*=}"; fi; done <<< "$keep_win"
}

# lc_windows_homes <home> <tmp> — Windows only (no-op elsewhere): native Windows
# programs take their home and temp folders from USERPROFILE / APPDATA /
# LOCALAPPDATA / TEMP / TMP, not from HOME / TMPDIR. Points all of them into the
# profile, so nothing lands in the real user folder. Call after exporting HOME.
lc_windows_homes() {
  lc_is_windows || return 0
  mkdir -p "$1/AppData/Roaming" "$1/AppData/Local" "$2" || lc_die "cannot create the Windows profile folders under $1"
  export USERPROFILE="$1" APPDATA="$1/AppData/Roaming" LOCALAPPDATA="$1/AppData/Local" TEMP="$2" TMP="$2"
}

# lc_windows_env <home> — Windows only: sets the array LC_WIN_ENV to the
# NAME=value words an `env -i` call needs to start a native Windows program
# (empty elsewhere). Usage: env -i PATH=… ${LC_WIN_ENV[@]+"${LC_WIN_ENV[@]}"} prog
# shellcheck disable=SC2034  # LC_WIN_ENV is read by the caller
lc_windows_env() {
  LC_WIN_ENV=()
  lc_is_windows || return 0
  LC_WIN_ENV=(SYSTEMROOT="${SYSTEMROOT:-}" WINDIR="${WINDIR:-}" PATHEXT="${PATHEXT:-}" USERPROFILE="$1"
    APPDATA="$1/AppData/Roaming" LOCALAPPDATA="$1/AppData/Local" TEMP="$1/tmp" TMP="$1/tmp" PYTHONUTF8=1)
  mkdir -p "$1/AppData/Roaming" "$1/AppData/Local" "$1/tmp" 2>/dev/null || true
}

# lc_native_path <path> — the path as a native program reads it: C:/… on Windows
# (Git Bash converts plain path arguments itself, but not one with extra text
# such as "src[extras]"), unchanged elsewhere.
lc_native_path() { if lc_is_windows; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# lc_sha256 <file> — prints the file's sha256 (shasum on macOS, sha256sum elsewhere).
lc_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
LC_USER="$(id -un)"

# lc_default_work_parent — a shared folder outside the home folder.
lc_default_work_parent() {
  if [ "$(uname -s)" = Darwin ]; then printf '%s\n' /Users/Shared/agent-work
  elif lc_is_windows; then printf '%s\n' /c/agent-work
  else printf '%s\n' /var/tmp/agent-work; fi
}
