#!/bin/sh
#
# audit-claim-delivery-retention.sh — retention sweep for the audit database's
# claim-delivery outbox (board T-1219, kit 1.9.6).
#
# ⚠ THIS FILE IS DUPLICATED, BYTE-FOR-BYTE, INTO
#     charts/lucairn/charts/audit/files/audit-claim-delivery-retention.sh
#   The Helm CronJob reads that copy with .Files.Get (a chart can only read files
#   inside its own directory); Compose mounts this one. Edit both together —
#   tests/test_audit_claim_delivery_retention.sh fails on any difference.
#
# ── WHAT IT DOES ──────────────────────────────────────────────────────────────
#
# Audit migration 000007 creates `audit_claim_deliveries`: one row per completed
# request, holding the request id, delivery bookkeeping, the output-scan summary
# (`output_scan_body`) and the signed claim bytes (`claim_raw`). The audit
# service only ever INSERTs and UPDATEs it. This sweep BLANKS the two payload
# columns on rows whose witness delivery finished long ago:
#
#   UPDATE audit_claim_deliveries
#      SET claim_raw = NULL, output_scan_body = NULL, updated_at = NOW()
#    WHERE delivery_state = 'DELIVERED'
#      AND delivered_at < now() - <retention days>
#      AND (claim_raw IS NOT NULL OR output_scan_body IS NOT NULL)
#
# run in batches (default 10,000 rows per statement, each its own transaction)
# under a statement timeout.
#
# ── WHY BLANK AND NOT DELETE ──────────────────────────────────────────────────
#
# The row itself must stay. The gateway can replay an already-delivered
# completion event from its in-memory spill buffer with NO maximum age (it is
# count-capped and drains only on the next audit call). The audit service
# inserts the outbox row with `INSERT … ON CONFLICT (event_id) DO NOTHING`; if
# the row were gone, the replay would create a fresh PENDING row and re-drive an
# old claim to the witness. With the row kept in state DELIVERED, a replay finds
# the conflict, does nothing, and emits nothing — and that path never reads the
# two blanked columns. What remains (event id, request id, state, counters,
# timestamps) is bookkeeping; the request id is also kept, forever, in the
# append-only `audit_events` table, so blanking adds no new retained data.
#
# ── WHAT IT NEVER TOUCHES ─────────────────────────────────────────────────────
#
#   * PENDING / DELIVERING rows (in flight).
#   * PARKED rows. An operator re-queue (PARKED -> PENDING) re-drives the claim
#     from these columns, and a blanked scan summary would produce a degraded
#     claim. PARKED rows older than the retention period are COUNTED and the run
#     line turns into a WARN so an operator investigates them (OPS.md).
#   * `audit_events` — the append-only audit trail stays complete.
#
# ── CONFIGURATION (environment) ───────────────────────────────────────────────
#
#   DATABASE_URL  required; the audit database as the migration role `dsa`
#                 (the runtime role audit_app may not update these columns).
#   LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED   exactly `true` (default)
#                 or `false`. Anything else is refused.
#   LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS      whole days >= 1, default
#                 30, at most 36500. 0, negatives and leading zeros are
#                 refused — to stop the sweep, set ENABLED=false.
#   LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_INTERVAL_SECONDS  0 (default) = run
#                 once and exit (Helm CronJob); > 0 = run, then sleep that long,
#                 forever (Compose service). `--once` as the first argument
#                 forces a single run regardless.
#   LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_BATCH_SIZE  rows per statement,
#                 1..100000, default 10000.
#
# ── LOGGING ───────────────────────────────────────────────────────────────────
#
# Every run prints exactly one result line: cutoff timestamp, retention, number
# of DELIVERED rows blanked, number of old PARKED rows left as they are. It never
# prints row contents, ids, or the connection string. psql errors are printed
# with any `user:password@` part of a URL masked.

set -eu

LOG_TAG="audit-claim-delivery-retention"

log() { printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_TAG" "$*"; }
err() { log "$*" >&2; }
fatal() { err "FATAL: $*"; exit 2; }

ENABLED="${LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED:-true}"
DAYS="${LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS:-30}"
INTERVAL="${LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_INTERVAL_SECONDS:-0}"
BATCH="${LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_BATCH_SIZE:-10000}"
# Safety stop: at most this many batches per run (10,000,000 rows at the default
# batch size). Anything left over is taken by the next run.
MAX_BATCHES=1000
# Retry delay after a failed run in loop mode, so a database blip does not skip
# a whole interval.
RETRY_SECONDS=300

ONCE=0
if [ "${1:-}" = "--once" ]; then
  ONCE=1
fi

case "$ENABLED" in
  true) ;;
  false)
    log "level=INFO disabled (LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false); nothing blanked"
    exit 0 ;;
  *) fatal "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED must be exactly true or false (got '${ENABLED}')" ;;
esac

# Whole days, >= 1, no leading zero, at most 36500 (length check first so the
# numeric comparison never sees an out-of-range number).
case "$DAYS" in
  ''|*[!0-9]*|0*) fatal "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS must be a whole number of days >= 1 without leading zeros (got '${DAYS}'). To stop the sweep set LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false." ;;
esac
[ "${#DAYS}" -le 5 ] && [ "$DAYS" -le 36500 ] \
  || fatal "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS must be at most 36500 (got '${DAYS}')"

case "$INTERVAL" in
  ''|*[!0-9]*) fatal "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_INTERVAL_SECONDS must be a whole number of seconds (got '${INTERVAL}')" ;;
esac
[ "${#INTERVAL}" -le 7 ] \
  || fatal "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_INTERVAL_SECONDS is out of range (got '${INTERVAL}')"

case "$BATCH" in
  ''|*[!0-9]*|0*) fatal "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_BATCH_SIZE must be a whole number >= 1 (got '${BATCH}')" ;;
esac
[ "${#BATCH}" -le 6 ] && [ "$BATCH" -le 100000 ] \
  || fatal "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_BATCH_SIZE must be at most 100000 (got '${BATCH}')"

[ -n "${DATABASE_URL:-}" ] || fatal "DATABASE_URL is not set"

command -v psql >/dev/null 2>&1 || fatal "psql not found in this image"

# Session settings for every statement: UTC timestamps in the log, bounded
# statement and lock waits, and a name that shows up in pg_stat_activity.
PGTZ=UTC
PGAPPNAME="$LOG_TAG"
PGCONNECT_TIMEOUT=10
PGOPTIONS="-c statement_timeout=300000 -c lock_timeout=10000"
export PGTZ PGAPPNAME PGCONNECT_TIMEOUT PGOPTIONS

scrub() {
  sed -e 's#://[^/@ ]*@#://***:***@#g' -e 's#password=[^ ]*#password=***#g'
}

# run_psql <psql args...> — SQL on stdin. Prints psql's stdout on success; on
# failure prints the (scrubbed) output to stderr and returns 1.
run_psql() {
  _out="$(psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DATABASE_URL" "$@" 2>&1)" || {
    printf '%s\n' "$_out" | scrub >&2
    return 1
  }
  printf '%s' "$_out"
}

is_count() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

sweep_once() {
  cutoff="$(run_psql -v days="$DAYS" <<'SQL'
SELECT CASE
         WHEN to_regclass('public.audit_claim_deliveries') IS NULL THEN 'absent'
         ELSE (now() - make_interval(days => :days))::text
       END;
SQL
)" || { err "level=ERROR could not read the cutoff (database unreachable or query failed)"; return 1; }

  if [ "$cutoff" = "absent" ]; then
    log "level=INFO table audit_claim_deliveries does not exist (audit schema below migration 000007); nothing to blank"
    return 0
  fi

  total=0
  batches=0
  capped=0
  while :; do
    n="$(run_psql -v cutoff="$cutoff" -v batch="$BATCH" <<'SQL'
WITH batch AS (
  SELECT event_id
    FROM audit_claim_deliveries
   WHERE delivery_state = 'DELIVERED'
     AND delivered_at < :'cutoff'::timestamptz
     AND (claim_raw IS NOT NULL OR output_scan_body IS NOT NULL)
   ORDER BY delivered_at
   LIMIT :batch
   FOR UPDATE SKIP LOCKED
), blanked AS (
  UPDATE audit_claim_deliveries d
     SET claim_raw = NULL,
         output_scan_body = NULL,
         updated_at = NOW()
    FROM batch
   WHERE d.event_id = batch.event_id
     AND d.delivery_state = 'DELIVERED'
  RETURNING 1
)
SELECT count(*) FROM blanked;
SQL
)" || { err "level=ERROR blanking batch failed after ${total} rows (cutoff=${cutoff})"; return 1; }
    is_count "$n" || { err "level=ERROR unexpected batch result (not a row count)"; return 1; }
    total=$((total + n))
    batches=$((batches + 1))
    [ "$n" -lt "$BATCH" ] && break
    if [ "$batches" -ge "$MAX_BATCHES" ]; then
      capped=1
      break
    fi
  done

  parked="$(run_psql -v cutoff="$cutoff" <<'SQL'
SELECT count(*)
  FROM audit_claim_deliveries
 WHERE delivery_state = 'PARKED'
   AND parked_at < :'cutoff'::timestamptz;
SQL
)" || { err "level=ERROR could not count old PARKED rows (cutoff=${cutoff})"; return 1; }
  is_count "$parked" || { err "level=ERROR unexpected PARKED count (not a row count)"; return 1; }

  level=INFO
  note=""
  if [ "$parked" -gt 0 ]; then
    level=WARN
    note=" note=PARKED_rows_older_than_retention_are_not_blanked_investigate_them(OPS.md)"
  fi
  if [ "$capped" -eq 1 ]; then
    level=WARN
    note="${note} note=batch_cap_reached_remainder_next_run"
  fi
  log "level=${level} cutoff=${cutoff} retention_days=${DAYS} delivered_blanked=${total} batches=${batches} parked_older_than_retention=${parked} untouched_states=PENDING,DELIVERING,PARKED${note}"
  return 0
}

if [ "$ONCE" -eq 1 ] || [ "$INTERVAL" -eq 0 ]; then
  sweep_once
  exit $?
fi

trap 'log "level=INFO stopping on signal"; exit 0' TERM INT
while :; do
  if sweep_once; then
    sleep "$INTERVAL" &
  else
    err "level=ERROR run failed; retrying in ${RETRY_SECONDS}s"
    sleep "$RETRY_SECONDS" &
  fi
  wait $! || true
done
