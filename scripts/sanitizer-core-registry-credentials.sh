#!/usr/bin/env bash
# sanitizer-core-registry-credentials.sh — keep the sanitizer core's registry
# credentials across a rollback (kit 2.0, PRD prd-2026-11-02-kit-2-0-new-core.md
# row 4; K-E fix round 1, review P1 on PR #162; fix rounds 2 and 4).
#
# The registry volume (by default <Compose project>_pg-sanitizer-core-data)
# only works with the two customer.env secrets it was created with:
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
#   the kit root, or install/ of an extracted customer bundle. add and check
#   also take --overlays "FILE ...": the install's compose overlays, kit file
#   names in that directory; default the ones the runtime profile beside the
#   env file records — bin/lucairn-init passes the ones it will record)
#
#   save   Rollback, BEFORE the 1.9.7 kit files go back: copies the 2.0
#          customer.env, its two sidecar files and the registry DSN file into
#          DIR (default backups/sanitizer-core-<UTC time>/ beside customer.env;
#          mode 0700, every file 0600), and writes DIR/sanitizer-core-registry.env
#          with the two lines exactly as customer.env holds them, plus
#          DIR/.gitignore and (default DIR) backups/.gitignore holding `*`:
#          untracked ignore files a `git checkout v1.9.7` keeps, so the copies
#          stay out of `git add` after the kit's own backups/ rule is gone.
#          Prints the saved credentials file's path on stdout.
#   add    Upgrade step 4: appends the two lines to customer.env. Without
#          --from it generates new values ONLY when this install has no registry
#          volume; when it has one it refuses and names the saved file to
#          restore. --from SAVED appends the saved lines (a 0600 or 0400 file
#          holding exactly the two lines). Nothing changes when customer.env
#          already holds both (with --from: the same two).
#   check  rc 0 no registry volume · 3 one exists (stderr says what to restore)
#          · 4 cannot tell: the daemon answered, but a registry volume name of
#          this install cannot be resolved (Docker Compose missing, the
#          project or an overlay does not render) and no name that did
#          resolve is on the daemon's list · 5 cannot tell: Docker cannot be
#          asked (no docker CLI, or the docker CLI reports it cannot connect
#          to the daemon) · 6 cannot tell: Docker was asked but gave no
#          volume list (the daemon answered with an error, or the CLI failed
#          in any other way — permission denied included).
#          bin/lucairn-init runs it before it generates a new customer.env;
#          its --confirm-no-registry-volume overrides exit 5 only.
#
# The volume name is Compose's own (fix round 2, review P2 on PR #162): the
# install's project — docker-compose.customer.yml plus its overlays, as
# bin/lucairn up starts it, and once more with the ServiceNow mode overlay
# when that file is there — rendered client side through bin/compose-env.sh
# cev_volume gives the name of the volume postgres-sanitizer-core keeps its
# data in (project name, COMPOSE_PROJECT_NAME, a custom or external `name:`
# included). A volume of ANY of those names counts. Fix round 4 (review P2 on
# PR #162): every name that resolves is matched against the daemon's list
# BEFORE a failed render is reported, so a known volume is refused (exit 3)
# even when another of the renders fails. A name that cannot be resolved is
# "cannot tell" (exit 4), never a guess. The daemon is asked only for its
# version and its volume list. Final check on PR #162 and fix round 1 on PR
# #163: only no docker CLI, or one of the docker CLI's own "cannot connect"
# errors (listed at docker_cannot_connect, v24–v29), is "Docker cannot be
# asked" (exit 5); every other failure of either request — an error response,
# an HTTP error such as an empty 500, permission denied, any unknown message —
# is exit 6, which no flag overrides. The list is matched in
# the shell, never through `printf | grep -q`: under pipefail grep's exit at
# the match sent printf a SIGPIPE and the match was dropped once the list
# outgrew the pipe. No secret value is ever printed.
#
# Exit codes: 0 ok · 1 a copy or write failed · 2 usage or a refused input ·
# 3 a registry volume exists and no saved credentials were given · 4 cannot
# check for a registry volume: a volume name cannot be resolved (nothing was
# generated) · 5 cannot check for a registry volume: Docker cannot be asked
# (nothing was generated) · 6 cannot check for a registry volume: Docker was
# asked but gave no volume list (nothing was generated).

set -euo pipefail

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROG="sanitizer-core-registry-credentials"
SELF="scripts/sanitizer-core-registry-credentials.sh"
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
ENV_FILE="" FROM="" DIR="" OVERLAYS="" OVERLAYS_SET=0
BASE_COMPOSE="docker-compose.customer.yml"
SN_OVERLAY="docker-compose.servicenow-control.yml"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file) [ "$#" -ge 2 ] || die 2 "--env-file needs a path"; ENV_FILE="$2"; shift 2 ;;
    --project-dir) [ "$#" -ge 2 ] || die 2 "--project-dir needs a path"; PROJECT_DIR="$2"; shift 2 ;;
    --overlays) [ "$CMD" != save ] || die 2 "--overlays belongs to add and check"; [ "$#" -ge 2 ] || die 2 "--overlays needs a list (may be empty)"; OVERLAYS="$2"; OVERLAYS_SET=1; shift 2 ;;
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

# install_overlays — sets OVL to the overlay files of this install's project,
# one per line (--overlays, else the runtime profile beside the env file; none
# when there is no profile). rc 1 with VOL_WHY when they cannot be read.
install_overlays() {
  local profile list o lib="$KIT_ROOT/bin/runtime-profile-lib.sh"
  OVL=""
  if [ "$OVERLAYS_SET" -eq 1 ]; then
    list="$(printf '%s\n' "$OVERLAYS" | tr ' ' '\n')"
  else
    profile="$ENV_FILE.runtime-profile.yaml"
    if [ ! -e "$profile" ] && [ ! -L "$profile" ]; then return 0; fi
    [ -f "$lib" ] && [ ! -L "$lib" ] || { VOL_WHY="missing $lib (the runtime profile reader)"; return 1; }
    # shellcheck source=../bin/runtime-profile-lib.sh
    . "$lib"
    list="$(runtime_profile_overlays "$profile")" || { VOL_WHY="the runtime profile $profile cannot be read"; return 1; }
  fi
  while IFS= read -r o; do
    [ -n "$o" ] && [ "$o" != "$BASE_COMPOSE" ] || continue
    case "$o" in
      */*|.*|*[!A-Za-z0-9._-]*) VOL_WHY="the overlay name $o is not a kit file name"; return 1 ;;
    esac
    [ -f "$PROJECT_DIR/$o" ] && [ ! -L "$PROJECT_DIR/$o" ] || { VOL_WHY="the overlay $o is missing in $PROJECT_DIR"; return 1; }
    OVL="${OVL:+$OVL
}$o"
  done <<EOF
$list
EOF
}

# volume_name <env file> <compose args...> — appends the registry volume name
# Compose gives that project to VOLS (newline-separated, no duplicates).
volume_name() {
  local envf="$1" out name err
  shift
  err="$(mktemp "${TMPDIR:-/tmp}/lucairn-vol-err.XXXXXX")" || { VOL_WHY="no private temp file"; return 1; }
  out="$(cev_volume --env-file "$envf" --project-dir "$PROJECT_DIR" -- "$@" 2>"$err")" || {
    VOL_WHY="$(sed -n 's/^compose-env: //p' "$err" | head -1)"
    rm -f "$err"
    VOL_WHY="Docker Compose did not give the registry volume of this install (${VOL_WHY:-no reason given})"
    return 1
  }
  rm -f "$err"
  name="$(printf '%s\n' "$out" | sed -n 's/^volume	//p' | head -1)"
  [ -n "$name" ] || { VOL_WHY="Docker Compose did not give the registry volume of this install"; return 1; }
  case "
$VOLS
" in *"
$name
"*) : ;; *) VOLS="${VOLS:+$VOLS
}$name" ;; esac
}

# docker_cannot_connect <output> — rc 0 ONLY when <output> (stdout and stderr
# of a failed docker CLI call) is one of the docker CLI's own "cannot connect"
# errors: the request reached no daemon. Every other failure is rc 1, which
# the caller refuses with or without --confirm-no-registry-volume (fix round 1
# on PR #163: an empty HTTP 500 from a reachable daemon, "request returned 500
# Internal Server Error for API route and version …", used to count as
# unreachable). The recognised strings, exactly as the docker CLI v24.0–v29.6
# prints them (its vendored API client: github.com/docker/docker/client
# errors.go + request.go doRequest for v24–v28, github.com/moby/moby/client
# for v29):
#   "Cannot connect to the Docker daemon at <host>. Is the docker daemon running?"
#   "Cannot connect to the Docker daemon. Is the docker daemon running on this host?"
#       errors.go, v24–v29: connection refused, a failed `dial unix` (v24–v28
#       also a socket path that does not exist), a dial timeout
#   "failed to connect to the docker API at <host>; check if the path is correct and if the daemon is running: …"
#   "failed to connect to the docker API at <host>: …"
#       request.go, v29: the socket path does not exist ("… connect: no such
#       file or directory"), the daemon's host name does not resolve
#   "error during connect: …"
#       request.go, v24–v29: any other transport error before an HTTP
#       response (a Windows named pipe that is not there, an ssh:// host that
#       cannot be reached, a v24–v28 host name that does not resolve)
# The bare "connection refused" / "connect: no such file or directory" are not
# matched alone: the CLI only prints them inside the phrases above, and a
# daemon's own error response can carry them. Never recognised, even inside
# one of the phrases above:
#   "Error response from daemon", "request returned " — an HTTP response: the
#       daemon answered
#   "permission denied" (v24–v28 "… to the Docker daemon socket at", v29 "…
#       to the docker API at"; ssh "Permission denied"), "Access is denied",
#       "elevated privileges" — Docker is there, this user may not use it
#   "x509:", "tls:" — a TLS server answered
# Not recognised either, so refused: a timeout the client does not report as
# "Cannot connect" ("context deadline exceeded"), a context or config error,
# any message not listed here.
docker_cannot_connect() {
  case "$1" in
    *"Error response from daemon"*|*"request returned "*) return 1 ;;
    *[Pp]"ermission denied"*|*"Access is denied"*|*"elevated privileges"*|*"x509:"*|*"tls:"*) return 1 ;;
    *"Cannot connect to the Docker daemon at "*". Is the docker daemon running?"*) return 0 ;;
    *"Cannot connect to the Docker daemon. Is the docker daemon running on this host?"*) return 0 ;;
    *"failed to connect to the docker API at "*) return 0 ;;
    *"error during connect: "*) return 0 ;;
  esac
  return 1
}

# registry_volume — sets VOL (the registry volume this install has, or the
# first name it would have) and returns 0 when one exists, 1 when none does,
# 2 when a name cannot be resolved and no resolved one exists, 3 when Docker
# cannot be asked, 4 when Docker was asked but gave no volume list (VOL_WHY
# says why, value-free). The daemon is asked first, so a host without one
# answers fast. Fix round 1 on PR #163: only a positively recognised "cannot
# connect" (docker_cannot_connect) or no docker CLI is 3, the one case the
# init flag overrides; every other failure of `docker version` or `docker
# volume ls` — an HTTP error, an error response, an unknown message — is 4.
# Once `docker version` has answered, a failed volume list is 4 whatever it
# says (the daemon was reached).
registry_volume() {
  local tmp envf out name rc=0 why="" said
  local -a args
  VOL="" VOL_WHY="" VOLS=""
  command -v docker >/dev/null 2>&1 || { VOL_WHY="the docker CLI is not on PATH"; return 3; }
  if ! said="$(docker version --format '{{.Server.Version}}' 2>&1 </dev/null)"; then
    if docker_cannot_connect "$said"; then
      VOL_WHY="the Docker daemon is not reachable"; return 3
    fi
    VOL_WHY="Docker was asked but did not give its version, with an error that is not the docker CLI's \"cannot connect\" (run docker version)"; return 4
  fi
  out="$(docker volume ls -q 2>/dev/null </dev/null)" \
    || { VOL_WHY="the Docker daemon answered but did not list its volumes (docker volume ls failed)"; return 4; }
  cev_compose_cmd 2>/dev/null || { VOL_WHY="Docker Compose is not available here"; return 2; }
  [ -f "$PROJECT_DIR/$BASE_COMPOSE" ] && [ ! -L "$PROJECT_DIR/$BASE_COMPOSE" ] \
    || { VOL_WHY="no $BASE_COMPOSE in $PROJECT_DIR"; return 2; }
  install_overlays || return 2
  args=(-f "$PROJECT_DIR/$BASE_COMPOSE")
  while IFS= read -r name; do
    [ -z "$name" ] || args+=(-f "$PROJECT_DIR/$name")
  done <<EOF
$OVL
EOF
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lucairn-env-probe.XXXXXX")" || { VOL_WHY="no private temp directory"; return 2; }
  chmod 0700 "$tmp"
  envf="$ENV_FILE"
  if [ ! -f "$envf" ]; then envf="$tmp/empty.env"; : > "$envf"; fi
  volume_name "$envf" "${args[@]}" || { rc=2; why="$VOL_WHY"; }
  if [ -f "$PROJECT_DIR/$SN_OVERLAY" ] && [ ! -L "$PROJECT_DIR/$SN_OVERLAY" ]; then
    case " ${args[*]} " in
      *"/$SN_OVERLAY "*) : ;;
      *) volume_name "$envf" "${args[@]}" -f "$PROJECT_DIR/$SN_OVERLAY" || { rc=2; why="${why:-$VOL_WHY}"; } ;;
    esac
  fi
  rm -rf "$tmp"
  # Fix round 4: a resolved name the daemon lists is a known volume, whatever
  # another render did — refuse on it before reporting "cannot tell". One
  # whole line of the list, matched in the shell (no pipe, no temp file).
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "
$out
" in *"
$name
"*) VOL="$name"; return 0 ;; esac
  done <<EOF
$VOLS
EOF
  [ "$rc" -eq 0 ] || { VOL_WHY="$why"; return 2; }
  VOL="$(printf '%s\n' "$VOLS" | head -1)"
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
  local f="$1" n c mode v rc=0
  [ -f "$f" ] && [ ! -L "$f" ] || die 2 "$f is not a regular file"
  mode="$(file_mode "$f")"
  case "$mode" in 600|400) : ;; *) die 2 "$f has mode $mode; it holds the registry key and password, so it must be 0600 (chmod 600 '$f')" ;; esac
  for n in "$KEY_NAME" "$PW_NAME"; do
    c="$(count_lines "$n" "$f")"
    [ "$c" = 1 ] || die 2 "$f must hold exactly one $n line (it holds $c)"
  done
  # Final check on PR #162: one grep reads the file (`grep -v | grep -q .`
  # under pipefail dropped this match once the other lines outgrew the pipe),
  # and a read error refuses too.
  grep -qvE "$(assign_re "$KEY_NAME")|$(assign_re "$PW_NAME")|^[[:space:]]*$" "$f" || rc=$?
  case "$rc" in
    0) die 2 "$f holds a line other than $KEY_NAME and $PW_NAME (refused; not printed)" ;;
    1) : ;;
    *) die 2 "$f cannot be read" ;;
  esac
  v="$(grep -E "$(assign_re "$KEY_NAME")" "$f" | sed -E "s/^(export[[:space:]]+)?$KEY_NAME=//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/")"
  [[ $v =~ ^[0-9a-fA-F]{64}$ ]] || die 2 "$KEY_NAME in $f is not 64 hex characters (not printed)"
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
    3) printf '%s\n' "$VOL_WHY" >&2; exit 5 ;;
    4) printf '%s\n' "$VOL_WHY" >&2; exit 6 ;;
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
  # Fix round 2 (review P2 on PR #162): the rollback's `git checkout v1.9.7`
  # brings back a .gitignore without the kit's backups/ rule, and the copies
  # (the DSN file holds the database password) would be offered to `git add`.
  # An untracked ignore file survives a checkout and git honours it: one in
  # the saved folder, written before anything is copied in, and one in
  # backups/ for the default folder.
  ignore_all() {
    local f="$1/.gitignore"
    [ ! -L "$f" ] || die 1 "$f is a symbolic link; nothing was saved"
    local lead=""
    if [ -f "$f" ] && grep -qx '[*]' "$f"; then return 0; fi
    if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then lead='\n'; fi
    printf '%b%s\n' "$lead" '*' >> "$f" || die 1 "could not write $f; nothing was saved"
  }
  ignore_all "$DIR"
  case "$DIR" in "$ENV_DIR/backups/"*) ignore_all "$ENV_DIR/backups" ;; esac
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
    3) die 5 "cannot check whether this install already has a sanitizer core registry volume ($VOL_WHY), so no credentials were generated: new ones would not open an existing registry. Start Docker and re-run, or pass --from <saved file>" ;;
    4) die 6 "cannot check whether this install already has a sanitizer core registry volume ($VOL_WHY), so no credentials were generated: new ones would not open an existing registry. Fix what keeps Docker from listing its volumes (run docker version and docker volume ls as this user) and re-run, or pass --from <saved file>" ;;
    *) die 4 "cannot check whether this install already has a sanitizer core registry volume ($VOL_WHY), so no credentials were generated: new ones would not open an existing registry. Fix the cause and re-run, or pass --from <saved file>" ;;
  esac
  command -v openssl >/dev/null 2>&1 || die 2 "openssl is required"
  key="$(openssl rand -hex 32)"
  pw="$(openssl rand -hex 24)"
  [[ $key =~ ^[0-9a-f]{64}$ ]] && [[ $pw =~ ^[0-9a-f]{48}$ ]] \
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
