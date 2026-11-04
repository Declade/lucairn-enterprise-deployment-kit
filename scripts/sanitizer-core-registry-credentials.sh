#!/usr/bin/env bash
# sanitizer-core-registry-credentials.sh — keep the sanitizer core's registry
# credentials across a rollback (kit 2.0, PRD prd-2026-11-02-kit-2-0-new-core.md
# row 4; K-E fix round 1, review P1 on PR #162).
#
# The registry volume (<Compose project>_pg-sanitizer-core-data) only works
# with the two customer.env secrets it was created with:
#   POSTGRES_SANITIZER_CORE_PASSWORD  Postgres sets the role's password when the
#                                     volume is first created; another one fails
#                                     the migration's (and the core's) login.
#   DSA_SANITIZER_CORE_REGISTRY_KEY   seals every registry row; another key
#                                     leaves the existing rows unreadable.
# A rollback to 1.9.7 restores the 1.9.7 customer.env (which has neither) and
# keeps the volume, so a later re-upgrade that generates new values breaks it.
#
# Usage:
#   scripts/sanitizer-core-registry-credentials.sh save  --env-file customer.env [--dir DIR]
#   scripts/sanitizer-core-registry-credentials.sh add   --env-file customer.env [--from SAVED]
#   scripts/sanitizer-core-registry-credentials.sh check --env-file customer.env
#   (each also takes --project-dir DIR: the Compose project directory; default
#   the kit root, or install/ of an extracted customer bundle)
#
#   save   Rollback, BEFORE the 1.9.7 kit files go back: copies the 2.0
#          customer.env, its two sidecar files and the registry DSN file into
#          DIR (default backups/sanitizer-core-<UTC time>/ beside customer.env;
#          mode 0700, every file 0600), and writes DIR/sanitizer-core-registry.env
#          with the two lines exactly as customer.env holds them. Prints that
#          file's path on stdout.
#   add    Upgrade step 4: appends the two lines to customer.env. Without
#          --from it generates new values ONLY when this install has no registry
#          volume; when it has one it refuses and names the saved file to
#          restore. --from SAVED appends the saved lines (a 0600 or 0400 file
#          holding exactly the two lines). Nothing changes when customer.env
#          already holds both (with --from: the same two).
#   check  rc 0 no registry volume · 3 one exists (stderr says what to restore)
#          · 4 cannot tell (Docker Compose or the Docker daemon not reachable).
#          bin/lucairn-init runs it before it generates a new customer.env.
#
# The volume name is Compose's own: a throw-away project without `name:`,
# rendered with this project directory and env file (client side), gives the
# project name exactly as bin/lucairn up gets it (the directory name, or
# COMPOSE_PROJECT_NAME from the env file or this shell). The daemon is asked
# only for its volume list. No secret value is ever printed.
#
# Exit codes: 0 ok · 1 a copy or write failed · 2 usage or a refused input ·
# 3 a registry volume exists and no saved credentials were given · 4 cannot
# check for a registry volume (nothing was generated).

set -euo pipefail

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROG="sanitizer-core-registry-credentials"
SELF="scripts/sanitizer-core-registry-credentials.sh"
VOLUME_KEY="pg-sanitizer-core-data"
SAVED_NAME="sanitizer-core-registry.env"
KEY_NAME="DSA_SANITIZER_CORE_REGISTRY_KEY"
PW_NAME="POSTGRES_SANITIZER_CORE_PASSWORD"

log() { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die() { local rc="$1"; shift; printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit "$rc"; }

LIB="$KIT_ROOT/bin/compose-env.sh"
[ -f "$LIB" ] && [ ! -L "$LIB" ] || die 2 "missing $LIB (the kit's Compose env reader)"
# shellcheck source=../bin/compose-env.sh
. "$LIB"

CMD="${1:-}"
case "$CMD" in
  save|add|check) shift ;;
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
  *) die 2 "first argument must be save, add or check (see --help)" ;;
esac

PROJECT_DIR="$KIT_ROOT"
if [ ! -f "$KIT_ROOT/docker-compose.customer.yml" ] && [ -f "$KIT_ROOT/install/docker-compose.customer.yml" ]; then
  PROJECT_DIR="$KIT_ROOT/install"
fi
ENV_FILE="" FROM="" DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file) [ "$#" -ge 2 ] || die 2 "--env-file needs a path"; ENV_FILE="$2"; shift 2 ;;
    --project-dir) [ "$#" -ge 2 ] || die 2 "--project-dir needs a path"; PROJECT_DIR="$2"; shift 2 ;;
    --from) [ "$CMD" = add ] || die 2 "--from belongs to add"; [ "$#" -ge 2 ] || die 2 "--from needs a path"; FROM="$2"; shift 2 ;;
    --dir) [ "$CMD" = save ] || die 2 "--dir belongs to save"; [ "$#" -ge 2 ] || die 2 "--dir needs a path"; DIR="$2"; shift 2 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || die 2 "project directory not found"
[ -n "$ENV_FILE" ] || ENV_FILE="$PROJECT_DIR/customer.env"
ENV_DIR="$(cd "$(dirname "$ENV_FILE")" 2>/dev/null && pwd)" || die 2 "the directory of $ENV_FILE does not exist"

# One assignment line of NAME, as Compose's env-file parser accepts it.
assign_re() { printf '^(export[[:space:]]+)?%s=' "$1"; }
count_lines() { grep -cE "$(assign_re "$1")" "$2" 2>/dev/null || true; }
both_lines() { grep -E "$(assign_re "$KEY_NAME")|$(assign_re "$PW_NAME")" "$1"; }

# The newest saved credentials file beside the env file, if any.
newest_saved() {
  local f newest=""
  for f in "$ENV_DIR"/backups/sanitizer-core-*/"$SAVED_NAME"; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
  done
  printf '%s' "$newest"
}

# registry_volume — sets VOL (the volume name Compose gives this install) and
# returns 0 when it exists, 1 when it does not, 2 when that cannot be told
# (VOL_WHY says why, value-free).
registry_volume() {
  local tmp envf proj="" out
  VOL="" VOL_WHY=""
  cev_compose_cmd 2>/dev/null || { VOL_WHY="Docker Compose is not available here"; return 2; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lucairn-env-probe.XXXXXX")" || { VOL_WHY="no private temp directory"; return 2; }
  chmod 0700 "$tmp"
  printf '{"services":{"probe":{"image":"lucairn-env-probe"}}}\n' > "$tmp/probe.json"
  envf="$ENV_FILE"
  if [ ! -f "$envf" ]; then envf="$tmp/empty.env"; : > "$envf"; fi
  if "${CEV_CMD[@]}" --project-directory "$PROJECT_DIR" -f "$tmp/probe.json" --env-file "$envf" \
       config --format json > "$tmp/out.json" 2>/dev/null </dev/null; then
    proj="$(LC_ALL=C sed -n 's/^  "name": "\([a-z0-9][a-z0-9_-]*\)",\{0,1\}$/\1/p' "$tmp/out.json" | head -1)"
  fi
  rm -rf "$tmp"
  [ -n "$proj" ] || { VOL_WHY="Docker Compose did not give this install's project name"; return 2; }
  VOL="${proj}_${VOLUME_KEY}"
  command -v docker >/dev/null 2>&1 || { VOL_WHY="the docker CLI is not on PATH"; return 2; }
  out="$(docker volume ls -q 2>/dev/null </dev/null)" || { VOL_WHY="the Docker daemon is not reachable"; return 2; }
  if printf '%s\n' "$out" | grep -Fxq -- "$VOL"; then return 0; fi
  return 1
}

# refuse_existing <context> — exit 3, naming what to restore.
refuse_existing() {
  local saved hint
  saved="$(newest_saved)"
  if [ "$1" = init ]; then
    if [ -n "$saved" ]; then
      hint="put the kit 2.0 customer.env and its two sidecar files saved in $(dirname "$saved") back beside the kit (cp -p) and use that env instead of a new one"
    else
      hint="put back the kit 2.0 customer.env that created it (a rollback saved it with its two sidecar files in backups/sanitizer-core-<time>/ beside customer.env, INSTALL.md § \"Rollback to 1.9.7\") instead of generating a new one"
    fi
  elif [ -n "$saved" ]; then
    hint="restore the credentials the rollback saved: $SELF add --env-file '$ENV_FILE' --from '$saved'"
  else
    hint="restore the credentials the rollback saved (backups/sanitizer-core-<time>/$SAVED_NAME beside customer.env, INSTALL.md § \"Rollback to 1.9.7\"): $SELF add --env-file '$ENV_FILE' --from <that file>"
  fi
  die 3 "this install already has a sanitizer core registry volume ($VOL), created with the registry key and database password of an earlier kit 2.0 run. New ones cannot open it (the registry migration fails to log in and every sealed row stays unreadable), so none were generated. Either $hint — or, to give up its sealed state (at most the last 24 hours), delete the volume first: docker volume rm $VOL"
}

file_mode() {
  case "$(uname -s)" in
    Darwin|FreeBSD|OpenBSD|NetBSD) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

# validate_saved <file> — a saved credentials file: regular, owner-only,
# exactly one line of each name, nothing else; the key 64 hex, the password
# non-empty. Never prints a value.
validate_saved() {
  local f="$1" n c mode v
  [ -f "$f" ] && [ ! -L "$f" ] || die 2 "$f is not a regular file"
  mode="$(file_mode "$f")"
  case "$mode" in 600|400) : ;; *) die 2 "$f has mode $mode; it holds the registry key and password, so it must be 0600 (chmod 600 '$f')" ;; esac
  for n in "$KEY_NAME" "$PW_NAME"; do
    c="$(count_lines "$n" "$f")"
    [ "$c" = 1 ] || die 2 "$f must hold exactly one $n line (it holds $c)"
  done
  if grep -vE "$(assign_re "$KEY_NAME")|$(assign_re "$PW_NAME")|^[[:space:]]*$" "$f" | grep -q .; then
    die 2 "$f holds a line other than $KEY_NAME and $PW_NAME (refused; not printed)"
  fi
  v="$(grep -E "$(assign_re "$KEY_NAME")" "$f" | sed -E "s/^(export[[:space:]]+)?$KEY_NAME=//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/")"
  printf '%s' "$v" | grep -Eqx '[0-9a-fA-F]{64}' || die 2 "$KEY_NAME in $f is not 64 hex characters (not printed)"
  v="$(grep -E "$(assign_re "$PW_NAME")" "$f" | sed -E "s/^(export[[:space:]]+)?$PW_NAME=//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/")"
  [ -n "$v" ] || die 2 "$PW_NAME in $f is empty"
}

# append_lines — stdin onto the env file, after a line break if it lacks one.
append_lines() {
  if [ -s "$ENV_FILE" ] && [ -n "$(tail -c 1 "$ENV_FILE")" ]; then printf '\n' >> "$ENV_FILE"; fi
  cat >> "$ENV_FILE"
}

do_check() {
  local rc=0
  registry_volume || rc=$?
  case "$rc" in
    0) refuse_existing init ;;
    1) exit 0 ;;
    *) printf '%s\n' "$VOL_WHY" >&2; exit 4 ;;
  esac
}

do_save() {
  local n c out dsn base s
  [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || die 2 "$ENV_FILE is not a regular file"
  for n in "$KEY_NAME" "$PW_NAME"; do
    c="$(count_lines "$n" "$ENV_FILE")"
    [ "$c" = 1 ] || die 2 "$ENV_FILE must hold exactly one $n line (it holds $c): run save with the kit 2.0 customer.env, before the 1.9.7 one is restored"
  done
  # The DSN file as Compose resolves it (SANITIZER_CORE_REGISTRY_DSN_FILE or
  # the compose default), never by a hand-written reader.
  out="$(cev_registry --env-file "$ENV_FILE" --project-dir "$PROJECT_DIR" 2>/dev/null)" \
    || die 4 "cannot read $ENV_FILE through Docker Compose (run this on the Docker host, with the 2.0 kit files still in place); nothing was saved"
  dsn="$(printf '%s\n' "$out" | sed -n 's/^dsn_file	//p' | head -1)"
  out=""
  if [ -z "$DIR" ]; then
    DIR="$ENV_DIR/backups/sanitizer-core-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  [ ! -e "$DIR" ] && [ ! -L "$DIR" ] || die 2 "$DIR exists; pass --dir with a new folder"
  umask 077
  mkdir -p "$(dirname "$DIR")"
  mkdir "$DIR" || die 1 "could not create $DIR"
  chmod 0700 "$DIR"
  copy() {
    cp "$1" "$DIR/$2" && chmod 0600 "$DIR/$2" && cmp -s "$1" "$DIR/$2" || die 1 "could not copy $1 into $DIR"
  }
  base="$(basename "$ENV_FILE")"
  copy "$ENV_FILE" "$base"
  for s in runtime-profile.yaml image-manifest.yaml; do
    if [ -f "$ENV_FILE.$s" ] && [ ! -L "$ENV_FILE.$s" ]; then copy "$ENV_FILE.$s" "$base.$s"; fi
  done
  if [ -n "$dsn" ] && [ -f "$dsn" ] && [ ! -L "$dsn" ]; then
    copy "$dsn" "$(basename "$dsn")"
  else
    log "note: no registry DSN file at ${dsn:-the default path}; scripts/write-sanitizer-core-registry-dsn.sh writes it again from customer.env"
  fi
  both_lines "$ENV_FILE" > "$DIR/$SAVED_NAME" || die 1 "could not write $DIR/$SAVED_NAME"
  chmod 0600 "$DIR/$SAVED_NAME"
  validate_saved "$DIR/$SAVED_NAME"
  log "saved the kit 2.0 customer.env, its sidecar files, the registry DSN file and $SAVED_NAME in $DIR (0700; files 0600; values not printed)"
  log "keep this folder as long as the registry volume exists: it holds the only copy of the key that opens its rows; delete both together"
  printf '%s\n' "$DIR/$SAVED_NAME"
}

do_add() {
  local kc pc rc=0 key pw
  [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || die 2 "$ENV_FILE is not a regular file"
  kc="$(count_lines "$KEY_NAME" "$ENV_FILE")"
  pc="$(count_lines "$PW_NAME" "$ENV_FILE")"
  [ "$kc" -le 1 ] && [ "$pc" -le 1 ] || die 2 "$ENV_FILE holds $KEY_NAME or $PW_NAME more than once; keep one of each"
  if [ "$kc" = 1 ] && [ "$pc" = 1 ]; then
    if [ -n "$FROM" ]; then
      validate_saved "$FROM"
      if [ "$(both_lines "$ENV_FILE")" = "$(both_lines "$FROM")" ]; then
        log "$ENV_FILE already holds the saved registry credentials; nothing changed"
        exit 0
      fi
      die 2 "$ENV_FILE already holds a registry key and password that differ from $FROM (values not printed); delete those two lines from $ENV_FILE, then re-run"
    fi
    log "$ENV_FILE already holds $KEY_NAME and $PW_NAME; nothing changed"
    exit 0
  fi
  [ "$kc" = "$pc" ] || die 2 "$ENV_FILE holds only one of $KEY_NAME and $PW_NAME; they belong together (restore both from the saved file with --from, or delete the one line)"
  if [ -n "$FROM" ]; then
    validate_saved "$FROM"
    both_lines "$FROM" | append_lines
    log "restored $KEY_NAME and $PW_NAME from $FROM into $ENV_FILE (values not printed)"
    exit 0
  fi
  registry_volume || rc=$?
  case "$rc" in
    0) refuse_existing add ;;
    1) : ;;
    *) die 4 "cannot check whether this install already has a sanitizer core registry volume ($VOL_WHY), so no credentials were generated: new ones would not open an existing registry. Start Docker and re-run, or pass --from <saved file>" ;;
  esac
  command -v openssl >/dev/null 2>&1 || die 2 "openssl is required"
  key="$(openssl rand -hex 32)"
  pw="$(openssl rand -hex 24)"
  printf '%s' "$key" | grep -Eqx '[0-9a-f]{64}' && printf '%s' "$pw" | grep -Eqx '[0-9a-f]{48}' \
    || die 1 "openssl did not generate the expected values"
  printf '%s=%s\n%s=%s\n' "$KEY_NAME" "$key" "$PW_NAME" "$pw" | append_lines
  key="" pw=""
  log "no registry volume ($VOL) yet: generated $KEY_NAME and $PW_NAME into $ENV_FILE (values not printed; keep them stable)"
}

case "$CMD" in
  check) do_check ;;
  save) do_save ;;
  add) do_add ;;
esac
