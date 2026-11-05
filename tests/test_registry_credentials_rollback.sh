#!/usr/bin/env bash
# Kit 2.0 K-E fix round 1 (review P1 on PR #162; PRD
# prd-2026-11-02-kit-2-0-new-core.md row 4) and fix round 2 (init fails closed
# without a daemon; the volume name is the one the rendered project gives; the
# saved folder stays git-ignored after a checkout of 1.9.7): upgrade -> rollback -> re-upgrade
# must reuse the sanitizer core's registry credentials. Fix round 4: a known
# volume is refused before a failed render is reported, "Docker unreachable"
# has its own exit code (5), and --confirm-no-registry-volume overrides only
# that one. The registry volume
# survives a rollback and only opens with the key and database password it was
# created with; the 1.9.7 customer.env a rollback restores has neither, and the
# guide's step 4 used to generate new ones (the migration then fails to log in
# and every sealed row stays unreadable).
#
# No daemon and no image run here: Docker Compose renders client side (the
# project name, the env reads), and a stub `docker volume ls` stands for the
# daemon, so the script's refusal and reuse logic and bin/lucairn-init's
# refusal are tested as the guide drives them. What a real run adds — the
# migration logging in and the core opening the old rows — follows from the
# same two values reaching customer.env and the DSN file, which is asserted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
# shellcheck source=lib/test-helpers.sh
. "$ROOT/tests/lib/test-helpers.sh"
lucairn_use_released_kit "$TMPDIR"
KIT="$ROOT"
DOCS_ROOT="${REAL_ROOT:-$ROOT}"

PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

LUCAIRN_TEST_REAL_DOCKER="$(command -v docker 2>/dev/null || true)"
[ -n "$LUCAIRN_TEST_REAL_DOCKER" ] && "$LUCAIRN_TEST_REAL_DOCKER" compose version >/dev/null 2>&1 \
  || { echo "registry credentials rollback: needs the docker CLI with the Compose plugin (client side only)" >&2; exit 1; }
STUB_DAEMON="$TMPDIR/daemon"
STUB_VOLUMES="$TMPDIR/volumes"
STUB_MSG="$TMPDIR/docker-message"
: > "$STUB_MSG"
STUB_CONTEXT="$TMPDIR/docker-context"
export LUCAIRN_TEST_REAL_DOCKER STUB_DAEMON STUB_VOLUMES STUB_MSG STUB_CONTEXT
mkdir "$TMPDIR/bin"
cat > "$TMPDIR/bin/docker" <<'STUB'
#!/bin/bash
# Compose renders (client side: `version` and `config`) go to the real CLI;
# the daemon is a stub. Any other Compose command would need a daemon.
# Daemon states ($STUB_DAEMON): up · down (cannot connect) · qerr (answers,
# but its volume list fails) · deny (answers every request with an error
# response, as an authorization plugin does) · msg (every request fails with
# exactly the text in $STUB_MSG on stderr: a docker CLI error message).
# `docker context inspect` prints $STUB_CONTEXT (the current context's
# endpoint), or fails when it holds `fail` (fix round 2 on PR #163).
if [ "${1:-}" = compose ]; then
  case " $* " in *" config "*|*" version"*) exec "$LUCAIRN_TEST_REAL_DOCKER" "$@" ;; esac
fi
if [ "${1:-}" = context ] && [ "${2:-}" = inspect ]; then
  c="$(cat "$STUB_CONTEXT")"
  [ "$c" != fail ] || { echo 'context "stub": context not found' >&2; exit 1; }
  printf '%s\n' "$c"; exit 0
fi
if [ "${1:-}" = version ]; then
  case "$(cat "$STUB_DAEMON")" in
    up|qerr) echo "27.5.1"; exit 0 ;;
    deny) echo "Error response from daemon: authorization denied by plugin stub-authz" >&2; exit 1 ;;
    msg) cat "$STUB_MSG" >&2; exit 1 ;;
    *) echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1 ;;
  esac
fi
if [ "${1:-}" = volume ] && [ "${2:-}" = ls ]; then
  case "$(cat "$STUB_DAEMON")" in
    up) cat "$STUB_VOLUMES"; exit 0 ;;
    qerr|deny) echo "Error response from daemon: stub volume list failure" >&2; exit 1 ;;
    msg) cat "$STUB_MSG" >&2; exit 1 ;;
    *) echo "Cannot connect to the Docker daemon" >&2; exit 1 ;;
  esac
fi
echo "unexpected docker call: $*" >&2
exit 97
STUB
chmod 0755 "$TMPDIR/bin/docker"
export PATH="$TMPDIR/bin:$PATH"

# Fix round 2 on PR #163: "no Docker here" (exit 5, the one case
# --confirm-no-registry-volume covers) needs the docker CLI's endpoint to be a
# local unix socket that a raw connect finds missing or refusing. Real sockets
# for that, in a short directory (a unix socket path has at most 104 bytes on
# macOS): accept.sock (a listener: a daemon or a proxy is there), denied.sock
# (a listener this user may not open), refuse.sock (a socket file nothing
# listens on), missing.sock (nothing). The stub daemon's states above keep
# their meaning; DOCKER_HOST says where the CLI would have gone, by default
# the missing socket (so "down" is the documented no-daemon case).
command -v python3 >/dev/null 2>&1 || { echo "registry credentials rollback: needs python3 (socket fixtures)" >&2; exit 1; }
SOCKDIR="$(mktemp -d /tmp/lucairn-sock.XXXXXX)"
python3 -I -c '
import select, socket, sys
socks = []
for p in sys.argv[2:]:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(p)
    s.listen(64)
    socks.append(s)
open(sys.argv[1], "w").close()
while True:
    ready, _, _ = select.select(socks, [], [], 60)
    for s in ready:
        c, _ = s.accept()
        c.close()
' "$SOCKDIR/ready" "$SOCKDIR/accept.sock" "$SOCKDIR/denied.sock" </dev/null >/dev/null 2>&1 &
LISTENER=$!
disown "$LISTENER" 2>/dev/null || true  # no "Terminated" job report at exit
trap 'kill "$LISTENER" 2>/dev/null || true; rm -rf "$TMPDIR" "$SOCKDIR"' EXIT
for _ in $(seq 1 100); do [ -e "$SOCKDIR/ready" ] && break; sleep 0.1; done
[ -e "$SOCKDIR/ready" ] || { echo "registry credentials rollback: the socket listener did not start" >&2; exit 1; }
chmod 000 "$SOCKDIR/denied.sock"
python3 -I -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$SOCKDIR/refuse.sock"
ln -s "$SOCKDIR/gone.sock" "$SOCKDIR/dangling.sock"
use_endpoint() { # <DOCKER_HOST value> | context:<what `docker context inspect` prints, or fail>
  case "$1" in
    context:*) unset DOCKER_HOST; printf '%s' "${1#context:}" > "$STUB_CONTEXT" ;;
    *) DOCKER_HOST="$1"; export DOCKER_HOST ;;
  esac
}
printf '%s' "unix://$SOCKDIR/missing.sock" > "$STUB_CONTEXT"
use_endpoint "unix://$SOCKDIR/missing.sock"

CRED="$KIT/scripts/sanitizer-core-registry-credentials.sh"
ENV="$KIT/customer.env"
DSN="$KIT/.secrets/sanitizer-core/registry-dsn"
# The fixture kit directory is `released-kit`: Compose's project name.
VOL="released-kit_pg-sanitizer-core-data"
PAIR_RE='^(DSA_SANITIZER_CORE_REGISTRY_KEY|POSTGRES_SANITIZER_CORE_PASSWORD)='
pair() { grep -E "$PAIR_RE" "$1" || true; }
mode_of() {
  case "$(uname -s)" in Darwin|*BSD) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}
drop_pair() { grep -vE "$PAIR_RE" "$ENV" > "$ENV.next"; chmod 0600 "$ENV.next"; mv "$ENV.next" "$ENV"; }
run() { # <name> <cmd...> — rc in RC, output in $TMPDIR/<name>.{out,err}
  local name="$1"; shift
  RC=0
  "$@" > "$TMPDIR/$name.out" 2> "$TMPDIR/$name.err" || RC=$?
}

echo "1. kit 2.0 install, no registry volume yet"
echo up > "$STUB_DAEMON"
printf 'other_pg-sanitizer-core-data\nreleased-kit_pg-sanitizer-core-data-old\n' > "$STUB_VOLUMES"
run init-2-0 "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$ENV" --skip-doctor
check "init writes a 2.0 customer.env (rc $RC; volumes of other names do not count)" '[ "$RC" -eq 0 ] && [ -f "$ENV" ]'
ORIG="$(pair "$ENV")"
check "the 2.0 env holds one registry key and one registry DB password" '[ "$(printf "%s\n" "$ORIG" | grep -c .)" -eq 2 ]'
KEYVAL="$(sed -n 's/^DSA_SANITIZER_CORE_REGISTRY_KEY=//p' "$ENV")"
PWVAL="$(sed -n 's/^POSTGRES_SANITIZER_CORE_PASSWORD=//p' "$ENV")"
ORIG_DSN="$(cat "$DSN")"
check "init wrote the registry DSN file" '[ -n "$ORIG_DSN" ]'

echo "2. the stack ran: Compose created the registry volume"
printf 'other_pg-sanitizer-core-data\n%s\n' "$VOL" > "$STUB_VOLUMES"

echo "3. rollback step 2: save the 2.0 credentials (2.0 kit files still in place)"
run save bash "$CRED" save --env-file "$ENV"
SAVED="$(cat "$TMPDIR/save.out")"
SAVED_DIR="$(dirname "$SAVED")"
check "save succeeds and prints the saved credentials file (rc $RC)" '[ "$RC" -eq 0 ] && [ -f "$SAVED" ]'
check "the saved folder is backups/sanitizer-core-<time>/ beside customer.env" 'case "$SAVED_DIR" in "$KIT"/backups/sanitizer-core-*) true ;; *) false ;; esac'
check "the saved folder is mode 0700" '[ "$(mode_of "$SAVED_DIR")" = 700 ]'
ALL600=1
for f in "$SAVED_DIR"/*; do [ "$(mode_of "$f")" = 600 ] || ALL600=0; done
check "every saved file is mode 0600" '[ "$ALL600" -eq 1 ]'
check "the saved credentials file holds exactly the two 2.0 lines" '[ "$(cat "$SAVED")" = "$ORIG" ]'
check "the 2.0 customer.env is saved byte for byte" 'cmp -s "$ENV" "$SAVED_DIR/customer.env"'
check "the registry DSN file is saved byte for byte" 'cmp -s "$DSN" "$SAVED_DIR/registry-dsn"'
check "both sidecar files are saved" '[ -f "$SAVED_DIR/customer.env.runtime-profile.yaml" ] && [ -f "$SAVED_DIR/customer.env.image-manifest.yaml" ]'
check "the saved folder is git-ignored (backups/)" 'grep -qx "backups/" "$KIT/.gitignore"'
check "save writes an ignore-all .gitignore into the saved folder and into backups/" \
  'grep -qx "[*]" "$SAVED_DIR/.gitignore" && grep -qx "[*]" "$KIT/backups/.gitignore"'
# Rollback step 3 puts the 1.9.7 kit files back; that tree's .gitignore has no
# backups/ rule. The untracked ignore files stay and keep every copy (the DSN
# file holds the database password) out of `git add`.
cp -p "$KIT/.gitignore" "$TMPDIR/gitignore.2-0"
grep -vx 'backups/' "$TMPDIR/gitignore.2-0" > "$KIT/.gitignore"
GIT_STATUS="$(cd "$KIT" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q . \
  && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git status --porcelain --untracked-files=all --ignored=no 2>&1)"
check "after a checkout without the backups/ rule, git lists no saved file (git add cannot pick one up)" \
  '! printf "%s\n" "$GIT_STATUS" | grep -q "backups/" && printf "%s\n" "$GIT_STATUS" | grep -q "docker-compose.customer.yml"'
rm -rf "$KIT/.git"
cp -p "$TMPDIR/gitignore.2-0" "$KIT/.gitignore"

echo "4. rollback steps 3-4: the 1.9.7 customer.env (no registry credentials) comes back"
drop_pair
check "the restored env holds neither credential" '[ -z "$(pair "$ENV")" ]'

echo "5. re-upgrade step 4 without the saved file: refused"
cp -p "$ENV" "$TMPDIR/env.before"
run add-refused bash "$CRED" add --env-file "$ENV"
check "add refuses to generate new credentials while the volume exists (rc $RC, want 3)" '[ "$RC" -eq 3 ]'
check "the refusal names the volume" 'grep -Fq "$VOL" "$TMPDIR/add-refused.err"'
check "the refusal names the saved file to restore, with --from" 'grep -Fq -- "--from '"'"'$SAVED'"'"'" "$TMPDIR/add-refused.err"'
check "nothing was appended to customer.env" 'cmp -s "$TMPDIR/env.before" "$ENV"'

echo "6. re-upgrade step 4 with the saved file: the same two values come back"
run add-from bash "$CRED" add --env-file "$ENV" --from "$SAVED"
check "add --from restores (rc $RC)" '[ "$RC" -eq 0 ]'
check "customer.env holds the ORIGINAL registry key and password again" '[ "$(pair "$ENV")" = "$ORIG" ]'
cp -p "$ENV" "$TMPDIR/env.restored"
run add-again bash "$CRED" add --env-file "$ENV" --from "$SAVED"
check "a second add --from changes nothing (rc $RC)" '[ "$RC" -eq 0 ] && cmp -s "$TMPDIR/env.restored" "$ENV"'

echo "7. re-upgrade step 5: the DSN file carries the password the volume was created with"
rm -f "$DSN"
run dsn bash "$KIT/scripts/write-sanitizer-core-registry-dsn.sh" --env-file "$ENV"
check "the DSN writer succeeds on the restored env (rc $RC)" '[ "$RC" -eq 0 ]'
check "the rewritten DSN equals the 2.0 DSN (the registry login still works)" '[ "$(cat "$DSN")" = "$ORIG_DSN" ]'

echo "8. bin/lucairn-init refuses a fresh customer.env while the volume exists"
mkdir "$TMPDIR/aside"
mv "$ENV" "$ENV.runtime-profile.yaml" "$ENV.image-manifest.yaml" "$TMPDIR/aside/"
run init-refused "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$ENV" --skip-doctor
check "init exits 8 (rc $RC)" '[ "$RC" -eq 8 ]'
check "init names the volume" 'grep -Fq "$VOL" "$TMPDIR/init-refused.err"'
check "init names the folder holding the saved 2.0 customer.env" 'grep -Fq "$SAVED_DIR" "$TMPDIR/init-refused.err"'
check "init wrote nothing" '[ ! -e "$ENV" ] && [ ! -e "$ENV.runtime-profile.yaml" ] && [ ! -e "$ENV.image-manifest.yaml" ]'
mv "$TMPDIR/aside"/customer.env* "$KIT/"

echo "9. no Docker daemon: add and init generate nothing (fail closed)"
echo down > "$STUB_DAEMON"
drop_pair
cp -p "$ENV" "$TMPDIR/env.before"
run add-nodaemon bash "$CRED" add --env-file "$ENV"
check "add refuses when Docker cannot be asked (rc $RC, want 5: its own code)" '[ "$RC" -eq 5 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
check "the refusal says why (daemon not reachable)" 'grep -Fq "the Docker daemon is not reachable" "$TMPDIR/add-nodaemon.err"'
run check-nodaemon bash "$CRED" check --env-file "$ENV"
check "check exits 5 when Docker cannot be asked, apart from 4 (a name not resolved) (rc $RC)" '[ "$RC" -eq 5 ]'
OTHER="$KIT/other.env"
other_absent() { [ ! -e "$OTHER" ] && [ ! -e "$OTHER.runtime-profile.yaml" ] && [ ! -e "$OTHER.image-manifest.yaml" ] && [ ! -e "$KIT/.secrets/sanitizer-core/other.env.registry-dsn" ]; }
run init-nodaemon "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor
check "init without a daemon REFUSES to mint registry credentials (rc $RC, want 8)" '[ "$RC" -eq 8 ]'
check "init without a daemon wrote nothing" 'other_absent'
check "the refusal says why and names both ways out (start Docker, or --confirm-no-registry-volume)" \
  'grep -Fq "the Docker daemon is not reachable" "$TMPDIR/init-nodaemon.err" && grep -Fq "Start Docker" "$TMPDIR/init-nodaemon.err" && grep -Fq -- "--confirm-no-registry-volume" "$TMPDIR/init-nodaemon.err"'
run init-confirmed "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init without a daemon but with --confirm-no-registry-volume writes the env (rc $RC) with a note" \
  '[ "$RC" -eq 0 ] && [ -f "$OTHER" ] && grep -Fq "could not check for an existing sanitizer core registry volume" "$TMPDIR/init-confirmed.err" && grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-confirmed.err"'
rm -f "$OTHER" "$OTHER.runtime-profile.yaml" "$OTHER.image-manifest.yaml" "$KIT/.secrets/sanitizer-core/other.env.registry-dsn"
echo up > "$STUB_DAEMON"
run init-confirmed-vol "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "a volume the daemon reports is refused even with --confirm-no-registry-volume (rc $RC, want 8)" \
  '[ "$RC" -eq 8 ] && grep -Fq "$VOL" "$TMPDIR/init-confirmed-vol.err" && other_absent'
# Fix round 4 (review P2 on PR #162): the base project resolves to a volume the
# daemon lists, but the ServiceNow overlay render fails. The known match wins:
# refused (3 / init 8), never "cannot tell" that the flag would override.
cp -p "$KIT/docker-compose.servicenow-control.yml" "$TMPDIR/sn.orig"
printf 'services: [\n' > "$KIT/docker-compose.servicenow-control.yml"
run check-vol-snfail bash "$CRED" check --env-file "$ENV"
check "a listed base volume is refused although the ServiceNow overlay does not render (rc $RC, want 3)" \
  '[ "$RC" -eq 3 ] && grep -Fq "($VOL)" "$TMPDIR/check-vol-snfail.err"'
run init-vol-snfail "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init with --confirm-no-registry-volume refuses a listed base volume when the ServiceNow render fails (rc $RC, want 8)" \
  '[ "$RC" -eq 8 ] && grep -Fq "$VOL" "$TMPDIR/init-vol-snfail.err" && ! grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-vol-snfail.err" && other_absent'
printf 'other_pg-sanitizer-core-data\n' > "$STUB_VOLUMES"
run check-snfail bash "$CRED" check --env-file "$ENV"
check "no listed volume and the ServiceNow overlay does not render: 'cannot tell' (rc $RC, want 4, not 5)" '[ "$RC" -eq 4 ]'
run init-snfail "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init with --confirm-no-registry-volume refuses when a render fails (rc $RC, want 8; the flag covers only Docker unreachable)" \
  '[ "$RC" -eq 8 ] && grep -Fq -- "--confirm-no-registry-volume does not apply" "$TMPDIR/init-snfail.err" && ! grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-snfail.err" && other_absent'
cp -p "$TMPDIR/sn.orig" "$KIT/docker-compose.servicenow-control.yml"
printf 'other_pg-sanitizer-core-data\n%s\n' "$VOL" > "$STUB_VOLUMES"
check "init --help documents --confirm-no-registry-volume" '"$KIT/bin/lucairn-init" --help | grep -Fq -- "--confirm-no-registry-volume"'

echo "10. no registry volume: add generates a new pair"
echo up > "$STUB_DAEMON"
printf 'released-kit_pg-sanitizer-core-data-old\n' > "$STUB_VOLUMES"
run check-none bash "$CRED" check --env-file "$ENV"
check "check exits 0 without the volume (rc $RC)" '[ "$RC" -eq 0 ]'
run add-new bash "$CRED" add --env-file "$ENV"
NEW="$(pair "$ENV")"
check "add generates the pair (rc $RC)" '[ "$RC" -eq 0 ] && [ "$(printf "%s\n" "$NEW" | grep -c .)" -eq 2 ]'
check "the new key is 64 hex and the password 48 hex" 'grep -Eqx "DSA_SANITIZER_CORE_REGISTRY_KEY=[0-9a-f]{64}" "$ENV" && grep -Eqx "POSTGRES_SANITIZER_CORE_PASSWORD=[0-9a-f]{48}" "$ENV"'
check "the new pair differs from the saved one" '[ "$NEW" != "$ORIG" ]'

echo "11. --from refusals"
printf '%s\n' "$VOL" > "$STUB_VOLUMES"
run add-conflict bash "$CRED" add --env-file "$ENV" --from "$SAVED"
check "add --from refuses when customer.env already holds a different pair (rc $RC)" '[ "$RC" -eq 2 ] && [ "$(pair "$ENV")" = "$NEW" ]'
drop_pair
cp "$SAVED" "$TMPDIR/open.env"; chmod 0644 "$TMPDIR/open.env"
run add-open bash "$CRED" add --env-file "$ENV" --from "$TMPDIR/open.env"
check "a saved file readable by others is refused (rc $RC)" '[ "$RC" -eq 2 ] && [ -z "$(pair "$ENV")" ]'
{ cat "$SAVED"; echo 'GATEWAY_BASE_URL=http://elsewhere'; } > "$TMPDIR/extra.env"; chmod 0600 "$TMPDIR/extra.env"
run add-extra bash "$CRED" add --env-file "$ENV" --from "$TMPDIR/extra.env"
check "a saved file with another line is refused (rc $RC)" '[ "$RC" -eq 2 ] && [ -z "$(pair "$ENV")" ]'
grep -v '^POSTGRES_SANITIZER_CORE_PASSWORD=' "$SAVED" > "$TMPDIR/half.env"; chmod 0600 "$TMPDIR/half.env"
run add-half bash "$CRED" add --env-file "$ENV" --from "$TMPDIR/half.env"
check "a saved file missing the password is refused (rc $RC)" '[ "$RC" -eq 2 ] && [ -z "$(pair "$ENV")" ]'
printf 'DSA_SANITIZER_CORE_REGISTRY_KEY=%s\n' "$KEYVAL" >> "$ENV"
run add-one bash "$CRED" add --env-file "$ENV"
check "an env holding only one of the two is refused (rc $RC)" '[ "$RC" -eq 2 ]'

echo "11b. the volume name comes from the rendered project (a custom name:)"
drop_pair
CUSTOM="lucairn-registry-custom"
cp -p "$KIT/docker-compose.customer.yml" "$TMPDIR/compose.orig"
awk -v n="$CUSTOM" '{ print } /^  pg-sanitizer-core-data:$/ { print "    name: " n }' "$TMPDIR/compose.orig" > "$KIT/docker-compose.customer.yml"
check "fixture: the registry volume has a custom name" 'grep -Fqx "    name: $CUSTOM" "$KIT/docker-compose.customer.yml"'
printf '%s\n' "$VOL" > "$STUB_VOLUMES"
run check-default-gone bash "$CRED" check --env-file "$ENV"
check "a volume of the DEFAULT name no longer counts once the project names another (rc $RC, want 0)" '[ "$RC" -eq 0 ]'
printf 'other_pg-sanitizer-core-data\n%s\n' "$CUSTOM" > "$STUB_VOLUMES"
run check-custom bash "$CRED" check --env-file "$ENV"
check "check finds the custom-named registry volume (rc $RC, want 3)" '[ "$RC" -eq 3 ] && grep -Fq "($CUSTOM)" "$TMPDIR/check-custom.err" && grep -Fq "docker volume rm $CUSTOM" "$TMPDIR/check-custom.err"'
cp -p "$ENV" "$TMPDIR/env.before"
run add-custom bash "$CRED" add --env-file "$ENV"
check "add refuses new credentials against the custom-named volume (rc $RC, want 3)" '[ "$RC" -eq 3 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
mv "$ENV" "$ENV.runtime-profile.yaml" "$ENV.image-manifest.yaml" "$TMPDIR/aside/"
run init-custom "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$ENV" --skip-doctor --confirm-no-registry-volume
check "init refuses a fresh env against the custom-named volume (rc $RC, want 8)" '[ "$RC" -eq 8 ] && grep -Fq "$CUSTOM" "$TMPDIR/init-custom.err" && [ ! -e "$ENV" ]'
mv "$TMPDIR/aside"/customer.env* "$KIT/"
# A name Compose cannot resolve for this env (a ${...} it does not hold, and the
# env lacks the registry secrets, so only the uninterpolated project renders).
awk '{ print } /^  pg-sanitizer-core-data:$/ { print "    name: \"${LUCAIRN_TEST_REGISTRY_VOLUME}\"" }' "$TMPDIR/compose.orig" > "$KIT/docker-compose.customer.yml"
printf '\n' > "$STUB_VOLUMES"
run check-unresolved bash "$CRED" check --env-file "$ENV"
check "a volume name that cannot be resolved is 'cannot tell' (rc $RC, want 4), never the default" '[ "$RC" -eq 4 ] && grep -Fq "not resolved" "$TMPDIR/check-unresolved.err"'
run add-unresolved bash "$CRED" add --env-file "$ENV"
check "add generates nothing when the name cannot be resolved (rc $RC, want 4)" '[ "$RC" -eq 4 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
run init-unresolved "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init with --confirm-no-registry-volume refuses a volume name that cannot be resolved (rc $RC, want 8)" \
  '[ "$RC" -eq 8 ] && grep -Fq "not resolved" "$TMPDIR/init-unresolved.err" && grep -Fq -- "--confirm-no-registry-volume does not apply" "$TMPDIR/init-unresolved.err" && ! grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-unresolved.err" && other_absent'
printf 'services: [\n' > "$KIT/docker-compose.customer.yml"
run check-norender bash "$CRED" check --env-file "$ENV"
check "a project Compose cannot render is 'cannot tell' (rc $RC, want 4)" '[ "$RC" -eq 4 ]'
cp -p "$TMPDIR/compose.orig" "$KIT/docker-compose.customer.yml"

# Final check on PR #162 (T-1441): (1) only a daemon that cannot be reached is
# "Docker unreachable" (exit 5, the one case --confirm-no-registry-volume
# covers); a daemon that answers but fails the volume query is refused (exit
# 6), with or without the flag. (2) A long volume list keeps every match: the
# old `printf | grep -q` under pipefail dropped one (grep exits at the match,
# printf gets SIGPIPE, the pipeline is false) once the list outgrew the pipe.
echo "11c. a daemon that answers but fails the query; a long volume list"
clear_other() { rm -f "$OTHER" "$OTHER.runtime-profile.yaml" "$OTHER.image-manifest.yaml" "$KIT/.secrets/sanitizer-core/other.env.registry-dsn"; }
cp -p "$ENV" "$TMPDIR/env.before"
printf '%s\n' "$VOL" > "$STUB_VOLUMES"
echo qerr > "$STUB_DAEMON"
run check-qerr bash "$CRED" check --env-file "$ENV"
check "a reachable daemon whose volume list fails is not 'Docker unreachable' (rc $RC, want 6)" \
  '[ "$RC" -eq 6 ] && grep -Fq "the Docker daemon answered but did not list its volumes" "$TMPDIR/check-qerr.err"'
run add-qerr bash "$CRED" add --env-file "$ENV"
check "add generates nothing when a reachable daemon fails the volume query (rc $RC, want 6)" '[ "$RC" -eq 6 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
cp -p "$TMPDIR/env.before" "$ENV"
run init-qerr "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init with --confirm-no-registry-volume refuses when a reachable daemon fails the volume query (rc $RC, want 8)" \
  '[ "$RC" -eq 8 ] && grep -Fq -- "--confirm-no-registry-volume does not apply" "$TMPDIR/init-qerr.err" && ! grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-qerr.err" && other_absent'
clear_other
run init-qerr-plain "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor
check "init without the flag refuses when a reachable daemon fails the volume query (rc $RC, want 8)" '[ "$RC" -eq 8 ] && other_absent'
clear_other
echo deny > "$STUB_DAEMON"
use_endpoint "unix://$SOCKDIR/accept.sock"
run check-deny bash "$CRED" check --env-file "$ENV"
check "a daemon that answers even its version with an error response is reachable (rc $RC, want 6)" '[ "$RC" -eq 6 ]'
run init-deny "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init with --confirm-no-registry-volume refuses a daemon that answers with error responses (rc $RC, want 8)" '[ "$RC" -eq 8 ] && other_absent'
clear_other
use_endpoint "unix://$SOCKDIR/missing.sock"
echo down > "$STUB_DAEMON"
run check-down bash "$CRED" check --env-file "$ENV"
check "a daemon that cannot be reached is still 'Docker unreachable' (rc $RC, want 5)" '[ "$RC" -eq 5 ] && grep -Fq "the Docker daemon is not reachable" "$TMPDIR/check-down.err"'
run init-down-confirmed "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init with --confirm-no-registry-volume still proceeds when the daemon cannot be reached (rc $RC, the documented case)" \
  '[ "$RC" -eq 0 ] && [ -f "$OTHER" ] && grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-down-confirmed.err"'
clear_other
echo up > "$STUB_DAEMON"
awk -v v="$VOL" 'BEGIN { print v; for (i = 0; i < 20000; i++) printf "unrelated-volume-%05d\n", i }' > "$STUB_VOLUMES"
check "fixture: 20,001 volume names, the registry volume first" \
  '[ "$(wc -l < "$STUB_VOLUMES" | tr -d " ")" -eq 20001 ] && [ "$(head -1 "$STUB_VOLUMES")" = "$VOL" ]'
run check-long bash "$CRED" check --env-file "$ENV"
check "check finds the registry volume first in a list of 20,001 (rc $RC, want 3)" '[ "$RC" -eq 3 ] && grep -Fq "($VOL)" "$TMPDIR/check-long.err"'
run add-long bash "$CRED" add --env-file "$ENV"
check "add refuses against the registry volume first in a list of 20,001 (rc $RC, want 3)" '[ "$RC" -eq 3 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
cp -p "$TMPDIR/env.before" "$ENV"
run init-long "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor
check "init refuses against the registry volume first in a list of 20,001 (rc $RC, want 8)" '[ "$RC" -eq 8 ] && grep -Fq "$VOL" "$TMPDIR/init-long.err" && other_absent'
clear_other
run init-long-confirmed "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "init with --confirm-no-registry-volume refuses against it too (rc $RC, want 8)" '[ "$RC" -eq 8 ] && grep -Fq "$VOL" "$TMPDIR/init-long-confirmed.err" && other_absent'
clear_other
awk -v v="$VOL" 'BEGIN { for (i = 0; i < 20000; i++) printf "unrelated-volume-%05d\n", i; print v }' > "$STUB_VOLUMES"
run check-long-last bash "$CRED" check --env-file "$ENV"
check "check finds the registry volume last in a list of 20,001 (rc $RC, want 3)" '[ "$RC" -eq 3 ]'
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "unrelated-volume-%05d\n", i }' > "$STUB_VOLUMES"
run check-long-none bash "$CRED" check --env-file "$ENV"
check "a list of 20,000 other names holds no registry volume (rc $RC, want 0)" '[ "$RC" -eq 0 ]'
# The same pipe race in the saved-file check: `grep -v | grep -q .` dropped
# the "another line" match once the other lines outgrew the pipe.
{ cat "$SAVED"; awk 'BEGIN { for (i = 0; i < 20000; i++) printf "EXTRA_SETTING_%05d=x\n", i }'; } > "$TMPDIR/long-extra.env"
chmod 0600 "$TMPDIR/long-extra.env"
cp -p "$TMPDIR/env.before" "$ENV"
run add-long-extra bash "$CRED" add --env-file "$ENV" --from "$TMPDIR/long-extra.env"
check "a saved file with 20,000 other lines is refused (rc $RC, want 2)" '[ "$RC" -eq 2 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
printf '%s\n' "$VOL" > "$STUB_VOLUMES"

# Fix round 1 on PR #163 (review P2): an empty HTTP 500 of a reachable daemon
# was "Docker unreachable". Fix round 2 on PR #163 (review P2): so was a
# CONNECT proxy answering 503 or 407 ("error during connect: … Service
# Unavailable"), because round 1 still classified docker CLI messages. No
# message is read any more: exit 5 (the one case --confirm-no-registry-volume
# covers) only with no docker CLI, or when the CLI's endpoint (DOCKER_HOST,
# else the current context) is a local unix socket that a raw connect finds
# missing (ENOENT) or refusing (ECONNREFUSED). Everything else is exit 6,
# which init refuses (8) with or without the flag.
echo "11d. 'no Docker here' only with a proof: no CLI, or a local socket that is missing or refuses"
printf '%s\n' "$VOL" > "$STUB_VOLUMES"
echo msg > "$STUB_DAEMON"
cp -p "$TMPDIR/env.before" "$ENV"
CASE=""
refused_case() { # <label> <endpoint> <docker CLI message>: exit 6, init with the flag refuses
  CASE="$1"
  use_endpoint "$2"
  printf '%s' "$3" > "$STUB_MSG"
  run "check-$CASE" bash "$CRED" check --env-file "$ENV"
  check "$CASE: check is 'cannot tell', not 'no Docker here' (rc $RC, want 6)" \
    '[ "$RC" -eq 6 ] && ! grep -Fq "the Docker daemon is not reachable" "$TMPDIR/check-$CASE.err"'
  clear_other
  run "init-$CASE" "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
  check "$CASE: init with --confirm-no-registry-volume refuses (rc $RC, want 8)" \
    '[ "$RC" -eq 8 ] && grep -Fq -- "--confirm-no-registry-volume does not apply" "$TMPDIR/init-$CASE.err" && ! grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-$CASE.err" && other_absent'
  clear_other
}
proceeds_case() { # <label> <endpoint> <docker CLI message>: exit 5, init with the flag proceeds
  CASE="$1"
  use_endpoint "$2"
  printf '%s' "$3" > "$STUB_MSG"
  run "check-$CASE" bash "$CRED" check --env-file "$ENV"
  check "$CASE: check is 'no Docker here' (rc $RC, want 5)" \
    '[ "$RC" -eq 5 ] && grep -Fq "the Docker daemon is not reachable" "$TMPDIR/check-$CASE.err"'
  clear_other
  run "init-$CASE" "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
  check "$CASE: init with --confirm-no-registry-volume proceeds (rc $RC, the documented case)" \
    '[ "$RC" -eq 0 ] && [ -f "$OTHER" ] && grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-$CASE.err"'
  clear_other
}
ACCEPT="unix://$SOCKDIR/accept.sock"
CANNOT='Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?'
# The review's case (round 2): a reachable CONNECT proxy in front of a remote
# daemon answers 503 / 407; the docker CLI wraps it as "error during connect".
refused_case proxy-503 tcp://docker.example.invalid:2376 'error during connect: Get "https://docker.example.invalid:2376/v1.51/version": Service Unavailable'
refused_case proxy-407 tcp://docker.example.invalid:2376 'error during connect: Get "https://docker.example.invalid:2376/v1.51/version": Proxy Authentication Required'
# Any remote endpoint whose daemon does not answer: no proof that it has no volume.
refused_case tcp-down tcp://127.0.0.1:2375 'Cannot connect to the Docker daemon at tcp://127.0.0.1:2375. Is the docker daemon running?'
refused_case tcp-dns tcp://docker.example.invalid:2375 'failed to connect to the docker API at tcp://docker.example.invalid:2375: lookup docker.example.invalid: no such host'
refused_case ssh-refused ssh://deploy@docker.example.invalid 'error during connect: Get "http://docker.example.invalid/v1.24/version": command [ssh -o ConnectTimeout=30 -T -- docker.example.invalid docker system dial-stdio] has exited with exit status 255, make sure the URL is valid, and Docker 18.09 or later is installed on the remote host: stderr=ssh: connect to host docker.example.invalid port 22: Connection refused'
refused_case npipe-missing npipe:////./pipe/docker_engine 'error during connect: this error may indicate that the docker daemon is not running: Get "http://%2F%2F.%2Fpipe%2Fdocker_engine/v1.24/version": open //./pipe/docker_engine: The system cannot find the file specified.'
refused_case context-tcp context:tcp://docker.example.invalid:2376 'Cannot connect to the Docker daemon at tcp://docker.example.invalid:2376. Is the docker daemon running?'
refused_case context-unreadable context:fail "$CANNOT"
refused_case unix-no-path unix:// "$CANNOT"
# A local socket that accepts the connection: something answers there, so a
# failed `docker version` proves nothing, whatever the CLI printed.
refused_case socket-accepts "$ACCEPT" "$CANNOT"
refused_case context-socket-accepts "context:$ACCEPT" "$CANNOT"
refused_case http500-empty "$ACCEPT" 'request returned 500 Internal Server Error for API route and version http://%2Fvar%2Frun%2Fdocker.sock/v1.51/version, check if the server supports the requested API version'
refused_case http500-empty-v24 "$ACCEPT" 'request returned Internal Server Error for API route and version http://%2Fvar%2Frun%2Fdocker.sock/v1.43/version, check if the server supports the requested API version'
refused_case unknown "$ACCEPT" 'stub: an error message no docker CLI version prints'
refused_case empty "$ACCEPT" ''
refused_case deadline "$ACCEPT" 'context deadline exceeded'
refused_case daemon-quotes "$ACCEPT" 'Error response from daemon: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?'
# A local socket this user may not open (root opens it: accepted, 6 as well).
refused_case perm-v24 "unix://$SOCKDIR/denied.sock" 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get "http://%2Fvar%2Frun%2Fdocker.sock/v1.24/version": dial unix /var/run/docker.sock: connect: permission denied'
refused_case perm-v29 "unix://$SOCKDIR/denied.sock" 'permission denied while trying to connect to the docker API at unix:///var/run/docker.sock'
refused_case perm-ssh ssh://deploy@docker.example.invalid 'error during connect: Get "http://docker.example.invalid/v1.24/version": command [ssh -o ConnectTimeout=30 -T -- docker.example.invalid docker system dial-stdio] has exited with exit status 255, make sure the URL is valid, and Docker 18.09 or later is installed on the remote host: stderr=deploy@docker.example.invalid: Permission denied (publickey).'
refused_case tls tcp://docker.example.invalid:2376 'error during connect: Get "https://docker.example.invalid:2376/v1.24/version": tls: failed to verify certificate: x509: certificate signed by unknown authority'
# Fix round 4 on PR #163 (review P2): the docker CLI normalises its endpoint
# (trims spaces, drops a doubled unix:// prefix), a raw probe of the string as
# written does not — 'unix://<accepting socket> ' reaches the daemon while the
# probe of the path ending in a space finds nothing (was exit 5). Only the
# exact unix:///<absolute path> counts, in DOCKER_HOST and in the context.
refused_case host-trailing-space "$ACCEPT " "$CANNOT"
check "host-trailing-space: check names the way out (unset DOCKER_HOST or set it exactly)" \
  'grep -Fq "unset DOCKER_HOST or set it to the exact local socket" "$TMPDIR/check-host-trailing-space.err"'
refused_case host-leading-space " $ACCEPT" "$CANNOT"
refused_case host-doubled-prefix "unix://$ACCEPT" "$CANNOT"
refused_case host-relative-path "unix://lucairn-no-such-dir/missing.sock" "$CANNOT"
refused_case host-upper-case "UNIX://$SOCKDIR/missing.sock" "$CANNOT"
refused_case context-trailing-space "context:$ACCEPT " "$CANNOT"
check "context-trailing-space: check says the context endpoint is not exact" \
  'grep -Fq "current docker context'"'"'s endpoint is not exactly unix:///" "$TMPDIR/check-context-trailing-space.err"'
refused_case context-doubled-prefix "context:unix://$ACCEPT" "$CANNOT"
# Kit 2.0.0 version-bump PR (owner 5 Nov "Merge, allowlist in bump PR", after
# the round-4 final check on PR #163: a Unicode no-break space after the path
# passed the white-space test under LC_ALL=C, the docker CLI trims it, so the
# CLI reached the accepting socket while the probe of the longer path found
# nothing = exit 5). The endpoint now counts only when it is ASCII
# ^unix:///[A-Za-z0-9._/-]+$ with no `..` segment, whatever the caller's
# locale: every case below runs under LC_ALL=C and under a UTF-8 locale.
NBSP=$'\xc2\xa0'        # U+00A0 NO-BREAK SPACE (the review's case)
NNBSP=$'\xe2\x80\xaf'   # U+202F NARROW NO-BREAK SPACE
EMSP=$'\xe2\x80\x83'    # U+2003 EM SPACE
IDSP=$'\xe3\x80\x80'    # U+3000 IDEOGRAPHIC SPACE
NEL=$'\xc2\x85'         # U+0085 NEXT LINE
ZWSP=$'\xe2\x80\x8b'    # U+200B ZERO WIDTH SPACE
EACUTE=$'\xc3\xa9'      # U+00E9 (a letter, but not ASCII)
_LOCALES_HERE="$(locale -a 2>/dev/null || true)"
UTF8_LOCALE=""
for _l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if grep -qx "$_l" <<<"$_LOCALES_HERE"; then UTF8_LOCALE="$_l"; break; fi
done
[ -n "$UTF8_LOCALE" ] || echo "  NOTE  no UTF-8 locale on this host: the allowlist cases run under LC_ALL=C only (NON-COVERAGE: UTF-8 leg)"
_HAD_LC_ALL="${LC_ALL+set}" _ORIG_LC_ALL="${LC_ALL-}"
for _loc in C $UTF8_LOCALE; do
  export LC_ALL="$_loc"
  refused_case "host-nbsp-after-path-$_loc" "$ACCEPT$NBSP" "$CANNOT"
  refused_case "host-nbsp-before-prefix-$_loc" "${NBSP}$ACCEPT" "$CANNOT"
  refused_case "host-nbsp-in-path-$_loc" "unix://$SOCKDIR/missing${NBSP}.sock" "$CANNOT"
  refused_case "host-narrow-nbsp-after-path-$_loc" "$ACCEPT$NNBSP" "$CANNOT"
  refused_case "host-em-space-after-path-$_loc" "$ACCEPT$EMSP" "$CANNOT"
  refused_case "host-ideographic-space-after-path-$_loc" "$ACCEPT$IDSP" "$CANNOT"
  refused_case "host-next-line-after-path-$_loc" "$ACCEPT$NEL" "$CANNOT"
  refused_case "host-zero-width-space-after-path-$_loc" "$ACCEPT$ZWSP" "$CANNOT"
  refused_case "host-non-ascii-letter-$_loc" "unix://$SOCKDIR/miss${EACUTE}ng.sock" "$CANNOT"
  refused_case "host-trailing-ascii-space-$_loc" "unix://$SOCKDIR/missing.sock " "$CANNOT"
  refused_case "host-doubled-prefix-missing-$_loc" "unix://unix://$SOCKDIR/missing.sock" "$CANNOT"
  refused_case "host-mixed-case-scheme-$_loc" "Unix://$SOCKDIR/missing.sock" "$CANNOT"
  refused_case "host-relative-dot-path-$_loc" "unix://./missing.sock" "$CANNOT"
  refused_case "host-dotdot-segment-$_loc" "unix://$SOCKDIR/../$(basename "$SOCKDIR")/missing.sock" "$CANNOT"
  refused_case "host-dotdot-last-segment-$_loc" "unix://$SOCKDIR/no-such-dir/.." "$CANNOT"
  refused_case "context-nbsp-after-path-$_loc" "context:$ACCEPT$NBSP" "$CANNOT"
  refused_case "context-em-space-after-path-$_loc" "context:$ACCEPT$EMSP" "$CANNOT"
  refused_case "context-dotdot-segment-$_loc" "context:unix://$SOCKDIR/../$(basename "$SOCKDIR")/missing.sock" "$CANNOT"
  refused_case "context-mixed-case-scheme-$_loc" "context:Unix://$SOCKDIR/missing.sock" "$CANNOT"
  # The documented cases still proceed under the same locale.
  proceeds_case "allowlist-socket-missing-$_loc" "unix://$SOCKDIR/missing.sock" "$CANNOT"
  proceeds_case "allowlist-socket-refuses-$_loc" "unix://$SOCKDIR/refuse.sock" "$CANNOT"
  proceeds_case "allowlist-context-socket-missing-$_loc" "context:unix://$SOCKDIR/missing.sock" "$CANNOT"
done
if [ -n "$_HAD_LC_ALL" ]; then export LC_ALL="$_ORIG_LC_ALL"; else unset LC_ALL; fi
check "host-nbsp-after-path: check names the allowed form" \
  'grep -Fq "unix:///<absolute socket path>" "$TMPDIR/check-host-nbsp-after-path-C.err"'
use_endpoint tcp://docker.example.invalid:2376
printf '%s' 'error during connect: Get "https://docker.example.invalid:2376/v1.51/version": Service Unavailable' > "$STUB_MSG"
run add-proxy-503 bash "$CRED" add --env-file "$ENV"
check "add generates nothing behind a proxy answering 503 (rc $RC, want 6)" '[ "$RC" -eq 6 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
cp -p "$TMPDIR/env.before" "$ENV"
clear_other
run init-proxy-503-plain "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor
check "init without the flag refuses behind a proxy answering 503 (rc $RC, want 8)" '[ "$RC" -eq 8 ] && other_absent'
clear_other
# No python3 to test the local socket: no proof either.
NOPY="$TMPDIR/no-python-bin"
mkdir "$NOPY"
for t in bash env dirname basename sed awk grep mktemp rm cat tr head tail uname stat chmod cp cmp date mkdir mv wc sort cut ls id ln rmdir touch; do
  if p="$(command -v "$t")" && [ -x "$p" ]; then ln -s "$p" "$NOPY/$t"; fi
done
ln -s "$TMPDIR/bin/docker" "$NOPY/docker"
check "fixture: the docker stub but no python3 on the restricted PATH" \
  '! env PATH="$NOPY" bash -c "command -v python3" >/dev/null 2>&1 && env PATH="$NOPY" bash -c "command -v docker" >/dev/null 2>&1'
use_endpoint "unix://$SOCKDIR/missing.sock"
printf '%s' "$CANNOT" > "$STUB_MSG"
run check-nopython env PATH="$NOPY" bash "$CRED" check --env-file "$ENV"
check "no python3: a missing local socket cannot be proven, check is 'cannot tell' (rc $RC, want 6)" \
  '[ "$RC" -eq 6 ] && grep -Fq "without python3" "$TMPDIR/check-nopython.err"'
# The documented case: the CLI's local socket is missing or refuses (Docker
# not installed as a daemon here, or stopped), with DOCKER_HOST or a context.
proceeds_case socket-missing "unix://$SOCKDIR/missing.sock" "$CANNOT"
proceeds_case socket-missing-v29 "unix://$SOCKDIR/missing.sock" "failed to connect to the docker API at unix://$SOCKDIR/missing.sock; check if the path is correct and if the daemon is running: dial unix $SOCKDIR/missing.sock: connect: no such file or directory"
proceeds_case socket-dir-missing "unix://$SOCKDIR/no-such-dir/docker.sock" "$CANNOT"
proceeds_case socket-dangling-link "unix://$SOCKDIR/dangling.sock" "$CANNOT"
proceeds_case socket-refuses "unix://$SOCKDIR/refuse.sock" "$CANNOT"
proceeds_case context-socket-missing "context:unix://$SOCKDIR/missing.sock" 'Cannot connect to the Docker daemon. Is the docker daemon running on this host?'
proceeds_case context-socket-refuses "context:unix://$SOCKDIR/refuse.sock" "$CANNOT"
# Whatever the CLI printed: the proof is the socket, not the message.
proceeds_case socket-missing-odd-message "unix://$SOCKDIR/missing.sock" 'stub: an error message no docker CLI version prints'
use_endpoint "unix://$SOCKDIR/missing.sock"
# No docker CLI on PATH at all: exit 5 as well.
NODOCKER="$TMPDIR/no-docker-bin"
mkdir "$NODOCKER"
for t in bash env dirname basename sed awk grep mktemp rm cat tr head tail uname stat chmod cp cmp date mkdir mv wc sort cut ls id ln rmdir touch sleep kill openssl; do
  if p="$(command -v "$t")" && [ -x "$p" ]; then ln -s "$p" "$NODOCKER/$t"; fi
done
check "fixture: no docker CLI on the restricted PATH" '! PATH="$NODOCKER" command -v docker >/dev/null 2>&1'
run check-nocli env PATH="$NODOCKER" bash "$CRED" check --env-file "$ENV"
check "no docker CLI: check is 'Docker unreachable' (rc $RC, want 5)" '[ "$RC" -eq 5 ] && grep -Fq "the docker CLI is not on PATH" "$TMPDIR/check-nocli.err"'
run add-nocli env PATH="$NODOCKER" bash "$CRED" add --env-file "$ENV"
check "no docker CLI: add generates nothing (rc $RC, want 5)" '[ "$RC" -eq 5 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
cp -p "$TMPDIR/env.before" "$ENV"
clear_other
run init-nocli env PATH="$NODOCKER" bash "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor
check "no docker CLI: init without the flag refuses (rc $RC, want 8) and names the flag" \
  '[ "$RC" -eq 8 ] && grep -Fq "the docker CLI is not on PATH" "$TMPDIR/init-nocli.err" && grep -Fq -- "--confirm-no-registry-volume" "$TMPDIR/init-nocli.err" && other_absent'
clear_other
run init-nocli-confirmed env PATH="$NODOCKER" bash "$KIT/bin/lucairn-init" --dev --runtime-mode managed-byok --output "$OTHER" --skip-doctor --confirm-no-registry-volume
check "no docker CLI: init with --confirm-no-registry-volume passes the registry check (rc $RC, the documented case)" \
  '[ "$RC" -ne 8 ] && grep -Fq -- "--confirm-no-registry-volume states" "$TMPDIR/init-nocli-confirmed.err"'
clear_other
echo up > "$STUB_DAEMON"

echo "12. the guide drives it"
ROLLBACK="$(awk '/^### Rollback to 1\.9\.7/{f=1;next} f&&/^## /{exit} f' "$DOCS_ROOT/INSTALL.md")"
SAVE_LINE="$(printf '%s\n' "$ROLLBACK" | grep -n 'sanitizer-core-registry-credentials.sh save --env-file customer.env' | head -1 | cut -d: -f1)"
CHECKOUT_LINE="$(printf '%s\n' "$ROLLBACK" | grep -n 'git checkout v1.9.7' | head -1 | cut -d: -f1)"
check "rollback saves the 2.0 credentials BEFORE the 1.9.7 kit files go back" '[ -n "$SAVE_LINE" ] && [ -n "$CHECKOUT_LINE" ] && [ "$SAVE_LINE" -lt "$CHECKOUT_LINE" ]'
STEP4="$(awk '/^4\. \*\*Add the kit 2\.0 settings/{f=1} f&&/^5\. /{exit} f' "$DOCS_ROOT/INSTALL.md")"
check "upgrade step 4 adds the pair with the script" 'printf "%s\n" "$STEP4" | grep -Fq "scripts/sanitizer-core-registry-credentials.sh add --env-file customer.env"'
check "upgrade step 4 restores with --from after a rollback" 'printf "%s\n" "$STEP4" | grep -Fq -- "--from backups/sanitizer-core-<time>/sanitizer-core-registry.env"'
check "upgrade step 4 no longer generates the pair by hand" '! printf "%s\n" "$STEP4" | grep -Eq "(DSA_SANITIZER_CORE_REGISTRY_KEY|POSTGRES_SANITIZER_CORE_PASSWORD)=\\\$\\(openssl"'

echo "13. no registry value in any output"
LEAK=0
for f in "$TMPDIR"/*.out "$TMPDIR"/*.err; do
  if grep -Fq "$KEYVAL" "$f" || grep -Fq "$PWVAL" "$f"; then LEAK=1; echo "    value in $(basename "$f")"; fi
done
check "neither the key nor the password is printed" '[ "$LEAK" -eq 0 ]'

echo
echo "registry credentials rollback: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
