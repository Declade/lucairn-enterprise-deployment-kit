# shellcheck shell=bash
#
# contrib/clients/lib/common.sh — shared helpers for the Lucairn client launchers
# (hermes/, opencode/, openwork/). SOURCE it; it is not a program.
#
# What lives here, and why it is shared:
#   - key loading: environment first, then the macOS Keychain BY ITEM NAME.
#     SOURCING this file takes both keys out of the environment at once (into
#     unexported shell variables), so no helper program the launcher runs ever
#     sees them; lc_exec_client puts them back into the environment of the
#     client only, at the moment the client replaces the launcher (exec).
#     Never written to a file, never put on a command line.
#   - the work-folder rule: a work folder whose full path holds the account
#     name breaks file tasks through the gateway (the sanitizer replaces the
#     name inside file paths and the model loses track of its own files).
#   - one place for the gateway address (hosted default, or your own gateway),
#     parsed and checked; a bad address stops the launch.
#   - Windows: the launchers run under Git Bash (Git for Windows); the clients
#     themselves run as native Windows programs. lc_is_windows and the
#     lc_windows_* helpers hold every Windows difference.
#
# Nothing in this file contacts the network.

# ── on sourcing: internal names and the two keys leave the environment ──────────
# An inherited LC_* name of ours (e.g. an exported LC_LUCAIRN_KEY) would otherwise
# be passed on to children or be removed by lc_scrub_env under `set -u`.
for _lc_v in LC_LUCAIRN_KEY LC_UPSTREAM_KEY LC_ENV_LUCAIRN_KEY LC_ENV_UPSTREAM_KEY LC_USER LC_HOME \
             LC_GW LC_WORK LC_WIN_ENV LC_DEFAULT_GATEWAY_URL; do
  unset "$_lc_v"
done
unset _lc_v
export -n LC_PROG 2>/dev/null || true
LC_ENV_LUCAIRN_KEY="${LUCAIRN_API_KEY:-}"
LC_ENV_UPSTREAM_KEY="${LUCAIRN_UPSTREAM_KEY:-}"
unset LUCAIRN_API_KEY LUCAIRN_UPSTREAM_KEY
LC_USER="$(id -un)"
LC_HOME="${HOME:-}"

LC_DEFAULT_GATEWAY_URL="https://gateway.lucairn.eu"

lc_die() { printf '%s: %s\n' "${LC_PROG:-lucairn-client}" "$*" >&2; exit 2; }
lc_say() { printf '%s: %s\n' "${LC_PROG:-lucairn-client}" "$*" >&2; }

# A path is absolute if it starts with "/"; under Git Bash on Windows "E:/..." and "E:\..." also are.
lc_is_abs() {
  case "$1" in /*) return 0 ;; esac
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      case "$1" in [A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;; esac ;;
  esac
  return 1
}

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
  printf '%s\n' "${LUCAIRN_CLIENTS_HOME:-${XDG_DATA_HOME:-$LC_HOME/.local/share}/lucairn-clients}"
}

# lc_lower <text> — the text in lower case.
lc_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# lc_gateway_url — checks LUCAIRN_GATEWAY_URL (default the hosted gateway) and
# sets LC_GW to it without a trailing slash. Call it directly, never inside
# $(…): a bad address stops the launch (exit 2) before anything starts.
# Accepted, nothing else:
#   https://<host>[:<port>][/<path>]
#   http://127.0.0.1|localhost|[::1][:<port>][/<path>]   (a gateway on this computer)
# No user name or password part ("…@…"), no query or fragment, no percent
# escapes or backslashes; the host is checked as written.
lc_gateway_url() {
  local url="${LUCAIRN_GATEWAY_URL:-$LC_DEFAULT_GATEWAY_URL}" scheme rest auth path host port
  local stop="Nothing was started."
  url="${url%/}"
  case "$url" in
    https://*) scheme=https; rest="${url#https://}" ;;
    http://*) scheme=http; rest="${url#http://}" ;;
    *) lc_die "LUCAIRN_GATEWAY_URL must start with https:// (got '$url'). $stop" ;;
  esac
  auth="${rest%%/*}"; path="${rest#"$auth"}"
  case "$auth" in
    *@*) lc_die "LUCAIRN_GATEWAY_URL must not hold a user name or password ('…@…'): got '$url'. $stop" ;;
  esac
  case "$rest" in
    *[!]A-Za-z0-9._~:/[-]*) lc_die "LUCAIRN_GATEWAY_URL holds a character a gateway address does not need (got '$url'). $stop" ;;
  esac
  case "$auth" in
    \[*\]|\[*\]:*) host="${auth%%]*}]"; port="${auth#"$host"}" ;;
    *) host="${auth%%:*}"; port="${auth#"$host"}" ;;
  esac
  [ -n "$host" ] || lc_die "LUCAIRN_GATEWAY_URL has no host (got '$url'). $stop"
  if [ -n "$port" ]; then
    port="${port#:}"
    case "$port" in
      ''|*[!0-9]*) lc_die "LUCAIRN_GATEWAY_URL has an invalid port (got '$url'). $stop" ;;
    esac
    if [ "${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      lc_die "LUCAIRN_GATEWAY_URL has an invalid port (got '$url'). $stop"
    fi
  fi
  host="$(lc_lower "$host")"
  if [ "$scheme" = http ]; then
    case "$host" in
      127.0.0.1|localhost|\[::1\]) : ;;
      *) lc_die "LUCAIRN_GATEWAY_URL: http:// only for a gateway on this computer (127.0.0.1, localhost, [::1]); use https:// (got '$url'). $stop" ;;
    esac
  else
    case "$host" in
      \[*\]) local inner="${host#[}"; inner="${inner%]}"
        case "$inner" in ''|*[!0-9a-f:.]*) lc_die "LUCAIRN_GATEWAY_URL has an invalid address (got '$url'). $stop" ;; esac ;;
      .*|*.|*..*|-*|*[!a-z0-9.-]*) lc_die "LUCAIRN_GATEWAY_URL has an invalid host name (got '$url'). $stop" ;;
    esac
  fi
  case "$path" in
    ''|/*) : ;;
    *) lc_die "LUCAIRN_GATEWAY_URL has an invalid path (got '$url'). $stop" ;;
  esac
  # shellcheck disable=SC2034  # read by the launchers
  LC_GW="$url"
}

# _lc_keychain <service> — prints the secret of a macOS Keychain generic
# password item (account = LUCAIRN_KEYCHAIN_ACCOUNT, default the login name),
# or nothing. The value goes to stdout for a command substitution only.
_lc_keychain() {
  [ "$(uname -s)" = Darwin ] || return 0
  [ -x /usr/bin/security ] || return 0
  /usr/bin/security find-generic-password -s "$1" -a "${LUCAIRN_KEYCHAIN_ACCOUNT:-$LC_USER}" -w 2>/dev/null || true
}

# lc_load_keys — sets LC_LUCAIRN_KEY and LC_UPSTREAM_KEY (shell variables, NOT
# exported: no program sees them until lc_exec_client). Sources, in order:
#   LUCAIRN_API_KEY      env (taken when this file was sourced), else Keychain item ${LUCAIRN_KEYCHAIN_ITEM:-lucairn-api-key}
#   LUCAIRN_UPSTREAM_KEY env (taken when this file was sourced), else Keychain item ${LUCAIRN_UPSTREAM_KEYCHAIN_ITEM:-lucairn-upstream-key}
# The provider ("upstream") key travels to the gateway in the X-Upstream-Key
# header. Both are required: the verified setup is the API-key lane.
lc_load_keys() {
  LC_LUCAIRN_KEY="${LC_ENV_LUCAIRN_KEY:-}"
  LC_UPSTREAM_KEY="${LC_ENV_UPSTREAM_KEY:-}"
  unset LC_ENV_LUCAIRN_KEY LC_ENV_UPSTREAM_KEY
  if [ -z "$LC_LUCAIRN_KEY" ]; then LC_LUCAIRN_KEY="$(_lc_keychain "${LUCAIRN_KEYCHAIN_ITEM:-lucairn-api-key}")"; fi
  if [ -z "$LC_UPSTREAM_KEY" ]; then LC_UPSTREAM_KEY="$(_lc_keychain "${LUCAIRN_UPSTREAM_KEYCHAIN_ITEM:-lucairn-upstream-key}")"; fi
  [ -n "$LC_LUCAIRN_KEY" ] || lc_die "no Lucairn API key: set LUCAIRN_API_KEY, or store it in the macOS Keychain as item '${LUCAIRN_KEYCHAIN_ITEM:-lucairn-api-key}' (see README)"
  [ -n "$LC_UPSTREAM_KEY" ] || lc_die "no provider key: set LUCAIRN_UPSTREAM_KEY, or store it in the macOS Keychain as item '${LUCAIRN_UPSTREAM_KEYCHAIN_ITEM:-lucairn-upstream-key}' (see README)"
  case "$LC_LUCAIRN_KEY$LC_UPSTREAM_KEY" in
    *[[:space:]]*) lc_die "a key contains whitespace — check the Keychain item / variable" ;;
  esac
}

# lc_exec_client <program> [args…] — the ONLY place the keys enter an
# environment: exported here, and the program replaces this shell at once
# (exec), so no other program ever has them. Run it as the last command of the
# launcher, or inside a ( … ) / pipeline / & subshell that ends with it. The
# values are never on a command line.
lc_exec_client() {
  export LUCAIRN_API_KEY="$LC_LUCAIRN_KEY" LUCAIRN_UPSTREAM_KEY="$LC_UPSTREAM_KEY"
  unset LC_LUCAIRN_KEY LC_UPSTREAM_KEY
  exec "$@"
}

# lc_work_dir_check <dir> — the work-folder rule. Creates the folder and sets
# LC_WORK to its physical path; stops the launch (exit 2) when the path contains
# the login name or the home folder's name ANYWHERE (case-insensitive: also
# /var/tmp/alice-project for login alice). Call it directly, never inside $(…).
# Override at your own cost: LUCAIRN_ALLOW_NAMED_WORKDIR=1.
lc_work_dir_check() {
  local w="$1" me home_name low named=0
  [ -n "$w" ] || lc_die "internal: empty work folder"
  mkdir -p "$w" 2>/dev/null || lc_die "cannot create the work folder $w"
  w="$(cd "$w" && pwd -P)" || lc_die "cannot enter the work folder"
  if [ "${LUCAIRN_ALLOW_NAMED_WORKDIR:-}" != 1 ]; then
    # compared in lower case: macOS and Windows file names ignore case
    me="$(lc_lower "$LC_USER")"; home_name="$(lc_lower "${LC_HOME##*/}")"; low="$(lc_lower "$w")"
    if [ -n "$me" ]; then case "$low" in *"$me"*) named=1 ;; esac; fi
    if [ -n "$home_name" ]; then case "$low" in *"$home_name"*) named=1 ;; esac; fi
    if [ "$named" = 1 ]; then
      lc_say "the work folder path contains the account name: $w"
      lc_die "file tools through Lucairn need a work folder whose full path holds no person's or account name (the gateway replaces such a path and file work can loop). Use e.g. LUCAIRN_WORK_DIR=$(lc_default_work_parent)/<project>. Nothing was started."
    fi
  fi
  # shellcheck disable=SC2034  # read by the launchers
  LC_WORK="$w"
}

# lc_scrub_env — unset EVERY exported variable of this shell (stray provider
# keys, a real HOME, …; the two Lucairn keys already left the environment when
# this file was sourced) except the proxy settings (HTTPS_PROXY, HTTP_PROXY,
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

# lc_default_work_parent — a shared folder outside the home folder.
lc_default_work_parent() {
  if [ "$(uname -s)" = Darwin ]; then printf '%s\n' /Users/Shared/agent-work
  elif lc_is_windows; then printf '%s\n' /c/agent-work
  else printf '%s\n' /var/tmp/agent-work; fi
}
