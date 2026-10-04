#!/usr/bin/env bash
# test_audit_claim_delivery_retention.sh — T-1219 (kit 1.9.6).
#
# Covers the retention sweep for audit_claim_deliveries (audit migration
# 000007) on both install paths:
#
#   A. The sweep script on its own (no database): byte-identity between the
#      Compose copy (scripts/) and the Helm copy (charts/.../audit/files/),
#      shell syntax, and the refusals (bad ENABLED / DAYS / BATCH, missing
#      PG* settings, any DATABASE_URL) — each refused WITHOUT ever calling psql;
#      the synthetic password never appears in any output (stub AND real psql);
#      loop mode + disabled idles instead of exiting; doctor agrees with the
#      runtime and checks the script beside the SELECTED compose file.
#   B. Helm (`helm template`): the CronJob renders with the defaults, embeds the
#      script byte-for-byte, connects as `dsa` via discrete PG* settings with
#      PGPASSWORD from audit-credentials/POSTGRES_PASSWORD, and
#      renders NOTHING when disabled, with external Postgres, or with the audit
#      subchart off. `retention` ("<N>d", a string) below 1d — and every
#      malformed spelling, including YAML numbers from a values FILE (030 is
#      octal 24) — is refused at render time. Image digest = image-manifest.yaml.
#   C. Compose (`docker compose config`, client-side only — no daemon): the
#      service exists, uses the postgres-audit image, waits for migrate-audit,
#      sits on dsa-audit only, and carries the shipped env names + defaults.
#   D. REAL POSTGRES (needs a docker daemon — local, or a remote host over ssh):
#      applies audit migrations 1..CEILING_AUDIT from migrations/audit/ (000003
#      rendered by scripts/render-migrations.sh, as the kit does), seeds
#      SYNTHETIC rows in all four delivery states with old and new timestamps,
#      runs the sweep as `dsa`, and asserts:
#        - old DELIVERED rows: claim_raw + output_scan_body NULL, row still there,
#          still DELIVERED;
#        - new DELIVERED, PENDING, DELIVERING and ALL PARKED rows unchanged
#          (content hash), the old PARKED rows reported in a WARN line;
#        - audit_events unchanged (count + content hash);
#        - a second run blanks nothing;
#        - audit_app (the runtime role) still cannot DELETE;
#        - a replay of a blanked event_id through the audit service's own
#          statements (INSERT … ON CONFLICT (event_id) DO NOTHING, the
#          BeginClaimDelivery lease UPDATE, the retry-worker SELECT) creates no
#          row, acquires nothing, selects nothing;
#      then runs the sweep a second way, exactly as the Compose service is
#      defined (entrypoint, user, read-only rootfs, env from `docker compose
#      config`), to prove the shipped env names connect.
#
#   Where D runs:
#     - a local docker daemon, if `docker info` answers; otherwise
#     - T1219_DOCKER_SSH=<user@host> (+ optional T1219_DOCKER_SSH_KEY=<path>):
#       every docker command runs on that host over ssh. Only uniquely named
#       throwaway objects are created (network t1219-net-*, containers
#       t1219-pg-* / t1219-svc-*, a temp dir t1219-* in the remote $HOME), no
#       ports are published, and everything is removed on exit.
#     - neither: a LOUD SKIP (never a silent pass). T1219_REQUIRE_PG=1 turns the
#       skip into a failure.
#   The Postgres image is the one the kit pins by digest (image-manifest.yaml
#   enterprise_kind.postgres), pulled by digest so no moving tag is re-pointed.
#
# All data is synthetic. Every external command is time-bounded.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/audit-claim-delivery-retention.sh"
CHART_SCRIPT="$ROOT/charts/lucairn/charts/audit/files/audit-claim-delivery-retention.sh"
CHART="$ROOT/charts/lucairn"
VALUES="$ROOT/customer-values.yaml.example"
COMPOSE="$ROOT/docker-compose.customer.yml"

WK="$(mktemp -d)"
trap 'rm -rf "$WK"' EXIT
PASS=0
FAILS=0
SKIPS=0

ok()   { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
die()  { echo "FAIL: $*" >&2; exit 1; }
skip() {
  echo "  ##################################################################" >&2
  echo "  ## SKIP: $*" >&2
  echo "  ##################################################################" >&2
  SKIPS=$((SKIPS + 1))
}

# Time bound for every external command (macOS has no `timeout`).
if command -v timeout >/dev/null 2>&1; then
  tmo() { timeout "$@"; }
else
  tmo() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

# shellcheck source=lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

# The postgres:16-alpine digest the kit records (image-manifest.yaml
# image_digests.enterprise_kind.postgres) — the retention job's image must be
# pinned to exactly this on both install paths (sol r1 P2).
MANIFEST_PG="$(python3 - "$ROOT/image-manifest.yaml" <<'PY2'
import sys, yaml
pg = yaml.safe_load(open(sys.argv[1]))["image_digests"]["enterprise_kind"]["postgres"]
print(pg["ref"] + "@" + pg["digest"])
PY2
)"
case "$MANIFEST_PG" in postgres:16-alpine@sha256:*) ;; *) die "could not read image_digests.enterprise_kind.postgres from image-manifest.yaml (got '$MANIFEST_PG')" ;; esac

# ═══════════════════════════════════════════════════════════════════════════
echo "== A. sweep script (no database) =="
# ═══════════════════════════════════════════════════════════════════════════

[ -f "$SCRIPT" ] || die "missing $SCRIPT"
[ -f "$CHART_SCRIPT" ] || die "missing $CHART_SCRIPT"
if cmp -s "$SCRIPT" "$CHART_SCRIPT"; then
  ok "scripts/ and charts/lucairn/charts/audit/files/ copies are byte-identical"
else
  bad "the Compose and Helm copies of audit-claim-delivery-retention.sh differ — edit both together"
fi
sh -n "$SCRIPT" && ok "sh -n syntax" || bad "sh -n syntax error"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s sh "$SCRIPT" && ok "shellcheck -s sh clean" || bad "shellcheck findings"
fi
# Static: the sweep never DELETEs and only ever blanks DELIVERED rows.
if grep -Eiq '^[^#]*\bdelete[[:space:]]+from\b' "$SCRIPT"; then
  bad "the sweep script contains a DELETE statement — it must only blank columns"
else
  ok "no DELETE statement in the sweep"
fi
grep -q "delivery_state = 'DELIVERED'" "$SCRIPT" && grep -q "SET claim_raw = NULL" "$SCRIPT" \
  && ok "blanking UPDATE targets DELIVERED rows" || bad "blanking UPDATE not found"

# A stub psql that records any call: refusals must happen before psql runs.
STUBDIR="$WK/stub"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/psql" <<EOF
#!/bin/sh
echo called >> "$WK/psql-called"
exit 99
EOF
chmod +x "$STUBDIR/psql"

# run_unit <expect-rc> <label> <env assignments...>
run_unit() {
  local want="$1" label="$2"; shift 2
  rm -f "$WK/psql-called"
  local out rc
  out="$(tmo 20 env -i PATH="$STUBDIR:/usr/bin:/bin" "$@" sh "$SCRIPT" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" != "$want" ]; then
    bad "$label: exit $rc, want $want (output: $out)"
    return
  fi
  if [ -f "$WK/psql-called" ]; then
    bad "$label: psql was called"
    return
  fi
  ok "$label (exit $rc, psql not called)"
  LAST_OUT="$out"
}
# Discrete connection settings (the script refuses connection URLs). The
# password is an obviously synthetic marker; no output may ever contain it.
SECRET="syntheticSecret"
CONN=(PGHOST=127.0.0.1 PGPORT=1 PGUSER=dsa PGDATABASE=audit "PGPASSWORD=${SECRET}")
run_unit 0 "ENABLED=false exits 0 without touching the database" "${CONN[@]}" LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false
case "${LAST_OUT:-}" in *"level=INFO disabled"*) ok "disabled run logs one line" ;; *) bad "disabled run did not log the disabled line" ;; esac
# Disabled means the retention value is never read (doctor mirrors this).
run_unit 0 "ENABLED=false with DAYS=0 still exits 0 (value unused when disabled)" "${CONN[@]}" LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS=0
# (An EMPTY value means "use the default", exactly as Compose's ${VAR:-default}.)
for v in TRUE yes 1 " true"; do
  run_unit 2 "ENABLED='$v' refused" "${CONN[@]}" "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=$v"
done
for v in 0 -1 030 1.5 abc 36501 999999999999 " 30"; do
  run_unit 2 "DAYS='$v' refused" "${CONN[@]}" "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS=$v"
done
for v in 0 -5 abc 100001; do
  run_unit 2 "BATCH_SIZE='$v' refused" "${CONN[@]}" "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_BATCH_SIZE=$v"
done
run_unit 2 "INTERVAL_SECONDS='x' refused" "${CONN[@]}" "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_INTERVAL_SECONDS=x"
run_unit 2 "missing PGPASSWORD refused" PGHOST=127.0.0.1 PGUSER=dsa PGDATABASE=audit
run_unit 2 "missing PGHOST refused" PGUSER=dsa PGDATABASE=audit "PGPASSWORD=${SECRET}"

# ── sol r1 P1: the password never reaches the log ────────────────────────────
# no_secret <label> <output> — the synthetic password must not appear.
no_secret() {
  case "$2" in
    *"$SECRET"*) bad "$1: output contains the synthetic password: $2" ;;
    *) ok "$1: password not in output" ;;
  esac
}
# Malformed credential spellings that made libpq quote the password back on
# a3cff3c (`invalid percent-encoded token: "syntheticSecret%GG"`, `invalid
# integer value "syntheticSecret" for connection option "port"`). The script
# must refuse each BEFORE psql, without echoing the value.
MAL_URL1="postgres://dsa:${SECRET}%GG@127.0.0.1:1/audit"
MAL_URL2="postgres://dsa@127.0.0.1:${SECRET}/audit"
run_unit 2 "DATABASE_URL (malformed, carries the password) refused" "${CONN[@]}" "DATABASE_URL=$MAL_URL1"
no_secret "DATABASE_URL refusal" "${LAST_OUT:-}"
run_unit 2 "PGHOST holding a pasted URL refused" PGHOST="$MAL_URL1" PGUSER=dsa PGDATABASE=audit "PGPASSWORD=${SECRET}x"
no_secret "PGHOST refusal" "${LAST_OUT:-}"
run_unit 2 "PGPORT holding the password refused" PGHOST=127.0.0.1 "PGPORT=${SECRET}" PGUSER=dsa PGDATABASE=audit PGPASSWORD=x
no_secret "PGPORT refusal" "${LAST_OUT:-}"
# A psql that prints libpq-style diagnostics quoting the password: the script
# must log a fixed reason, never psql's text.
cat > "$STUBDIR/psql" <<'EOF'
#!/bin/sh
echo "psql: error: invalid percent-encoded token: \"${PGPASSWORD}%GG\"" >&2
echo "psql: error: connection to server at \"127.0.0.1\", port 1 failed: password authentication failed for user \"dsa\" (password ${PGPASSWORD})" >&2
exit 2
EOF
chmod +x "$STUBDIR/psql"
out="$(tmo 20 env -i PATH="$STUBDIR:/usr/bin:/bin" "${CONN[@]}" sh "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  bad "a failing psql made the run exit 0"
else
  ok "psql failure: non-zero exit ($rc)"
fi
no_secret "psql diagnostics quoting the password" "$out"
case "$out" in *"reason=auth_failed psql_exit=2"*) ok "psql failure logged as a fixed reason (auth_failed, exit 2)" ;; *) bad "psql failure not mapped to a fixed reason: $out" ;; esac
case "$out" in *"psql: error"*|*"percent-encoded"*) bad "raw psql stderr reached the log" ;; *) ok "raw psql stderr never logged" ;; esac

# The same with the REAL libpq/psql client, when one is installed here (the
# container run in D covers the shipped image's psql). Every case: non-zero
# exit, password absent from all output.
REAL_PSQL="$(command -v psql 2>/dev/null || true)"
if [ -z "$REAL_PSQL" ]; then
  skip "no psql client on this machine — real-libpq leak check in A NOT RUN (D repeats it inside the Postgres image)"
else
  REALBIN="$WK/realbin"; mkdir -p "$REALBIN"; ln -sf "$REAL_PSQL" "$REALBIN/psql"
  real_leak() { # <label> <env assignments...>
    local label="$1"; shift
    local out rc
    out="$(tmo 30 env -i PATH="$REALBIN:/usr/bin:/bin" HOME="$WK" "$@" sh "$SCRIPT" --once 2>&1)" && rc=0 || rc=$?
    [ "$rc" != 0 ] && ok "real psql, $label: non-zero exit ($rc)" || bad "real psql, $label: exit 0"
    no_secret "real psql, $label" "$out"
  }
  real_leak "malformed URL with %GG in the password" PGHOST=127.0.0.1 PGUSER=dsa PGDATABASE=audit "PGPASSWORD=${SECRET}" "DATABASE_URL=$MAL_URL1"
  real_leak "password in the URL port slot" PGHOST=127.0.0.1 PGUSER=dsa PGDATABASE=audit "PGPASSWORD=${SECRET}" "DATABASE_URL=$MAL_URL2"
  real_leak "%GG password, nothing listening" PGHOST=127.0.0.1 PGPORT=1 PGUSER=dsa PGDATABASE=audit "PGPASSWORD=${SECRET}%GG"
  real_leak "unresolvable host" PGHOST=t1219-no-such-host.invalid PGUSER=dsa PGDATABASE=audit "PGPASSWORD=${SECRET}"
fi

# ── sol r1 P2: loop mode + disabled idles quietly (restart: unless-stopped) ──
# The Compose service runs in loop mode. Disabled, it must log ONE line and
# keep running (no exit -> no restart loop), touch no database, and stop
# cleanly on SIGTERM, taking its sleep child with it.
cat > "$STUBDIR/psql" <<EOF
#!/bin/sh
echo called >> "$WK/psql-called"
exit 99
EOF
chmod +x "$STUBDIR/psql"
rm -f "$WK/psql-called" "$WK/idle.out"
# perl alarm + exec (not the tmo function): every step execs, so $! IS the
# script's shell — a backgrounded shell function would be a subshell wrapper.
perl -e 'alarm shift; exec @ARGV' 60 env -i PATH="$STUBDIR:/usr/bin:/bin" "${CONN[@]}" \
  LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false \
  LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_INTERVAL_SECONDS=86400 \
  sh "$SCRIPT" > "$WK/idle.out" 2>&1 &
IDLE_PID=$!
sleep 3
if kill -0 "$IDLE_PID" 2>/dev/null; then
  ok "loop mode + ENABLED=false: still running after 3 s (no exit, so no restart loop)"
  IDLE_CHILD="$(pgrep -P "$IDLE_PID" 2>/dev/null | head -1 || true)"
  kill -TERM "$IDLE_PID" 2>/dev/null || true
  wait "$IDLE_PID" && IDLE_RC=0 || IDLE_RC=$?
  [ "$IDLE_RC" = 0 ] && ok "idle process stops on SIGTERM with exit 0" || bad "idle process exit $IDLE_RC on SIGTERM"
  if [ -n "$IDLE_CHILD" ]; then
    sleep 1
    if kill -0 "$IDLE_CHILD" 2>/dev/null; then
      bad "idle sleep child $IDLE_CHILD survived SIGTERM"
      kill "$IDLE_CHILD" 2>/dev/null || true
    else
      ok "idle sleep child stopped with it"
    fi
  fi
else
  wait "$IDLE_PID" 2>/dev/null && IDLE_RC=0 || IDLE_RC=$?
  bad "loop mode + ENABLED=false exited (rc=$IDLE_RC) — under a restart policy that is a restart loop"
fi
[ "$(grep -c "level=INFO disabled" "$WK/idle.out")" = 1 ] && ok "idle: exactly one disabled line" || bad "idle: disabled line count $(grep -c "level=INFO disabled" "$WK/idle.out")"
[ -f "$WK/psql-called" ] && bad "idle: psql was called" || ok "idle: database never contacted"

# Doctor pre-flight (bin/lucairn check_audit_claim_delivery_retention): silent
# on a valid env, fails on values the service would refuse or a missing script.
doctor_check() { # <env file> [compose file]
  local envf="$1" composef="${2:-}"
  (
    set --                      # empty args -> the sourced CLI's main is inert
    # shellcheck disable=SC1091
    source "$ROOT/bin/lucairn" >/dev/null 2>&1
    check_audit_claim_delivery_retention "$envf" "$composef" 2>&1
  )
}
denv() { printf '%s\n' "$@" > "$WK/doctor.env"; }
denv "POSTGRES_AUDIT_PASSWORD=x"
out="$(doctor_check "$WK/doctor.env" "$COMPOSE")" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "doctor: defaults pass silently" || bad "doctor defaults: rc=$rc out=$out"
denv "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS=7" "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false"
out="$(doctor_check "$WK/doctor.env" "$COMPOSE")" && rc=0 || rc=$?
[ "$rc" = 0 ] && ok "doctor: DAYS=7 ENABLED=false pass" || bad "doctor valid overrides: rc=$rc out=$out"
# sol r1 P2: doctor must agree with the runtime — disabled, the service never
# reads DAYS (A: ENABLED=false DAYS=0 exits 0), so doctor must not fail on it,
# and must not tell the operator to set the flag that is already false.
for v in 0 -3 030 abc; do
  denv "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false" "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS=$v"
  out="$(doctor_check "$WK/doctor.env" "$COMPOSE")" && rc=0 || rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "audit retention: disabled"; then
    ok "doctor: ENABLED=false DAYS=$v passes and reports the sweep disabled (matches the runtime)"
  else
    bad "doctor: ENABLED=false DAYS=$v rc=$rc out=$out (the runtime accepts this)"
  fi
done
for v in 0 -3 030 abc 36501; do
  denv "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS=$v"
  out="$(doctor_check "$WK/doctor.env" "$COMPOSE")" && rc=0 || rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "audit retention" && ok "doctor: DAYS=$v flagged" || bad "doctor: DAYS=$v not flagged"
done
denv "LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=yes"
out="$(doctor_check "$WK/doctor.env" "$COMPOSE")" && rc=0 || rc=$?
[ "$rc" != 0 ] && ok "doctor: ENABLED=yes flagged" || bad "doctor: ENABLED=yes not flagged"
# sol r1 P2: the script checked must be the one Compose mounts — beside the
# SELECTED compose file — with no fallback to this checkout's copy (which
# exists: ROOT is the kit root and keeps its scripts/ here).
mkdir -p "$WK/fake-install"
cp "$COMPOSE" "$WK/fake-install/docker-compose.customer.yml"
denv "POSTGRES_AUDIT_PASSWORD=x"
[ -f "$ROOT/scripts/audit-claim-delivery-retention.sh" ] || die "kit copy of the script missing"
out="$(doctor_check "$WK/doctor.env" "$WK/fake-install/docker-compose.customer.yml")" && rc=0 || rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "missing beside" \
  && ok "doctor: script missing beside the selected compose file is flagged although the kit checkout has one" \
  || bad "doctor: missing script not flagged (rc=$rc) — it fell back to the checkout copy"
mkdir -p "$WK/fake-install/scripts"
cp "$SCRIPT" "$WK/fake-install/scripts/"
out="$(doctor_check "$WK/doctor.env" "$WK/fake-install/docker-compose.customer.yml")" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "doctor: script present beside the selected compose file passes" || bad "doctor with the script in place: rc=$rc out=$out"

# ═══════════════════════════════════════════════════════════════════════════
echo "== B. Helm CronJob (helm template) =="
# ═══════════════════════════════════════════════════════════════════════════

CJ_NAME="audit-claim-delivery-retention"
if ! command -v helm >/dev/null 2>&1; then
  skip "helm not installed — Helm acceptance (B) NOT RUN"
else
  COMMON=(
    --set "global.imagePullDockerConfigJson=x"
    --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
    "${HELM_TEST_SECRET_ARGS[@]}"
  )
  render() { tmo 180 helm template lucairn "$CHART" -f "$VALUES" "${COMMON[@]}" "$@"; }

  # cj_query <render file> — prints a JSON summary of the retention CronJob
  # (or "absent"), via PyYAML.
  cj_query() {
    python3 - "$1" "$CHART_SCRIPT" <<'PY'
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
script = open(sys.argv[2]).read()
cjs = [d for d in docs if d.get("kind") == "CronJob" and d["metadata"]["name"] == "audit-claim-delivery-retention"]
sts = [d for d in docs if d.get("kind") == "StatefulSet" and d["metadata"]["name"] == "audit-postgresql"]
if not cjs:
    print("absent"); sys.exit(0)
cj = cjs[0]
pod = cj["spec"]["jobTemplate"]["spec"]["template"]["spec"]
c = pod["containers"][0]
env = {e["name"]: e for e in c.get("env", [])}
out = {
  "count": len(cjs),
  "namespace": cj["metadata"]["namespace"],
  "schedule": cj["spec"]["schedule"],
  "concurrency": cj["spec"].get("concurrencyPolicy"),
  "image": c["image"],
  "pg_image": sts[0]["spec"]["template"]["spec"]["containers"][0]["image"] if sts else None,
  "script_identical": c["args"][0] == script,
  "command": c["command"],
  "days": env.get("LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS", {}).get("value"),
  "enabled": env.get("LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED", {}).get("value"),
  "has_database_url": "DATABASE_URL" in env,
  "pg": {k: env.get(k, {}).get("value") for k in ("PGHOST", "PGPORT", "PGUSER", "PGDATABASE", "PGSSLMODE")},
  "pw_ref": env.get("PGPASSWORD", {}).get("valueFrom", {}).get("secretKeyRef"),
  "run_as_non_root": pod["securityContext"].get("runAsNonRoot"),
  "automount": pod.get("automountServiceAccountToken"),
  "ro_rootfs": c["securityContext"].get("readOnlyRootFilesystem"),
}
print(json.dumps(out, sort_keys=True))
PY
  }

  R="$WK/r-default.yaml"
  if render > "$R" 2>"$WK/r-default.err"; then
    J="$(cj_query "$R")"
    if [ "$J" = "absent" ]; then
      bad "default render has no $CJ_NAME CronJob"
    else
      jget() { printf '%s' "$J" | python3 -c "import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print(json.dumps(v) if not isinstance(v,str) else v)" "$1"; }
      [ "$(jget count)" = 1 ] && ok "default render: exactly one $CJ_NAME CronJob" || bad "CronJob count $(jget count)"
      [ "$(jget namespace)" = dsa-audit ] && ok "runs in the audit namespace (dsa-audit)" || bad "namespace $(jget namespace)"
      [ "$(jget schedule)" = "17 3 * * *" ] && ok "daily schedule 17 3 * * *" || bad "schedule $(jget schedule)"
      [ "$(jget concurrency)" = Forbid ] && ok "concurrencyPolicy Forbid" || bad "concurrencyPolicy $(jget concurrency)"
      [ "$(jget image)" = "$MANIFEST_PG" ] && ok "image = the manifest-pinned $(jget image)" \
        || bad "image $(jget image) != the digest image-manifest.yaml records ($MANIFEST_PG)"
      [ "$(jget image)" = "$(jget pg_image)@${MANIFEST_PG#*@}" ] && ok "same postgres:16-alpine as the bundled audit Postgres (no new image), plus the digest" \
        || bad "image $(jget image) is not the bundled Postgres image $(jget pg_image) + digest"
      [ "$(jget script_identical)" = true ] && ok "CronJob embeds the sweep script byte-for-byte" || bad "embedded script differs from files/audit-claim-delivery-retention.sh"
      [ "$(jget days)" = 30 ] && ok "default retention 30 days" || bad "days $(jget days)"
      [ "$(jget enabled)" = true ] && ok "ENABLED=true in the pod" || bad "enabled $(jget enabled)"
      [ "$(jget has_database_url)" = false ] && ok "no DATABASE_URL in the pod (no URL ever reaches libpq)" || bad "the pod still gets DATABASE_URL"
      [ "$(jget pg)" = '{"PGDATABASE": "audit", "PGHOST": "audit-postgresql", "PGPORT": "5432", "PGSSLMODE": "disable", "PGUSER": "dsa"}' ] \
        && ok "discrete PGHOST/PGPORT/PGUSER/PGDATABASE/PGSSLMODE = dsa@audit-postgresql:5432/audit" || bad "pg settings $(jget pg)"
      [ "$(jget pw_ref)" = '{"key": "POSTGRES_PASSWORD", "name": "audit-credentials"}' ] \
        && ok "PGPASSWORD from audit-credentials/POSTGRES_PASSWORD (the dsa password the StatefulSet uses)" || bad "password ref $(jget pw_ref)"
      [ "$(jget run_as_non_root)" = true ] && [ "$(jget automount)" = false ] && [ "$(jget ro_rootfs)" = true ] \
        && ok "non-root, no SA token, read-only rootfs" || bad "pod hardening missing"
    fi
  else
    bad "default render failed: $(tail -3 "$WK/r-default.err")"
  fi

  expect_absent() { # <label> <helm args...>
    local label="$1"; shift
    local f="$WK/r-absent.yaml"
    if render "$@" > "$f" 2>"$WK/r-absent.err"; then
      [ "$(cj_query "$f")" = absent ] && ok "$label renders no retention CronJob" || bad "$label still rendered the CronJob"
    else
      bad "$label: render failed: $(tail -3 "$WK/r-absent.err")"
    fi
  }
  expect_absent "enabled=false" --set audit.claimDeliveryRetention.enabled=false
  expect_absent "external Postgres (audit.postgresql.enabled=false)" \
    --set audit.postgresql.enabled=false --set "audit.external.databaseUrl=postgres://dsa:x@db.example.invalid:5432/audit"
  expect_absent "audit.enabled=false" --set audit.enabled=false

  expect_days() { # <want> <helm args...>
    local want="$1"; shift
    local f="$WK/r-days.yaml"
    if render "$@" > "$f" 2>"$WK/r-days.err"; then
      local got
      got="$(cj_query "$f" | python3 -c "import json,sys; print(json.load(sys.stdin)['days'])" 2>/dev/null)"
      [ "$got" = "$want" ] && ok "retention $want days accepted ($*)" || bad "retention ($*): got '$got', want '$want'"
    else
      bad "retention $want refused ($*): $(tail -3 "$WK/r-days.err")"
    fi
  }
  expect_days 1 --set audit.claimDeliveryRetention.retention=1d
  expect_days 7 --set audit.claimDeliveryRetention.retention=7d
  expect_days 36500 --set audit.claimDeliveryRetention.retention=36500d

  expect_refused() { # <label> <helm args...>
    local label="$1"; shift
    if render "$@" > /dev/null 2>"$WK/r-refused.err"; then
      bad "$label was NOT refused"
    elif grep -q "claimDeliveryRetention" "$WK/r-refused.err"; then
      ok "$label refused at render time"
    else
      bad "$label failed for an unrelated reason: $(tail -2 "$WK/r-refused.err")"
    fi
  }
  expect_refused "retention=0d" --set audit.claimDeliveryRetention.retention=0d
  expect_refused "retention=-1d" --set-string audit.claimDeliveryRetention.retention=-1d
  expect_refused "retention=1.5d" --set audit.claimDeliveryRetention.retention=1.5d
  expect_refused "retention=030d (leading zero)" --set audit.claimDeliveryRetention.retention=030d
  expect_refused "retention=abc" --set-string audit.claimDeliveryRetention.retention=abc
  expect_refused "retention=36501d" --set audit.claimDeliveryRetention.retention=36501d
  expect_refused "retention=30 (--set number)" --set audit.claimDeliveryRetention.retention=30
  expect_refused "retention=030 (--set-string, no unit)" --set-string audit.claimDeliveryRetention.retention=030
  expect_refused "retention=true" --set audit.claimDeliveryRetention.retention=true

  # sol r1 P1 — values FILES. YAML 1.1 parses these before any template sees
  # them (030 -> 24 octal, 0x1E -> 30 hex, 3e1 / 30.0 -> float, true -> bool):
  # every one must be REFUSED, never rendered as some other number. On a3cff3c
  # `retentionDays: 030` in a file rendered 24 days.
  vfile() { # <yaml scalar line under claimDeliveryRetention>
    printf 'audit:\n  claimDeliveryRetention:\n    %s\n' "$1" > "$WK/v-ret.yaml"
    printf '%s' "$WK/v-ret.yaml"
  }
  for line in 'retention: 030' 'retention: 0x1E' 'retention: 3e1' 'retention: 30.0' 'retention: true' \
              'retention: 30' 'retention: 0o36' 'retention: "030d"' 'retention: 0d' 'retention: "-1d"' \
              'retention: 1.5d' 'retention: 30D' 'retention: "30 d"' 'retention: ""' 'retention: 36501d' \
              'retentionDays: 030' 'retentionDays: 30'; do
    f="$(vfile "$line")"
    if render -f "$f" > "$WK/r-vfile.yaml" 2>"$WK/r-vfile.err"; then
      got="$(cj_query "$WK/r-vfile.yaml" | python3 -c "import json,sys; print(json.load(sys.stdin)['days'])" 2>/dev/null)"
      bad "values file '$line' was NOT refused (rendered days='$got')"
    elif grep -q "claimDeliveryRetention" "$WK/r-vfile.err"; then
      ok "values file '$line' refused at render time"
    else
      bad "values file '$line' failed for an unrelated reason: $(tail -2 "$WK/r-vfile.err")"
    fi
  done
  expect_days 30 -f "$(vfile 'retention: 30d')"
  expect_days 7 -f "$(vfile 'retention: "7d"')"
  expect_days 36500 -f "$(vfile 'retention: 36500d')"
  # null: Helm 4 deletes the key (→ refused as "not set"); Helm 3 restores the
  # sub-chart default 30d (see _migration-cap.tpl, T-691). Both are safe; what
  # must never happen is a render with any other value.
  if render --set audit.claimDeliveryRetention.retention=null > "$WK/r-null.yaml" 2>"$WK/r-null.err"; then
    got="$(cj_query "$WK/r-null.yaml" | python3 -c "import json,sys; print(json.load(sys.stdin)['days'])" 2>/dev/null)"
    [ "$got" = 30 ] && ok "retention=null falls back to the default 30d (this Helm major)" || bad "retention=null rendered days='$got'"
  elif grep -q "claimDeliveryRetention.retention is not set" "$WK/r-null.err"; then
    ok "retention=null refused as not set (this Helm major)"
  else
    bad "retention=null failed for an unrelated reason: $(tail -2 "$WK/r-null.err")"
  fi
  expect_refused "enabled=\"false\" (string)" --set-string audit.claimDeliveryRetention.enabled=false
  expect_refused "schedule=\"\"" --set-string audit.claimDeliveryRetention.schedule=
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "== C. Compose service definition (docker compose config) =="
# ═══════════════════════════════════════════════════════════════════════════

compose_json() { # <env file> [-f overlay ...]
  local envf="$1"; shift
  tmo 120 docker compose -f "$COMPOSE" "$@" --env-file "$envf" config --format json
}
HAVE_COMPOSE=0
if command -v docker >/dev/null 2>&1 && tmo 30 docker compose version >/dev/null 2>&1; then
  HAVE_COMPOSE=1
fi
if [ "$HAVE_COMPOSE" != 1 ]; then
  skip "docker compose CLI not available — Compose definition checks (C) NOT RUN"
else
  CJ="$WK/compose.json"
  if compose_json "$ROOT/customer.env.example" > "$CJ" 2>"$WK/compose.err"; then
    EXPECTED_PW="$(sed -n 's/^POSTGRES_AUDIT_PASSWORD=//p' "$ROOT/customer.env.example" | tail -1)"
    python3 - "$CJ" "$MANIFEST_PG" "$EXPECTED_PW" > "$WK/compose-check.txt" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["services"]
manifest_pg, expected_pw = sys.argv[2], sys.argv[3]
s = c.get("audit-claim-delivery-retention")
def p(ok, msg): print(("ok " if ok else "FAIL ") + msg)
if not s:
    p(False, "service audit-claim-delivery-retention missing"); sys.exit(0)
p(s["image"] == manifest_pg, "image pinned to the manifest digest (%s)" % s["image"])
p(s["image"].split("@")[0] == c["postgres-audit"]["image"].split("@")[0], "same postgres:16-alpine as postgres-audit (no new image)")
p(s.get("entrypoint") == ["/bin/sh", "/scripts/audit-claim-delivery-retention.sh"], "entrypoint runs the mounted script")
vols = s.get("volumes", [])
p(any(v.get("target") == "/scripts/audit-claim-delivery-retention.sh" and v.get("source", "").endswith("/scripts/audit-claim-delivery-retention.sh") and v.get("read_only") for v in vols), "script mounted read-only from scripts/")
p(list((s.get("networks") or {}).keys()) == ["dsa-audit"], "only on the dsa-audit network")
d = (s.get("depends_on") or {}).get("migrate-audit", {})
p(d.get("condition") == "service_completed_successfully", "waits for migrate-audit to complete")
env = s.get("environment", {})
p(env.get("LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS") == "30", "default DAYS=30")
p(env.get("LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED") == "true", "default ENABLED=true")
p(env.get("LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_INTERVAL_SECONDS") == "86400", "loops daily (86400 s)")
p("DATABASE_URL" not in env, "no DATABASE_URL (no URL ever reaches libpq)")
p((env.get("PGHOST"), env.get("PGPORT"), env.get("PGUSER"), env.get("PGDATABASE"), env.get("PGSSLMODE")) == ("postgres-audit", "5432", "dsa", "audit", "disable"),
  "discrete PGHOST/PGPORT/PGUSER/PGDATABASE/PGSSLMODE = dsa@postgres-audit:5432/audit")
p(bool(expected_pw) and env.get("PGPASSWORD") == expected_pw, "PGPASSWORD = POSTGRES_AUDIT_PASSWORD (same value postgres-audit uses)")
p(s.get("restart") == "unless-stopped", "restart unless-stopped (survives a Docker daemon restart; disabled idles instead of exiting)")
p(s.get("user") == "65534:65534" and s.get("read_only") is True, "non-root user + read-only rootfs")
PY
    while IFS= read -r line; do
      case "$line" in ok\ *) ok "compose: ${line#ok }" ;; *) bad "compose: ${line#FAIL }" ;; esac
    done < "$WK/compose-check.txt"
  else
    bad "docker compose config failed: $(tail -3 "$WK/compose.err")"
  fi
  # Overrides flow through the shipped env names.
  cp "$ROOT/customer.env.example" "$WK/override.env"
  printf '\nLUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS=7\nLUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED=false\n' >> "$WK/override.env"
  if compose_json "$WK/override.env" > "$WK/compose-ovr.json" 2>/dev/null; then
    got="$(jq -r '.services["audit-claim-delivery-retention"].environment | "\(.LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_DAYS) \(.LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_ENABLED)"' "$WK/compose-ovr.json")"
    [ "$got" = "7 false" ] && ok "compose: customer.env overrides reach the service (DAYS=7 ENABLED=false)" || bad "compose override: got '$got'"
  else
    bad "docker compose config with overrides failed"
  fi
  # Present in the self-hosted topology too (it is defined in the base file).
  if compose_json "$ROOT/customer.env.example" -f "$ROOT/docker-compose.self-hosted.yml" > "$WK/compose-sh.json" 2>/dev/null \
     && jq -e '.services["audit-claim-delivery-retention"]' "$WK/compose-sh.json" >/dev/null; then
    ok "compose: service present with the self-hosted overlay"
  else
    bad "compose: service missing with the self-hosted overlay"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "== D. real Postgres (synthetic data) =="
# ═══════════════════════════════════════════════════════════════════════════

MODE=""
if command -v docker >/dev/null 2>&1 && tmo 20 docker info >/dev/null 2>&1; then
  MODE=local
elif [ -n "${T1219_DOCKER_SSH:-}" ]; then
  MODE=remote
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
[ -n "${T1219_DOCKER_SSH_KEY:-}" ] && SSH_OPTS+=(-i "$T1219_DOCKER_SSH_KEY")

# dk <docker args...> — docker locally or on the remote host. stdin passes through.
dk() {
  if [ "$MODE" = local ]; then
    tmo 300 docker "$@"
  else
    tmo 300 ssh "${SSH_OPTS[@]}" "$T1219_DOCKER_SSH" "docker $(printf '%q ' "$@")"
  fi
}
# rsh <shell command> — run on the docker host (remote) or locally.
rsh() {
  if [ "$MODE" = local ]; then
    tmo 60 sh -c "$1"
  else
    tmo 60 ssh "${SSH_OPTS[@]}" "$T1219_DOCKER_SSH" "$1"
  fi
}
# put <local file> <docker-host path> (mode 600)
put() {
  if [ "$MODE" = local ]; then
    cp "$1" "$2" && chmod 600 "$2"
  else
    tmo 60 ssh "${SSH_OPTS[@]}" "$T1219_DOCKER_SSH" "umask 077; cat > $(printf '%q' "$2")" < "$1"
  fi
}

PG_RUN=0
if [ -z "$MODE" ]; then
  if [ "${T1219_REQUIRE_PG:-0}" = 1 ]; then
    bad "real-Postgres acceptance required (T1219_REQUIRE_PG=1) but no docker daemon and no T1219_DOCKER_SSH"
  else
    skip "no docker daemon here and T1219_DOCKER_SSH unset — REAL-POSTGRES ACCEPTANCE (D) NOT RUN. This is NOT a pass for the database behaviour."
  fi
elif ! command -v python3 >/dev/null 2>&1; then
  bad "python3 needed for D"
else
  PG_RUN=1
fi

if [ "$PG_RUN" = 1 ]; then
  PG_IMAGE="$(python3 - "$ROOT/image-manifest.yaml" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
def find(o):
    if isinstance(o, dict):
        if "enterprise_kind" in o:
            return o["enterprise_kind"]["postgres"]
        for v in o.values():
            r = find(v)
            if r: return r
pg = find(m)
ref, dig = pg["ref"], pg["digest"]
print(ref.split(":")[0] + "@" + dig)
PY
)"
  case "$PG_IMAGE" in postgres@sha256:*) ok "Postgres image pinned by the kit: $PG_IMAGE ($MODE docker)" ;; *) die "could not read the pinned Postgres digest from image-manifest.yaml" ;; esac

  SFX="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  NET="t1219-net-$SFX"
  PG="t1219-pg-$SFX"
  SVCC="t1219-svc-$SFX"
  PGPW="t1219$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  APPPW="t1219app$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  if [ "$MODE" = local ]; then
    HOSTDIR="$WK/hostdir"; mkdir -p "$HOSTDIR"; chmod 755 "$HOSTDIR"
  else
    HOSTDIR="$(rsh 'umask 022; mktemp -d "$HOME/t1219-XXXXXXXX"')" || die "cannot create the remote temp dir"
    case "$HOSTDIR" in */t1219-*) ;; *) die "unexpected remote temp dir '$HOSTDIR'" ;; esac
    rsh "chmod 755 $(printf '%q' "$HOSTDIR")" || true
  fi
  IMAGE_WAS_PRESENT=0
  dk image inspect "$PG_IMAGE" >/dev/null 2>&1 && IMAGE_WAS_PRESENT=1

  cleanup_pg() {
    dk rm -f "$SVCC" >/dev/null 2>&1 || true
    dk rm -f "$PG" >/dev/null 2>&1 || true
    dk network rm "$NET" >/dev/null 2>&1 || true
    if [ "$MODE" = remote ]; then
      rsh "rm -rf $(printf '%q' "$HOSTDIR")" || true
      [ "$IMAGE_WAS_PRESENT" = 1 ] || dk image rm "$PG_IMAGE" >/dev/null 2>&1 || true
    fi
  }
  trap 'cleanup_pg; rm -rf "$WK"' EXIT

  # psql as dsa inside the Postgres container (unix socket). SQL on stdin.
  q() { dk exec -i "$PG" psql -X -q -t -A -v ON_ERROR_STOP=1 -U dsa -d audit; }
  # psql as audit_app over TCP with its password (the runtime role).
  qapp() { dk exec -i -e "PGPASSWORD=$APPPW" "$PG" psql -X -q -t -A -v ON_ERROR_STOP=1 -h 127.0.0.1 -U audit_app -d audit; }

  dk network create --internal "$NET" >/dev/null || die "docker network create failed"
  dk pull -q "$PG_IMAGE" >/dev/null || die "pulling $PG_IMAGE failed"
  dk run -d --name "$PG" --network "$NET" --network-alias postgres-audit \
    -e POSTGRES_USER=dsa -e "POSTGRES_PASSWORD=$PGPW" -e POSTGRES_DB=audit \
    "$PG_IMAGE" >/dev/null || die "starting the throwaway Postgres failed"
  ready=0
  for _ in $(seq 1 90); do
    if dk exec "$PG" pg_isready -h 127.0.0.1 -U dsa -d audit >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "throwaway Postgres never became ready"
  ok "throwaway Postgres $PG up (no published ports, network $NET)"

  # ── migrations 1..CEILING_AUDIT, rendered the way the kit renders them ─────
  CEIL="$(sed -n 's/^CEILING_AUDIT=//p' "$ROOT/scripts/migration-ceilings.conf")"
  [ -n "$CEIL" ] || die "CEILING_AUDIT not found"
  mkdir -p "$WK/rendered"
  SRC_ROOT="$ROOT/migrations" OUT_ROOT="$WK/rendered" AUDIT_APP_PASSWORD="$APPPW" VEIL_APP_PASSWORD="t1219-unused" \
    tmo 60 sh "$ROOT/scripts/render-migrations.sh" >/dev/null 2>&1 || die "scripts/render-migrations.sh failed"
  applied=0
  for v in $(seq 1 "$CEIL"); do
    f=""
    for cand in "$WK/rendered/audit/$(printf '%06d' "$v")"_*.up.sql; do
      [ -f "$cand" ] && { f="${cand##*/}"; break; }
    done
    [ -n "$f" ] || die "no rendered audit migration for version $v"
    # One transaction per file, as golang-migrate's single Exec does.
    dk exec -i "$PG" psql -X -q -1 -v ON_ERROR_STOP=1 -U dsa -d audit < "$WK/rendered/audit/$f" >/dev/null 2>"$WK/mig.err" \
      || die "migration $f failed: $(head -3 "$WK/mig.err")"
    applied=$((applied + 1))
  done
  [ "$(printf 'SELECT to_regclass($$public.audit_claim_deliveries$$) IS NOT NULL;\n' | q)" = t ] \
    && ok "applied audit migrations 1..$CEIL ($applied files); audit_claim_deliveries exists" \
    || die "audit_claim_deliveries missing after migrations"

  # ── synthetic seed ─────────────────────────────────────────────────────────
  # Categories (cat column in a helper table so assertions can address them):
  #   old_delivered   11 DELIVERED, delivered_at 40 d ago (10 with both payload
  #                   columns, 1 with claim_raw only)
  #   new_delivered    3 DELIVERED, delivered_at 5 d ago
  #   null_delivered   1 DELIVERED, delivered_at NULL (never matches the cutoff)
  #   old_pending      2 PENDING created 40 d ago
  #   old_delivering   2 DELIVERING created 40 d ago
  #   old_parked       2 PARKED parked_at 40 d ago
  #   new_parked       1 PARKED parked_at 5 d ago
  q > /dev/null <<'SQL' || die "seeding synthetic rows failed"
CREATE TABLE t1219_cat (event_id text PRIMARY KEY, cat text NOT NULL);
DO $$
DECLARE
  spec text[] := ARRAY[
    'old_delivered:11', 'new_delivered:3', 'null_delivered:1', 'old_pending:2',
    'old_delivering:2', 'old_parked:2', 'new_parked:1'];
  s text; c text; n int; i int; eid text; rid text;
BEGIN
  FOREACH s IN ARRAY spec LOOP
    c := split_part(s, ':', 1); n := split_part(s, ':', 2)::int;
    FOR i IN 1..n LOOP
      eid := 'evt_completion_t1219_' || c || '_' || i;
      rid := 'req_t1219_synthetic_' || c || '_' || i;
      INSERT INTO audit_events (event_id, event_type, source_service, actor, event_hash, payload, request_id, timestamp, created_at)
      VALUES (eid, 'PROXY_INFERENCE_COMPLETED', 'gateway', 'synthetic-actor', md5(eid), convert_to('{"request_id":"' || rid || '"}', 'UTF8'), rid,
              now() - interval '41 days', now() - interval '41 days');
      INSERT INTO t1219_cat VALUES (eid, c);
      INSERT INTO audit_claim_deliveries (event_id, request_id, output_scan_body, claim_raw, delivery_state,
                                          delivery_attempt_id, delivery_lease_until, attempt_count, delivered_at, parked_at,
                                          next_attempt_at, created_at, updated_at)
      VALUES (eid, rid,
              CASE WHEN c = 'old_delivered' AND i = 11 THEN NULL ELSE convert_to('{"synthetic_scan":' || i || '}', 'UTF8') END,
              convert_to('synthetic-claim-bytes-' || eid, 'UTF8'),
              CASE WHEN c LIKE '%delivered' THEN 'DELIVERED' WHEN c = 'old_pending' THEN 'PENDING'
                   WHEN c = 'old_delivering' THEN 'DELIVERING' ELSE 'PARKED' END,
              CASE WHEN c = 'old_delivering' THEN 'attempt-' || i END,
              CASE WHEN c = 'old_delivering' THEN now() + interval '5 minutes' END,
              CASE WHEN c LIKE '%parked' THEN 5 ELSE 1 END,
              CASE WHEN c = 'old_delivered' THEN now() - interval '40 days'
                   WHEN c = 'new_delivered' THEN now() - interval '5 days' END,
              CASE WHEN c = 'old_parked' THEN now() - interval '40 days'
                   WHEN c = 'new_parked' THEN now() - interval '5 days' END,
              CASE WHEN c = 'old_pending' THEN now() + interval '1 hour' ELSE now() - interval '40 days' END,
              now() - interval '40 days', now() - interval '40 days');
    END LOOP;
  END LOOP;
END $$;
SQL
  # Snapshot helpers.
  state_counts() { printf "SELECT string_agg(delivery_state || '=' || n, ',' ORDER BY delivery_state) FROM (SELECT delivery_state, count(*) n FROM audit_claim_deliveries GROUP BY 1) x;\n" | q; }
  events_fp() { printf "SELECT count(*) || ':' || md5(string_agg(id || '|' || event_id || '|' || event_hash || '|' || encode(coalesce(payload, ''::bytea), 'hex'), ',' ORDER BY id)) FROM audit_events;\n" | q; }
  # Full-content fingerprint of every row that must NOT change.
  untouched_fp() { printf "SELECT md5(string_agg(row_to_json(d)::text, ',' ORDER BY d.event_id)) FROM audit_claim_deliveries d JOIN t1219_cat c USING (event_id) WHERE c.cat NOT IN ('old_delivered', 'd2');\n" | q; }
  STATES_BEFORE="$(state_counts)"
  EVENTS_BEFORE="$(events_fp)"
  UNTOUCHED_BEFORE="$(untouched_fp)"
  ROWS_BEFORE="$(printf 'SELECT count(*) FROM audit_claim_deliveries;\n' | q)"
  echo "  seeded: rows=$ROWS_BEFORE states[$STATES_BEFORE] audit_events=${EVENTS_BEFORE%%:*}"

  # ── run 1: the sweep as dsa (batch size 4 → 3 batches over 11 rows) ────────
  dk exec -i "$PG" sh -c 'cat > /tmp/t1219-sweep.sh && chmod 644 /tmp/t1219-sweep.sh' < "$SCRIPT" || die "copying the sweep into the container failed"
  run_sweep_exec() {
    dk exec -u 65534:65534 -e HOME=/tmp -e PGHOST=127.0.0.1 -e PGPORT=5432 -e PGUSER=dsa -e PGDATABASE=audit \
      -e PGSSLMODE=disable -e "PGPASSWORD=$PGPW" -e LUCAIRN_AUDIT_CLAIM_DELIVERY_RETENTION_BATCH_SIZE=4 \
      "$PG" sh /tmp/t1219-sweep.sh --once 2>&1
  }
  OUT1="$(run_sweep_exec)" && RC1=0 || RC1=$?
  echo "  sweep run 1 (rc=$RC1): $OUT1"
  [ "$RC1" = 0 ] && ok "sweep run 1 exited 0" || bad "sweep run 1 exit $RC1"
  [ "$(printf '%s\n' "$OUT1" | grep -c "audit-claim-delivery-retention: level=")" = 1 ] && ok "exactly one result line" || bad "expected one result line"
  case "$OUT1" in *"level=WARN"*"retention_days=30 delivered_blanked=11 batches=3 parked_older_than_retention=2"*) ok "run 1 line: WARN, 11 blanked in 3 batches, 2 old PARKED reported" ;; *) bad "run 1 line unexpected" ;; esac
  case "$OUT1" in *"$PGPW"*|*evt_completion*|*synthetic-claim*|*req_t1219*) bad "the log line carries a secret or row content" ;; *) ok "log line carries no row content and no DSN" ;; esac

  OLD_STATE="$(printf "SELECT count(*) FILTER (WHERE d.delivery_state='DELIVERED' AND d.claim_raw IS NULL AND d.output_scan_body IS NULL) || '/' || count(*) FROM audit_claim_deliveries d JOIN t1219_cat c USING (event_id) WHERE c.cat='old_delivered';\n" | q)"
  [ "$OLD_STATE" = "11/11" ] && ok "old DELIVERED: 11/11 rows still present, still DELIVERED, both columns NULL" || bad "old DELIVERED state $OLD_STATE"
  ROWS_AFTER="$(printf 'SELECT count(*) FROM audit_claim_deliveries;\n' | q)"
  [ "$ROWS_AFTER" = "$ROWS_BEFORE" ] && ok "no row deleted ($ROWS_AFTER rows before and after)" || bad "row count $ROWS_BEFORE -> $ROWS_AFTER"
  [ "$(state_counts)" = "$STATES_BEFORE" ] && ok "state counts unchanged [$STATES_BEFORE]" || bad "state counts changed: $(state_counts)"
  [ "$(untouched_fp)" = "$UNTOUCHED_BEFORE" ] && ok "new DELIVERED, NULL-delivered_at, PENDING, DELIVERING and all PARKED rows byte-for-byte unchanged" || bad "a row that must not change was modified"
  [ "$(events_fp)" = "$EVENTS_BEFORE" ] && ok "audit_events unchanged (count + content hash)" || bad "audit_events changed"

  # ── run 2: idempotent ─────────────────────────────────────────────────────
  OUT2="$(run_sweep_exec)" && RC2=0 || RC2=$?
  echo "  sweep run 2 (rc=$RC2): $OUT2"
  case "$OUT2" in *"delivered_blanked=0 batches=1 parked_older_than_retention=2"*) ok "run 2 blanks nothing (idempotent)" ;; *) bad "run 2 unexpected" ;; esac

  # ── sol r1 P1 on the shipped image's own psql/libpq ─────────────────────
  # Malformed / wrong synthetic credentials against the live throwaway server:
  # non-zero exit, a fixed reason, and the synthetic password in NO output.
  leak_exec() { # <label> <want reason or "refused"> <docker exec -e args...>
    local label="$1" want="$2"; shift 2
    local out rc
    out="$(dk exec -u 65534:65534 -e HOME=/tmp "$@" "$PG" sh /tmp/t1219-sweep.sh --once 2>&1)" && rc=0 || rc=$?
    [ "$rc" != 0 ] && ok "image psql, $label: non-zero exit ($rc)" || bad "image psql, $label: exit 0"
    no_secret "image psql, $label" "$out"
    case "$want" in
      refused) case "$out" in *FATAL:*) ok "image psql, $label: refused before psql" ;; *) bad "image psql, $label: not refused: $out" ;; esac ;;
      *) case "$out" in *"reason=$want "*) ok "image psql, $label: logged reason=$want" ;; *) bad "image psql, $label: expected reason=$want: $out" ;; esac ;;
    esac
  }
  # The official image TRUSTS loopback (pg_hba), so the wrong-password case
  # dials the container's own network address, where scram-sha-256 applies.
  PG_IP="$(dk inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PG" 2>/dev/null | tr -d '[:space:]')"
  case "$PG_IP" in
    *[!0-9.]*|'') bad "could not read the throwaway Postgres address ('$PG_IP')" ;;
    *) leak_exec "wrong password containing %GG" auth_failed -e "PGHOST=$PG_IP" -e PGUSER=dsa -e PGDATABASE=audit -e "PGPASSWORD=${SECRET}%GG" ;;
  esac
  leak_exec "malformed DATABASE_URL" refused -e PGHOST=127.0.0.1 -e PGUSER=dsa -e PGDATABASE=audit -e "PGPASSWORD=$PGPW" -e "DATABASE_URL=postgres://dsa:${SECRET}%GG@127.0.0.1:5432/audit"
  leak_exec "password in the port" refused -e PGHOST=127.0.0.1 -e "PGPORT=${SECRET}" -e PGUSER=dsa -e PGDATABASE=audit -e "PGPASSWORD=${SECRET}"
  leak_exec "nothing listening" connection_refused -e PGHOST=127.0.0.1 -e PGPORT=1 -e PGUSER=dsa -e PGDATABASE=audit -e "PGPASSWORD=${SECRET}%GG"
  [ "$(state_counts)" = "$STATES_BEFORE" ] && ok "failed runs changed nothing" || bad "state counts changed after the failing runs"

  # ── audit_app: still no DELETE ────────────────────────────────────────────
  BLANKED_ID="evt_completion_t1219_old_delivered_1"
  DEL_OUT="$(printf "DELETE FROM audit_claim_deliveries WHERE event_id = '%s';\n" "$BLANKED_ID" | qapp 2>&1)" && DEL_RC=0 || DEL_RC=$?
  if [ "$DEL_RC" != 0 ] && printf '%s' "$DEL_OUT" | grep -q "permission denied"; then
    ok "audit_app DELETE on audit_claim_deliveries: permission denied"
  else
    bad "audit_app could DELETE (rc=$DEL_RC: $DEL_OUT)"
  fi
  DEL_OUT="$(printf "DELETE FROM audit_events WHERE event_id = '%s';\n" "$BLANKED_ID" | qapp 2>&1)" && DEL_RC=0 || DEL_RC=$?
  [ "$DEL_RC" != 0 ] && ok "audit_app DELETE on audit_events refused" || bad "audit_app could DELETE from audit_events"

  # ── replay of a blanked event through the audit service's own statements ──
  # store.go:252-255 (event insert), :320-322 (outbox insert), :411-416 (lease),
  # :531-540 (retry worker) at DSA 168874d8 — run as audit_app, the runtime role.
  REPLAY_OUT="$(qapp 2>&1 <<SQL
\\set ON_ERROR_STOP 1
WITH ins AS (
  INSERT INTO audit_events (event_id, event_type, source_service, actor, request_id, previous_event_hash, event_hash, payload)
  VALUES ('$BLANKED_ID', 'PROXY_INFERENCE_COMPLETED', 'gateway', 'synthetic-actor', 'req_t1219_synthetic_old_delivered_1', '', 'replayed', '\\x00'::bytea)
  ON CONFLICT (event_id) DO NOTHING RETURNING 1)
SELECT 'events_inserted=' || count(*) FROM ins;
WITH ins AS (
  INSERT INTO audit_claim_deliveries (event_id, request_id, output_scan_body, delivery_state, next_attempt_at)
  VALUES ('$BLANKED_ID', 'req_t1219_synthetic_old_delivered_1', '\\x01'::bytea, 'PENDING', NOW())
  ON CONFLICT (event_id) DO NOTHING RETURNING 1)
SELECT 'outbox_inserted=' || count(*) FROM ins;
WITH lease AS (
  UPDATE audit_claim_deliveries
     SET delivery_state = 'DELIVERING', delivery_attempt_id = 't1219', delivery_lease_until = NOW() + interval '1 minute', updated_at = NOW()
   WHERE event_id = '$BLANKED_ID'
     AND (delivery_state = 'PENDING' OR (delivery_state = 'DELIVERING' AND delivery_lease_until <= NOW()))
  RETURNING 1)
SELECT 'lease_acquired=' || count(*) FROM lease;
SELECT 'retry_selects_blanked=' || count(*)
  FROM audit_claim_deliveries d JOIN audit_events e ON e.event_id = d.event_id
 WHERE ((d.delivery_state = 'PENDING' AND d.next_attempt_at <= NOW())
     OR (d.delivery_state = 'DELIVERING' AND d.delivery_lease_until <= NOW()))
   AND d.claim_raw IS NULL AND d.output_scan_body IS NULL;
SQL
)" && RP_RC=0 || RP_RC=$?
  echo "  replay as audit_app (rc=$RP_RC): $(printf '%s' "$REPLAY_OUT" | tr '\n' ' ')"
  for want in events_inserted=0 outbox_inserted=0 lease_acquired=0 retry_selects_blanked=0; do
    printf '%s\n' "$REPLAY_OUT" | grep -qx "$want" && ok "replay of a blanked event: $want" || bad "replay: expected $want"
  done
  RP_ROW="$(printf "SELECT delivery_state || ':' || (claim_raw IS NULL) || ':' || (output_scan_body IS NULL) FROM audit_claim_deliveries WHERE event_id = '%s';\n" "$BLANKED_ID" | q)"
  [ "$RP_ROW" = "DELIVERED:true:true" ] && ok "after the replay the row is still DELIVERED and blanked" || bad "after replay: $RP_ROW"
  [ "$(printf 'SELECT count(*) FROM audit_claim_deliveries;\n' | q)" = "$ROWS_BEFORE" ] && ok "replay created no row" || bad "replay changed the row count"

  # ── acceptance 2: the Compose service definition, run once ────────────────
  if [ "$HAVE_COMPOSE" != 1 ]; then
    skip "docker compose CLI not available — Compose-shaped real run (D2) NOT RUN"
  else
    # Render the service with an env file whose audit password is this
    # throwaway database's; everything else comes from customer.env.example.
    sed "s|^POSTGRES_AUDIT_PASSWORD=.*|POSTGRES_AUDIT_PASSWORD=$PGPW|" "$ROOT/customer.env.example" > "$WK/d2.env"
    compose_json "$WK/d2.env" > "$WK/d2.json" 2>/dev/null || die "compose config for D2 failed"
    python3 - "$WK/d2.json" "$WK/d2-run.env" "$WK/d2-args" <<'PY' || die "could not extract the compose service"
import json, sys
s = json.load(open(sys.argv[1]))["services"]["audit-claim-delivery-retention"]
with open(sys.argv[2], "w") as f:
    for k, v in sorted(s["environment"].items()):
        f.write("%s=%s\n" % (k, v))
ep = s["entrypoint"]
with open(sys.argv[3], "w") as f:
    f.write("\n".join([s["user"], ep[0]] + ep[1:]) + "\n")
PY
    SVC_USER="$(sed -n 1p "$WK/d2-args")"
    EP0="$(sed -n 2p "$WK/d2-args")"
    EP_REST=()
    while IFS= read -r l; do EP_REST+=("$l"); done < <(sed -n '3,$p' "$WK/d2-args")
    # Two more old DELIVERED rows for this run to blank.
    q > /dev/null <<'SQL' || die "seeding D2 rows failed"
INSERT INTO audit_events (event_id, event_type, source_service, actor, event_hash, payload, request_id)
SELECT 'evt_completion_t1219_d2_' || i, 'PROXY_INFERENCE_COMPLETED', 'gateway', 'synthetic-actor', md5('d2' || i), NULL, 'req_t1219_d2_' || i FROM generate_series(1, 2) i;
INSERT INTO audit_claim_deliveries (event_id, request_id, output_scan_body, claim_raw, delivery_state, delivered_at)
SELECT 'evt_completion_t1219_d2_' || i, 'req_t1219_d2_' || i, convert_to('scan', 'UTF8'), convert_to('claim', 'UTF8'), 'DELIVERED', now() - interval '31 days' FROM generate_series(1, 2) i;
INSERT INTO t1219_cat SELECT 'evt_completion_t1219_d2_' || i, 'd2' FROM generate_series(1, 2) i;
SQL
    EVENTS_BEFORE_D2="$(events_fp)"
    put "$SCRIPT" "$HOSTDIR/audit-claim-delivery-retention.sh" && rsh "chmod 644 $(printf '%q' "$HOSTDIR/audit-claim-delivery-retention.sh")" \
      || die "uploading the script failed"
    put "$WK/d2-run.env" "$HOSTDIR/d2-run.env" || die "uploading the env file failed"
    # Mirrors the compose service: entrypoint, user, read_only + tmpfs /tmp,
    # cap_drop ALL, no-new-privileges, the script bind-mounted read-only, the
    # environment exactly as `docker compose config` rendered it, the dsa-audit
    # network role (alias postgres-audit). Only `--once` is added: the shipped
    # service loops daily. Image: the kit-pinned digest of the same
    # postgres:16-alpine the service names (the moving tag is not pulled).
    dk create --name "$SVCC" --network "$NET" --user "$SVC_USER" --read-only --tmpfs /tmp \
      --cap-drop ALL --security-opt no-new-privileges:true \
      --env-file "$HOSTDIR/d2-run.env" \
      -v "$HOSTDIR/audit-claim-delivery-retention.sh:/scripts/audit-claim-delivery-retention.sh:ro" \
      --entrypoint "$EP0" "$PG_IMAGE" "${EP_REST[@]}" --once >/dev/null || die "creating the compose-shaped container failed"
    OUT3="$(dk start -a "$SVCC" 2>&1)" && RC3=0 || RC3=$?
    RC3C="$(dk inspect -f '{{.State.ExitCode}}' "$SVCC" 2>/dev/null || echo '?')"
    echo "  compose-shaped run (exit=$RC3C): $OUT3"
    [ "$RC3" = 0 ] && [ "$RC3C" = 0 ] && ok "compose-shaped service connected as dsa@postgres-audit with the shipped env names and exited 0" \
      || bad "compose-shaped run failed (rc=$RC3 exit=$RC3C)"
    case "$OUT3" in *"retention_days=30 delivered_blanked=2 "*"parked_older_than_retention=2"*) ok "compose-shaped run blanked the 2 new old rows (default 30 days)" ;; *) bad "compose-shaped run line unexpected" ;; esac
    D2_STATE="$(printf "SELECT count(*) FILTER (WHERE d.delivery_state='DELIVERED' AND d.claim_raw IS NULL AND d.output_scan_body IS NULL) || '/' || count(*) FROM audit_claim_deliveries d JOIN t1219_cat c USING (event_id) WHERE c.cat='d2';\n" | q)"
    [ "$D2_STATE" = "2/2" ] && ok "D2 rows blanked, still present" || bad "D2 rows: $D2_STATE"
    [ "$(untouched_fp)" = "$UNTOUCHED_BEFORE" ] && ok "protected rows still unchanged after the compose-shaped run" || bad "protected rows changed in D2"
    [ "$(events_fp)" = "$EVENTS_BEFORE_D2" ] && ok "audit_events unchanged by the compose-shaped run" || bad "audit_events changed in D2"
  fi
  printf '  final row states: %s\n' "$(printf "SELECT string_agg(cat || ':' || delivery_state || ':blanked=' || b, ' ' ORDER BY cat) FROM (SELECT c.cat, d.delivery_state, count(*) FILTER (WHERE d.claim_raw IS NULL AND d.output_scan_body IS NULL) || '/' || count(*) b FROM audit_claim_deliveries d JOIN t1219_cat c USING (event_id) GROUP BY 1, 2) x;\n" | q)"
fi

echo
echo "audit claim-delivery retention: $PASS ok, $FAILS failed, $SKIPS skipped"
if [ "$SKIPS" -gt 0 ]; then
  echo "  ⚠ $SKIPS section(s) SKIPPED — see the SKIP banners above; skipped sections prove nothing."
fi
[ "$FAILS" = 0 ] || exit 1
exit 0
