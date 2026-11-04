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
# except space, $ ' " \ ` and # (doctor refuses them too); a line feed or any
# other control character is refused as well — it is read from the value
# Compose really hands to Postgres, so a quoted value ending in a line feed is
# seen as such, never trimmed.
#
# Needs Docker Compose (the `docker compose` plugin, or docker-compose v2) and
# nothing else: every value is read THROUGH Compose (bin/compose-env.sh),
# client side, no daemon needed. Without it the script refuses.
#
# Permissions: the file is mode 0444 inside a directory of mode 0700. The
# directory keeps every other host user out; the file itself is readable by
# the container user (uid 10001), whichever host uid ran this script, under a
# rootful, rootless or user-namespace-remapped daemon — no chown needed. A
# single file is bind-mounted, so the directory's mode does not apply inside
# the container.
#
# Usage:
#   scripts/write-sanitizer-core-registry-dsn.sh [--env-file customer.env]
#       [--compose docker-compose.customer.yml] [<dsn file>]
#
#   --env-file   default <kit>/customer.env (in an extracted customer bundle:
#                install/customer.env)
#   --compose    the base compose file; its directory is the Compose project
#                directory relative paths resolve against. Default
#                <kit>/docker-compose.customer.yml, or, in an extracted
#                customer bundle, install/docker-compose.customer.yml.
#   <dsn file>   default SANITIZER_CORE_REGISTRY_DSN_FILE from the env file,
#                else .secrets/sanitizer-core/registry-dsn (the compose
#                default) in the Compose project directory.
#
# Idempotent: an up-to-date file is left alone (same inode, so a running core
# is unaffected). After a CHANGE (new password or sslmode) recreate the core:
#   docker compose ... up -d --no-deps --force-recreate sanitizer-core
# A restart is not enough: the container keeps the file it was created with.
#
# The DSN and the password are never printed.

set -euo pipefail

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '[write-sanitizer-core-registry-dsn] %s\n' "$*" >&2; }
die() { printf '[write-sanitizer-core-registry-dsn] ERROR: %s\n' "$*" >&2; exit 1; }

# The Compose project directory = the directory of the base compose file:
# the kit root, or install/ of an extracted customer bundle (final-read H2:
# the bundle ships this script; its compose file and customer.env live in
# install/, so its relative paths resolve there, exactly as `docker compose -f
# install/docker-compose.customer.yml` resolves them).
PROJECT_DIR="$KIT_ROOT"
if [ ! -f "$KIT_ROOT/docker-compose.customer.yml" ] && [ -f "$KIT_ROOT/install/docker-compose.customer.yml" ]; then
  PROJECT_DIR="$KIT_ROOT/install"
fi
ENV_FILE="$PROJECT_DIR/customer.env"
DSN_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file) [ "$#" -ge 2 ] || die "--env-file needs a path"; ENV_FILE="$2"; shift 2 ;;
    --compose)
      [ "$#" -ge 2 ] || die "--compose needs a path"
      [ -f "$2" ] || die "compose file not found: $2"
      PROJECT_DIR="$(cd "$(dirname "$2")" && pwd)"; shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$DSN_FILE" ] || die "only one DSN file path may be given"; DSN_FILE="$1"; shift ;;
  esac
done

[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"

# Every value is taken from Docker Compose ITSELF (bin/compose-env.sh, kit 2.0
# K-A fix round 2): Compose's own env-file parser and interpolation, so
# quotes, multi-line values, backslash escapes ("\0101" is "A" to Compose), a
# quoted password ending in a line feed and a variable exported in this shell
# are resolved exactly as `docker compose up` resolves them. No value is
# parsed or expanded here. Without Docker Compose on PATH this script refuses
# (it never guesses a value). bin/lucairn doctor reads through the same file.
LIB="$KIT_ROOT/bin/compose-env.sh"
[ -f "$LIB" ] && [ ! -L "$LIB" ] || die "missing $LIB (the kit's Compose env reader)"
# shellcheck source=../bin/compose-env.sh
. "$LIB"
PW_UNSAFE="POSTGRES_SANITIZER_CORE_PASSWORD holds a character customer.env cannot carry safely (space, \$, a quote, \\, \`, #, a line feed or another control character, or a non-ASCII byte); generate one: openssl rand -hex 24"

rc=0
OUT="$(cev_registry --env-file "$ENV_FILE" --project-dir "$PROJECT_DIR" \
  ${DSN_FILE:+--dsn-file "$DSN_FILE"} --print-dsn)" || rc=$?
case "$rc" in
  0) : ;;
  10) die "Docker Compose is not available here; customer.env is read through Compose itself, never guessed (run this on the Docker host)" ;;
  11) die "Docker Compose cannot read $ENV_FILE (fix the file; the reason is above)" ;;
  *) die "could not read $ENV_FILE through Docker Compose (exit $rc; the reason is above)" ;;
esac
PW_STATE="" SSLMODE="" OVERRIDES="" DSN=""
DSN_FILE=""
while IFS="$(printf '\t')" read -r k v; do
  case "$k" in
    pw) PW_STATE="$v" ;;
    sslmode) SSLMODE="$v" ;;
    overrides) OVERRIDES="$v" ;;
    dsn_file) DSN_FILE="$v" ;;
    dsn) DSN="$v" ;;
  esac
done < <(printf '%s\n' "$OUT")
OUT=""
if [ -n "$OVERRIDES" ]; then
  die "$OVERRIDES exported in this shell with a value other than $ENV_FILE's; Docker Compose run from another shell would use the file's value and the DSN would not match (unset it, or put the value in $ENV_FILE). The values are not printed"
fi
case "$PW_STATE" in
  ok) : ;;
  unset) die "POSTGRES_SANITIZER_CORE_PASSWORD is not set in $ENV_FILE (generate one: openssl rand -hex 24)" ;;
  placeholder) die "POSTGRES_SANITIZER_CORE_PASSWORD is still a REPLACE_ placeholder in $ENV_FILE (generate one: openssl rand -hex 24)" ;;
  *) die "$PW_UNSAFE" ;;
esac
[ "$SSLMODE" != invalid ] || die "POSTGRES_SSLMODE must be one of disable, allow, prefer, require, verify-ca, verify-full"
[ -n "$DSN_FILE" ] || die "SANITIZER_CORE_REGISTRY_DSN_FILE holds a quote, backslash or control character Compose escapes; use a plain path"
[ -n "$DSN" ] || die "bin/compose-env.sh gave no DSN (internal error)"
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
