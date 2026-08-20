#!/usr/bin/env bash
#
# T-350 — migration version cap: the kit must never run an open-ended
# `migrate up`, on either the Helm path or the Compose path.
#
# WHAT THIS SUITE EXISTS TO STOP (the defect, stated precisely):
#
#   Every DB-bearing migration job ran `migrate -path=... -database=... up`.
#   `up` with no argument applies EVERY migration file it finds. On the Helm
#   path those files come from the SERVICE IMAGE (`cp -r /migrations
#   /shared/migrations`), not from this repository — so which tables a customer
#   install creates was decided by whichever image tag happened to be pinned.
#
#   The veil-witness SOURCE TREE carries 000011_certificate_persistence_outbox,
#   000012_claim_receipts (table witness_claim_receipts) and
#   000013_decoder_expiry. The first two create tables holding un-redacted
#   personal data and this kit ships NO deletion path for either. The tag pinned
#   today (0.5.4) carries none of them — measured, its /migrations stops at
#   000010 — so the exposure is the NEXT image bump, which an uncapped `up`
#   would have taken silently, with nothing in the chart or the release
#   checklist positioned to notice. 000013 is the retention machinery, but
#   `goto 13` applies 011+012 on the way, so it cannot be taken without them.
#
# POSITIVE CONTROLS (none of these is a tautology — each goes red against the
# pre-fix tree, or against a tree where the specific guard it names has been
# removed):
#   - helm-no-open-ended-up: the pre-fix tree renders
#     `migrate ... -database="$DATABASE_URL" up` in all four Jobs, so this case
#     FAILS there. Re-adding the bare `up` turns it red again.
#   - helm-renders-capped-goto: pins the replacement, so deleting the cap
#     without restoring `up` (i.e. rendering nothing) is also caught.
#   - helm-ceiling-refuses-forbidden-target: `--set …targetVersion=12` is the
#     exact forbidden class (000011/000012). Deleting the ceiling check in
#     lucairn.migrationCap.validate turns this red.
#   - helm-unset/zero/non-numeric-refused: fail-CLOSED. If any of them started
#     defaulting to `up`, this goes red.
#   - helm-escape-hatch-still-works: the ceiling must not be a blanket ban — an
#     operator who explicitly acknowledges the retention consequences can still
#     get the old behaviour. If the guard over-fires, this goes red.
#   - compose-*: the Compose half of the same defect. A compose file that kept
#     `command: [..., "up"]` re-creates it independently of the chart.
#   - runtime-*: exercises scripts/migrate-capped.sh against a STUB `migrate`
#     binary that records its argv. This is the only layer that can prove the
#     script never calls `goto` downward and never falls back to `up` — the
#     rendered YAML cannot show that.
#   - parity-ceilings-match: the Helm ceiling and the Compose ceiling are two
#     independently-editable literals for the same fact. If they drift, one
#     path silently reviews a different migration set than the other.
#
# NON-COVERAGE (deliberate, stated rather than implied):
#   - No live cluster and no live database are involved. The runtime cases use
#     a stub `migrate`; they prove the DECISION logic, not golang-migrate's own
#     behaviour.
#   - The runtime cases run under this host's /bin/sh, not the busybox ash
#     inside migrate/migrate:v4.17.0. Only POSIX constructs are used.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
COMPOSE="$ROOT/docker-compose.customer.yml"
SCRIPT="$ROOT/scripts/migrate-capped.sh"

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

FAILS=0
N=0
pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }

check_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"; else fail "$name (want '$want', got '$got')"; fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "T-350 gate: ERROR — $1 is required" >&2; exit 2; }
}
require_command helm
require_command python3
python3 -c 'import yaml' 2>/dev/null || {
  echo "T-350 gate: ERROR — PyYAML is required (CI provisions python3-yaml)" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {
  helm template lucairn "$CHART" \
    "${HELM_TEST_SECRET_ARGS[@]}" \
    --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
    --set global.skipPullSecretGuard=true \
    "$@"
}

# migrate_command <render-file> <job-name-prefix>
# Prints the shell body of that Job's wait-and-migrate container.
migrate_command() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
path, prefix = sys.argv[1], sys.argv[2]
for doc in yaml.safe_load_all(open(path)):
    if not doc or doc.get("kind") != "Job":
        continue
    if not doc["metadata"]["name"].startswith(prefix):
        continue
    for c in doc["spec"]["template"]["spec"]["containers"]:
        if c.get("name") == "wait-and-migrate":
            print(c["command"][2])
PY
}

# The four DB-bearing subcharts and the migration version each one's ceiling
# is pinned at. These numbers are the last version in this repo's own
# migrations/<tree>/ mirror.
#
# No associative arrays: this repo's harness must run under macOS bash 3.2.
CHARTS=(veil-witness audit id-bridge sandbox-a)
ceiling_of() {
  case "$1" in
    veil-witness) echo 10 ;;
    audit)        echo 6 ;;
    id-bridge)    echo 4 ;;
    sandbox-a)    echo 8 ;;
    *) echo "ceiling_of: unknown chart $1" >&2; exit 2 ;;
  esac
}
compose_svc_of() {
  case "$1" in
    veil-witness) echo migrate-veil ;;
    audit)        echo migrate-audit ;;
    id-bridge)    echo migrate-bridge ;;
    sandbox-a)    echo migrate-sandbox-a ;;
    *) echo "compose_svc_of: unknown chart $1" >&2; exit 2 ;;
  esac
}

echo "T-350 migration version cap gate"
echo ""
echo "1. Helm: the stock render contains NO open-ended \`migrate up\`"

STOCK="$TMP/stock.yaml"
if ! render > "$STOCK" 2>"$TMP/stock.err"; then
  fail "stock render succeeds"
  sed -n '1,10p' "$TMP/stock.err"
else
  pass "stock render succeeds"

  for c in "${CHARTS[@]}"; do
    body="$(migrate_command "$STOCK" "${c}-migrate")"
    if [ -z "$body" ]; then
      fail "helm-job-present ($c)"
      continue
    fi
    # The literal pre-fix command. Its absence is the whole point.
    if printf '%s' "$body" | grep -qE 'migrate .*-database=("\$DATABASE_URL"|\$DATABASE_URL) up([[:space:]]|$)'; then
      fail "helm-no-open-ended-up ($c) — rendered command still runs a bare \`migrate ... up\`"
    else
      pass "helm-no-open-ended-up ($c)"
    fi
    # Nothing at all would also satisfy the check above, so pin the replacement.
    if printf '%s' "$body" | grep -q 'goto "\$MIGRATE_TARGET_VERSION"'; then
      pass "helm-renders-capped-goto ($c)"
    else
      fail "helm-renders-capped-goto ($c) — no capped \`migrate goto\` in the rendered command"
    fi
    got="$(printf '%s' "$body" | sed -n "s/^MIGRATE_TARGET_VERSION='\([0-9]*\)'$/\1/p")"
    check_eq "helm-default-target-is-ceiling ($c)" "$(ceiling_of "$c")" "$got"
    # NOTE: a grep for "NEVER migrates down" here would be a tautology — that
    # string lives INSIDE the block it would claim to prove runs. Disabling the
    # guard while keeping the echo left such a check green. The Helm body is a
    # second, hand-maintained copy of the algorithm, and it is the copy guarding
    # the exact scenario this commit exists for, so section 5b EXECUTES it.
  done
fi

echo ""
echo "2. Helm: fail-CLOSED — a bad target refuses to render, it never degrades to \`up\`"

expect_render_fail() {
  local name="$1"; shift
  local want_substr="$1"; shift
  if render "$@" > "$TMP/out.yaml" 2>"$TMP/out.err"; then
    fail "$name — render SUCCEEDED; it must refuse"
  elif grep -qF "$want_substr" "$TMP/out.err"; then
    pass "$name"
  else
    fail "$name — refused, but the message did not mention '$want_substr'"
    sed -n '1,4p' "$TMP/out.err"
  fi
}

for c in "${CHARTS[@]}"; do
  cl="$(ceiling_of "$c")"
  over=$(( cl + 1 ))
  expect_render_fail "helm-ceiling-refuses-over-target ($c: $over > $cl)" \
    "exceeds this kit release's reviewed ceiling" \
    --set "${c}.migrations.targetVersion=${over}"
done

# The forbidden class by name, on the chart it actually applies to.
expect_render_fail "helm-ceiling-refuses-forbidden-000012 (veil-witness targetVersion=12)" \
  "000012" --set "veil-witness.migrations.targetVersion=12"

expect_render_fail "helm-unset-target-refused" \
  "is not set" --set "veil-witness.migrations.targetVersion=null"
expect_render_fail "helm-zero-target-refused" \
  "must be a positive integer" --set "veil-witness.migrations.targetVersion=0"
expect_render_fail "helm-non-numeric-target-refused" \
  "must be a positive integer" --set-string "veil-witness.migrations.targetVersion=abc"
# ── H1: sprig `int` is base-0 and coerces booleans. Measured on this chart
#    BEFORE the guard: targetVersion 000010 -> '8', 010 -> '8', true -> '1',
#    0x10 -> 16. Zero-padding is how an operator copies the number out of a
#    migration FILENAME, so the silent result was a LOWER cap = silent
#    under-migration, the T-182 shape RELEASING.md step 3b warns about.
expect_render_fail "helm-leading-zero-target-refused (000010 rendered '8' via octal)" \
  "no leading zeros" --set "veil-witness.migrations.targetVersion=000010"
expect_render_fail "helm-octal-short-target-refused (010 rendered '8')" \
  "no leading zeros" --set "veil-witness.migrations.targetVersion=010"
expect_render_fail "helm-boolean-target-refused (true rendered '1')" \
  "no leading zeros" --set "veil-witness.migrations.targetVersion=true"
expect_render_fail "helm-hex-target-refused (0x10 became 16)" \
  "no leading zeros" --set "veil-witness.migrations.targetVersion=0x10"
expect_render_fail "helm-non-bool-override-refused" \
  "must be a YAML boolean" --set-string "veil-witness.migrations.unsafeAcknowledgeOpenEndedMigrateUp=yes-please"

echo ""
echo "3. Helm: the screaming escape hatch still works (the cap is not a blanket ban)"

if render --set "veil-witness.migrations.unsafeAcknowledgeOpenEndedMigrateUp=true" \
          --set "veil-witness.migrations.targetVersion=12" > "$TMP/unsafe.yaml" 2>"$TMP/unsafe.err"; then
  body="$(migrate_command "$TMP/unsafe.yaml" "veil-witness-migrate")"
  if printf '%s' "$body" | grep -qE 'migrate -path="\$MIGRATE_PATH" -database="\$DATABASE_URL" up$'; then
    pass "helm-escape-hatch-renders-open-ended-up"
  else
    fail "helm-escape-hatch-renders-open-ended-up — override set but no open-ended \`up\` rendered"
  fi
  if printf '%s' "$body" | grep -q 'UNSAFE OVERRIDE ACTIVE'; then
    pass "helm-escape-hatch-is-loud"
  else
    fail "helm-escape-hatch-is-loud — the override renders silently"
  fi
  # The other three charts must be unaffected by one chart's override.
  for c in audit id-bridge sandbox-a; do
    other="$(migrate_command "$TMP/unsafe.yaml" "${c}-migrate")"
    if printf '%s' "$other" | grep -qE '\-database="\$DATABASE_URL" up$'; then
      fail "helm-escape-hatch-is-per-chart ($c leaked open-ended up)"
    else
      pass "helm-escape-hatch-is-per-chart ($c)"
    fi
  done
else
  fail "helm-escape-hatch-renders (render failed)"
  sed -n '1,6p' "$TMP/unsafe.err"
fi

echo ""
echo "4. Compose: same cap, same escape hatch, no bare \`up\`"

compose_svc_field() {
  python3 - "$COMPOSE" "$1" "$2" <<'PY'
import sys, yaml, re
path, svc, field = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(path).read()
# customer.env interpolation (${VAR:?msg} / ${VAR:-default}) is not YAML's
# problem; neutralise it so the file parses, keeping the default where given.
raw = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]*)\}', r'\2', raw)
raw = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*):\?[^}]*\}', r'STUB', raw)
doc = yaml.safe_load(raw)
s = doc["services"].get(svc, {})
v = s
for part in field.split("."):
    if isinstance(v, dict):
        v = v.get(part)
    else:
        v = None
print("" if v is None else (v if isinstance(v, str) else yaml.safe_dump(v, default_flow_style=True).strip()))
PY
}

if grep -qE '^\s+- "up"\s*$' "$COMPOSE"; then
  fail "compose-no-open-ended-up — a migrate-* service still passes a bare \"up\""
else
  pass "compose-no-open-ended-up"
fi

for c in "${CHARTS[@]}"; do
  svc="$(compose_svc_of "$c")"
  cl="$(ceiling_of "$c")"
  ckey=""; chart_ceiling=""
  ep="$(compose_svc_field "$svc" entrypoint)"
  case "$ep" in
    *migrate-capped.sh*) pass "compose-uses-capped-entrypoint ($svc)" ;;
    *) fail "compose-uses-capped-entrypoint ($svc) — entrypoint is '$ep'" ;;
  esac
  # The ceiling is NOT in the compose environment any more — an `environment:`
  # value is overridable by a second `-f` overlay or `docker compose run -e`,
  # which made the cap a convention rather than a control (proven: a run with
  # MIGRATE_KNOWN_SAFE_MAX=99 applied `goto 12` and still logged "capped").
  if [ -n "$(compose_svc_field "$svc" environment.MIGRATE_KNOWN_SAFE_MAX)" ]; then
    fail "compose-ceiling-not-env-settable ($svc) — MIGRATE_KNOWN_SAFE_MAX is back in the environment block"
  else
    pass "compose-ceiling-not-env-settable ($svc)"
  fi
  ckey="$(compose_svc_field "$svc" environment.MIGRATE_CEILING_KEY)"
  check_eq "compose-ceiling-file-value ($svc)" "$cl" \
    "$(sed -n "s/^CEILING_${ckey}=\([0-9]*\)$/\1/p" "$ROOT/scripts/migration-ceilings.conf")"
  # Real parity: read the CHART's baked literal, not the test's own table.
  # The previous version of this check compared the compose value to
  # ceiling_of() twice under two names and could not fail for a chart reason.
  chart_ceiling="$(sed -n 's/^{{- \$knownSafeMax := \([0-9]*\) }}$/\1/p' \
    "$CHART/charts/$c/templates/migration-job.yaml")"
  check_eq "parity-ceilings-match ($c: chart \$knownSafeMax vs ceiling file)" \
    "$chart_ceiling" \
    "$(sed -n "s/^CEILING_${ckey}=\([0-9]*\)$/\1/p" "$ROOT/scripts/migration-ceilings.conf")"
  check_eq "compose-default-target-is-ceiling ($svc)" "$cl" \
    "$(compose_svc_field "$svc" environment.MIGRATE_TARGET_VERSION)"
  check_eq "compose-override-defaults-false ($svc)" "false" \
    "$(compose_svc_field "$svc" environment.MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP)"
  # The hatch must be PER SERVICE. One global variable would mean unblocking
  # id-bridge silently also opened veil-witness — the exact class the cap exists
  # to stop. Helm's hatch is per-subchart and had a positive control; Compose
  # did not, and was global.
  if grep -qE "LUCAIRN_MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP_[A-Z_]+:-false" \
       <(sed -n "/^  $svc:/,/^    restart/p" "$COMPOSE"); then
    pass "compose-hatch-is-per-service ($svc)"
  else
    fail "compose-hatch-is-per-service ($svc) — hatch is not service-scoped"
  fi
done

echo ""
echo "5. Runtime: scripts/migrate-capped.sh against a stub \`migrate\` (records argv)"

# The exact string golang-migrate emits when the Version() query itself fails —
# note it contains the column name `dirty`, which is why a substring match
# misreported every permission/timeout error as a dirty ledger (H1).
QUERY_ERR='error: pq: permission denied for schema public in line 0: CREATE TABLE IF NOT EXISTS "public"."schema_migrations" (version bigint not null primary key, dirty boolean not null)'

STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/migrate" <<'STUB'
#!/bin/sh
# Records argv, then answers `version` from STUB_VERSION_OUT / STUB_VERSION_RC.
echo "$@" >> "$STUB_ARGV_LOG"
for a in "$@"; do
  if [ "$a" = "version" ]; then
    printf '%s\n' "${STUB_VERSION_OUT:-no migration}"
    exit "${STUB_VERSION_RC:-1}"
  fi
done
exit 0
STUB
chmod +x "$STUB_DIR/migrate"

# The ceiling now comes from a release-shipped file, not the environment. Use
# the REAL shipped file so the fixture cannot drift from what customers get.
CEILING_FIXTURE="$ROOT/scripts/migration-ceilings.conf"

MIGDIR="$TMP/migrations/veil-witness"  # basename drives the H2 ceiling-key derivation
mkdir -p "$MIGDIR"
for n in 000001 000002 000003 000004 000005 000006 000007 000008 000009 000010 000011 000012; do
  : > "$MIGDIR/${n}_x.up.sql"
  : > "$MIGDIR/${n}_x.down.sql"
done

# run_case <name> <expected-exit> <expected-argv-grep|-> [ENV=VAL ...]
run_case() {
  local name="$1" want_rc="$2" want_argv="$3"; shift 3
  local log="$TMP/argv.log"; : > "$log"
  local out rc
  out="$(env STUB_ARGV_LOG="$log" PATH="$STUB_DIR:$PATH" \
        MIGRATE_LABEL=t350 MIGRATE_PATH="$MIGDIR" DATABASE_URL="postgres://stub" \
        MIGRATE_CEILING_KEY=VEIL_WITNESS MIGRATE_CEILING_FILE="$CEILING_FIXTURE" \
        "$@" /bin/sh "$SCRIPT" 2>&1)"
  rc=$?
  if [ "$rc" != "$want_rc" ]; then
    fail "$name (exit want $want_rc, got $rc)"
    printf '        %s\n' "$out" | head -3
    return
  fi
  if [ "$want_argv" = "-" ]; then
    # Assert NOTHING was applied: no goto, no up.
    if grep -qE '(^| )(up|goto)( |$)' "$log"; then
      fail "$name — applied something: $(tr '\n' '|' < "$log")"
    else
      pass "$name"
    fi
  elif grep -qE "$want_argv" "$log"; then
    pass "$name"
  else
    fail "$name — argv log did not match /$want_argv/: $(tr '\n' '|' < "$log")"
  fi
}

# Fresh database, default cap: applies exactly `goto 10`, never `up`.
run_case "runtime-fresh-db-applies-goto-cap" 0 'goto 10' \
  MIGRATE_TARGET_VERSION=10 STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1

# Database already AHEAD of the cap (a site that ran an older, uncapped kit):
# exit 0 having called nothing. `goto 10` here would run 000012+000011 DOWN.
run_case "runtime-db-ahead-never-migrates-down" 0 '-' \
  MIGRATE_TARGET_VERSION=10 STUB_VERSION_OUT="12" STUB_VERSION_RC=0

# Database exactly at the cap: nothing to do.
run_case "runtime-db-at-cap-noop" 0 '-' \
  MIGRATE_TARGET_VERSION=10 STUB_VERSION_OUT="10" STUB_VERSION_RC=0

# Behind the cap: upward only, to the cap, not to the 12 on disk.
run_case "runtime-partial-db-goes-to-cap-not-disk-max" 0 'goto 10' \
  MIGRATE_TARGET_VERSION=10 STUB_VERSION_OUT="7" STUB_VERSION_RC=0

# Fail-closed cases: all apply NOTHING.
run_case "runtime-empty-target-applies-nothing" 90 '-' \
  MIGRATE_TARGET_VERSION= STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1
run_case "runtime-non-numeric-target-applies-nothing" 90 '-' \
  MIGRATE_TARGET_VERSION=abc
run_case "runtime-zero-target-applies-nothing" 90 '-' \
  MIGRATE_TARGET_VERSION=0
run_case "runtime-over-ceiling-applies-nothing" 91 '-' \
  MIGRATE_TARGET_VERSION=12
run_case "runtime-missing-ceiling-file-applies-nothing" 91 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_CEILING_FILE=/nonexistent/ceilings.env
run_case "runtime-dirty-ledger-applies-nothing" 92 '-' \
  MIGRATE_TARGET_VERSION=10 STUB_VERSION_OUT="11 (dirty)" STUB_VERSION_RC=1
run_case "runtime-query-error-is-not-dirty" 93 '-' \
  MIGRATE_TARGET_VERSION=10 \
  STUB_VERSION_OUT="$QUERY_ERR" STUB_VERSION_RC=1
run_case "runtime-unparseable-version-applies-nothing" 93 '-' \
  MIGRATE_TARGET_VERSION=10 STUB_VERSION_OUT="dial tcp: connection refused" STUB_VERSION_RC=1

# TOB-002 regression, proven before the fix: MIGRATE_KNOWN_SAFE_MAX=99 in the
# environment applied `goto 12` (creating 000011 + 000012) while the log line
# still said "capped". The file is now authoritative and a disagreeing env value
# is refused outright rather than silently ignored.
run_case "runtime-env-cannot-raise-ceiling" 91 '-' \
  MIGRATE_TARGET_VERSION=12 MIGRATE_KNOWN_SAFE_MAX=99
run_case "runtime-env-agreeing-with-file-is-accepted" 0 'goto 10' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 \
  STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1

# ── H2: moving the ceiling VALUE out of the environment left the environment
#    naming WHICH file and WHICH key were authoritative. Both were proven
#    bypasses: MIGRATE_CEILING_FILE=<attacker file> applied `goto 12` reporting
#    "ceiling 99", and migrate-audit naming VEIL_WITNESS's key applied `goto 10`
#    against a real ceiling of 6.
CEIL_EVIL="$TMP/evil-ceilings.conf"
printf 'CEILING_VEIL_WITNESS=99\n' > "$CEIL_EVIL"
run_case "runtime-ceiling-file-must-sit-beside-runner" 91 '-' \
  MIGRATE_TARGET_VERSION=12 MIGRATE_CEILING_FILE="$CEIL_EVIL"
run_case "runtime-ceiling-key-must-match-migrations-tree" 91 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_CEILING_KEY=AUDIT
run_case "runtime-ceiling-file-rejects-dotdot" 91 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_CEILING_FILE="$ROOT/scripts/../scripts/migration-ceilings.conf"
# L2: an ambiguous hatch value must be refused, not silently read as "off".
run_case "runtime-ambiguous-hatch-value-refused" 95 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP=True

# Cap beyond what the mounted tree actually holds: chart/image disagreement.
EMPTYDIR="$TMP/empty-tree/veil-witness"; mkdir -p "$EMPTYDIR"  # basename must stay veil-witness: the H2 key check runs first
log="$TMP/argv.log"; : > "$log"
out="$(env STUB_ARGV_LOG="$log" PATH="$STUB_DIR:$PATH" MIGRATE_LABEL=t350 \
      MIGRATE_PATH="$EMPTYDIR" DATABASE_URL="postgres://stub" \
      MIGRATE_CEILING_KEY=VEIL_WITNESS MIGRATE_CEILING_FILE="$CEILING_FIXTURE" \
      MIGRATE_TARGET_VERSION=10 \
      STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1 /bin/sh "$SCRIPT" 2>&1)"
rc=$?
if [ "$rc" = "94" ] && ! grep -qE '(^| )(up|goto)( |$)' "$log"; then
  pass "runtime-image-tree-below-cap-applies-nothing"
else
  fail "runtime-image-tree-below-cap-applies-nothing (exit $rc, argv: $(tr '\n' '|' < "$log"))"
fi

# The escape hatch, at runtime: open-ended `up`, and it ignores the ceiling.
run_case "runtime-escape-hatch-runs-open-ended-up" 0 '(^| )up$' \
  MIGRATE_TARGET_VERSION=99 \
  MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP=true

echo ""
echo "5b. Runtime: the RENDERED HELM BODY, executed (not grepped)"

# The Helm container body is a second, hand-maintained copy of the same ~80-line
# algorithm as scripts/migrate-capped.sh; section 5 covers only the Compose copy.
# Without this section, deleting the Helm copy's `current >= target`
# short-circuit — the guard stopping `migrate goto` from running .down.sql on a
# site already at 12/13 under an older uncapped kit — left the whole suite green
# (mutation-proven).
#
# The rendered body runs verbatim. Two stubs stand in for the cluster: `nc` (the
# Postgres wait) and `migrate` (records argv). MIGRATE_PATH is honoured by the
# rendered script for exactly this purpose; the Job spec sets no such env, so in
# a cluster it is always the /shared/migrations literal.
HELM_BODY="$TMP/helm-body.sh"
migrate_command "$STOCK" "veil-witness-migrate" > "$HELM_BODY"

cat > "$STUB_DIR/nc" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$STUB_DIR/nc"

helm_case() {
  local name="$1" want_rc="$2" want_argv="$3"; shift 3
  local log="$TMP/argv.log"; : > "$log"
  local out rc
  out="$(env STUB_ARGV_LOG="$log" PATH="$STUB_DIR:$PATH" \
        MIGRATE_PATH="$MIGDIR" DATABASE_URL="postgres://stub" \
        "$@" /bin/sh "$HELM_BODY" 2>&1)"
  rc=$?
  if [ "$rc" != "$want_rc" ]; then
    fail "$name (exit want $want_rc, got $rc)"
    printf '        %s\n' "$out" | head -3
    return
  fi
  if [ "$want_argv" = "-" ]; then
    if grep -qE '(^| )(up|goto)( |$)' "$log"; then
      fail "$name — applied something: $(tr '\n' '|' < "$log")"
    else
      pass "$name"
    fi
  elif grep -qE "$want_argv" "$log"; then
    pass "$name"
  else
    fail "$name — argv log did not match /$want_argv/: $(tr '\n' '|' < "$log")"
  fi
}

if [ ! -s "$HELM_BODY" ]; then
  fail "helm-body-extracted"
else
  pass "helm-body-extracted"
  helm_case "helm-runtime-fresh-db-applies-goto-cap" 0 'goto 10' \
    STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1
  # THE ONE THAT MATTERS: DB ahead of the cap. `goto 10` here would run
  # 000012.down + 000011.down and drop the two personal-data tables.
  helm_case "helm-runtime-db-ahead-never-migrates-down" 0 '-' \
    STUB_VERSION_OUT="12" STUB_VERSION_RC=0
  helm_case "helm-runtime-db-at-cap-noop" 0 '-' \
    STUB_VERSION_OUT="10" STUB_VERSION_RC=0
  helm_case "helm-runtime-partial-db-goes-to-cap" 0 'goto 10' \
    STUB_VERSION_OUT="7" STUB_VERSION_RC=0
  helm_case "helm-runtime-dirty-ledger-applies-nothing" 92 '-' \
    STUB_VERSION_OUT="11 (dirty)" STUB_VERSION_RC=1
  # H1 regression: golang-migrate echoes its own SQL on a query failure and that
  # SQL contains the column name `dirty`. A substring match reported this as a
  # dirty ledger and recommended `migrate force`, which rewrites the ledger
  # blind. It must be an unparseable-version refusal (93), not 92.
  helm_case "helm-runtime-query-error-is-not-dirty" 93 '-' \
    STUB_VERSION_OUT="$QUERY_ERR" STUB_VERSION_RC=1
fi

echo ""
echo "6. The helper is per-subchart and the four copies are byte-identical"

# Why this matters: an umbrella-only helper renders fine under `helm template
# charts/lucairn` but breaks a DIRECT child-chart render — which this repo's own
# harness does (tests/test_wp1_s4_helm_boundary.sh,
# tests/test_l3_model_upgrade_gate.sh) and which a customer packaging a single
# sub-chart would also hit. So the helper ships in each sub-chart. Duplication is
# only safe while the copies agree, which is what these checks pin.
CANON="$ROOT/charts/lucairn/charts/veil-witness/templates/_migration-cap.tpl"
if [ -f "$ROOT/charts/lucairn/templates/_migration-cap.tpl" ]; then
  fail "helper-not-umbrella-only — an umbrella copy exists; a direct child render cannot see it"
else
  pass "helper-not-umbrella-only"
fi
for c in "${CHARTS[@]}"; do
  f="$ROOT/charts/lucairn/charts/$c/templates/_migration-cap.tpl"
  if [ ! -f "$f" ]; then
    fail "helper-present ($c)"
  elif cmp -s "$CANON" "$f"; then
    pass "helper-byte-identical ($c)"
  else
    fail "helper-byte-identical ($c) — copies have drifted; re-sync from veil-witness"
  fi
done

# The regression itself: render sandbox-a standalone, the way the boundary suite
# does. Against an umbrella-only helper this is `error calling include`.
cat > "$TMP/direct-child.yaml" <<YAML
ephemeral: "true"
secrets:
  values:
    postgresPassword: "${TEST_SECRET_VALUE}"
global:
  imageRegistry: ""
  imageTag: "0.5.4"
  imagePullSecrets: []
  postgresqlSslmode: disable
  dsaServiceToken: ""
  dsaEnv: development
  nodeIsolation: false
  mtls:
    enabled: false
YAML
if helm template sandbox-a "$CHART/charts/sandbox-a" -f "$TMP/direct-child.yaml" > "$TMP/direct.yaml" 2>"$TMP/direct.err"; then
  if grep -q 'goto "\$MIGRATE_TARGET_VERSION"' "$TMP/direct.yaml"; then
    pass "direct-child-render-works"
  else
    fail "direct-child-render-works — rendered, but with no capped goto"
  fi
else
  fail "direct-child-render-works — $(head -1 "$TMP/direct.err")"
fi

echo ""
echo "7. Every ./scripts/* the Compose file mounts actually exists"

# TOB-001: `bundle create` staged a HAND-MAINTAINED list of one script. T-350
# added a second mount (and then a third, the ceiling file). A missing mount is
# not a soft failure — Docker materialises the absent source as a DIRECTORY and
# the service dies, so an air-gapped bundle install would never start.
mounted="$(grep -oE '\./scripts/[A-Za-z0-9._-]+' "$COMPOSE" | sed 's#^\./scripts/##' | sort -u)"
if [ -z "$mounted" ]; then
  fail "compose-mounts-enumerable"
else
  pass "compose-mounts-enumerable"
  for m in $mounted; do
    if [ ! -f "$ROOT/scripts/$m" ]; then
      fail "compose-mount-exists ($m) — bind-mount source missing from the repo"
      continue
    fi
    pass "compose-mount-exists ($m)"
    # Present-on-disk is NOT enough, and this is the check that would have
    # caught the shipped defect: `.gitignore` line 2 is `*.env`, so the ceiling
    # file was silently skipped by `git add -A`, `git status` reported a clean
    # tree, every local gate passed against the untracked working copy, and the
    # PUSHED commit had no such file. The release tarball is built with
    # `git archive HEAD` (scripts/package-release.sh), so an untracked mount
    # source is absent from the artifact too.
    if git -C "$ROOT" ls-files --error-unmatch "scripts/$m" >/dev/null 2>&1; then
      pass "compose-mount-tracked ($m)"
    else
      fail "compose-mount-tracked ($m) — present on disk but NOT tracked by git; it will be missing from the commit and from \`git archive\` release tarballs"
    fi
  done
  # The previous version of this check grepped for the variable NAME
  # `bundle_mounted_scripts=`, which a hardcoded one-entry list satisfies —
  # mutation-proven vacuous (the suite stayed 96/96 green with the derivation
  # replaced by a literal list). Run the bundler's OWN derivation pipeline and
  # compare the resulting SET against the mounted set.
  bundler_pipeline="$(sed -n 's/.*bundle_mounted_scripts="\$(\(.*\))"$/\1/p' "$ROOT/bin/lucairn")"
  if [ -z "$bundler_pipeline" ]; then
    fail "bundler-derivation-extractable — could not find the staging derivation in bin/lucairn"
  else
    staged="$(bundle_compose_src="$COMPOSE" ROOT="$ROOT" sh -c "$bundler_pipeline" 2>/dev/null | sort -u)"
    mounted_sorted="$(printf '%s\n' $mounted | sort -u)"
    if [ "$staged" = "$mounted_sorted" ]; then
      pass "bundler-stages-exactly-the-mounted-set"
    else
      fail "bundler-stages-exactly-the-mounted-set — staged=[$(printf '%s' "$staged" | tr '\n' ' ')] mounted=[$(printf '%s' "$mounted_sorted" | tr '\n' ' ')]"
    fi
  fi
  # A literal per-file cp into the staging scripts dir would re-introduce the
  # hand-maintained list alongside the loop.
  # A LITERAL filename (no shell variable) is the hand-maintained-list shape.
  # The derived loop's own `cp "$ROOT/scripts/$_script" ...` must not trip it.
  if grep -qE 'cp "\$ROOT/scripts/[A-Za-z0-9._-]+" "\$staging/install/scripts/' "$ROOT/bin/lucairn"; then
    fail "bundler-has-no-hardcoded-script-cp — a literal cp into \$staging/install/scripts/ survives beside the derived loop"
  else
    pass "bundler-has-no-hardcoded-script-cp"
  fi
  if grep -q 'migrate-capped.sh missing beside the selected Compose file' "$ROOT/bin/lucairn"; then
    pass "doctor-preflights-migrate-runner"
  else
    fail "doctor-preflights-migrate-runner — doctor has no check for the new mount"
  fi
fi

echo ""
echo "8. docs/RELEASING.md carries the migration-review gate"

REL="$ROOT/docs/RELEASING.md"
for needle in "Migration review" "targetVersion" "deletion path" "release-blocking"; do
  if grep -qF "$needle" "$REL"; then
    pass "releasing-doc-mentions ($needle)"
  else
    fail "releasing-doc-mentions ($needle) — docs/RELEASING.md does not mention it"
  fi
done

echo ""
if [ "$FAILS" -eq 0 ]; then
  echo "T-350 migration version cap gate: PASS ($N checks)"
  exit 0
fi
echo "T-350 migration version cap gate: FAIL ($FAILS of $N checks)"
exit 1
