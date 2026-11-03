#!/usr/bin/env bash
# write-sanitizer-core-registry-dsn.sh — the file the new sanitizer core reads
# its registry DSN from (kit 2.0, PRD prd-2026-11-02-kit-2-0-new-core.md K1;
# DSA #956 cmd/sanitizer-core/registry_dsn.go).
#
# The registry DSN carries the Postgres password of postgres-sanitizer-core.
# Passed as `--dsn` it sits in the core's process arguments, which every local
# user of the Docker host can read (`ps`, /proc/<pid>/cmdline). The kit passes
# `--registry-dsn-file /run/secrets/sanitizer-core/registry-dsn` instead and
# bind-mounts the file this script writes (docker-compose.customer.yml,
# service sanitizer-core). `bin/lucairn doctor` refuses an install where the
# file is missing, unreadable for the core, readable by other host users,
# not a postgres:// URL, or out of date against customer.env.
#
# What it writes (one line, nothing else):
#
#   postgres://dsa:<password, percent-encoded>@postgres-sanitizer-core:5432/sanitizer_core?sslmode=<POSTGRES_SSLMODE or disable>
#
# The core accepts ONLY this URL form from a file, with every byte of the
# password outside A-Z a-z 0-9 - . _ ~ percent-encoded (/ ? # @ : % and spaces
# would otherwise be read as URL syntax). This script does that encoding, so
# POSTGRES_SANITIZER_CORE_PASSWORD may hold any printable ASCII character
# except space, $ ' " \ ` and # (those break customer.env / Compose
# interpolation before the password ever reaches Postgres; doctor refuses
# them too).
#
# Permissions: the file is mode 0444 inside a directory of mode 0700. The
# directory keeps every other host user out; the file itself is readable by
# the container user (uid 10001), whichever host uid ran this script, under a
# rootful, rootless or user-namespace-remapped daemon — no chown needed. A
# single file is bind-mounted, so the directory's mode does not apply inside
# the container.
#
# Usage:
#   scripts/write-sanitizer-core-registry-dsn.sh [--env-file customer.env] [<dsn file>]
#
#   --env-file   default <kit>/customer.env
#   <dsn file>   default SANITIZER_CORE_REGISTRY_DSN_FILE from the env file,
#                else <kit>/.secrets/sanitizer-core/registry-dsn (the compose
#                default). Relative paths resolve against the kit directory
#                (the Compose project directory).
#
# Idempotent: an up-to-date file is left alone (same inode, so a running core
# is unaffected). After a CHANGE (new password or sslmode) recreate the core:
#   docker compose ... up -d --no-deps --force-recreate sanitizer-core
# A restart is not enough: the container keeps the file it was created with.
#
# The DSN and the password are never printed.

set -euo pipefail

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_DSN_FILE="./.secrets/sanitizer-core/registry-dsn"

log() { printf '[write-sanitizer-core-registry-dsn] %s\n' "$*" >&2; }
die() { printf '[write-sanitizer-core-registry-dsn] ERROR: %s\n' "$*" >&2; exit 1; }

ENV_FILE="$KIT_ROOT/customer.env"
DSN_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file) [ "$#" -ge 2 ] || die "--env-file needs a path"; ENV_FILE="$2"; shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$DSN_FILE" ] || die "only one DSN file path may be given"; DSN_FILE="$1"; shift ;;
  esac
done

[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"

# customer.env is read EXACTLY as Docker Compose reads it (only a matching
# pair of outer quotes is removed, multi-line quoted values, comments, the
# last assignment wins …), by the ONE reader bin/lucairn doctor uses too:
# bin/compose-env-lib.sh (rules and source citations in its header). A file
# Compose would refuse, or a value it would interpolate or unescape, is
# refused here rather than guessed.
LIB="$KIT_ROOT/bin/compose-env-lib.sh"
[ -f "$LIB" ] && [ ! -L "$LIB" ] || die "missing $LIB (the kit's Compose env-file reader)"
# shellcheck source=../bin/compose-env-lib.sh
. "$LIB"
PW_UNSAFE="POSTGRES_SANITIZER_CORE_PASSWORD holds a character customer.env cannot carry safely (space, \$, a quote, \\, \` or #, or a non-ASCII byte); generate one: openssl rand -hex 24"
env_get() {
  local v rc=0
  v="$(compose_env_get "$ENV_FILE" "$1")" || rc=$?
  if [ "$rc" -eq 3 ] && [ "$1" = POSTGRES_SANITIZER_CORE_PASSWORD ]; then
    # $-interpolation or a backslash escape: both characters are refused in
    # the password anyway, so it gets the password's own refusal.
    die "$PW_UNSAFE"
  elif [ "$rc" -ne 0 ]; then
    die "cannot read $1 from $ENV_FILE the way Docker Compose reads it: $v"
  fi
  if compose_env_shell_override "$1" "$v"; then
    die "$1 is exported in this shell with a value other than $ENV_FILE's; Docker Compose run from this shell would use the exported one (unset it, or put the value in $ENV_FILE). The values are not printed"
  fi
  printf '%s' "$v"
}

# sanitizer_core_pct_encode: stdin bytes -> RFC 3986 percent-encoding of every
# byte outside the unreserved set. Byte-wise through od, so no locale or
# multibyte handling can change it. bin/lucairn doctor uses the same rule.
pct_encode() {
  LC_ALL=C od -An -v -tx1 | tr -s '[:space:]' '\n' | while IFS= read -r h; do
    [ -n "$h" ] || continue
    case "$h" in
      2d|2e|5f|7e|3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a])
        # shellcheck disable=SC2059  # the format IS the one octal escape
        printf "\\$(printf '%03o' "0x$h")" ;;
      *) printf '%%%s' "$(printf '%s' "$h" | tr 'a-f' 'A-F')" ;;
    esac
  done
}

# env_get dies inside a command substitution only for that subshell, so each
# read is checked: an empty result after a refusal must stop the script.
PW="$(env_get POSTGRES_SANITIZER_CORE_PASSWORD)" || exit 1
[ -n "$PW" ] || die "POSTGRES_SANITIZER_CORE_PASSWORD is not set in $ENV_FILE (generate one: openssl rand -hex 24)"
# Allowed: printable ASCII 0x21-0x7E except $ ' " \ ` # (and no space).
if [ -n "$(printf '%s' "$PW" | LC_ALL=C tr -d '\041-\176')" ] \
   || printf '%s' "$PW" | LC_ALL=C grep -q "[\$'\"\\\`#]"; then
  die "$PW_UNSAFE"
fi

SSLMODE="$(env_get POSTGRES_SSLMODE)" || exit 1
SSLMODE="${SSLMODE:-disable}"
case "$SSLMODE" in
  disable|allow|prefer|require|verify-ca|verify-full) : ;;
  *) die "POSTGRES_SSLMODE must be one of disable, allow, prefer, require, verify-ca, verify-full" ;;
esac

if [ -z "$DSN_FILE" ]; then
  DSN_FILE="$(env_get SANITIZER_CORE_REGISTRY_DSN_FILE)" || exit 1
  DSN_FILE="${DSN_FILE:-$DEFAULT_DSN_FILE}"
fi
case "$DSN_FILE" in
  /*) : ;;
  *) DSN_FILE="$KIT_ROOT/${DSN_FILE#./}" ;;
esac
DIR="$(dirname "$DSN_FILE")"

if [ -L "$DSN_FILE" ]; then
  die "$DSN_FILE is a symlink; point SANITIZER_CORE_REGISTRY_DSN_FILE at the real file"
fi
if [ -d "$DSN_FILE" ]; then
  die "$DSN_FILE is a directory (Docker creates one when a bind source is missing); remove it (rmdir) and re-run"
fi

umask 077
if [ ! -d "$DIR" ]; then
  mkdir -p "$DIR"
  chmod 0700 "$DIR"
fi
case "$(uname -s)" in
  Darwin|FreeBSD|OpenBSD|NetBSD) DIR_MODE="$(stat -f '%Lp' "$DIR")" ;;
  *) DIR_MODE="$(stat -c '%a' "$DIR")" ;;
esac
if [ $((8#$DIR_MODE & 077)) -ne 0 ]; then
  die "$DIR has mode $DIR_MODE: the DSN file is readable by any uid (so the core can read it), so its directory must keep group and others out (chmod 700 '$DIR')"
fi

DSN="postgres://dsa:$(printf '%s' "$PW" | pct_encode)@postgres-sanitizer-core:5432/sanitizer_core?sslmode=$SSLMODE"

if [ -f "$DSN_FILE" ] && [ -r "$DSN_FILE" ] && [ "$(cat "$DSN_FILE")" = "$DSN" ]; then
  log "$DSN_FILE is up to date (unchanged; the DSN is not printed)"
  exit 0
fi

TMP="$(mktemp "$DIR/.registry-dsn.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$DSN" > "$TMP"
chmod 0444 "$TMP"
mv -f "$TMP" "$DSN_FILE"
trap - EXIT
log "wrote $DSN_FILE (mode 0444 in a 0700 directory; the DSN is not printed)"
log "if the core is running, recreate it: docker compose ... up -d --no-deps --force-recreate sanitizer-core"
