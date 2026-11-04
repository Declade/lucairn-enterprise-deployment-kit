#!/usr/bin/env bash
# Kit 2.0 K-E fix round 1 (review P1 on PR #162; PRD
# prd-2026-11-02-kit-2-0-new-core.md row 4) and fix round 2 (init fails closed
# without a daemon; the volume name is the one the rendered project gives; the
# saved folder stays git-ignored after a checkout of 1.9.7): upgrade -> rollback -> re-upgrade
# must reuse the sanitizer core's registry credentials. The registry volume
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
export LUCAIRN_TEST_REAL_DOCKER STUB_DAEMON STUB_VOLUMES
mkdir "$TMPDIR/bin"
cat > "$TMPDIR/bin/docker" <<'STUB'
#!/bin/bash
# Compose renders (client side: `version` and `config`) go to the real CLI;
# the daemon is a stub. Any other Compose command would need a daemon.
if [ "${1:-}" = compose ]; then
  case " $* " in *" config "*|*" version"*) exec "$LUCAIRN_TEST_REAL_DOCKER" "$@" ;; esac
fi
if [ "${1:-}" = volume ] && [ "${2:-}" = ls ]; then
  [ "$(cat "$STUB_DAEMON")" = up ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
  cat "$STUB_VOLUMES"
  exit 0
fi
echo "unexpected docker call: $*" >&2
exit 97
STUB
chmod 0755 "$TMPDIR/bin/docker"
export PATH="$TMPDIR/bin:$PATH"

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
check "add refuses when it cannot check for the volume (rc $RC, want 4)" '[ "$RC" -eq 4 ] && cmp -s "$TMPDIR/env.before" "$ENV"'
check "the refusal says why (daemon not reachable)" 'grep -Fq "the Docker daemon is not reachable" "$TMPDIR/add-nodaemon.err"'
run check-nodaemon bash "$CRED" check --env-file "$ENV"
check "check exits 4 when it cannot tell (rc $RC)" '[ "$RC" -eq 4 ]'
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
printf 'services: [\n' > "$KIT/docker-compose.customer.yml"
run check-norender bash "$CRED" check --env-file "$ENV"
check "a project Compose cannot render is 'cannot tell' (rc $RC, want 4)" '[ "$RC" -eq 4 ]'
cp -p "$TMPDIR/compose.orig" "$KIT/docker-compose.customer.yml"

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
