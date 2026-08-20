#!/bin/sh
#
# migrate-capped.sh — Compose-path migration runner with a pinned version cap.
#
# Board T-350. This is the Compose twin of the Helm mechanism in
# charts/lucairn/templates/_migration-cap.tpl; the two must stay behaviourally
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
# 000012_witness_claim_receipts as soon as the mounted migrations directory
# carries them; both create tables holding un-redacted personal data for which
# this kit ships NO deletion path. Nothing in the compose file, the chart, or
# the release checklist was positioned to notice that happening.
#
# ── THE MECHANISM ─────────────────────────────────────────────────────────────
#
#   MIGRATE_TARGET_VERSION   the migration VERSION to stop at (not a count).
#                            Compose supplies the release's known-safe default;
#                            operators may lower it via customer.env.
#   MIGRATE_KNOWN_SAFE_MAX   the ceiling this kit release reviewed for
#                            personal-data retention impact. Hardcoded as a
#                            literal in docker-compose.customer.yml, NOT
#                            operator-settable: raising it is a code change
#                            gated by docs/RELEASING.md § "Migration review".
#   MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP
#                            the single escape hatch. "true" restores the old
#                            open-ended `migrate up` and bypasses the ceiling.
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
CEILING="${MIGRATE_KNOWN_SAFE_MAX:-}"
UNSAFE_ACK="${MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP:-false}"

fatal() {
  echo "[$LABEL] FATAL: $1 Applying NO migrations. See docs/RELEASING.md § \"Migration review\" (board T-350)." >&2
  exit "$2"
}

highest_on_disk="$(ls "$MIGRATE_PATH" 2>/dev/null | grep -E '^[0-9]{6}_.*\.up\.sql$' | cut -c1-6 | sort -n | tail -1 | sed 's/^0*//')"
[ -n "$highest_on_disk" ] || highest_on_disk=0

if [ "$UNSAFE_ACK" = "true" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  echo "!! [$LABEL] UNSAFE OVERRIDE ACTIVE" >&2
  echo "!! LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP=true" >&2
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

case "$CEILING" in
  ''|*[!0-9]*)
    fatal "MIGRATE_KNOWN_SAFE_MAX is not a positive integer (got '${CEILING}'). It is set as a literal by docker-compose.customer.yml; an install that has lost it cannot know which migrations this release reviewed." 91 ;;
esac

if [ "$TARGET" -gt "$CEILING" ]; then
  fatal "MIGRATE_TARGET_VERSION=${TARGET} exceeds this kit release's reviewed ceiling of ${CEILING}. Migrations above the ceiling have not been reviewed for personal-data retention impact and this kit ships no deletion path for the tables some of them create (the veil-witness 000011 certificate-persistence-outbox / 000012 claim-receipts class). If you have reviewed every migration yourself and accept the retention consequences, set LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP=true instead." 91
fi

# `migrate version` writes to stdout or stderr depending on build/verbosity and
# exits non-zero on a fresh database, so capture both streams and never let it
# trip `set -e`.
ver_out="$(migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" version 2>&1 || true)"
# Measured: on a URL-parse error `migrate version` echoes the DSN back verbatim,
# password and all (e.g. `parse "postgres://veil:SUPER SECRET PW@host:5432/db":
# net/url: invalid userinfo`). Every branch below quotes $ver_out into a log
# line, so scrub any `scheme://user:pass@` credential before it can be printed.
ver_out="$(printf '%s' "$ver_out" | sed 's#://[^@]*@#://***:***@#g')"

case "$ver_out" in
  *dirty*|*Dirty*|*DIRTY*)
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

echo "[$LABEL] Applying migrations ${current} -> ${TARGET} (capped; open-ended migration is disabled — T-350)."
exec migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" goto "$TARGET"
