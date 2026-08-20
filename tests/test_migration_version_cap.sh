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
#   The veil-witness image carries 000011_certificate_persistence_outbox and
#   000012_witness_claim_receipts. Both create tables holding un-redacted
#   personal data, and this kit ships NO deletion path for either. A routine
#   image-tag bump was therefore sufficient to start creating them at a customer
#   site, silently, with nothing in the chart or the release checklist
#   positioned to notice.
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
    # The guard that makes `goto` safe: current >= target must short-circuit,
    # because `goto` runs .down.sql when the DB is ahead of the target.
    if printf '%s' "$body" | grep -q 'NEVER migrates down'; then
      pass "helm-never-migrates-down-guard ($c)"
    else
      fail "helm-never-migrates-down-guard ($c) — no current>=target short-circuit before \`goto\`"
    fi
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
  ep="$(compose_svc_field "$svc" entrypoint)"
  case "$ep" in
    *migrate-capped.sh*) pass "compose-uses-capped-entrypoint ($svc)" ;;
    *) fail "compose-uses-capped-entrypoint ($svc) — entrypoint is '$ep'" ;;
  esac
  check_eq "compose-ceiling-is-literal ($svc)" "$cl" \
    "$(compose_svc_field "$svc" environment.MIGRATE_KNOWN_SAFE_MAX)"
  check_eq "parity-ceilings-match ($c: chart vs compose)" "$cl" \
    "$(compose_svc_field "$svc" environment.MIGRATE_KNOWN_SAFE_MAX)"
  check_eq "compose-default-target-is-ceiling ($svc)" "$cl" \
    "$(compose_svc_field "$svc" environment.MIGRATE_TARGET_VERSION)"
  check_eq "compose-override-defaults-false ($svc)" "false" \
    "$(compose_svc_field "$svc" environment.MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP)"
done

echo ""
echo "5. Runtime: scripts/migrate-capped.sh against a stub \`migrate\` (records argv)"

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

MIGDIR="$TMP/migrations/veil-witness"
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
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1

# Database already AHEAD of the cap (a site that ran an older, uncapped kit):
# exit 0 having called nothing. `goto 10` here would run 000012+000011 DOWN.
run_case "runtime-db-ahead-never-migrates-down" 0 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 STUB_VERSION_OUT="12" STUB_VERSION_RC=0

# Database exactly at the cap: nothing to do.
run_case "runtime-db-at-cap-noop" 0 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 STUB_VERSION_OUT="10" STUB_VERSION_RC=0

# Behind the cap: upward only, to the cap, not to the 12 on disk.
run_case "runtime-partial-db-goes-to-cap-not-disk-max" 0 'goto 10' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 STUB_VERSION_OUT="7" STUB_VERSION_RC=0

# Fail-closed cases: all apply NOTHING.
run_case "runtime-empty-target-applies-nothing" 90 '-' \
  MIGRATE_TARGET_VERSION= MIGRATE_KNOWN_SAFE_MAX=10 STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1
run_case "runtime-non-numeric-target-applies-nothing" 90 '-' \
  MIGRATE_TARGET_VERSION=abc MIGRATE_KNOWN_SAFE_MAX=10
run_case "runtime-zero-target-applies-nothing" 90 '-' \
  MIGRATE_TARGET_VERSION=0 MIGRATE_KNOWN_SAFE_MAX=10
run_case "runtime-over-ceiling-applies-nothing" 91 '-' \
  MIGRATE_TARGET_VERSION=12 MIGRATE_KNOWN_SAFE_MAX=10
run_case "runtime-missing-ceiling-applies-nothing" 91 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=
run_case "runtime-dirty-ledger-applies-nothing" 92 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 STUB_VERSION_OUT="11 (dirty)" STUB_VERSION_RC=1
run_case "runtime-unparseable-version-applies-nothing" 93 '-' \
  MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 STUB_VERSION_OUT="dial tcp: connection refused" STUB_VERSION_RC=1

# Cap beyond what the mounted tree actually holds: chart/image disagreement.
EMPTYDIR="$TMP/migrations/empty"; mkdir -p "$EMPTYDIR"
log="$TMP/argv.log"; : > "$log"
out="$(env STUB_ARGV_LOG="$log" PATH="$STUB_DIR:$PATH" MIGRATE_LABEL=t350 \
      MIGRATE_PATH="$EMPTYDIR" DATABASE_URL="postgres://stub" \
      MIGRATE_TARGET_VERSION=10 MIGRATE_KNOWN_SAFE_MAX=10 \
      STUB_VERSION_OUT="no migration" STUB_VERSION_RC=1 /bin/sh "$SCRIPT" 2>&1)"
rc=$?
if [ "$rc" = "94" ] && ! grep -qE '(^| )(up|goto)( |$)' "$log"; then
  pass "runtime-image-tree-below-cap-applies-nothing"
else
  fail "runtime-image-tree-below-cap-applies-nothing (exit $rc, argv: $(tr '\n' '|' < "$log"))"
fi

# The escape hatch, at runtime: open-ended `up`, and it ignores the ceiling.
run_case "runtime-escape-hatch-runs-open-ended-up" 0 '(^| )up$' \
  MIGRATE_TARGET_VERSION=99 MIGRATE_KNOWN_SAFE_MAX=10 \
  MIGRATE_UNSAFE_ACKNOWLEDGE_OPEN_ENDED_MIGRATE_UP=true

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
echo "7. docs/RELEASING.md carries the migration-review gate"

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
