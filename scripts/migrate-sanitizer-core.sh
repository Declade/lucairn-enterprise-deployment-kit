#!/bin/sh
#
# migrate-sanitizer-core.sh — the explicit, capped registry-migration step for
# the new sanitizer core (kit 2.0, PRD prd-2026-11-02-kit-2-0-new-core.md K1).
#
# The core's registry database (postgres-sanitizer-core) is migrated as an
# OPERATOR STEP at install and at every upgrade, never on boot. The core image
# carries the same migrations embedded and can apply them itself with
# `serve --migrate`, but that flag is for local test databases only; on the
# hosted service the migrations ran as a listed window step (Marc, 20 Oct).
# This script is the kit's copy of that step:
#
#   docker compose -f docker-compose.customer.yml --env-file customer.env \
#     --profile sanitizer-core-migrate run --rm migrate-sanitizer-core
#
# Until it has run, the core refuses to start ("the registry has no attempt
# record (apply migration 0007)"), which is loud on purpose.
#
# ── WHAT IT APPLIES, AND HOW ─────────────────────────────────────────────────
#
# The files in migrations/sanitizer-core/ are byte-copies of the core's
# services/sanitizer-core/store/migrations/*.up.sql at the release commit
# (migrations/sanitizer-core/SOURCE names it; SHA256SUMS pins every file and
# is checked before anything runs). The ledger is the core's OWN ledger,
# registry_schema_migrations(name, at), written exactly as the core's
# PG.Migrate writes it (services/sanitizer-core/store/store.go): one row per
# file name, the advisory lock 7413001, everything in ONE transaction. So a
# kit-migrated database and a hosted one carry the same ledger, and a later
# core that runs its own Migrate against this database sees every file as
# applied.
#
# One difference from PG.Migrate, deliberately: the ledger INSERT has no
# ON CONFLICT clause. The pending set is read before the lock is taken, so a
# second runner that slipped in between makes this run's INSERT collide and the
# whole transaction roll back. A concurrent run fails closed; it never applies a
# body twice.
#
# ── THE CAP (same contract as scripts/migrate-capped.sh, board T-350) ────────
#
#   MIGRATE_TARGET_VERSION  the version to stop at (Compose default = the
#                           ceiling; operators may lower it).
#   MIGRATE_CEILING_KEY     must match the tree being applied (SANITIZER_CORE
#                           for /migrations/sanitizer-core).
#   MIGRATE_CEILING_FILE    must sit beside this script; the value comes from
#                           CEILING_SANITIZER_CORE in the shipped, read-only
#                           scripts/migration-ceilings.conf, never from the
#                           environment. Raising it is a kit-release change
#                           gated by docs/RELEASING.md § "Migration review".
#
# There is NO open-ended escape hatch here (unlike migrate-capped.sh): the core
# reads its registry with a fixed schema, so "apply whatever is on disk" has no
# legitimate use. It never migrates down and it never edits the ledger.
#
# Connection: discrete PGHOST/PGPORT/PGUSER/PGDATABASE + PGPASSWORD, never a
# URL (libpq quotes a malformed URL, password included, in its errors).
#
# Exit codes: 0 applied or nothing to do · 90 bad target · 91 ceiling problem ·
# 92 ledger inconsistent · 93 cannot read the ledger · 94 tree/target disagree ·
# 95 file checksum mismatch · 96 apply failed (rolled back).

set -eu

LABEL="${MIGRATE_LABEL:-migrate-sanitizer-core}"
MIGRATE_PATH="${MIGRATE_PATH:?MIGRATE_PATH must be set (e.g. /migrations/sanitizer-core)}"
TARGET="${MIGRATE_TARGET_VERSION:-}"
CEILING_KEY="${MIGRATE_CEILING_KEY:?MIGRATE_CEILING_KEY must be set (SANITIZER_CORE)}"
CEILING_FILE="${MIGRATE_CEILING_FILE:-/scripts/migration-ceilings.conf}"
PSQL="${PSQL:-psql}"

fatal() {
  echo "[$LABEL] FATAL: $1 Applying NO migrations. See docs/RELEASING.md § \"Migration review\"." >&2
  exit "$2"
}

need() { [ -n "$2" ] || fatal "$1 must be set (discrete libpq settings; never a connection URL)." 93; }
need PGHOST "${PGHOST:-}"
need PGUSER "${PGUSER:-}"
need PGDATABASE "${PGDATABASE:-}"
need PGPASSWORD "${PGPASSWORD:-}"

# ── Ceiling file and key: the same two pointer guards as migrate-capped.sh ──
case "$CEILING_FILE" in
  *..*) fatal "MIGRATE_CEILING_FILE=${CEILING_FILE} contains '..'." 91 ;;
esac
_self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _self_dir=""
_ceil_dir="$(cd "$(dirname "$CEILING_FILE")" 2>/dev/null && pwd)" || _ceil_dir=""
if [ -z "$_self_dir" ] || [ -z "$_ceil_dir" ] || [ "$_ceil_dir" != "$_self_dir" ]; then
  fatal "MIGRATE_CEILING_FILE=${CEILING_FILE} is not beside this script (${_self_dir:-unresolved})." 91
fi
_tree="${MIGRATE_PATH##*/}"
EXPECTED_KEY="$(printf '%s' "$_tree" | tr '[:lower:]-' '[:upper:]_')"
[ "$CEILING_KEY" = "$EXPECTED_KEY" ] \
  || fatal "MIGRATE_CEILING_KEY=${CEILING_KEY} does not match the migrations tree being applied (${MIGRATE_PATH} implies ${EXPECTED_KEY})." 91
[ -f "$CEILING_FILE" ] || fatal "the release ceiling file ${CEILING_FILE} is missing." 91
CEILING="$(grep -E "^CEILING_${CEILING_KEY}=[0-9]+$" "$CEILING_FILE" 2>/dev/null | tail -1 | cut -d= -f2)"
case "$CEILING" in
  ''|*[!0-9]*) fatal "${CEILING_FILE} has no valid CEILING_${CEILING_KEY}=<integer> entry." 91 ;;
esac
if [ -n "${MIGRATE_KNOWN_SAFE_MAX:-}" ] && [ "${MIGRATE_KNOWN_SAFE_MAX}" != "$CEILING" ]; then
  fatal "MIGRATE_KNOWN_SAFE_MAX=${MIGRATE_KNOWN_SAFE_MAX} in the environment disagrees with CEILING_${CEILING_KEY}=${CEILING}; the FILE is authoritative." 91
fi

case "$TARGET" in
  ''|*[!0-9]*) fatal "MIGRATE_TARGET_VERSION is not a positive integer (got '${TARGET}')." 90 ;;
esac
TARGET="$(printf '%s' "$TARGET" | sed 's/^0*//')"
[ -n "$TARGET" ] && [ "$TARGET" -ge 1 ] || fatal "MIGRATE_TARGET_VERSION must be >= 1." 90
[ "$TARGET" -le "$CEILING" ] \
  || fatal "MIGRATE_TARGET_VERSION=${TARGET} exceeds this kit release's reviewed ceiling of ${CEILING} (CEILING_${CEILING_KEY} in ${CEILING_FILE})." 91

# ── The tree: NNNN_name.up.sql, contiguous from 0001, checksummed ───────────
[ -d "$MIGRATE_PATH" ] || fatal "migrations directory ${MIGRATE_PATH} is missing." 94
[ -f "$MIGRATE_PATH/SHA256SUMS" ] || fatal "${MIGRATE_PATH}/SHA256SUMS is missing; refusing to apply files nobody pinned." 95
if ! (cd "$MIGRATE_PATH" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
  fatal "a file in ${MIGRATE_PATH} does not match SHA256SUMS (edited or truncated)." 95
fi
FILES=""
for p in "$MIGRATE_PATH"/*.up.sql; do
  [ -f "$p" ] || continue
  b="${p##*/}"
  printf '%s' "$b" | grep -Eq '^[0-9]{4}_[a-z0-9_]+\.up\.sql$' \
    || fatal "unexpected file name ${b} in ${MIGRATE_PATH} (want NNNN_name.up.sql)." 94
  FILES="${FILES}${FILES:+ }${b}"
done
# The glob expands in collation order; NNNN_ names sort the same in every locale.
[ -n "$FILES" ] || fatal "no NNNN_*.up.sql files in ${MIGRATE_PATH}." 94
i=0
for f in $FILES; do
  i=$((i + 1))
  v="$(printf '%s' "$f" | cut -c1-4 | sed 's/^0*//')"
  [ "$v" = "$i" ] || fatal "${MIGRATE_PATH} is not contiguous from 0001 (found ${f} at position ${i})." 94
  grep -qF "  $f" "$MIGRATE_PATH/SHA256SUMS" || fatal "${f} is not listed in SHA256SUMS." 95
done
HIGHEST="$i"
[ "$TARGET" -le "$HIGHEST" ] \
  || fatal "cap is ${TARGET} but ${MIGRATE_PATH} only reaches version ${HIGHEST}; compose file and migrations tree disagree." 94
if [ "$HIGHEST" -gt "$TARGET" ]; then
  echo "[$LABEL] NOTICE: ${MIGRATE_PATH} holds versions up to ${HIGHEST}; capped at ${TARGET}. Versions above the cap are NOT applied." >&2
fi

# ── The ledger as it stands ─────────────────────────────────────────────────
psql_q() { "$PSQL" -X -q -At -v ON_ERROR_STOP=1 "$@"; }
has_ledger="$(psql_q -c "SELECT to_regclass('public.registry_schema_migrations') IS NOT NULL" 2>/dev/null)" \
  || fatal "cannot query ${PGDATABASE} on ${PGHOST} (is postgres-sanitizer-core healthy?)." 93
APPLIED=""
if [ "$has_ledger" = "t" ]; then
  APPLIED="$(psql_q -c "SELECT name FROM registry_schema_migrations ORDER BY name" 2>/dev/null)" \
    || fatal "cannot read registry_schema_migrations." 93
fi

# Every applied name must be the on-disk file of the same position: a prefix of
# the tree, optionally followed by names a NEWER core applied (never a gap).
current=0
pos=0
for name in $APPLIED; do
  pos=$((pos + 1))
  # shellcheck disable=SC2086 # FILES is a space-separated list of safe names
  want="$(printf '%s\n' $FILES | sed -n "${pos}p")"
  if [ -z "$want" ]; then
    echo "[$LABEL] NOTICE: the ledger holds ${name}, which this kit release does not ship (applied by a newer core)." >&2
    current="$pos"
    continue
  fi
  [ "$name" = "$want" ] || fatal "ledger row ${pos} is '${name}' but this kit ships '${want}' at that position; the registry was migrated by something else." 92
  current="$pos"
done

if [ "$current" -ge "$TARGET" ]; then
  echo "[$LABEL] Registry is at version ${current}; cap is ${TARGET}. Nothing to apply. This step NEVER migrates down."
  exit 0
fi

# ── Apply current+1 .. TARGET in ONE transaction (PG.Migrate's ledger) ──────
SQL="$(mktemp "${TMPDIR:-/tmp}/migrate-sanitizer-core.XXXXXX")"
trap 'rm -f "$SQL"' EXIT
{
  echo "SELECT pg_advisory_xact_lock(7413001);"
  echo "CREATE TABLE IF NOT EXISTS registry_schema_migrations (name TEXT PRIMARY KEY, at TIMESTAMPTZ NOT NULL DEFAULT now());"
  n=0
  for f in $FILES; do
    n=$((n + 1))
    [ "$n" -gt "$current" ] || continue
    [ "$n" -le "$TARGET" ] || break
    echo "INSERT INTO registry_schema_migrations (name) VALUES ('${f}');"
    echo "\\i ${MIGRATE_PATH}/${f}"
  done
} > "$SQL"

echo "[$LABEL] Applying registry migrations ${current} -> ${TARGET} in one transaction; ceiling ${CEILING} from ${CEILING_FILE} (CEILING_${CEILING_KEY})."
if ! "$PSQL" -X -q -v ON_ERROR_STOP=1 --single-transaction -o /dev/null -f "$SQL"; then
  fatal "psql reported an error; the transaction was rolled back and the registry is unchanged." 96
fi

after="$(psql_q -c "SELECT count(*) FROM registry_schema_migrations" 2>/dev/null)" \
  || fatal "applied, but the ledger could not be read back." 93
echo "[$LABEL] Done: registry_schema_migrations holds ${after} names (target ${TARGET})."
