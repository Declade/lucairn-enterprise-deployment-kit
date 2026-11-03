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
#   D2. scripts/write-sanitizer-core-registry-dsn.sh (DSA #956: the core reads
#      its registry DSN from --registry-dsn-file, never --dsn): the exact
#      postgres:// URL with the password percent-encoded, mode 0444 in a 0700
#      directory, idempotent (same inode), refusals (unsafe password, missing
#      password, bad sslmode, a directory at the path, an open directory), and
#      neither the DSN nor the password is ever printed.
#   E. `bin/lucairn doctor` RED-PROOF (each case goes red on a deliberately
#      broken install and green on the generated one): witness client cert
#      missing, wrong witness SAN, CA copies differ, key readable by others,
#      LCR_PROFILE=hosted, half a digest pair, registry key placeholder — and,
#      registry DSN file missing / a directory / not a URL / out of date /
#      open to other host users / unreadable by the core (Linux), a compose
#      file passing --dsn — and, online with a stub Docker engine: memory below
#      the floor, sidecar absent, core joined to an old sidecar namespace,
#      registry not migrated, claims dropped, plaintext witness transport, an
#      overlay forwarding LCR_PROFILE=hosted, a rendered core with --dsn, with
#      no DSN source, or with an unmounted --registry-dsn-file path.
#   F. `bin/lucairn support-bundle` never carries the DSN file: the archive of
#      the generated install holds neither the DSN nor the password, and a
#      collected file that does (a redaction miss) makes it refuse to archive.
#
# FIX ROUND 1 (sol r1 on PR #158: four P2 + point 6), each red on 0e51bca:
#   1. customer.env is read EXACTLY as Docker Compose reads it, by ONE reader
#      the DSN writer and doctor share (bin/compose-env-lib.sh): D2 quote
#      cases (`"BoundaryProbe4829'"` is refused, not stripped), E doctor REDs,
#      and D3 — the reader and Docker Compose itself agree on a corpus.
#   2. support-bundle scans for every secret value the kit knows, whether or
#      not the DSN file exists (F: DSN missing + a planted password / registry
#      key / signing key -> refused; an online bundle is not falsely refused).
#   3. the core's namespace sits on three dedicated internal networks, one per
#      link (B: only the gateway shares a network with the core's listener; the
#      core reaches only its registry DB and the witness; no egress; the
#      witness-central overlay adds exactly one egress link with no other member).
#   4. the core/sidecar pair never starts from a bare tag: Compose refuses to
#      render without both digests (B), doctor FAILS while the manifest is
#      pending / the env digests are empty or differ (E), and verify-images
#      covers the pair and fails closed while it is pending (G). GREEN cases
#      run against a released-kit fixture with SYNTHETIC signed digests.
#   6. an unreadable migration ledger is a doctor failure, not a note (E online).
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
#   * The core's own parse of the DSN file (URL form, path refusal) is the DSA
#     repo's registry_dsn tests; here the file's exact bytes are asserted. The
#     kit-written file was also run through `sanitizer-core serve` built from
#     DSA main ed8a5858 (out of band: it passes every DSN check and stops only
#     at the registry connection).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test-helpers.sh
. "$ROOT/tests/lib/test-helpers.sh"
COMPOSE="$ROOT/docker-compose.customer.yml"
SELFHOSTED="$ROOT/docker-compose.self-hosted.yml"
EXAMPLE_ENV="$ROOT/customer.env.example"
CEILINGS="$ROOT/scripts/migration-ceilings.conf"
MIGDIR="$ROOT/migrations/sanitizer-core"
RUNNER="$ROOT/scripts/migrate-sanitizer-core.sh"
BOOTSTRAP="$ROOT/scripts/bootstrap-sanitizer-core-mtls.sh"
WRITER="$ROOT/scripts/write-sanitizer-core-registry-dsn.sh"
DSN_TARGET="/run/secrets/sanitizer-core/registry-dsn"

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
  # The example env with the (synthetic) signed digests a kit release records:
  # without them the project does not render at all (asserted below).
  PINNED_ENV="$TMP/example-pinned.env"
  cp "$EXAMPLE_ENV" "$PINNED_ENV"
  printf '\nLUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=%s\nLUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=%s\n' \
    "$TEST_SANITIZER_CORE_DIGEST" "$TEST_SANITIZER_CORE_SIDECAR_DIGEST" >> "$PINNED_ENV"
  cp "$PINNED_ENV" "$TMP/render.env"
  printf '\nSANDBOX_B_MESSAGES_JSON_MAX_BYTES=8388608\nPOSTGRES_SANITIZER_CORE_PASSWORD=k158RenderCanaryPassword\n' >> "$TMP/render.env"
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
# Network isolation (fix round 1, sol r1 finding 3): ONE internal network per
# link of the core, shared with nothing else. Only the gateway reaches the
# core; the core reaches only its registry DB and the witness; no egress.
CORE_LINKS = {"dsa-sanitizer-core-ingress": {"gateway", "sanitizer-core-sidecar"},
              "dsa-sanitizer-core-witness": {"sanitizer-core-sidecar", "veil-witness"},
              "dsa-sanitizer-core": {"postgres-sanitizer-core", "sanitizer-core-sidecar", "migrate-sanitizer-core"}}
p(set(sn) == set(CORE_LINKS), "sidecar (= the core's namespace) on exactly the three core links (%s)" % sorted(sn))
def members(net):
    return {n for n, x in svcs.items() if net in (x.get("networks") or {})}
for net, want in sorted(CORE_LINKS.items()):
    p(nets.get(net, {}).get("internal") is True, "%s is internal: true (no route off the host)" % net)
    p(members(net) == want, "%s members = %s (got %s)" % (net, sorted(want), sorted(members(net))))
p(all(nets.get(n, {}).get("internal") is True for n in sn), "every network of the core's namespace is internal (no external egress)")
reach = {n for net in sn for n in members(net)} - {"sanitizer-core-sidecar"}
p(reach == {"gateway", "veil-witness", "postgres-sanitizer-core", "migrate-sanitizer-core"},
  "the only services sharing a network with the core: gateway, veil-witness, its registry DB + migrate step (%s)" % sorted(reach))
p(not {"dsa-identity", "dsa-witness-identity"} & set(sn), "the core's namespace is off the shared identity + witness-identity bridges")
al = set((sn.get("dsa-sanitizer-core-ingress") or {}).get("aliases") or [])
p({"sanitizer-core", "dsa-sanitizer-core"} <= al, "sidecar answers for sanitizer-core + dsa-sanitizer-core on the ingress link (the core's SANs)")
p(not (sn.get("dsa-sanitizer-core-witness") or {}).get("aliases") and not (sn.get("dsa-sanitizer-core") or {}).get("aliases"), "no alias for the core on the witness / registry links")
p(not side.get("ports") and not core.get("ports") and not pg.get("ports"), "no host port on core / sidecar / registry DB")
p(list((pg.get("networks") or {}).keys()) == ["dsa-sanitizer-core"], "registry DB only on dsa-sanitizer-core")
# Memory caps (the hosted window's A8 values).
def lim(s):
    return ((s.get("deploy") or {}).get("resources") or {}).get("limits", {}).get("memory")
p(str(side.get("mem_limit")) == str(6500 * 1024 * 1024) and str(lim(side)) == str(6500 * 1024 * 1024), "sidecar capped at 6500 MiB (mem_limit + deploy limit) — got %s / %s" % (side.get("mem_limit"), lim(side)))
p(str(side.get("memswap_limit")) == str(6500 * 1024 * 1024), "sidecar swap capped at the same 6500 MiB")
p(str(core.get("mem_limit")) == str(1024 ** 3) and str(lim(core)) == str(1024 ** 3), "core capped at 1 GiB")
# Images: one tag for the pair, ALWAYS pulled by the signed digest; digest-pinned
# postgres for the new DB services.
ci, si = core.get("image", ""), side.get("image", "")
p(re.fullmatch(r"ghcr\.io/declade/dsa-sanitizer-core:1\.1\.0@sha256:[0-9a-f]{64}", ci) is not None, "core image ghcr.io/declade/dsa-sanitizer-core:1.1.0@sha256:… (%s)" % ci)
p(re.fullmatch(r"ghcr\.io/declade/dsa-sanitizer-core-sidecar:1\.1\.0@sha256:[0-9a-f]{64}", si) is not None, "sidecar image ghcr.io/declade/dsa-sanitizer-core-sidecar:1.1.0@sha256:… (%s)" % si)
pgd = re.search(r'postgres:\n\s+ref: "postgres:16-alpine"[\s\S]*?digest: "(sha256:[0-9a-f]{64})"', manifest)
want_pg = "postgres:16-alpine@" + (pgd.group(1) if pgd else "?")
p(pg.get("image") == want_pg and mig.get("image") == want_pg, "registry DB + migrate step pinned to the manifest postgres digest")
# Core command + entrypoint: hosted watchdog, never --migrate.
cmd = core.get("command") or []
p("serve" in cmd and "--listen=0.0.0.0:8790" in cmd and "--sidecar=http://127.0.0.1:8765" in cmd, "core serves :8790 with the sidecar on 127.0.0.1:8765")
p(not any(a.startswith("--migrate") for a in cmd), "core command never carries --migrate (migrations are an operator step)")
# Registry DSN (DSA #956): a mounted file, never --dsn, never the password in the core's config.
p("--registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn" in cmd, "core reads its DSN with --registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn")
p(not any(re.search(r"(^|[\s\"'])--?dsn([=\s\"']|$)", a) for a in cmd + list(core.get("entrypoint") or [])), "core command/entrypoint carry no --dsn")
dsnp = "/run/secrets/sanitizer-core/registry-dsn"
p("://" not in dsnp and "@" not in dsnp, "the --registry-dsn-file path holds neither :// nor @ (the core refuses those)")
dm = [v for v in (core.get("volumes") or []) if v.get("target") == dsnp]
p(len(dm) == 1 and dm[0].get("type") == "bind" and dm[0].get("read_only") is True
  and (dm[0].get("bind") or {}).get("create_host_path") is not True
  and dm[0].get("source", "").endswith("/.secrets/sanitizer-core/registry-dsn"),
  "the DSN file is ONE read-only bind of .secrets/sanitizer-core/registry-dsn, never auto-created (%s)" % dm)
others = [n for n, x in svcs.items() if n != "sanitizer-core" and any(v.get("target") == dsnp or v.get("source", "").endswith("/.secrets/sanitizer-core/registry-dsn") for v in (x.get("volumes") or []))]
p(not others, "no other service mounts the DSN file (%s)" % others)
p("k158RenderCanaryPassword" not in json.dumps(core), "the registry password appears nowhere in the core's rendered config")
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

  SERVICES="$(docker compose -f "$COMPOSE" -f "$SELFHOSTED" --env-file "$PINNED_ENV" config --services 2>/dev/null || true)"
  if printf '%s\n' "$SERVICES" | grep -qx migrate-sanitizer-core; then
    fail "migrate-sanitizer-core-not-in-default-project (a plain up would run it)"
  else
    pass "migrate-sanitizer-core-not-in-default-project"
  fi
  # The base file alone (split-remote topology) also carries the core.
  # Captured first: `| grep -q` under pipefail SIGPIPEs the writer and reads as a failure.
  BASE_SERVICES="$(docker compose -f "$COMPOSE" --env-file "$PINNED_ENV" config --services 2>/dev/null || true)"
  if printf '%s\n' "$BASE_SERVICES" | grep -qx sanitizer-core; then
    pass "split-remote base file carries the core"
  else
    fail "split-remote base file carries the core"
  fi
  # Fix round 1 (sol r1 finding 4): the pair never starts from a bare tag.
  # The example env carries no digest (the release records them), so the
  # project refuses to render at all; half a pair refuses too.
  if docker compose -f "$COMPOSE" --env-file "$EXAMPLE_ENV" config --quiet > "$TMP/nodigest.out" 2>&1; then
    fail "no core/sidecar digest -> the project refuses to render (it rendered: the pair would start by tag)"
  elif grep -q 'LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST must be the signed digest' "$TMP/nodigest.out"; then
    pass "no core/sidecar digest -> the project refuses to render, naming LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST"
  else
    fail "no core/sidecar digest -> refused, but not by the digest guard: $(tail -1 "$TMP/nodigest.out")"
  fi
  cp "$EXAMPLE_ENV" "$TMP/halfdigest.env"
  printf '\nLUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=%s\n' "$TEST_SANITIZER_CORE_DIGEST" >> "$TMP/halfdigest.env"
  if docker compose -f "$COMPOSE" --env-file "$TMP/halfdigest.env" config --quiet > "$TMP/nodigest.out" 2>&1; then
    fail "only the core digest -> the project refuses to render (it rendered)"
  elif grep -q 'LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST must be the signed digest' "$TMP/nodigest.out"; then
    pass "only the core digest -> refuses to render, naming LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST"
  else
    fail "only the core digest -> refused, but not by the sidecar digest guard: $(tail -1 "$TMP/nodigest.out")"
  fi
  # The witness-central overlay gives the core's namespace exactly ONE extra
  # link: non-internal (the central witness is off the host), no other member.
  cp "$PINNED_ENV" "$TMP/central.env"
  printf '\nLUCAIRN_CENTRAL_WITNESS_ADDR=witness.example.invalid:50057\nLUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.example.invalid:50058\nLUCAIRN_WITNESS_CLIENT_CERT_DIR=%s\nLUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR=%s\n' "$TMP/wc-claim" "$TMP/wc-gw" >> "$TMP/central.env"
  if docker compose -f "$COMPOSE" -f "$ROOT/contrib/witness-central/docker-compose.witness-central.yml" --env-file "$TMP/central.env" \
       config --format json > "$TMP/central.json" 2> "$TMP/central.err"; then
    python3 - "$TMP/central.json" > "$TMP/central-check.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); svcs, nets = d["services"], d.get("networks", {})
sn = set((svcs["sanitizer-core-sidecar"].get("networks") or {}))
extra = sn - {"dsa-sanitizer-core-ingress", "dsa-sanitizer-core-witness", "dsa-sanitizer-core"}
def members(net): return {n for n, x in svcs.items() if net in (x.get("networks") or {})}
ok = len(extra) == 1 and not nets.get(next(iter(extra)), {}).get("internal") and members(next(iter(extra))) == {"sanitizer-core-sidecar"}
print(("ok " if ok else "FAIL ") + "witness-central: the core's namespace gains ONE egress link with no other member (%s)" % sorted(extra))
PY
    while IFS= read -r line; do
      case "$line" in ok\ *) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac
    done < "$TMP/central-check.txt"
  else
    fail "witness-central overlay renders: $(tail -2 "$TMP/central.err")"
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
  grep -v '^DSA_SANITIZER_CORE_REGISTRY_KEY=' "$PINNED_ENV" > "$TMP/nokey.env"
  if docker compose -f "$COMPOSE" --env-file "$TMP/nokey.env" config --quiet >/dev/null 2>&1; then
    fail "missing DSA_SANITIZER_CORE_REGISTRY_KEY refuses to render"
  else
    pass "missing DSA_SANITIZER_CORE_REGISTRY_KEY refuses to render"
  fi
  grep -v '^POSTGRES_SANITIZER_CORE_PASSWORD=' "$PINNED_ENV" > "$TMP/nopw.env"
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
echo "D2. scripts/write-sanitizer-core-registry-dsn.sh"
file_mode() { case "$(uname -s)" in Darwin|FreeBSD|OpenBSD|NetBSD) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac; }
file_inode() { case "$(uname -s)" in Darwin|FreeBSD|OpenBSD|NetBSD) stat -f '%i' "$1" ;; *) stat -c '%i' "$1" ;; esac; }
WD="$TMP/dsnw"
mkdir -p "$WD"
# Every URL-syntax character the core's parser would misread, plus the
# unreserved ones that must stay literal.
SPECIAL_PW='Pa@ss/w:rd?%&+=x-~._Z9'
SPECIAL_ENC='Pa%40ss%2Fw%3Ard%3F%25%26%2B%3Dx-~._Z9'
printf 'POSTGRES_SANITIZER_CORE_PASSWORD=%s\nPOSTGRES_SSLMODE=require\n' "$SPECIAL_PW" > "$WD/e.env"
DF="$WD/sec/sanitizer-core/registry-dsn"
if bash "$WRITER" --env-file "$WD/e.env" "$DF" > "$WD/w.out" 2>&1; then pass "writer runs"; else fail "writer runs: $(tail -2 "$WD/w.out")"; fi
check_eq "file = the exact postgres:// URL, password percent-encoded, sslmode from customer.env" \
  "postgres://dsa:${SPECIAL_ENC}@postgres-sanitizer-core:5432/sanitizer_core?sslmode=require" "$(cat "$DF" 2>/dev/null)"
check_eq "file is one line" "1" "$(wc -l < "$DF" | tr -d ' ')"
check_eq "file mode 0444 (readable by the core's uid whoever wrote it)" "444" "$(file_mode "$DF")"
check_eq "directory mode 0700 (other host users kept out)" "700" "$(file_mode "$(dirname "$DF")")"
if grep -Fq "$SPECIAL_PW" "$WD/w.out" || grep -Fq "$SPECIAL_ENC" "$WD/w.out"; then fail "writer never prints the password or the DSN"; else pass "writer never prints the password or the DSN"; fi
INO1="$(file_inode "$DF")"
bash "$WRITER" --env-file "$WD/e.env" "$DF" > "$WD/w2.out" 2>&1
check_eq "re-run leaves an up-to-date file alone (same inode: a running core is unaffected)" "$INO1" "$(file_inode "$DF")"
printf 'POSTGRES_SANITIZER_CORE_PASSWORD=plainhexvalue0123456789\n' > "$WD/p.env"
bash "$WRITER" --env-file "$WD/p.env" "$DF" > /dev/null 2>&1
check_eq "a changed password rewrites the file (sslmode defaults to disable)" \
  "postgres://dsa:plainhexvalue0123456789@postgres-sanitizer-core:5432/sanitizer_core?sslmode=disable" "$(cat "$DF")"
check_eq "rewritten file keeps mode 0444" "444" "$(file_mode "$DF")"
expect_writer_refuses() { # <name> <env content> <path> <grep-fixed message>
  printf '%s\n' "$2" > "$WD/r.env"
  bash "$WRITER" --env-file "$WD/r.env" "$3" > "$WD/r.out" 2>&1; local rc=$?
  cat "$WD/r.out" >> "$WD/r.all"
  if [ "$rc" -eq 0 ]; then
    fail "$1 — writer accepted it"
  elif grep -Fq "$4" "$WD/r.out"; then
    pass "$1 — refused: $4"
  else
    fail "$1 — refused without '$4': $(tail -1 "$WD/r.out")"
  fi
}
expect_writer_refuses "unsafe password (\$)" 'POSTGRES_SANITIZER_CORE_PASSWORD=has$dollar' "$WD/x1/f" "cannot carry safely"
expect_writer_refuses "unsafe password (space)" 'POSTGRES_SANITIZER_CORE_PASSWORD=has space' "$WD/x2/f" "cannot carry safely"
expect_writer_refuses "missing password" 'OTHER=1' "$WD/x3/f" "POSTGRES_SANITIZER_CORE_PASSWORD is not set"
expect_writer_refuses "off-enum sslmode" "$(printf 'POSTGRES_SANITIZER_CORE_PASSWORD=okpassword123\nPOSTGRES_SSLMODE=on')" "$WD/x4/f" "POSTGRES_SSLMODE must be one of"
mkdir -p "$WD/x5/f"
expect_writer_refuses "a directory at the path (Docker's auto-created bind source)" 'POSTGRES_SANITIZER_CORE_PASSWORD=okpassword123' "$WD/x5/f" "is a directory"
mkdir -p "$WD/x6"; chmod 0755 "$WD/x6"
expect_writer_refuses "a directory open to group/others" 'POSTGRES_SANITIZER_CORE_PASSWORD=okpassword123' "$WD/x6/f" "must keep group and others out"
[ ! -e "$WD/x6/f" ] && pass "nothing written into the open directory" || fail "nothing written into the open directory"
if grep -q 'dollar\|okpassword123' "$WD/r.all"; then fail "refusals never print the password"; else pass "refusals never print the password"; fi

# Fix round 1 (sol r1 finding 1): customer.env is read EXACTLY as Docker
# Compose reads it (bin/compose-env-lib.sh): only a MATCHING pair of outer
# quotes is removed. The old per-line reader stripped a lone trailing quote,
# so this password reached validation as BoundaryProbe4829 while Postgres got
# the apostrophe.
expect_writer_refuses "a lone trailing apostrophe inside double quotes (Compose keeps it)" \
  "POSTGRES_SANITIZER_CORE_PASSWORD=\"BoundaryProbe4829'\"" "$WD/q1/f" "cannot carry safely"
expect_writer_refuses "mismatched quotes (Compose refuses the file)" \
  "POSTGRES_SANITIZER_CORE_PASSWORD=\"BoundaryProbe4829'" "$WD/q2/f" "unterminated quoted value"
expect_writer_refuses "an unquoted value ending in a quote (Compose keeps it)" \
  "POSTGRES_SANITIZER_CORE_PASSWORD=BoundaryProbe4829\"" "$WD/q3/f" "cannot carry safely"
expect_writer_refuses "an octal escape in double quotes (Compose turns \\0101 into A; not evaluated here)" \
  'POSTGRES_SANITIZER_CORE_PASSWORD="Boundary\0101Probe4829"' "$WD/q4/f" "cannot carry safely"
expect_writer_refuses "a value Compose takes from \$-interpolation" \
  'POSTGRES_SANITIZER_CORE_PASSWORD=${OTHER_SECRET}' "$WD/q5/f" "cannot carry safely"
writer_gets() { # <name> <env content> <expected password, encoded>
  printf '%s\n' "$2" > "$WD/g.env"
  rm -rf "$WD/g"
  if bash "$WRITER" --env-file "$WD/g.env" "$WD/g/f" > "$WD/g.out" 2>&1; then
    check_eq "$1" "postgres://dsa:$3@postgres-sanitizer-core:5432/sanitizer_core?sslmode=disable" "$(cat "$WD/g/f")"
  else
    fail "$1 — writer refused: $(tail -1 "$WD/g.out")"
  fi
}
writer_gets "a matching pair of double quotes is removed" 'POSTGRES_SANITIZER_CORE_PASSWORD="QuotedPassword4829"' "QuotedPassword4829"
writer_gets "a matching pair of single quotes is removed" "POSTGRES_SANITIZER_CORE_PASSWORD='QuotedPassword4829'" "QuotedPassword4829"
writer_gets "= inside a quoted value is kept (and encoded)" 'POSTGRES_SANITIZER_CORE_PASSWORD="a=b=c4829probe"' "a%3Db%3Dc4829probe"
writer_gets "= inside an unquoted value is kept (and encoded)" 'POSTGRES_SANITIZER_CORE_PASSWORD=a=b=c4829probe' "a%3Db%3Dc4829probe"
writer_gets "a comment after the closing quote is not part of the value" 'POSTGRES_SANITIZER_CORE_PASSWORD="QuotedPassword4829" # rotated 2026-11' "QuotedPassword4829"
writer_gets "export prefix, spaces around =, CRLF line end" "$(printf 'export POSTGRES_SANITIZER_CORE_PASSWORD = CrlfPassword4829\r')" "CrlfPassword4829"
writer_gets "the last assignment wins" "$(printf 'POSTGRES_SANITIZER_CORE_PASSWORD=FirstPassword4829\nPOSTGRES_SANITIZER_CORE_PASSWORD=SecondPassword4829')" "SecondPassword4829"
writer_gets "a KEY= line INSIDE a multi-line quoted value is not an assignment (Compose reads one token stream)" \
  "$(printf "POSTGRES_SANITIZER_CORE_PASSWORD=RealPassword4829\nOPERATOR_NOTE='old values:\nPOSTGRES_SANITIZER_CORE_PASSWORD=NotThePassword1\n'")" "RealPassword4829"
# The shell beats the file in Compose: an exported value that differs from
# customer.env would reach Postgres while the DSN file carried the file's.
printf 'POSTGRES_SANITIZER_CORE_PASSWORD=FilePassword4829\n' > "$WD/sh.env"
if POSTGRES_SANITIZER_CORE_PASSWORD=ShellPassword4829 bash "$WRITER" --env-file "$WD/sh.env" "$WD/sh/f" > "$WD/sh.out" 2>&1; then
  fail "a differing exported POSTGRES_SANITIZER_CORE_PASSWORD is refused — writer accepted it"
elif grep -q 'is exported in this shell' "$WD/sh.out" && ! grep -q 'Password4829' "$WD/sh.out"; then
  pass "a differing exported POSTGRES_SANITIZER_CORE_PASSWORD is refused (no value printed)"
else
  fail "a differing exported POSTGRES_SANITIZER_CORE_PASSWORD is refused — $(tail -1 "$WD/sh.out")"
fi

echo ""
echo "D3. bin/compose-env-lib.sh reads customer.env exactly as Docker Compose does"
# The SAME corpus through the kit's reader and through Docker Compose itself
# (`config --format json` of a one-service probe project; client-side only).
# Agreement = same value, or both refuse the file. rc 3 (a construct the
# reader does not evaluate) is a refusal by design and needs no agreement.
if [ "$HAVE_COMPOSE" -ne 1 ]; then
  skip "docker compose CLI not available — section D3"
else
  # shellcheck source=../bin/compose-env-lib.sh
  . "$ROOT/bin/compose-env-lib.sh"
  PD="$TMP/envprobe"; mkdir -p "$PD"
  printf 'services:\n  p:\n    image: scratch\n    environment:\n      V: "${K-}"\n' > "$PD/probe.yml"
  D3_AGREE=0; D3_REFUSED=0; D3_BAD=""
  d3() { # <env file content (printf %b)>
    printf '%b' "$1" > "$PD/t.env"
    local ours rc theirs crc
    ours="$(compose_env_get "$PD/t.env" K)"; rc=$?
    theirs="$(env -i PATH="$BASE_PATH" HOME="$HOME" docker compose -f "$PD/probe.yml" --project-directory "$PD" --env-file "$PD/t.env" config --format json 2>/dev/null \
      | python3 -c 'import json,sys
try: sys.stdout.write(json.load(sys.stdin)["services"]["p"]["environment"]["V"].replace("$$","$"))
except Exception: sys.exit(9)')"; crc=$?
    if [ "$rc" -eq 0 ] && [ "$crc" -eq 0 ] && [ "$ours" = "$theirs" ]; then D3_AGREE=$((D3_AGREE + 1))
    elif [ "$rc" -eq 2 ] && [ "$crc" -ne 0 ]; then D3_AGREE=$((D3_AGREE + 1))
    elif [ "$rc" -eq 3 ]; then D3_REFUSED=$((D3_REFUSED + 1))
    else D3_BAD="$D3_BAD [$1 => ours rc=$rc '$ours' / compose rc=$crc '$theirs']"; fi
  }
  # sol r1's case, mismatched and nested quotes, = inside values, comments
  d3 'K="BoundaryProbe4829\x27"\n'; d3 'K=\x27abc\x27\n'; d3 'K="abc\n'; d3 'K=\x27abc"\n'; d3 'K=abc"\n'; d3 'K=abc\x27\n'
  d3 'K="a"\x27\n'; d3 'K=a=b=c\n'; d3 'K="a=b=c"\n'; d3 'K=abc # c\n'; d3 'K=abc#not-a-comment\n'; d3 'K=abc\t# c\n'
  d3 'K="abc" # c\n'; d3 'K="abc"junk\n'; d3 'K=\x27a\x27 junk\n'; d3 'K=a  #c\n'
  # duplicates, inherited names, export, YAML style, white space, CRLF, BOM, no final newline
  d3 'K=1\nK="2"\n'; d3 'K=1\nK\n'; d3 'export K=exp\n'; d3 'export\tK=exp\n'; d3 'exportK=x\n'; d3 'K: yaml\n'
  d3 'K = sp \n'; d3 'K\t=tab\n'; d3 'K=x\r\n'; d3 'K="x"\r\n'; d3 '\xef\xbb\xbfK=bom\n'; d3 'K=nofinalnl'
  d3 'K=\n'; d3 'K=""\n'; d3 'K=\x27\x27\n'; d3 '\n\n\nK=late\n\n'; d3 '  # comment\nK=after\n'; d3 'K=x\n#K=y\n'
  d3 'K=x\n  K=y\n'; d3 'K=x\nexport K=y\n'; d3 'K=x\nfoo\n'; d3 'K=x\nfoo'; d3 'K=x\nexport'; d3 'K=x\nexport '
  d3 'K.dot=1\nK=2\n'; d3 'K[]=1\nK=2\n'; d3 'K:\nK=v\n'
  # multi-line quoted values: a KEY= line inside one is not a statement
  d3 'K="multi\nK=inner\n"\n'; d3 'K=real\nX=\x27\nK=fake\n\x27\n'; d3 'X="\nK=fake\n"\nK=real\n'
  # escapes and interpolation (single quotes are literal)
  d3 'K=\x27it\\\x27s\x27\n'; d3 'K="q\\"q"\n'; d3 'K=\x27a\\b\x27\n'; d3 'K=a\\b\n'; d3 'K="a\\0101"\n'; d3 'K=$X\n'; d3 'K=\x27$X\x27\n'; d3 'K="\\\\"\n'
  # syntax errors Compose refuses, Unicode white space and letters
  d3 'KE Y=x\n'; d3 'K;=x\n'; d3 'K="a b"\n'; d3 'K=a b\n'; d3 'K=\xc2\xa0x\n'; d3 'K=x\xc2\xa0\n'; d3 'K=x\xe2\x80\x80\n'
  d3 '\xc2\xa0K=nbsp\n'; d3 'K\xc2\xa0=nbsp\n'; d3 'K=\xc3\xa4\n'; d3 'G\xc3\x9cN=1\nK=2\n'
  if [ -z "$D3_BAD" ]; then
    pass "reader == Docker Compose on $D3_AGREE corpus files ($D3_REFUSED more refused as not evaluated: escapes, interpolation, a non-ASCII name)"
  else
    fail "reader disagrees with Docker Compose:$D3_BAD"
  fi
  [ "$D3_AGREE" -ge 55 ] && pass "the agreement corpus is not trivially small ($D3_AGREE files)" || fail "the agreement corpus is not trivially small ($D3_AGREE files)"
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

# A RELEASED kit (fix round 1, sol r1 finding 4): this checkout's manifest
# still says `pending: true` for the core/sidecar pair, so an install made from
# it cannot start and doctor fails (asserted below). Every GREEN case therefore
# runs init + doctor from a fixture kit whose manifest records SYNTHETIC
# signed digests (tests/lib/test-helpers.sh lucairn_released_kit_fixture).
KIT="$TMP/released-kit"
lucairn_released_kit_fixture "$ROOT" "$KIT" && pass "fixture: a released kit (synthetic signed core/sidecar digests)" \
  || fail "fixture: a released kit (synthetic signed core/sidecar digests)"
KIT_COMPOSE="$KIT/docker-compose.customer.yml"
ENVDIR="$TMP/install"
mkdir -p "$ENVDIR"
ENVF="$ENVDIR/customer.env"
PATH="$DBIN:$BASE_PATH" "$KIT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$ENVF" --skip-doctor > "$TMP/init.out" 2>&1 \
  || { fail "lucairn-init for the doctor fixture: $(tail -3 "$TMP/init.out")"; }
CERTS="$ENVDIR/.certs/sanitizer-core-mtls"
grep -q "^SANITIZER_CORE_MTLS_HOST_DIR=$CERTS$" "$ENVF" && pass "lucairn-init records the cert directory beside customer.env" || fail "lucairn-init records the cert directory beside customer.env"
[ -f "$CERTS/sanitizer-core/witness-client.crt" ] && pass "lucairn-init generated the core's mTLS material" || fail "lucairn-init generated the core's mTLS material"
grep -Eq '^DSA_SANITIZER_CORE_REGISTRY_KEY=[0-9a-f]{64}$' "$ENVF" && pass "lucairn-init generated the registry key" || fail "lucairn-init generated the registry key"
grep -Eq '^POSTGRES_SANITIZER_CORE_PASSWORD=[A-Za-z0-9]{32}$' "$ENVF" && pass "lucairn-init generated the registry DB password" || fail "lucairn-init generated the registry DB password"
DSNF="$ENVDIR/.secrets/sanitizer-core/registry-dsn"
grep -q "^SANITIZER_CORE_REGISTRY_DSN_FILE=$DSNF$" "$ENVF" && pass "lucairn-init records the DSN file beside customer.env" || fail "lucairn-init records the DSN file beside customer.env"
INIT_PW="$(sed -n 's/^POSTGRES_SANITIZER_CORE_PASSWORD=//p' "$ENVF" | tail -1)"
check_eq "lucairn-init wrote the DSN file from the generated password" \
  "postgres://dsa:${INIT_PW}@postgres-sanitizer-core:5432/sanitizer_core?sslmode=disable" "$(cat "$DSNF" 2>/dev/null)"
check_eq "lucairn-init's DSN file is 0444 in a 0700 directory" "444/700" "$(file_mode "$DSNF")/$(file_mode "$(dirname "$DSNF")")"
if grep -Fq "$INIT_PW" "$TMP/init.out"; then fail "lucairn-init never prints the registry password"; else pass "lucairn-init never prints the registry password"; fi
# Two lucairn-init runs into ONE directory with different --output names: each
# env gets its own DSN file (it carries that env's password); the second run
# must not overwrite the first env's file (found by test_lucairn_cli.sh).
TWO="$TMP/twoinit"; mkdir -p "$TWO"
for n in customer.env second.env; do
  PATH="$DBIN:$BASE_PATH" "$KIT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
    --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$TWO/$n" --skip-doctor > "$TMP/twoinit.out" 2>&1 \
    || fail "lucairn-init --output $n into a shared directory: $(tail -2 "$TMP/twoinit.out")"
done
grep -q "^SANITIZER_CORE_REGISTRY_DSN_FILE=$TWO/.secrets/sanitizer-core/second.env.registry-dsn$" "$TWO/second.env" \
  && pass "a non-customer.env output gets its own <name>.registry-dsn" || fail "a non-customer.env output gets its own <name>.registry-dsn"
for n in customer.env second.env; do
  pw="$(sed -n 's/^POSTGRES_SANITIZER_CORE_PASSWORD=//p' "$TWO/$n" | tail -1)"
  f="$(sed -n 's/^SANITIZER_CORE_REGISTRY_DSN_FILE=//p' "$TWO/$n" | tail -1)"
  check_eq "after both runs, $n's DSN file still matches $n" \
    "postgres://dsa:${pw}@postgres-sanitizer-core:5432/sanitizer_core?sslmode=disable" "$(cat "$f" 2>/dev/null)"
done

doctor_offline() { # <env file> — offline doctor, hermetic PATH
  PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" doctor --env "$1" --compose "$KIT_COMPOSE" --offline --skip-image-check > "$TMP/doc.out" 2>&1
}
variant() { # <name> — copy of the generated install (env + certs + sidecars)
  local d="$TMP/v-$1"
  rm -rf "$d"; mkdir -p "$d"
  cp -R "$ENVDIR/." "$d/"
  sed -i.bak -e "s#^SANITIZER_CORE_MTLS_HOST_DIR=.*#SANITIZER_CORE_MTLS_HOST_DIR=$d/.certs/sanitizer-core-mtls#" \
    -e "s#^SANITIZER_CORE_REGISTRY_DSN_FILE=.*#SANITIZER_CORE_REGISTRY_DSN_FILE=$d/.secrets/sanitizer-core/registry-dsn#" "$d/customer.env" && rm -f "$d/customer.env.bak"
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
for line in "sanitizer core registry key: ok" "sanitizer core registry DB password: ok" "sanitizer core registry DSN: ok" "sanitizer core profile: kit" "sanitizer core mTLS: ok" "sanitizer core images: ok (core + sidecar pinned to the signed manifest pair)"; do
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

V="$(variant halfpair)"; sed -i.bak 's/^LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=.*/LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "RED half a digest pair" "$V" "set LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST and LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST together"
# Fix round 1 (sol r1 finding 4): pending / empty digests are failures, never notes.
V="$(variant baretag)"; sed -i.bak -e 's/^LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=.*/LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=/' \
  -e 's/^LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=.*/LUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "RED no digest at all (the pair would start from a bare tag)" "$V" "the pair never starts from tag 1.1.0 alone"
V="$(variant otherpair)"; printf 'LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=sha256:%s\n' "$(printf 'c%.0s' $(seq 64))" >> "$V/customer.env"
expect_doctor_red "RED pinned core digest differs from the release's" "$V" "differ from the pair image-manifest.yaml records"
# An install made from THIS checkout (manifest pending: no signed release yet).
PEND="$TMP/pending-install"; mkdir -p "$PEND"
PATH="$DBIN:$BASE_PATH" "$ROOT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$PEND/customer.env" --skip-doctor > "$TMP/pinit.out" 2>&1 \
  || fail "lucairn-init from the unreleased checkout: $(tail -2 "$TMP/pinit.out")"
grep -q '^LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=$' "$PEND/customer.env" && pass "an unreleased kit writes no core digest (nothing invented)" || fail "an unreleased kit writes no core digest (nothing invented)"
if PATH="$DBIN:$BASE_PATH" bash "$ROOT/bin/lucairn" doctor --env "$PEND/customer.env" --compose "$COMPOSE" --offline --skip-image-check > "$TMP/doc.out" 2>&1; then
  fail "RED unreleased kit (manifest pending) — doctor stayed green (the old note)"
elif grep -Fq "image-manifest.yaml records no signed digest for the core/sidecar pair yet (pending)" "$TMP/doc.out"; then
  pass "RED unreleased kit (manifest pending) — doctor fails, naming the missing signed digests"
else
  fail "RED unreleased kit (manifest pending) — $(grep 'sanitizer core images' "$TMP/doc.out" | tr '\n' ' ')"
fi
if grep -Fq "sanitizer core images: note" "$TMP/doc.out"; then fail "pending digests are never a note"; else pass "pending digests are never a note"; fi

V="$(variant regkey)"; sed -i.bak 's/^DSA_SANITIZER_CORE_REGISTRY_KEY=.*/DSA_SANITIZER_CORE_REGISTRY_KEY=REPLACE_ME_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "RED registry key placeholder" "$V" "DSA_SANITIZER_CORE_REGISTRY_KEY still set to a placeholder"

V="$(variant badpw)"; sed -i.bak 's/^POSTGRES_SANITIZER_CORE_PASSWORD=.*/POSTGRES_SANITIZER_CORE_PASSWORD=has$dollar-in-it/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "RED registry DB password customer.env cannot carry (\$)" "$V" "customer.env and Compose interpolation cannot carry it safely"
# Fix round 1 (sol r1 finding 1): doctor reads the password exactly as Docker
# Compose does (the writer's reader). Before, the apostrophe below was
# stripped, doctor said ok and compared the DSN file against the wrong value.
pw_variant() { # <name> <new password line>
  local d; d="$(variant "$1")"
  grep -v '^POSTGRES_SANITIZER_CORE_PASSWORD=' "$d/customer.env" > "$d/customer.env.new"
  printf '%s\n' "$2" >> "$d/customer.env.new"; mv "$d/customer.env.new" "$d/customer.env"
  printf '%s' "$d"
}
V="$(pw_variant pwapos "POSTGRES_SANITIZER_CORE_PASSWORD=\"${INIT_PW}'\"")"
expect_doctor_red "RED a lone apostrophe inside double quotes (Compose keeps it)" "$V" "customer.env and Compose interpolation cannot carry it safely"
V="$(pw_variant pwmismatch "POSTGRES_SANITIZER_CORE_PASSWORD=\"${INIT_PW}")"
expect_doctor_red "RED mismatched quotes (Compose refuses the file)" "$V" "cannot be read from $V/customer.env the way Docker Compose reads it: line"
V="$(pw_variant pwquoted "POSTGRES_SANITIZER_CORE_PASSWORD=\"${INIT_PW}\"")"
if doctor_offline "$V/customer.env" && grep -Fq "sanitizer core registry DSN: ok" "$TMP/doc.out"; then
  pass "GREEN a matching pair of quotes is removed (doctor and the DSN file agree)"
else
  fail "GREEN a matching pair of quotes is removed — $(grep 'sanitizer core registry' "$TMP/doc.out" | tr '\n' ' ')"
fi
if POSTGRES_SANITIZER_CORE_PASSWORD=exportedOtherPassword42 doctor_offline "$ENVF"; then
  fail "RED a differing exported POSTGRES_SANITIZER_CORE_PASSWORD (Compose would use it) — doctor stayed green"
elif grep -Fq "is exported in this shell with a value other than" "$TMP/doc.out" && ! grep -Fq "exportedOtherPassword42" "$TMP/doc.out"; then
  pass "RED a differing exported POSTGRES_SANITIZER_CORE_PASSWORD (Compose would use it; no value printed)"
else
  fail "RED a differing exported POSTGRES_SANITIZER_CORE_PASSWORD — $(grep 'registry DB password' "$TMP/doc.out" | tr '\n' ' ')"
fi

# Registry DSN file (DSA #956: --registry-dsn-file, never --dsn).
V="$(variant urlpw)"
grep -v '^POSTGRES_SANITIZER_CORE_PASSWORD=' "$V/customer.env" > "$V/customer.env.new"
printf 'POSTGRES_SANITIZER_CORE_PASSWORD=%s\n' "$SPECIAL_PW" >> "$V/customer.env.new"
mv "$V/customer.env.new" "$V/customer.env"
bash "$WRITER" --env-file "$V/customer.env" > /dev/null 2>&1
if doctor_offline "$V/customer.env" && grep -Fq "sanitizer core registry DSN: ok" "$TMP/doc.out"; then
  pass "GREEN password with / ? % @ : & + = — the writer encodes it and doctor's own encoder agrees"
else
  fail "GREEN password with / ? % @ : & + = — $(grep 'sanitizer core registry' "$TMP/doc.out" | tr '\n' ' ')"
fi
grep -Fq "$SPECIAL_ENC@" "$V/.secrets/sanitizer-core/registry-dsn" && pass "that DSN file carries the percent-encoded password" || fail "that DSN file carries the percent-encoded password"

V="$(variant nodsn)"; rm -f "$V/.secrets/sanitizer-core/registry-dsn"
expect_doctor_red "RED DSN file missing" "$V" "sanitizer core registry DSN: failed (file missing"

V="$(variant dsndir)"; rm -f "$V/.secrets/sanitizer-core/registry-dsn"; mkdir "$V/.secrets/sanitizer-core/registry-dsn"
expect_doctor_red "RED DSN path is a directory (Docker's auto-created bind source)" "$V" "is a directory — Docker creates one"

V="$(variant dsnkv)"; F="$V/.secrets/sanitizer-core/registry-dsn"; chmod 0644 "$F"
printf 'host=postgres-sanitizer-core user=dsa password=%s dbname=sanitizer_core\n' "$INIT_PW" > "$F"; chmod 0444 "$F"
expect_doctor_red "RED DSN file in key=value form (the core takes a URL only)" "$V" "does not hold a postgres:// URL"
if grep -Fq "$INIT_PW" "$TMP/doc.out"; then fail "doctor never prints the DSN file's content"; else pass "doctor never prints the DSN file's content"; fi

V="$(variant dsnstale)"; sed -i.bak 's/^POSTGRES_SANITIZER_CORE_PASSWORD=.*/POSTGRES_SANITIZER_CORE_PASSWORD=rotatedPasswordValue42/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "RED DSN file out of date (password rotated in customer.env only)" "$V" "does not match customer.env"
if grep -Fq "rotatedPasswordValue42" "$TMP/doc.out" || grep -Fq "$INIT_PW" "$TMP/doc.out"; then fail "doctor prints neither the old nor the new password"; else pass "doctor prints neither the old nor the new password"; fi

V="$(variant dsnopen)"; chmod 0755 "$V/.secrets/sanitizer-core"
expect_doctor_red "RED DSN file readable by other host users (directory opened)" "$V" "every local user could read the registry password"

V="$(variant dsnwritable)"; chmod 0666 "$V/.secrets/sanitizer-core/registry-dsn"
expect_doctor_red "RED DSN file writable by group/others" "$V" "is writable by group/others"

V="$(variant dsnowner)"; chmod 0400 "$V/.secrets/sanitizer-core/registry-dsn"
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "10001" ]; then
  expect_doctor_red "RED DSN file 0400 owned by this user (the core's uid 10001 cannot read it)" "$V" "is not readable by the core, which runs as uid 10001"
else
  doctor_offline "$V/customer.env"
  grep -Fq "readability by the core not decided on $(uname -s)" "$TMP/doc.out" \
    && pass "DSN file 0400 on $(uname -s): doctor states it cannot decide the core's access (NON-COVERAGE note; the Linux RED runs on the PC runner)" \
    || fail "DSN file 0400 on $(uname -s): expected the NON-COVERAGE note: $(grep 'registry DSN' "$TMP/doc.out" | tr '\n' ' ')"
fi

# A compose file of the install that passes --dsn (an operator overlay, or a
# pre-K-A file): the static half of the check, offline.
# A symlink farm of the kit (doctor reads scripts/ etc. beside the compose
# file) with only docker-compose.customer.yml replaced.
mkdir -p "$TMP/dsnflag"
for e in "$ROOT"/* "$ROOT"/.[!.]*; do
  case "$(basename "$e")" in .git|docker-compose.customer.yml) continue ;; esac
  [ -e "$e" ] && ln -s "$e" "$TMP/dsnflag/$(basename "$e")"
done
sed 's#"--registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn"#"--dsn=postgres://dsa:x@postgres-sanitizer-core:5432/sanitizer_core"#' "$COMPOSE" > "$TMP/dsnflag/docker-compose.customer.yml"
grep -q -- '"--dsn=postgres' "$TMP/dsnflag/docker-compose.customer.yml" && pass "fixture: a compose copy that passes --dsn" || fail "fixture: a compose copy that passes --dsn"
if PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" doctor --env "$ENVF" --compose "$TMP/dsnflag/docker-compose.customer.yml" --offline --skip-image-check > "$TMP/doc.out" 2>&1; then
  fail "RED a compose file passing --dsn — doctor stayed green"
elif grep -Fq "sanitizer core registry DSN: failed (--dsn in $TMP/dsnflag/docker-compose.customer.yml:" "$TMP/doc.out"; then
  pass "RED a compose file passing --dsn — doctor names the file:line"
else
  fail "RED a compose file passing --dsn — $(grep 'registry DSN' "$TMP/doc.out" | tr '\n' ' ')"
fi
if grep -Fq 'dsa:x@' "$TMP/doc.out"; then fail "the --dsn line itself is not printed"; else pass "the --dsn line itself is not printed"; fi

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
# The core's rendered DSN wiring, shared by every stub below.
CORE_DSN_WIRING='"command":["serve","--listen=0.0.0.0:8790","--registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn","--sidecar=http://127.0.0.1:8765"],"volumes":[{"type":"bind","source":"/x/.secrets/sanitizer-core/registry-dsn","target":"/run/secrets/sanitizer-core/registry-dsn","read_only":true}]'
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar",'"$CORE_DSN_WIRING"',"environment":{"LCR_WITNESS_REQUIRE_MTLS":"true"}}}}' > "$TMP/config.ok.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar",'"$CORE_DSN_WIRING"',"environment":{"LCR_WITNESS_REQUIRE_MTLS":"true","LCR_PROFILE":"hosted"}}}}' > "$TMP/config.hosted.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--dsn=postgres://dsa:k158OnlineCanary@postgres-sanitizer-core:5432/sanitizer_core"],"environment":{"LCR_WITNESS_REQUIRE_MTLS":"true"}}}}' > "$TMP/config.dsnflag.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--listen=0.0.0.0:8790"],"environment":{"LCR_WITNESS_REQUIRE_MTLS":"true"}}}}' > "$TMP/config.nodsn.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn"],"environment":{"LCR_WITNESS_REQUIRE_MTLS":"true"}}}}' > "$TMP/config.unmounted.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--registry-dsn-file","postgres://dsa:k158OnlineCanary@db/x"],"environment":{"LCR_WITNESS_REQUIRE_MTLS":"true"}}}}' > "$TMP/config.dsnpath.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve"],"environment":{"LCR_WITNESS_REQUIRE_MTLS":"true","DSA_SANITIZER_CORE_REGISTRY_DSN":"postgres://dsa:k158OnlineCanary@postgres-sanitizer-core:5432/sanitizer_core"}}}}' > "$TMP/config.envdsn.json"

doctor_online() { # env assignments for the stub...
  env PATH="$DBIN:$BASE_PATH" STUB_MEM_BYTES=34359738368 STUB_PS="$TMP/ps.ok" STUB_NETMODE="container:$SIDE_ID" \
    STUB_CORE_LOG="$TMP/core.ok" STUB_WITNESS_LOG="$TMP/witness.log" STUB_CONFIG_JSON="$TMP/config.ok.json" STUB_LEDGER_OUT=7 \
    "$@" bash "$KIT/bin/lucairn" doctor --env "$ENVF" --compose "$KIT_COMPOSE" --customer-key-file "$KEY" --skip-image-check > "$TMP/online.out" 2>&1
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
# Fix round 1 (sol r1 point 6): a ledger the doctor cannot read is a failure.
online_case "RED migration ledger unreadable (DB down / wrong credentials)" "sanitizer core registry: failed (could not read the migration ledger" red STUB_LEDGER_OUT='psql: error: connection to server on socket failed: FATAL:  password authentication failed for user "dsa"'
online_case "RED claims dropped" "claim(s) DROPPED" red STUB_CORE_LOG="$TMP/core.drop"
online_case "RED witness transport not mtls" "witness transport mode=tls-insecure-dev, not mtls" red STUB_CORE_LOG="$TMP/core.tls"
online_case "RED overlay forwards LCR_PROFILE=hosted" "LCR_PROFILE is forwarded with a non-kit value" red STUB_CONFIG_JSON="$TMP/config.hosted.json"
online_case "RED rendered core given --dsn" "the core is given --dsn" red STUB_CONFIG_JSON="$TMP/config.dsnflag.json"
grep -Fq "k158OnlineCanary" "$TMP/online.out" && fail "the rendered --dsn value is never printed" || pass "the rendered --dsn value is never printed"
online_case "RED rendered core without any DSN source" "the core has no registry DSN source" red STUB_CONFIG_JSON="$TMP/config.nodsn.json"
online_case "RED --registry-dsn-file path not mounted" "nothing is mounted at the --registry-dsn-file path" red STUB_CONFIG_JSON="$TMP/config.unmounted.json"
online_case "RED --registry-dsn-file given a DSN instead of a path" "the --registry-dsn-file value holds :// or @" red STUB_CONFIG_JSON="$TMP/config.dsnpath.json"
grep -Fq "k158OnlineCanary" "$TMP/online.out" && fail "a DSN passed as the path is never printed" || pass "a DSN passed as the path is never printed"
online_case "GREEN rendered core with the DSN in its env (an accepted source)" "sanitizer core rendered config: ok" green STUB_CONFIG_JSON="$TMP/config.envdsn.json"
online_case "not started (nothing running) is not a failure" "sanitizer core runtime: not started" green STUB_PS=/dev/null

echo ""
echo "F. bin/lucairn support-bundle never carries the DSN file"
BUN="$TMP/bundles"
mkdir -p "$BUN"
if PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$ENVF" --compose "$KIT_COMPOSE" --output "$BUN/ok" --offline > "$TMP/sb.out" 2>&1; then
  pass "support-bundle (offline) on the generated install"
  ARCH="$(ls "$BUN/ok"/*.tar.gz 2>/dev/null | head -1)"
  mkdir -p "$BUN/ok-x"; tar -xzf "$ARCH" -C "$BUN/ok-x"
  if grep -rqF "$INIT_PW" "$BUN/ok-x" || grep -rqF "$(cat "$DSNF")" "$BUN/ok-x"; then
    fail "the bundle holds neither the DSN nor the registry password"
  else
    pass "the bundle holds neither the DSN nor the registry password"
  fi
  if find "$BUN/ok-x" -name 'registry-dsn*' | grep -q .; then fail "the bundle has no DSN file"; else pass "the bundle has no DSN file"; fi
else
  fail "support-bundle (offline) on the generated install: $(tail -2 "$TMP/sb.out")"
fi
# A redaction miss: the password under a key name redact_stream does not treat
# as secret. The guard must refuse to archive anything.
bundle_refuses() { # <name> <variant dir> <output name> <planted value>
  if PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$2/customer.env" --compose "$KIT_COMPOSE" --output "$BUN/$3" --offline > "$TMP/sb.out" 2>&1; then
    fail "RED $1 — it archived"
  elif grep -Fq "support bundle: refused" "$TMP/sb.out"; then
    pass "RED $1 — refused"
  else
    fail "RED $1 — without the refusal text: $(tail -1 "$TMP/sb.out")"
  fi
  if find "$BUN/$3" -mindepth 1 2>/dev/null | grep -q .; then fail "$1 — the refused bundle left nothing behind"; else pass "$1 — the refused bundle left nothing behind (no archive, no staging dir)"; fi
  grep -Fq "$4" "$TMP/sb.out" && fail "$1 — the refusal never prints the value" || pass "$1 — the refusal never prints the value"
}
V="$(variant sbleak)"; printf 'OPERATOR_NOTE=%s\n' "$INIT_PW" >> "$V/customer.env"
bundle_refuses "the registry password under a key redact_stream does not treat as secret" "$V" leak "$INIT_PW"
# Fix round 1 (sol r1 finding 2): the scan no longer depends on the DSN file.
# Before, a missing (or unreadable) DSN file skipped EVERY needle, including
# the password customer.env itself holds.
V="$(variant sbleaknodsn)"; rm -f "$V/.secrets/sanitizer-core/registry-dsn"; printf 'OPERATOR_NOTE=%s\n' "$INIT_PW" >> "$V/customer.env"
bundle_refuses "DSN file missing + the password planted under OPERATOR_NOTE" "$V" leaknodsn "$INIT_PW"
REGKEY="$(sed -n 's/^DSA_SANITIZER_CORE_REGISTRY_KEY=//p' "$ENVF" | tail -1)"
V="$(variant sbleakkey)"; printf 'OPERATOR_NOTE=%s\n' "$REGKEY" >> "$V/customer.env"
bundle_refuses "the registry KEY planted under OPERATOR_NOTE (every known secret is a needle)" "$V" leakkey "$REGKEY"
SIGKEY="$(sed -n 's/^LCR_SANITIZER_SIGNING_KEY=//p' "$ENVF" | tail -1)"
V="$(variant sbleaksig)"; rm -f "$V/.secrets/sanitizer-core/registry-dsn"; printf 'NOTES=%s\n' "$SIGKEY" >> "$V/customer.env"
bundle_refuses "the sanitizer signing key planted under NOTES, DSN file missing" "$V" leaksig "$SIGKEY"
# No false refusal on a full ONLINE bundle: `docker compose config` of the
# real project (client-side render, no daemon needed) lands in the bundle
# redacted; none of the needles may survive in it.
if [ "$HAVE_COMPOSE" -eq 1 ]; then
  if PATH="$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$ENVF" --compose "$KIT_COMPOSE" --output "$BUN/online" > "$TMP/sb.out" 2>&1; then
    pass "support-bundle (online, real compose render) on the generated install is not refused"
    ARCH="$(ls "$BUN/online"/*.tar.gz 2>/dev/null | head -1)"
    mkdir -p "$BUN/online-x"; tar -xzf "$ARCH" -C "$BUN/online-x"
    grep -q 'dsa-sanitizer-core-ingress' "$BUN/online-x"/*/redacted/compose-resolved.yml 2>/dev/null \
      && pass "the online bundle carries the resolved project (the scan saw a real render)" \
      || fail "the online bundle carries the resolved project (the scan saw a real render)"
    if grep -rqF -e "$INIT_PW" -e "$REGKEY" -e "$SIGKEY" "$BUN/online-x"; then fail "the online bundle holds none of the planted-class secrets"; else pass "the online bundle holds none of the planted-class secrets"; fi
  else
    fail "support-bundle (online, real compose render) on the generated install: $(tail -2 "$TMP/sb.out")"
  fi
else
  skip "docker compose CLI not available — online support-bundle no-false-refusal case"
fi

echo ""
echo "G. bin/lucairn verify-images covers the sanitizer core pair"
# Hermetic: a stub crane answers from the fixture record, a stub cosign
# accepts every signature with a Rekor entry. What is under test is the
# EXPECTED SET and the fail-closed pending path, not cosign.
VBIN="$TMP/verify-bin"; mkdir -p "$VBIN"
cat > "$VBIN/crane" <<'STUBCRANE'
#!/bin/sh
# crane digest <ref> -> the digest the fixture record holds for <ref>
awk -v r="$2" '!/^#/ && NF == 2 && $1 == r { print $2; f = 1 } END { exit !f }' "$STUB_RECORD"
STUBCRANE
cat > "$VBIN/cosign" <<'STUBCOSIGN'
#!/bin/sh
case "$1" in
  version) echo "GitVersion:    v2.4.1" ;;
  verify) echo '[{"optional":{"Bundle":{"Payload":{"logIndex":1}}}}]' ;;
esac
STUBCOSIGN
printf '#!/bin/sh
exit 1
' > "$VBIN/docker"; printf '#!/bin/sh
exit 1
' > "$VBIN/skopeo"
chmod 0755 "$VBIN"/*
REC_TAG=9.9.9
make_record() { # <file> <core digest> <sidecar digest> [omit-pair]
  {
    echo "# fixture record (synthetic digests, never pulled)"
    for img in dsa-gateway dsa-sanitizer dsa-audit dsa-id-bridge dsa-sandbox-a dsa-sandbox-b dsa-veil-witness dsa-reid-guard dsa-admin dsa-demo dsa-ingest dsa-llm-auditor; do
      printf 'ghcr.io/declade/%s:%s sha256:%s\n' "$img" "$REC_TAG" "$(printf '%s' "$img" | openssl dgst -sha256 | awk '{print $NF}')"
    done
    printf 'ghcr.io/declade/lucairn-dashboard:0.8.2 sha256:%s\n' "$(printf 'd%.0s' $(seq 64))"
    if [ "${4:-}" != omit-pair ]; then
      printf 'ghcr.io/declade/dsa-sanitizer-core:1.1.0 %s\n' "$2"
      printf 'ghcr.io/declade/dsa-sanitizer-core-sidecar:1.1.0 %s\n' "$3"
    fi
  } > "$1"
}
verify_run() { # <kit> -> rc in VRC, output in $TMP/verify.out
  env PATH="$VBIN:$BASE_PATH" STUB_RECORD="$VKEYS/image-digests-$REC_TAG.txt" bash "$1/bin/lucairn" verify-images --tag "$REC_TAG" > "$TMP/verify.out" 2>&1
  VRC=$?
}
# A released kit with its OWN keys/ directory (the fixture record beside the
# shipped ones).
KITV="$TMP/released-kit-verify"
lucairn_released_kit_fixture "$ROOT" "$KITV" || fail "fixture: released kit for verify-images"
rm -f "$KITV/keys"; mkdir -p "$KITV/keys"; cp "$ROOT"/keys/* "$KITV/keys/"
VKEYS="$KITV/keys"
make_record "$VKEYS/image-digests-$REC_TAG.txt" "$TEST_SANITIZER_CORE_DIGEST" "$TEST_SANITIZER_CORE_SIDECAR_DIGEST"
verify_run "$KITV"
if [ "$VRC" -eq 0 ] && grep -Fq "expecting EXACTLY 15 artifacts" "$TMP/verify.out" \
   && grep -Fq "PASS  ghcr.io/declade/dsa-sanitizer-core@$TEST_SANITIZER_CORE_DIGEST" "$TMP/verify.out" \
   && grep -Fq "PASS  ghcr.io/declade/dsa-sanitizer-core-sidecar@$TEST_SANITIZER_CORE_SIDECAR_DIGEST" "$TMP/verify.out"; then
  pass "GREEN released kit: verify-images checks 15 artifacts incl. the core + sidecar by their signed digests"
else
  fail "GREEN released kit: verify-images 15 artifacts (rc $VRC): $(grep -E 'expecting|FAIL|sanitizer-core' "$TMP/verify.out" | head -4 | tr '\n' ' ')"
fi
make_record "$VKEYS/image-digests-$REC_TAG.txt" "$TEST_SANITIZER_CORE_DIGEST" "$TEST_SANITIZER_CORE_SIDECAR_DIGEST" omit-pair
verify_run "$KITV"
if [ "$VRC" -ne 0 ] && grep -Fq "MISSING (expected but not recorded):" "$TMP/verify.out" && grep -Fq "dsa-sanitizer-core-sidecar:1.1.0" "$TMP/verify.out"; then
  pass "RED a release record without the pair -> MISSING, non-zero"
else
  fail "RED a release record without the pair (rc $VRC): $(grep -E 'MISSING|OK' "$TMP/verify.out" | tr '\n' ' ')"
fi
make_record "$VKEYS/image-digests-$REC_TAG.txt" "sha256:$(printf 'e%.0s' $(seq 64))" "$TEST_SANITIZER_CORE_SIDECAR_DIGEST"
verify_run "$KITV"
if [ "$VRC" -ne 0 ] && grep -Fq "the kit manifest and the signed record disagree" "$TMP/verify.out"; then
  pass "RED the record's core digest differs from the manifest's -> refused"
else
  fail "RED the record's core digest differs from the manifest's (rc $VRC): $(tail -2 "$TMP/verify.out" | tr '\n' ' ')"
fi
# THIS checkout: the manifest still says pending. Before fix round 1 the pair
# was not in the expected set and the other 13 verified -> PASS.
VUNREL="$TMP/unreleased-kit-verify"; mkdir -p "$VUNREL"
for e in "$ROOT"/* "$ROOT"/.[!.]*; do
  case "$(basename "$e")" in .git|keys) continue ;; esac
  if [ -d "$e" ]; then ln -s "$e" "$VUNREL/$(basename "$e")"; else cp -p "$e" "$VUNREL/"; fi
done
mkdir -p "$VUNREL/keys"; cp "$ROOT"/keys/* "$VUNREL/keys/"
VKEYS="$VUNREL/keys"
make_record "$VKEYS/image-digests-$REC_TAG.txt" "$TEST_SANITIZER_CORE_DIGEST" "$TEST_SANITIZER_CORE_SIDECAR_DIGEST"
verify_run "$VUNREL"
if [ "$VRC" -ne 0 ] && grep -Fq "has no signed digest in this kit's image-manifest.yaml yet (pending)" "$TMP/verify.out"; then
  pass "RED unreleased kit (manifest pending) -> verify-images fails closed, naming the pair"
else
  fail "RED unreleased kit (manifest pending) (rc $VRC): $(tail -2 "$TMP/verify.out" | tr '\n' ' ')"
fi

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
