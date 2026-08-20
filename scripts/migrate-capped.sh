#!/bin/sh
#
# migrate-capped.sh — Compose-path migration runner with a pinned version cap.
#
# Board T-350. This is the Compose twin of the Helm mechanism in
# charts/lucairn/charts/<subchart>/templates/_migration-cap.tpl; the two must stay behaviourally
# identical (tests/test_migration_version_cap.sh pins both).
#
# ── THE DEFECT THIS CLOSES ────────────────────────────────────────────────────
#
# Every migrate-* service in docker-compose.customer.yml used to run:
#
#     migrate -path=/migrations/<tree> -database=... up
#
# `up` with no argument applies EVERY migration file it finds, with no ceiling.
# The veil-witness tree gains 000011_certificate_persistence_outbox and
# 000012_claim_receipts as soon as the mounted migrations directory
# carries them; both create tables holding un-redacted personal data for which
# this kit ships NO deletion path. Nothing in the compose file, the chart, or
# the release checklist was positioned to notice that happening.
#
# ── THE MECHANISM ─────────────────────────────────────────────────────────────
#
#   MIGRATE_TARGET_VERSION   the migration VERSION to stop at (not a count).
#                            Compose supplies the release's known-safe default;
#                            operators may lower it via customer.env.
#   MIGRATE_CEILING_KEY      which ceiling to read (VEIL_WITNESS / AUDIT /
#                            ID_BRIDGE / SANDBOX_A).
#   MIGRATE_CEILING_FILE     the shipped ceiling file, default
#                            /scripts/migration-ceilings.conf. The ceiling this
#                            kit release reviewed lives THERE, not in the
#                            environment — a Compose `environment:` value is
#                            overridable by an extra `-f` overlay or
#                            `docker compose run -e`, which made the cap a
#                            convention rather than a control. Raising it is a
#                            kit-release change gated by docs/RELEASING.md
#                            § "Migration review".
#   MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP
#                            the single escape hatch, PER SERVICE (compose maps
#                            LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP_<SERVICE>
#                            into it). "true" restores the old open-ended
#                            `migrate up` and bypasses the ceiling; anything
#                            other than "true"/"false" is refused, not ignored.
#
# ── FAIL-CLOSED ───────────────────────────────────────────────────────────────
#
# An unset, empty, zero, negative, non-numeric, or over-ceiling target applies
# NOTHING and exits non-zero. It never falls back to `up`. So does a dirty
# schema_migrations ledger and an unparseable `migrate version` output.
#
# ── NEVER MIGRATES DOWN ───────────────────────────────────────────────────────
#
# `migrate goto <V>` runs .down.sql files when the database is AHEAD of V —
# data loss on a site that already applied more migrations under an older kit.
# So the current version is read first and the script exits 0 without calling
# `goto` whenever current >= target. `goto` is only ever reached upward.

set -eu

LABEL="${MIGRATE_LABEL:-migrate}"
MIGRATE_PATH="${MIGRATE_PATH:?MIGRATE_PATH must be set (e.g. /migrations/veil-witness)}"
DATABASE_URL="${DATABASE_URL:?DATABASE_URL must be set}"
TARGET="${MIGRATE_TARGET_VERSION:-}"
CEILING_KEY="${MIGRATE_CEILING_KEY:?MIGRATE_CEILING_KEY must be set (e.g. VEIL_WITNESS)}"
CEILING_FILE="${MIGRATE_CEILING_FILE:-/scripts/migration-ceilings.conf}"

fatal() {
  echo "[$LABEL] FATAL: $1 Applying NO migrations. See docs/RELEASING.md § \"Migration review\" (board T-350)." >&2
  exit "$2"
}

# ── H2: moving the ceiling VALUE out of the environment was not enough ───────
# The environment still named WHICH file and WHICH key were authoritative, so
# `docker compose run -e MIGRATE_CEILING_FILE=/tmp/mine.conf` or
# `-e MIGRATE_CEILING_KEY=VEIL_WITNESS` on migrate-audit raised the effective
# cap — and the success line then reported the raised ceiling as authoritative.
# Both are proven bypasses, so both pointers are constrained here.
#
# 1. The file must live under /scripts/, i.e. it must be something the compose
#    file mounted. Redirecting it then requires editing the compose file, which
#    is a deliberate, reviewable act rather than a one-off `-e`.
# The ceiling file must sit BESIDE this script. In the container both are in
# /scripts/ (mounted read-only from the release); in the harness both are in the
# repo's scripts/. Anchoring to the runner's own directory rather than a literal
# /scripts/ keeps the rule identical in both, so the test path is the shipped
# path and not a special case.
case "$CEILING_FILE" in
  *..*) fatal "MIGRATE_CEILING_FILE=${CEILING_FILE} contains '..'." 91 ;;
esac
# Compare RESOLVED directories: $0 may be relative ("scripts/migrate-capped.sh")
# while the value is absolute, and a raw string compare would reject the very
# layout the kit ships.
_self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _self_dir=""
_ceil_dir="$(cd "$(dirname "$CEILING_FILE")" 2>/dev/null && pwd)" || _ceil_dir=""
if [ -z "$_self_dir" ] || [ -z "$_ceil_dir" ] || [ "$_ceil_dir" != "$_self_dir" ]; then
  fatal "MIGRATE_CEILING_FILE=${CEILING_FILE} is not beside this script (${_self_dir:-unresolved}). The ceiling must come from the file this kit mounted next to the runner, not an arbitrary path — otherwise the environment raises the cap just by pointing somewhere else." 91
fi

# 2. The key must match the migrations tree this job is actually applying.
#    /migrations/veil-witness => VEIL_WITNESS. Naming another service's key
#    borrowed its (higher) ceiling; now the two have to agree.
_tree="${MIGRATE_PATH##*/}"
EXPECTED_KEY="$(printf '%s' "$_tree" | tr '[:lower:]-' '[:upper:]_')"
if [ "$CEILING_KEY" != "$EXPECTED_KEY" ]; then
  fatal "MIGRATE_CEILING_KEY=${CEILING_KEY} does not match the migrations tree being applied (${MIGRATE_PATH} implies ${EXPECTED_KEY}). Borrowing another database's ceiling is how a low-ceiling service acquires a high one." 91
fi
UNSAFE_ACK="${MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP:-false}"

highest_on_disk="$(ls "$MIGRATE_PATH" 2>/dev/null | grep -E '^[0-9]{6}_.*\.up\.sql$' | cut -c1-6 | sort -n | tail -1 | sed 's/^0*//')"
[ -n "$highest_on_disk" ] || highest_on_disk=0

# A data-retention escape hatch must not have an ambiguous value. Helm refuses a
# non-boolean at render time; Compose refuses it here rather than silently
# treating `True` / `1` / `yes` as "off" and leaving the operator believing the
# hatch is open when it is not (or vice versa).
case "$UNSAFE_ACK" in
  true|false) ;;
  *) fatal "MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP must be exactly 'true' or 'false' (got '${UNSAFE_ACK}'). Set LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP_<SERVICE>=true in customer.env, lowercase, if that is what you mean." 95 ;;
esac

if [ "$UNSAFE_ACK" = "true" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "!! [$LABEL] UNSAFE OVERRIDE ACTIVE" >&2
  echo "!! LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP_<SERVICE>=true" >&2
  echo "!! Running OPEN-ENDED 'migrate up'. EVERY migration in the mounted" >&2
  echo "!! directory will be applied, including migrations this kit release" >&2
  echo "!! never reviewed for personal-data retention impact, and for some" >&2
  echo "!! of which this kit ships NO deletion path (board T-350)." >&2
  echo "!! Directory holds migrations up to version ${highest_on_disk}." >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  exec migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" up
fi

case "$TARGET" in
  ''|*[!0-9]*)
    fatal "MIGRATE_TARGET_VERSION is not a positive integer (got '${TARGET}'). It is a target VERSION (as in 'migrate goto N'), not a count, and there is deliberately no fallback to an open-ended 'migrate up'." 90 ;;
esac
[ "$TARGET" -ge 1 ] || fatal "MIGRATE_TARGET_VERSION must be >= 1 (got '${TARGET}')." 90

# ── The ceiling comes from a SHIPPED FILE, never from the environment ────────
# A Compose `environment:` value is overridable by a second `-f` overlay or by
# `docker compose run -e`. Reading the ceiling from there made it a convention,
# not a control: MIGRATE_KNOWN_SAFE_MAX=99 applied migrations 11 and 12 while
# this script still logged "capped". The authoritative value is now
# scripts/migration-ceilings.conf, mounted read-only beside the compose file and
# shipped as part of the kit release.
[ -f "$CEILING_FILE" ] || fatal "the release ceiling file ${CEILING_FILE} is missing. It ships with the kit and is mounted read-only by docker-compose.customer.yml; without it this script cannot know which migrations this release reviewed." 91

# Read one KEY=VALUE line. Deliberately NOT `. "$CEILING_FILE"` — sourcing a
# mounted file would execute whatever it contains inside a container holding the
# database DSN.
CEILING="$(grep -E "^CEILING_${CEILING_KEY}=[0-9]+$" "$CEILING_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"

case "$CEILING" in
  ''|*[!0-9]*)
    fatal "${CEILING_FILE} has no valid CEILING_${CEILING_KEY}=<integer> entry. Refusing to guess which migrations this release reviewed." 91 ;;
esac

# If the environment ALSO carries a ceiling, it is advisory only and must agree.
# A disagreement means someone tried to raise the cap the easy way.
if [ -n "${MIGRATE_KNOWN_SAFE_MAX:-}" ] && [ "${MIGRATE_KNOWN_SAFE_MAX}" != "$CEILING" ]; then
  fatal "MIGRATE_KNOWN_SAFE_MAX=${MIGRATE_KNOWN_SAFE_MAX} in the environment disagrees with CEILING_${CEILING_KEY}=${CEILING} in ${CEILING_FILE}. The FILE is authoritative; the environment cannot raise the cap. If you have reviewed the migrations yourself, use LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP_<SERVICE>=true instead — it is loud and it is recorded in the log." 91
fi

if [ "$TARGET" -gt "$CEILING" ]; then
  fatal "MIGRATE_TARGET_VERSION=${TARGET} exceeds this kit release's reviewed ceiling of ${CEILING} (CEILING_${CEILING_KEY} in ${CEILING_FILE}). Migrations above the ceiling have not been reviewed for personal-data retention impact and this kit ships no deletion path for the tables some of them create (the veil-witness 000011 certificate-persistence-outbox / 000012 claim-receipts class). If you have reviewed every migration yourself and accept the retention consequences, set LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP_<SERVICE>=true instead." 91
fi

# `migrate version` writes to stdout or stderr depending on build/verbosity and
# exits non-zero on a fresh database, so capture both streams and never let it
# trip `set -e`.
ver_out="$(migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" version 2>&1 || true)"
# Measured: on a URL-parse error `migrate version` echoes the DSN back verbatim,
# password and all (e.g. `parse "postgres://veil:SUPER SECRET PW@host:5432/db":
# net/url: invalid userinfo`). Every branch below quotes $ver_out into a log
# line, so scrub any `scheme://user:pass@` credential before it can be printed.
ver_out="$(printf '%s' "$ver_out" | sed 's#://[^/]*@#://***:***@#g')"

# Match the LEDGER STATE, not a substring — see the note in
# charts/lucairn/charts/veil-witness/templates/_migration-cap.tpl. golang-migrate
# echoes its own SQL on a query failure and that SQL contains the column name
# `dirty`, so `*dirty*` reported every permission/timeout error as a dirty ledger
# and recommended `migrate force`, which rewrites the ledger blind.
case "$ver_out" in
  *[0-9]" (dirty)"*|*[0-9]" (Dirty)"*|*[0-9]" (DIRTY)"*)
    fatal "schema_migrations is DIRTY ('${ver_out}'). A previous migration failed half-way; resolve it deliberately ('migrate force <version>') before re-running." 92 ;;
esac

current="$(printf '%s' "$ver_out" | tr -d '[:space:]')"
case "$current" in
  ''|*[!0-9]*)
    case "$ver_out" in
      *"no migration"*|*"No migration"*|*"nil version"*) current=0 ;;
      *) fatal "cannot determine the current schema version; 'migrate version' said: '${ver_out}'." 93 ;;
    esac ;;
  *)
    current="$(printf '%s' "$current" | sed 's/^0*//')"
    [ -n "$current" ] || current=0 ;;
esac

if [ "$highest_on_disk" -gt "$TARGET" ]; then
  echo "[$LABEL] NOTICE: the mounted migrations directory holds versions up to ${highest_on_disk}, but this kit release is capped at ${TARGET}. Versions above the cap will NOT be applied — that is deliberate (board T-350)." >&2
fi

if [ "$current" -ge "$TARGET" ]; then
  echo "[$LABEL] Schema is at version ${current}; cap is ${TARGET}. Nothing to apply. This job NEVER migrates down."
  exit 0
fi

if [ "$TARGET" -gt "$highest_on_disk" ]; then
  fatal "cap is ${TARGET} but the mounted migrations directory only reaches version ${highest_on_disk}. Compose file and migrations tree disagree — refusing to guess." 94
fi

echo "[$LABEL] Applying migrations ${current} -> ${TARGET}; ceiling ${CEILING} from ${CEILING_FILE} (CEILING_${CEILING_KEY}). Open-ended migration is disabled — T-350."
exec migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" goto "$TARGET"
