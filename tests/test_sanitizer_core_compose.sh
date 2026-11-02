#!/usr/bin/env bash
#
# Kit 2.0 Slice K-A — the Compose path for the new sanitizer core and its
# doctor checks (PRD Opus Advisor specs/2026-11/prd-2026-11-02-kit-2-0-new-core.md
# K1 + K3, ticket T-1441).
#
# WHAT THIS PROVES
#   A. The migration mirror: migrations/sanitizer-core holds 0001..N contiguous,
#      SHA256SUMS matches, CEILING_SANITIZER_CORE == N == the compose default.
#   B. The rendered Compose project (`docker compose config`, client-side only,
#      no daemon): core + sidecar + registry DB + migrate step exist with the
#      hosted shape (shared namespace owned by the sidecar, internal DB network,
#      6.5 GB / 1 GB caps, witness latch + client leaf, kit profile, no
#      --migrate), the gateway carries the hosted switch set (delta, Gate
#      enforce, route posture observe, placement message, unredacted off) and
#      SANDBOX_B_MESSAGES_JSON_MAX_BYTES reaches BOTH the gateway and sandbox-b,
#      the witness serves the kit CA leaf, no container mounts the CA key, and
#      the old sanitizer is still there for the non-Anthropic routes.
#   C. scripts/migrate-sanitizer-core.sh against a STUB psql: one transaction
#      with PG.Migrate's ledger, capped, never down, fail-closed on every bad
#      input (bad target, over-ceiling, foreign ceiling file/key, tampered file,
#      foreign ledger, apply error).
#   D. scripts/bootstrap-sanitizer-core-mtls.sh: the four leaves verify for the
#      right purpose/SAN; a re-run rotates nothing; a leaf without its CA is
#      refused.
#   E. `bin/lucairn doctor` RED-PROOF (each case goes red on a deliberately
#      broken install and green on the generated one): witness client cert
#      missing, wrong witness SAN, CA copies differ, key readable by others,
#      LCR_PROFILE=hosted, half a digest pair, registry key placeholder — and,
#      online with a stub Docker engine: memory below the floor, sidecar absent,
#      core joined to an old sidecar namespace, registry not migrated, claims
#      dropped, plaintext witness transport, an overlay forwarding
#      LCR_PROFILE=hosted.
#
# NON-COVERAGE (stated, not implied)
#   * No container runs. Whether the images boot with these settings is the
#     compose rehearsal on a Docker host (PRD criterion 2), not this suite.
#   * The stub psql proves the runner's decisions and the SQL it hands psql,
#     not PostgreSQL's execution of the migration bodies.
#   * The doctor's production-only branch of the witness-hop check
#     (GRPC_TLS_ENABLED!=true -> FAIL) is driven in tests/test_sec_hardening.sh,
#     which holds the coherent production env that passes doctor; here only the
#     development branch (WARN) is driven.
#   * The online claim check reads log lines; it does not send a turn.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.customer.yml"
SELFHOSTED="$ROOT/docker-compose.self-hosted.yml"
EXAMPLE_ENV="$ROOT/customer.env.example"
CEILINGS="$ROOT/scripts/migration-ceilings.conf"
MIGDIR="$ROOT/migrations/sanitizer-core"
RUNNER="$ROOT/scripts/migrate-sanitizer-core.sh"
BOOTSTRAP="$ROOT/scripts/bootstrap-sanitizer-core-mtls.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE_PATH="$PATH"

FAILS=0
N=0
SKIPS=0
pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }
skip() { SKIPS=$((SKIPS + 1)); echo "  NOT RUN — $1"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

sha256_check() { # <dir> — verify SHA256SUMS in that directory
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$1" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
  else
    (cd "$1" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1)
  fi
}

echo "A. Registry migration mirror + ceiling"
CEIL="$(sed -n 's/^CEILING_SANITIZER_CORE=\([0-9][0-9]*\)$/\1/p' "$CEILINGS" | tail -1)"
COUNT="$(find "$MIGDIR" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]_*.up.sql' | wc -l | tr -d ' ')"
HIGHEST="$(find "$MIGDIR" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]_*.up.sql' -exec basename {} \; | sort | tail -1 | cut -c1-4 | sed 's/^0*//')"
check_eq "ceiling-present (CEILING_SANITIZER_CORE)" "7" "$CEIL"
check_eq "mirror-count-equals-ceiling" "$CEIL" "$COUNT"
check_eq "mirror-highest-equals-ceiling" "$CEIL" "$HIGHEST"
if sha256_check "$MIGDIR"; then pass "mirror-sha256sums-verify"; else fail "mirror-sha256sums-verify"; fi
check_eq "sha256sums-lists-every-file" "$COUNT" "$(grep -c '\.up\.sql$' "$MIGDIR/SHA256SUMS")"
grep -q 'CEILING_SANITIZER_CORE' "$ROOT/docs/RELEASING.md" && pass "releasing-md-names-the-ceiling" || fail "releasing-md-names-the-ceiling"

echo ""
echo "B. Rendered Compose project (docker compose config)"
HAVE_COMPOSE=0
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  HAVE_COMPOSE=1
fi
if [ "$HAVE_COMPOSE" -ne 1 ]; then
  skip "docker compose CLI not available — section B"
else
  cp "$EXAMPLE_ENV" "$TMP/render.env"
  printf '\nSANDBOX_B_MESSAGES_JSON_MAX_BYTES=8388608\n' >> "$TMP/render.env"
  if docker compose -f "$COMPOSE" -f "$SELFHOSTED" --env-file "$TMP/render.env" --profile sanitizer-core-migrate \
       config --format json > "$TMP/render.json" 2> "$TMP/render.err"; then
    pass "renders-with-the-example-env (customer + self-hosted)"
    python3 - "$TMP/render.json" "$ROOT/image-manifest.yaml" > "$TMP/render-check.txt" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
manifest = open(sys.argv[2]).read()
svcs, nets = d["services"], d.get("networks", {})
def p(ok, msg): print(("ok " if ok else "FAIL ") + msg)
def env(name):
    e = svcs[name].get("environment") or {}
    return e
for s in ("postgres-sanitizer-core", "sanitizer-core-sidecar", "sanitizer-core", "migrate-sanitizer-core", "sanitizer", "gateway", "veil-witness", "sandbox-b"):
    p(s in svcs, "service %s present" % s)
core, side, pg, mig, gw, wit = (svcs.get(k, {}) for k in ("sanitizer-core", "sanitizer-core-sidecar", "postgres-sanitizer-core", "migrate-sanitizer-core", "gateway", "veil-witness"))
# Topology: the sidecar owns the namespace; the core joins it.
p(core.get("network_mode") == "service:sanitizer-core-sidecar", "core joins the sidecar's network namespace")
p(not core.get("networks"), "core declares no networks of its own")
sn = side.get("networks") or {}
p(set(sn) == {"dsa-identity", "dsa-witness-identity", "dsa-sanitizer-core"}, "sidecar on dsa-identity + dsa-witness-identity + dsa-sanitizer-core (%s)" % sorted(sn))
al = set((sn.get("dsa-identity") or {}).get("aliases") or [])
p({"sanitizer-core", "dsa-sanitizer-core"} <= al, "sidecar answers for sanitizer-core + dsa-sanitizer-core on dsa-identity")
p(not side.get("ports") and not core.get("ports") and not pg.get("ports"), "no host port on core / sidecar / registry DB")
p(list((pg.get("networks") or {}).keys()) == ["dsa-sanitizer-core"], "registry DB only on dsa-sanitizer-core")
p(nets.get("dsa-sanitizer-core", {}).get("internal") is True, "dsa-sanitizer-core network is internal")
# Memory caps (the hosted window's A8 values).
def lim(s):
    return ((s.get("deploy") or {}).get("resources") or {}).get("limits", {}).get("memory")
p(str(side.get("mem_limit")) == str(6500 * 1024 * 1024) and str(lim(side)) == str(6500 * 1024 * 1024), "sidecar capped at 6500 MiB (mem_limit + deploy limit) — got %s / %s" % (side.get("mem_limit"), lim(side)))
p(str(side.get("memswap_limit")) == str(6500 * 1024 * 1024), "sidecar swap capped at the same 6500 MiB")
p(str(core.get("mem_limit")) == str(1024 ** 3) and str(lim(core)) == str(1024 ** 3), "core capped at 1 GiB")
# Images: one tag for the pair, digest-pinned postgres for the new DB services.
ci, si = core.get("image", ""), side.get("image", "")
p(re.fullmatch(r"ghcr\.io/declade/dsa-sanitizer-core:1\.1\.0", ci) is not None, "core image ghcr.io/declade/dsa-sanitizer-core:1.1.0 (%s)" % ci)
p(re.fullmatch(r"ghcr\.io/declade/dsa-sanitizer-core-sidecar:1\.1\.0", si) is not None, "sidecar image ghcr.io/declade/dsa-sanitizer-core-sidecar:1.1.0 (%s)" % si)
pgd = re.search(r'postgres:\n\s+ref: "postgres:16-alpine"[\s\S]*?digest: "(sha256:[0-9a-f]{64})"', manifest)
want_pg = "postgres:16-alpine@" + (pgd.group(1) if pgd else "?")
p(pg.get("image") == want_pg and mig.get("image") == want_pg, "registry DB + migrate step pinned to the manifest postgres digest")
# Core command + entrypoint: hosted watchdog, never --migrate.
cmd = core.get("command") or []
p("serve" in cmd and "--listen=0.0.0.0:8790" in cmd and "--sidecar=http://127.0.0.1:8765" in cmd, "core serves :8790 with the sidecar on 127.0.0.1:8765")
p(not any(a.startswith("--migrate") for a in cmd), "core command never carries --migrate (migrations are an operator step)")
p(any(a.startswith("--dsn=postgres://dsa:") and "@postgres-sanitizer-core:5432/sanitizer_core" in a for a in cmd), "core DSN points at postgres-sanitizer-core/sanitizer_core")
ep = " ".join(core.get("entrypoint") or [])
p("exit 70" in ep and "sidecar unreachable 3 checks in a row" in ep, "core entrypoint = the hosted sidecar watchdog")
dep = core.get("depends_on") or {}
p(dep.get("sanitizer-core-sidecar", {}).get("condition") == "service_healthy" and dep.get("postgres-sanitizer-core", {}).get("condition") == "service_healthy", "core waits for a healthy sidecar + registry DB")
p(dep.get("witness-egress-guard", {}).get("condition") == "service_completed_successfully", "core is gated by the T-682 witness-egress guard (it emits claims)")
ce = env("sanitizer-core")
p("LCR_PROFILE" not in ce, "LCR_PROFILE not forwarded (unset = kit profile; ServiceNow mode refused)")
p(not any(k.startswith("LCR_SERVICENOW_CONTROL_") for k in ce), "no ServiceNow control client on the core")
p(ce.get("LCR_WITNESS_REQUIRE_MTLS") == "true", "core witness latch on (A9)")
p(ce.get("LCR_WITNESS_ADDR") == "veil-witness:50057", "core dials the local witness claim port")
p(ce.get("LCR_WITNESS_MTLS_CA_BUNDLE_PATH") == "/etc/sanitizer-core-mtls/ca.crt"
  and ce.get("LCR_WITNESS_MTLS_CLIENT_CERT_PATH") == "/etc/sanitizer-core-mtls/witness-client.crt"
  and ce.get("LCR_WITNESS_MTLS_CLIENT_KEY_PATH") == "/etc/sanitizer-core-mtls/witness-client.key", "core witness client triple = the kit leaf")
p(ce.get("SANITIZER_CORE_MTLS_SERVER_CERT_PATH") == "/etc/sanitizer-core-mtls/dsa-sanitizer-core.crt"
  and ce.get("SANITIZER_CORE_MTLS_SERVER_KEY_PATH") == "/etc/sanitizer-core-mtls/dsa-sanitizer-core.key"
  and ce.get("SANITIZER_CORE_MTLS_CA_BUNDLE_PATH") == "/etc/sanitizer-core-mtls/ca.crt", "core server triple = the kit leaf")
p(ce.get("LCR_SIGNING_KEY") == env("sanitizer").get("LCR_SIGNING_KEY"), "core signs with the same LCR_SANITIZER_SIGNING_KEY seed as the old sanitizer")
p(bool(ce.get("DSA_SANITIZER_CORE_REGISTRY_KEY")), "registry key reaches the core")
# Gateway: the hosted switch set.
ge = env("gateway")
for k, v in (("GATEWAY_SANITIZER_PROTOCOL", "delta"), ("SANITIZER_CORE_URL", "https://sanitizer-core:8790"),
             ("GATEWAY_SANITIZER_GATE_POSTURE", "enforce"), ("GATEWAY_SANITIZER_GATE_ROUTE_POSTURE", "observe"),
             ("GATEWAY_ADDED_PARTS_PLACEMENT", "message"), ("GATEWAY_USER_UNREDACTED_ENABLED", "false"),
             ("SANITIZER_CORE_MTLS_CA_BUNDLE_PATH", "/etc/sanitizer-core-mtls/ca.crt"),
             ("SANITIZER_CORE_MTLS_CLIENT_CERT_PATH", "/etc/sanitizer-core-mtls/dsa-gateway.crt"),
             ("SANITIZER_CORE_MTLS_CLIENT_KEY_PATH", "/etc/sanitizer-core-mtls/dsa-gateway.key"),
             ("SANITIZER_URL", "http://sanitizer:8086")):
    p(ge.get(k) == v, "gateway %s=%s (got %r)" % (k, v, ge.get(k)))
p(ge.get("SANDBOX_B_MESSAGES_JSON_MAX_BYTES") == "8388608" and env("sandbox-b").get("SANDBOX_B_MESSAGES_JSON_MAX_BYTES") == "8388608",
  "SANDBOX_B_MESSAGES_JSON_MAX_BYTES reaches BOTH gateway and sandbox-b")
p((gw.get("depends_on") or {}).get("sanitizer-core", {}).get("condition") == "service_healthy", "gateway waits for a healthy core")
# Witness serves the kit CA leaf on :50057 / :50058.
we = env("veil-witness")
p(we.get("GRPC_TLS_CERT_FILE") == "/etc/sanitizer-core-mtls/dsa-veil-witness.crt" and we.get("GRPC_TLS_KEY_FILE") == "/etc/sanitizer-core-mtls/dsa-veil-witness.key", "witness serves the kit CA's dsa-veil-witness leaf")
# Mounts: each service sees only its own directory; the CA key directory is never mounted.
def mounts(s):
    return [(v.get("source", ""), v.get("target", "")) for v in (svcs[s].get("volumes") or []) if v.get("target") == "/etc/sanitizer-core-mtls"]
for s, sub in (("sanitizer-core", "sanitizer-core"), ("gateway", "gateway"), ("veil-witness", "veil-witness")):
    m = mounts(s)
    p(len(m) == 1 and m[0][0].endswith("/.certs/sanitizer-core-mtls/" + sub), "%s mounts only .certs/sanitizer-core-mtls/%s (%s)" % (s, sub, m))
allsrc = [v.get("source", "") for x in svcs.values() for v in (x.get("volumes") or [])]
p(not any(src.rstrip("/").endswith("sanitizer-core-mtls") or src.rstrip("/").endswith("sanitizer-core-mtls/ca") for src in allsrc), "no container mounts the CA directory or the whole cert tree")
# Migrate step: profile-gated, capped, discrete libpq settings.
me = env("migrate-sanitizer-core")
p(mig.get("profiles") == ["sanitizer-core-migrate"], "migrate step is behind the sanitizer-core-migrate profile (never on up)")
p(me.get("MIGRATE_TARGET_VERSION") == "7" and me.get("MIGRATE_CEILING_KEY") == "SANITIZER_CORE", "migrate step targets the ceiling (7) with key SANITIZER_CORE")
p("DATABASE_URL" not in me and me.get("PGHOST") == "postgres-sanitizer-core" and me.get("PGDATABASE") == "sanitizer_core", "migrate step uses discrete libpq settings, no URL")
p(mig.get("user") == "65534:65534" and mig.get("read_only") is True, "migrate step runs non-root on a read-only rootfs")
p(list((mig.get("networks") or {}).keys()) == ["dsa-sanitizer-core"], "migrate step only on dsa-sanitizer-core")
p(mig.get("restart") == "no", "migrate step never restarts")
PY
    while IFS= read -r line; do
      case "$line" in ok\ *) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac
    done < "$TMP/render-check.txt"
  else
    fail "renders-with-the-example-env: $(tail -3 "$TMP/render.err")"
  fi

  SERVICES="$(docker compose -f "$COMPOSE" -f "$SELFHOSTED" --env-file "$EXAMPLE_ENV" config --services 2>/dev/null || true)"
  if printf '%s\n' "$SERVICES" | grep -qx migrate-sanitizer-core; then
    fail "migrate-sanitizer-core-not-in-default-project (a plain up would run it)"
  else
    pass "migrate-sanitizer-core-not-in-default-project"
  fi
  # The base file alone (split-remote topology) also carries the core.
  # Captured first: `| grep -q` under pipefail SIGPIPEs the writer and reads as a failure.
  BASE_SERVICES="$(docker compose -f "$COMPOSE" --env-file "$EXAMPLE_ENV" config --services 2>/dev/null || true)"
  if printf '%s\n' "$BASE_SERVICES" | grep -qx sanitizer-core; then
    pass "split-remote base file carries the core"
  else
    fail "split-remote base file carries the core"
  fi
  # Digest variables pin both images as a pair.
  cp "$EXAMPLE_ENV" "$TMP/digest.env"
  printf '\nLUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=sha256:%s\nLUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=sha256:%s\n' \
    "$(printf 'a%.0s' $(seq 64))" "$(printf 'b%.0s' $(seq 64))" >> "$TMP/digest.env"
  IMAGES="$(docker compose -f "$COMPOSE" --env-file "$TMP/digest.env" config --images 2>/dev/null || true)"
  if printf '%s\n' "$IMAGES" | grep -qx "ghcr.io/declade/dsa-sanitizer-core:1.1.0@sha256:$(printf 'a%.0s' $(seq 64))" \
     && printf '%s\n' "$IMAGES" | grep -qx "ghcr.io/declade/dsa-sanitizer-core-sidecar:1.1.0@sha256:$(printf 'b%.0s' $(seq 64))"; then
    pass "digest variables pin core + sidecar by digest"
  else
    fail "digest variables pin core + sidecar by digest ($(printf '%s\n' "$IMAGES" | grep sanitizer-core | tr '\n' ' '))"
  fi
  # A missing registry key or DB password refuses to render.
  grep -v '^DSA_SANITIZER_CORE_REGISTRY_KEY=' "$EXAMPLE_ENV" > "$TMP/nokey.env"
  if docker compose -f "$COMPOSE" --env-file "$TMP/nokey.env" config --quiet >/dev/null 2>&1; then
    fail "missing DSA_SANITIZER_CORE_REGISTRY_KEY refuses to render"
  else
    pass "missing DSA_SANITIZER_CORE_REGISTRY_KEY refuses to render"
  fi
  grep -v '^POSTGRES_SANITIZER_CORE_PASSWORD=' "$EXAMPLE_ENV" > "$TMP/nopw.env"
  if docker compose -f "$COMPOSE" --env-file "$TMP/nopw.env" config --quiet >/dev/null 2>&1; then
    fail "missing POSTGRES_SANITIZER_CORE_PASSWORD refuses to render"
  else
    pass "missing POSTGRES_SANITIZER_CORE_PASSWORD refuses to render"
  fi
fi

echo ""
echo "C. scripts/migrate-sanitizer-core.sh against a stub psql"
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/psql" <<'STUBPSQL'
#!/bin/sh
# Records argv; answers the two ledger queries from STUB_HAS_LEDGER / STUB_LEDGER;
# copies an apply's SQL file (-f) aside so the test can read it.
echo "$*" >> "$STUB_LOG"
case "$*" in
  *"to_regclass"*) echo "${STUB_HAS_LEDGER:-f}"; exit 0 ;;
  *"SELECT name FROM registry_schema_migrations"*) [ -n "${STUB_LEDGER:-}" ] && printf '%s\n' $STUB_LEDGER; exit 0 ;;
  *"SELECT count(*) FROM registry_schema_migrations"*) echo "${STUB_COUNT:-7}"; exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-f" ]; then cp "$2" "$STUB_SQL"; fi
  shift
done
exit "${STUB_APPLY_RC:-0}"
STUBPSQL
chmod 0755 "$STUB/psql"

# The runner reads the ceiling file beside itself; run a staged copy of the
# shipped script + the shipped ceilings file so the guard sees the real layout.
RUN_DIR="$TMP/run/scripts"
mkdir -p "$RUN_DIR"
cp "$RUNNER" "$RUN_DIR/migrate-sanitizer-core.sh"
cp "$CEILINGS" "$RUN_DIR/migration-ceilings.conf"
mkdir -p "$TMP/run/migrations"
cp -R "$MIGDIR" "$TMP/run/migrations/sanitizer-core"

run_migrate() { # extra env assignments...
  : > "$TMP/stub.log"; rm -f "$TMP/stub.sql"
  env -i PATH="$STUB:$BASE_PATH" HOME="$TMP" TMPDIR="$TMP" STUB_LOG="$TMP/stub.log" STUB_SQL="$TMP/stub.sql" \
    PGHOST=postgres-sanitizer-core PGUSER=dsa PGDATABASE=sanitizer_core PGPASSWORD=synthetic-test-password \
    MIGRATE_PATH="$TMP/run/migrations/sanitizer-core" MIGRATE_CEILING_KEY=SANITIZER_CORE \
    MIGRATE_CEILING_FILE="$RUN_DIR/migration-ceilings.conf" MIGRATE_TARGET_VERSION=7 \
    "$@" sh "$RUN_DIR/migrate-sanitizer-core.sh" > "$TMP/migrate.out" 2>&1
}
expect_rc() { # <name> <rc> -- env...
  local name="$1" want="$2" got; shift 2
  run_migrate "$@"; got=$?
  if [ "$got" = "$want" ]; then pass "$name (exit $got)"; else fail "$name (want exit $want, got $got: $(tail -1 "$TMP/migrate.out"))"; fi
}

expect_rc "fresh-registry-applies-1-to-7" 0
if [ -f "$TMP/stub.sql" ]; then
  check_eq "one apply call with --single-transaction" "1" "$(grep -c -- '--single-transaction' "$TMP/stub.log")"
  head -1 "$TMP/stub.sql" | grep -q 'pg_advisory_xact_lock(7413001)' && pass "apply takes PG.Migrate's advisory lock first" || fail "apply takes PG.Migrate's advisory lock first"
  grep -q 'CREATE TABLE IF NOT EXISTS registry_schema_migrations (name TEXT PRIMARY KEY' "$TMP/stub.sql" && pass "apply creates the core's own ledger" || fail "apply creates the core's own ledger"
  check_eq "apply inserts 7 ledger names" "7" "$(grep -c "^INSERT INTO registry_schema_migrations (name) VALUES ('" "$TMP/stub.sql")"
  if grep -q 'ON CONFLICT' "$TMP/stub.sql"; then fail "ledger insert has no ON CONFLICT (a concurrent run collides)"; else pass "ledger insert has no ON CONFLICT (a concurrent run collides)"; fi
  ORDER="$(sed -n "s/^INSERT INTO registry_schema_migrations (name) VALUES ('\(.*\)');$/\1/p" "$TMP/stub.sql" | tr '\n' ' ')"
  WANT="$(cd "$MIGDIR" && ls -1 [0-9][0-9][0-9][0-9]_*.up.sql | tr '\n' ' ')"
  check_eq "ledger names in file order" "$WANT" "$ORDER"
  check_eq "each body included right after its ledger row" "7" "$(grep -c '^\\i .*/[0-9][0-9][0-9][0-9]_.*\.up\.sql$' "$TMP/stub.sql")"
else
  fail "fresh-registry apply wrote no SQL"
fi
ALL="$(cd "$MIGDIR" && ls -1 [0-9][0-9][0-9][0-9]_*.up.sql | tr '\n' ' ')"
expect_rc "at-ceiling-nothing-to-apply" 0 STUB_HAS_LEDGER=t "STUB_LEDGER=$ALL"
[ ! -f "$TMP/stub.sql" ] && pass "at-ceiling makes no apply call" || fail "at-ceiling makes no apply call"
expect_rc "never-migrates-down (ledger 7, target 3)" 0 STUB_HAS_LEDGER=t "STUB_LEDGER=$ALL" MIGRATE_TARGET_VERSION=3
[ ! -f "$TMP/stub.sql" ] && pass "never-down makes no apply call" || fail "never-down makes no apply call"
PART="$(cd "$MIGDIR" && ls -1 [0-9][0-9][0-9][0-9]_*.up.sql | head -4 | tr '\n' ' ')"
expect_rc "upgrade-applies-only-the-missing-tail (4 -> 7)" 0 STUB_HAS_LEDGER=t "STUB_LEDGER=$PART"
check_eq "upgrade inserts 3 names" "3" "$(grep -c '^INSERT INTO registry_schema_migrations' "$TMP/stub.sql" 2>/dev/null || echo 0)"
expect_rc "lowered-target-applies-1-to-3" 0 MIGRATE_TARGET_VERSION=3
check_eq "lowered target inserts 3 names" "3" "$(grep -c '^INSERT INTO registry_schema_migrations' "$TMP/stub.sql" 2>/dev/null || echo 0)"
expect_rc "target-above-ceiling-refused" 91 MIGRATE_TARGET_VERSION=8
expect_rc "non-numeric-target-refused" 90 MIGRATE_TARGET_VERSION=latest
expect_rc "zero-target-refused" 90 MIGRATE_TARGET_VERSION=0
expect_rc "foreign-ceiling-key-refused" 91 MIGRATE_CEILING_KEY=VEIL_WITNESS
printf 'CEILING_SANITIZER_CORE=99\n' > "$TMP/evil-ceilings.conf"
expect_rc "ceiling-file-not-beside-runner-refused" 91 MIGRATE_CEILING_FILE="$TMP/evil-ceilings.conf"
expect_rc "env-ceiling-disagreeing-refused" 91 MIGRATE_KNOWN_SAFE_MAX=99
expect_rc "missing-pgpassword-refused" 93 PGPASSWORD=
expect_rc "foreign-ledger-refused" 92 STUB_HAS_LEDGER=t "STUB_LEDGER=0001_registry.up.sql 0002_somebody_else.up.sql"
expect_rc "apply-error-reports-rollback" 96 STUB_APPLY_RC=3
NEWER="$ALL 0008_future.up.sql"
expect_rc "newer-core-ledger-accepted-not-downgraded" 0 STUB_HAS_LEDGER=t "STUB_LEDGER=$NEWER"
printf -- '-- tampered\n' >> "$TMP/run/migrations/sanitizer-core/0003_claim_records.up.sql"
expect_rc "tampered-migration-refused" 95
grep -q 'No migrations\|Applying NO migrations' "$TMP/migrate.out" && pass "refusal says nothing was applied" || fail "refusal says nothing was applied"
[ ! -f "$TMP/stub.sql" ] && pass "tampered tree makes no apply call" || fail "tampered tree makes no apply call"
if grep -q 'synthetic-test-password' "$TMP/migrate.out" "$TMP/stub.log"; then fail "PGPASSWORD never printed or passed as argv"; else pass "PGPASSWORD never printed or passed as argv"; fi

echo ""
echo "D. scripts/bootstrap-sanitizer-core-mtls.sh"
CD="$TMP/certs"
if bash "$BOOTSTRAP" "$CD" > "$TMP/boot.out" 2>&1; then pass "bootstrap runs"; else fail "bootstrap runs: $(tail -2 "$TMP/boot.out")"; fi
verify_leaf() { # <name> <crt> <purpose> <san>
  if openssl verify -CAfile "$CD/ca/ca.crt" -purpose "$3" "$2" >/dev/null 2>&1 \
     && openssl x509 -noout -text -in "$2" | grep -q "DNS:$4\(,\|$\)"; then
    pass "$1 verifies as $3 with SAN $4"
  else
    fail "$1 verifies as $3 with SAN $4"
  fi
}
verify_leaf "core server leaf" "$CD/sanitizer-core/dsa-sanitizer-core.crt" sslserver dsa-sanitizer-core
verify_leaf "core witness client leaf" "$CD/sanitizer-core/witness-client.crt" sslclient dsa-sanitizer
verify_leaf "gateway client leaf" "$CD/gateway/dsa-gateway.crt" sslclient dsa-gateway
verify_leaf "witness server leaf" "$CD/veil-witness/dsa-veil-witness.crt" sslserver dsa-veil-witness
if openssl verify -CAfile "$CD/ca/ca.crt" -purpose sslserver "$CD/gateway/dsa-gateway.crt" >/dev/null 2>&1; then
  fail "gateway client leaf is NOT a server leaf"
else
  pass "gateway client leaf is NOT a server leaf"
fi
[ ! -e "$CD/sanitizer-core/ca.key" ] && [ ! -e "$CD/gateway/ca.key" ] && [ ! -e "$CD/veil-witness/ca.key" ] \
  && pass "no CA key in a mounted directory" || fail "no CA key in a mounted directory"
BAD_MODES="$(find "$CD" -name '*.key' -perm -004 | wc -l | tr -d ' ')"
check_eq "every private key is 0600" "0" "$BAD_MODES"
BEFORE="$(find "$CD" -type f -exec cat {} + | openssl dgst -sha256 | awk '{print $NF}')"
bash "$BOOTSTRAP" "$CD" > /dev/null 2>&1
AFTER="$(find "$CD" -type f -exec cat {} + | openssl dgst -sha256 | awk '{print $NF}')"
check_eq "re-run rotates nothing" "$BEFORE" "$AFTER"
mkdir -p "$TMP/orphan/sanitizer-core"
cp "$CD/sanitizer-core/dsa-sanitizer-core.crt" "$CD/sanitizer-core/dsa-sanitizer-core.key" "$TMP/orphan/sanitizer-core/"
if bash "$BOOTSTRAP" "$TMP/orphan" > "$TMP/orphan.out" 2>&1; then
  fail "a leaf without its CA is refused"
else
  pass "a leaf without its CA is refused"
fi

echo ""
echo "E. bin/lucairn doctor RED-PROOF"
# Hermetic tool shims: no doctor run below reaches a real Docker engine,
# cluster, gateway or registry.
DBIN="$TMP/doctor-bin"
mkdir -p "$DBIN"
cat > "$DBIN/docker" <<'STUBDOCKER'
#!/bin/bash
# Stub Docker engine for the doctor. Answers from STUB_* files/values.
a=" $* "
case "$a" in
  " info "*) [ -n "${STUB_MEM_BYTES:-}" ] && { echo "$STUB_MEM_BYTES"; exit 0; }; exit 1 ;;
  " inspect "*) [ -n "${STUB_NETMODE:-}" ] && { echo "$STUB_NETMODE"; exit 0; }; exit 1 ;;
esac
if [ "${1:-}" = compose ]; then
  case "$a" in
    *" version "*) exit 0 ;;
    *" config --quiet "*) exit 0 ;;
    *" config --format json "*) [ -n "${STUB_CONFIG_JSON:-}" ] && cat "$STUB_CONFIG_JSON"; exit 0 ;;
    *" ps -a "*) [ -n "${STUB_PS:-}" ] && cat "$STUB_PS"; exit 0 ;;
    *" exec -T postgres-sanitizer-core "*) echo "${STUB_LEDGER_OUT:-7}"; exit 0 ;;
    *" logs --no-color sanitizer-core "*) [ -n "${STUB_CORE_LOG:-}" ] && cat "$STUB_CORE_LOG"; exit 0 ;;
    *" logs --no-color veil-witness "*) [ -n "${STUB_WITNESS_LOG:-}" ] && cat "$STUB_WITNESS_LOG"; exit 0 ;;
  esac
fi
exit 1
STUBDOCKER
printf '#!/bin/sh\nprintf 000\n' > "$DBIN/curl"
for t in kubectl helm pg_isready docker-compose; do printf '#!/bin/sh\nexit 1\n' > "$DBIN/$t"; done
chmod 0755 "$DBIN"/*

ENVDIR="$TMP/install"
mkdir -p "$ENVDIR"
ENVF="$ENVDIR/customer.env"
PATH="$DBIN:$BASE_PATH" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$ENVF" --skip-doctor > "$TMP/init.out" 2>&1 \
  || { fail "lucairn-init for the doctor fixture: $(tail -3 "$TMP/init.out")"; }
CERTS="$ENVDIR/.certs/sanitizer-core-mtls"
grep -q "^SANITIZER_CORE_MTLS_HOST_DIR=$CERTS$" "$ENVF" && pass "lucairn-init records the cert directory beside customer.env" || fail "lucairn-init records the cert directory beside customer.env"
[ -f "$CERTS/sanitizer-core/witness-client.crt" ] && pass "lucairn-init generated the core's mTLS material" || fail "lucairn-init generated the core's mTLS material"
grep -Eq '^DSA_SANITIZER_CORE_REGISTRY_KEY=[0-9a-f]{64}$' "$ENVF" && pass "lucairn-init generated the registry key" || fail "lucairn-init generated the registry key"
grep -Eq '^POSTGRES_SANITIZER_CORE_PASSWORD=[A-Za-z0-9]{32}$' "$ENVF" && pass "lucairn-init generated the registry DB password" || fail "lucairn-init generated the registry DB password"

doctor_offline() { # <env file> — offline doctor, hermetic PATH
  PATH="$DBIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$1" --compose "$COMPOSE" --offline --skip-image-check > "$TMP/doc.out" 2>&1
}
variant() { # <name> — copy of the generated install (env + certs + sidecars)
  local d="$TMP/v-$1"
  rm -rf "$d"; mkdir -p "$d"
  cp -R "$ENVDIR/." "$d/"
  sed -i.bak "s#^SANITIZER_CORE_MTLS_HOST_DIR=.*#SANITIZER_CORE_MTLS_HOST_DIR=$d/.certs/sanitizer-core-mtls#" "$d/customer.env" && rm -f "$d/customer.env.bak"
  printf '%s' "$d"
}
expect_doctor_red() { # <name> <dir> <grep-fixed message>
  if doctor_offline "$2/customer.env"; then
    fail "$1 — doctor stayed green"
  elif grep -Fq "$3" "$TMP/doc.out"; then
    pass "$1 — doctor red with: $3"
  else
    fail "$1 — doctor red but without '$3': $(grep -i 'sanitizer core' "$TMP/doc.out" | head -3 | tr '\n' ' ')"
  fi
}

if doctor_offline "$ENVF"; then
  pass "GREEN: offline doctor passes on the generated install"
else
  fail "GREEN: offline doctor passes on the generated install: $(grep -E 'failed|error' "$TMP/doc.out" | head -3 | tr '\n' ' ')"
fi
for line in "sanitizer core registry key: ok" "sanitizer core registry DB password: ok" "sanitizer core profile: kit" "sanitizer core mTLS: ok"; do
  grep -Fq "$line" "$TMP/doc.out" && pass "GREEN line: $line" || fail "GREEN line: $line"
done
grep -Fq "sanitizer core witness hop" "$TMP/doc.out" && grep -Fq "GRPC_TLS_ENABLED=false with DSA_ENV=development" "$TMP/doc.out" \
  && pass "dev install (GRPC_TLS_ENABLED=false) is WARNED that core claims cannot reach a plaintext witness" \
  || fail "dev install (GRPC_TLS_ENABLED=false) is WARNED that core claims cannot reach a plaintext witness"

V="$(variant nowitnesscert)"; rm -f "$V/.certs/sanitizer-core-mtls/sanitizer-core/witness-client.crt"
expect_doctor_red "RED witness client cert missing" "$V" "core witness client certificate missing"

V="$(variant badsan)"
W="$V/.certs/sanitizer-core-mtls"
printf 'basicConstraints = critical, CA:FALSE\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = serverAuth\nsubjectAltName = DNS:veil-witness\n' > "$TMP/badsan.ext"
openssl req -new -key "$W/veil-witness/dsa-veil-witness.key" -subj "/CN=veil-witness" -out "$TMP/badsan.csr" 2>/dev/null
openssl x509 -req -in "$TMP/badsan.csr" -CA "$W/ca/ca.crt" -CAkey "$W/ca/ca.key" -set_serial 0x1234 -days 30 -extfile "$TMP/badsan.ext" -out "$W/veil-witness/dsa-veil-witness.crt" 2>/dev/null
expect_doctor_red "RED witness leaf without the pinned SAN" "$V" "lacks the DNS SAN dsa-veil-witness"

V="$(variant cadiff)"
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/other-ca.key" 2>/dev/null
openssl req -new -x509 -key "$TMP/other-ca.key" -subj "/CN=other" -days 30 -out "$V/.certs/sanitizer-core-mtls/gateway/ca.crt" 2>/dev/null
expect_doctor_red "RED CA copies differ" "$V" "the three CA copies"

V="$(variant keymode)"; chmod 0644 "$V/.certs/sanitizer-core-mtls/gateway/dsa-gateway.key"
expect_doctor_red "RED private key readable by others" "$V" "is readable by group/others"

V="$(variant sha1)"
W="$V/.certs/sanitizer-core-mtls"
printf 'basicConstraints = critical, CA:FALSE\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = clientAuth\nsubjectAltName = DNS:dsa-gateway\n' > "$TMP/sha1.ext"
openssl req -new -key "$W/gateway/dsa-gateway.key" -subj "/CN=dsa-gateway" -out "$TMP/sha1.csr" 2>/dev/null
openssl x509 -req -sha1 -in "$TMP/sha1.csr" -CA "$W/ca/ca.crt" -CAkey "$W/ca/ca.key" -set_serial 0x4321 -days 30 -extfile "$TMP/sha1.ext" -out "$W/gateway/dsa-gateway.crt" 2>/dev/null
expect_doctor_red "RED SHA-1-signed leaf (Go refuses it; openssl verify does not)" "$V" "certificate is SHA-1-signed"

V="$(variant nodir)"; rm -rf "$V/.certs/sanitizer-core-mtls"
expect_doctor_red "RED cert directory missing" "$V" "does not exist — run scripts/bootstrap-sanitizer-core-mtls.sh"

V="$(variant profile)"; printf 'LCR_PROFILE=hosted\n' >> "$V/customer.env"
expect_doctor_red "RED LCR_PROFILE=hosted" "$V" "sanitizer core profile: failed (LCR_PROFILE=hosted"

V="$(variant halfpair)"; printf 'LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=sha256:%s\n' "$(printf 'c%.0s' $(seq 64))" >> "$V/customer.env"
expect_doctor_red "RED half a digest pair" "$V" "must come from one release"

V="$(variant regkey)"; sed -i.bak 's/^DSA_SANITIZER_CORE_REGISTRY_KEY=.*/DSA_SANITIZER_CORE_REGISTRY_KEY=REPLACE_ME_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "RED registry key placeholder" "$V" "DSA_SANITIZER_CORE_REGISTRY_KEY still set to a placeholder"

V="$(variant badpw)"; sed -i.bak 's/^POSTGRES_SANITIZER_CORE_PASSWORD=.*/POSTGRES_SANITIZER_CORE_PASSWORD=has@url:chars/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "RED registry DB password not URL-safe" "$V" "must use only A-Z a-z 0-9"

V="$(variant protocol)"; printf 'GATEWAY_SANITIZER_PROTOCOL=Delta\n' >> "$V/customer.env"
expect_doctor_red "RED off-enum GATEWAY_SANITIZER_PROTOCOL" "$V" "GATEWAY_SANITIZER_PROTOCOL must be delta or whole"

# ── Online doctor with a stub Docker engine ─────────────────────────────────
KEY="$TMP/customer.key"
printf '%s\n' 'lcr_live_synthetic_k_a_doctor_fixture_key' > "$KEY"
chmod 600 "$KEY"
SIDE_ID="5ide000000000000000000000000000000000000000000000000000000000001"
CORE_ID="c0re000000000000000000000000000000000000000000000000000000000002"
PG_ID="9f00000000000000000000000000000000000000000000000000000000000003"
GW_ID="9a7e000000000000000000000000000000000000000000000000000000000004"
cat > "$TMP/ps.ok" <<EOF
gateway|$GW_ID|running|healthy
postgres-sanitizer-core|$PG_ID|running|healthy
sanitizer-core-sidecar|$SIDE_ID|running|healthy
sanitizer-core|$CORE_ID|running|healthy
EOF
grep -v '^sanitizer-core-sidecar|' "$TMP/ps.ok" > "$TMP/ps.noside"
printf '%s\n' '2026/11/02 08:00:00 evidence: witness transport mode=mtls addr="veil-witness:50057"' > "$TMP/core.ok"
cp "$TMP/core.ok" "$TMP/core.drop"
printf '%s\n' '2026/11/02 08:01:00 ERROR retry_exhausted grpc_status=Unavailable attempts=4 retry_attempts=3; claim DROPPED' >> "$TMP/core.drop"
printf '%s\n' '2026/11/02 08:00:00 evidence: witness transport mode=tls-insecure-dev addr="veil-witness:50057"' > "$TMP/core.tls"
printf '%s\n' 'veil-claim-arrival request_id=r1 service_id=dsa-sanitizer' > "$TMP/witness.log"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","environment":{"LCR_WITNESS_REQUIRE_MTLS":"true"}}}}' > "$TMP/config.ok.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","environment":{"LCR_WITNESS_REQUIRE_MTLS":"true","LCR_PROFILE":"hosted"}}}}' > "$TMP/config.hosted.json"

doctor_online() { # env assignments for the stub...
  env PATH="$DBIN:$BASE_PATH" STUB_MEM_BYTES=34359738368 STUB_PS="$TMP/ps.ok" STUB_NETMODE="container:$SIDE_ID" \
    STUB_CORE_LOG="$TMP/core.ok" STUB_WITNESS_LOG="$TMP/witness.log" STUB_CONFIG_JSON="$TMP/config.ok.json" STUB_LEDGER_OUT=7 \
    "$@" bash "$ROOT/bin/lucairn" doctor --env "$ENVF" --compose "$COMPOSE" --customer-key-file "$KEY" --skip-image-check > "$TMP/online.out" 2>&1
  ONLINE_RC=$?
}
online_case() { # <name> <expected fixed text> <green|red> -- env...
  local name="$1" text="$2" want="$3"; shift 3
  doctor_online "$@"
  if grep -Fq "$text" "$TMP/online.out"; then
    if [ "$want" = red ] && grep -Fq 'lcr_live_synthetic_k_a_doctor_fixture_key' "$TMP/online.out"; then
      fail "$name — customer key leaked into doctor output"
    else
      pass "$name — '$text'"
    fi
  else
    fail "$name — expected '$text': $(grep -i 'sanitizer core' "$TMP/online.out" | tail -4 | tr '\n' ' ')"
  fi
  if [ "$want" = red ]; then
    # A red case must exit non-zero AND stop the doctor at the sanitizer-core
    # battery, before the runtime probes and the keyed journey ever run.
    if [ "$ONLINE_RC" -eq 0 ]; then fail "$name — doctor exited 0"
    elif grep -q 'gateway healthz:' "$TMP/online.out"; then fail "$name — doctor continued past the failed check"
    else pass "$name — doctor exited $ONLINE_RC and stopped at the failed check"; fi
  fi
}

online_case "GREEN online: memory" "sanitizer core memory: ok (32768 MiB docker-engine" green
for line in "sanitizer core rendered config: ok" "sanitizer core runtime: sanitizer-core-sidecar ok" "sanitizer core runtime: namespace ok" "sanitizer core registry: ok (7 migrations applied, ceiling 7)" "sanitizer core claims: transport ok (mtls)" "1 dsa-sanitizer claim arrival"; do
  grep -Fq "$line" "$TMP/online.out" && pass "GREEN online line: $line" || fail "GREEN online line: $line"
done
if grep -q 'sanitizer core.*failed' "$TMP/online.out"; then fail "GREEN online: no sanitizer-core check failed"; else pass "GREEN online: no sanitizer-core check failed"; fi

online_case "RED memory floor not met (8 GiB engine)" "sanitizer core memory: failed (8192 MiB (docker-engine) is below the kit 2.0 floor of 15000 MiB" red STUB_MEM_BYTES=8589934592
online_case "RED sidecar absent" "sanitizer core runtime: failed (sanitizer-core-sidecar absent" red STUB_PS="$TMP/ps.noside"
online_case "RED core joined to an old sidecar" "joined to an old sidecar container" red STUB_NETMODE="container:0ld0000000000000000000000000000000000000000000000000000000000009"
online_case "RED registry not migrated" "sanitizer core registry: failed (not migrated" red STUB_LEDGER_OUT='ERROR:  relation "registry_schema_migrations" does not exist'
online_case "RED registry behind the ceiling" "ledger at 5 of 7 migrations" red STUB_LEDGER_OUT=5
online_case "RED claims dropped" "claim(s) DROPPED" red STUB_CORE_LOG="$TMP/core.drop"
online_case "RED witness transport not mtls" "witness transport mode=tls-insecure-dev, not mtls" red STUB_CORE_LOG="$TMP/core.tls"
online_case "RED overlay forwards LCR_PROFILE=hosted" "LCR_PROFILE is forwarded with a non-kit value" red STUB_CONFIG_JSON="$TMP/config.hosted.json"
online_case "not started (nothing running) is not a failure" "sanitizer core runtime: not started" green STUB_PS=/dev/null

echo ""
if [ "$FAILS" -eq 0 ]; then
  if [ "$SKIPS" -gt 0 ]; then
    echo "sanitizer core compose + doctor (K-A): ok ($N checks; $SKIPS section(s) NOT RUN — see above)"
  else
    echo "sanitizer core compose + doctor (K-A): ok ($N checks)"
  fi
  exit 0
fi
echo "sanitizer core compose + doctor (K-A): $FAILS of $N checks FAILED" >&2
exit 1
