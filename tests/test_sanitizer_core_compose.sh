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
#      overlay forwarding LCR_PROFILE=hosted, (K-C) kit-servicenow or the
#      core's ServiceNow control client without the opt-in (the opt-in itself
#      is tests/test_servicenow_optin.sh), a rendered core with --dsn, with no
#      DSN source, or with an unmounted --registry-dsn-file path.
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
# FIX ROUND 2 (sol r2 on PR #158: three P2 + one note), each RED on 6547a8c:
#   e+f. ONE env source by construction: Docker Compose itself. The DSN writer,
#      doctor and the support-bundle needles read customer.env THROUGH Compose
#      (bin/compose-env.sh: Compose's env-file parser via a one-service probe,
#      Compose's interpolation via a second probe, and the install's rendered
#      project); the hand-written reader bin/compose-env-lib.sh is GONE (D3).
#      RED cases: a quoted password ending in a literal line feed (D2, E); an
#      escape Compose decodes (\0101 = A) under a non-secret key (F); a
#      shell-exported override planted under a non-secret key (F); a secret only
#      a compose file hands a container (F); an overlay remapping the registry
#      DB password (E). No Docker Compose = writer, doctor and bundle refuse.
#   g. Network: the witness-central overlay keeps every network of the core's
#      namespace internal and reaches the central witness through a relay on
#      the internal witness link (B, + a mutant of the r2 overlay shape); the
#      core listens on the ingress alias only, never every interface (B, + a
#      listen-all mutant).
#
# NON-COVERAGE (stated, not implied)
#   * No container runs. Whether the images boot with these settings is the
#     compose rehearsal on a Docker host (PRD criterion 2), not this suite —
#     including that `--listen=sanitizer-core:8790` resolves (Docker's embedded
#     DNS, inside the sidecar's namespace) to the ingress address, and that the
#     witness relay forwards the core's mTLS session (no Docker daemon here).
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
p("serve" in cmd and "--sidecar=http://127.0.0.1:8765" in cmd, "core serves with the sidecar on 127.0.0.1:8765")
# Fix round 2 (sol r2): the listener is bound to the INGRESS link only. The
# --listen host must be a name that only the ingress link carries (Docker's
# embedded DNS resolves it, inside the sidecar's namespace, to that one
# address), never 0.0.0.0 / :: / an empty host (= every link of the namespace).
ls_ = [a for a in cmd if a.startswith("--listen")]
lhost = ls_[0].split("=", 1)[1].rsplit(":", 1)[0] if len(ls_) == 1 and "=" in ls_[0] else None
p(ls_ == ["--listen=sanitizer-core:8790"], "core listens on sanitizer-core:8790 only (%s)" % ls_)
p(lhost not in (None, "", "0.0.0.0", "::", "[::]", "*"), "the core never listens on every interface (host %r)" % lhost)
others = {n for n in sn if n != "dsa-sanitizer-core-ingress"}
# (the core's own service name does not count: it has no network endpoint of
# its own, so Docker registers no DNS name for it)
p(all(lhost not in ((sn.get(n) or {}).get("aliases") or []) for n in others)
  and not any(n == lhost and x.get("networks") for n, x in svcs.items()),
  "the --listen name resolves on the ingress link alone (no alias / service of that name on the witness or registry links)")
hc = " ".join((core.get("healthcheck") or {}).get("test") or [])
p("nc -z sanitizer-core 8790" in hc and "127.0.0.1 8790" not in hc, "core healthcheck probes the bound ingress address (%s)" % hc)
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
  if grep -qx migrate-sanitizer-core <<<"$SERVICES"; then
    fail "migrate-sanitizer-core-not-in-default-project (a plain up would run it)"
  else
    pass "migrate-sanitizer-core-not-in-default-project"
  fi
  # The base file alone (split-remote topology) also carries the core.
  # Captured first: `| grep -q` under pipefail SIGPIPEs the writer and reads as a failure.
  BASE_SERVICES="$(docker compose -f "$COMPOSE" --env-file "$PINNED_ENV" config --services 2>/dev/null || true)"
  if grep -qx sanitizer-core <<<"$BASE_SERVICES"; then
    pass "split-remote base file carries the core"
  else
    fail "split-remote base file carries the core"
  fi
  # Fix round 1 (sol r1 finding 4): the pair never starts from a bare tag.
  # The example env carries no digest (the release records them), so the
  # project refuses to render at all; half a pair refuses too. With BOTH
  # missing, Compose names whichever required variable it reaches first (its
  # map order: CORE on one run, SIDECAR on the next — the 5890e469 CI flake),
  # so that case accepts either name; each half is asserted on its own below.
  if docker compose -f "$COMPOSE" --env-file "$EXAMPLE_ENV" config --quiet > "$TMP/nodigest.out" 2>&1; then
    fail "no core/sidecar digest -> the project refuses to render (it rendered: the pair would start by tag)"
  elif grep -Eq 'LUCAIRN_SANITIZER_CORE_(SIDECAR_)?IMAGE_DIGEST must be the signed digest' "$TMP/nodigest.out"; then
    pass "no core/sidecar digest -> the project refuses to render, naming a digest variable of the pair"
  else
    fail "no core/sidecar digest -> refused, but not by the digest guard: $(tail -1 "$TMP/nodigest.out")"
  fi
  cp "$EXAMPLE_ENV" "$TMP/coremissing.env"
  printf '\nLUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=%s\n' "$TEST_SANITIZER_CORE_SIDECAR_DIGEST" >> "$TMP/coremissing.env"
  if docker compose -f "$COMPOSE" --env-file "$TMP/coremissing.env" config --quiet > "$TMP/nodigest.out" 2>&1; then
    fail "only the sidecar digest -> the project refuses to render (it rendered)"
  elif grep -q 'LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST must be the signed digest' "$TMP/nodigest.out"; then
    pass "only the sidecar digest -> refuses to render, naming LUCAIRN_SANITIZER_CORE_IMAGE_DIGEST"
  else
    fail "only the sidecar digest -> refused, but not by the core digest guard: $(tail -1 "$TMP/nodigest.out")"
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
  # Fix round 2 (sol r2): the witness-central overlay must NOT give the core's
  # namespace a route off the host. The core reaches the central witness
  # through a relay container on its internal witness link; the relay is the
  # ONLY member of the overlay's egress link and forwards to ONE address.
  # The same checker runs over two mutants (the r2 overlay shape: the sidecar
  # on an egress network; a core that listens on 0.0.0.0) and must FAIL them.
  cp "$PINNED_ENV" "$TMP/central.env"
  printf '\nLUCAIRN_CENTRAL_WITNESS_ADDR=witness.example.invalid:50057\nLUCAIRN_CENTRAL_WITNESS_CERT_ADDR=witness.example.invalid:50058\nLUCAIRN_WITNESS_CLIENT_CERT_DIR=%s\nLUCAIRN_WITNESS_GATEWAY_CLIENT_CERT_DIR=%s\n' "$TMP/wc-claim" "$TMP/wc-gw" >> "$TMP/central.env"
  cat > "$TMP/netcheck.py" <<'NETCHECK'
import json, sys
d = json.load(open(sys.argv[1])); svcs, nets = d["services"], d.get("networks", {})
def p(ok, msg): print(("ok " if ok else "FAIL ") + msg)
side, core = svcs["sanitizer-core-sidecar"], svcs["sanitizer-core"]
sn = side.get("networks") or {}
def members(net): return {n for n, x in svcs.items() if net in (x.get("networks") or {})}
BASE = {"dsa-sanitizer-core-ingress", "dsa-sanitizer-core-witness", "dsa-sanitizer-core"}
p(set(sn) == BASE, "witness-central: the core's namespace keeps exactly its three links (%s)" % sorted(sn))
p(all(nets.get(n, {}).get("internal") is True for n in sn), "witness-central: every network of the core's namespace is internal (no route off the host)")
ce = core.get("environment") or {}
p(ce.get("LCR_WITNESS_ADDR") == "sanitizer-core-witness-relay-link:50057", "witness-central: the core dials the relay on its internal witness link (%s)" % ce.get("LCR_WITNESS_ADDR"))
r = svcs.get("sanitizer-core-witness-relay") or {}
rn = r.get("networks") or {}
eg = [n for n in rn if nets.get(n, {}).get("internal") is not True]
p(len(eg) == 1 and members(eg[0]) == {"sanitizer-core-witness-relay"}, "witness-central: the relay is the ONLY member of the one egress link (%s)" % [(n, sorted(members(n))) for n in eg])
p("sanitizer-core-witness-relay-link" in ((rn.get("dsa-sanitizer-core-witness") or {}).get("aliases") or []), "witness-central: the relay answers on the core's witness link")
# Round 4 (sol r3): the name the relay BINDS and the name the core DIALS must
# resolve to ONE address. Compose puts a service's name on every network the
# service joins and Docker's resolver answers it from a non-internal network
# first, so that name must be an alias that only the internal witness link
# carries: the relay binds it, the core dials it, and no other network (and
# no service name) holds it.
re_ = r.get("environment") or {}
bind = re_.get("RELAY_LISTEN_HOST") or ""
dial = (ce.get("LCR_WITNESS_ADDR") or "").rpartition(":")[0]
def carriers(name):  # every (network, service) where `name` resolves
    out = set()
    for sname, x in svcs.items():
        for n, cfg in (x.get("networks") or {}).items():
            names = {sname} | set((cfg or {}).get("aliases") or [])
            if x.get("container_name"):
                names.add(x["container_name"])
            if x.get("hostname"):
                names.add(x["hostname"])
            if name in names:
                out.add((n, sname))
    return out
p(bind == dial and bind != "", "witness-central: the relay binds the name the core dials (bind %r, dial %r)" % (bind, dial))
p(bind not in svcs, "witness-central: the relay's bind name is not a service name (Compose would put it on the egress link too) (%r)" % bind)
p(carriers(bind) == {("dsa-sanitizer-core-witness", "sanitizer-core-witness-relay")}, "witness-central: the bind name resolves ONLY on the internal witness link, to the relay (%s)" % sorted(carriers(bind)))
p(nets.get("dsa-sanitizer-core-witness", {}).get("internal") is True, "witness-central: the network that carries the bind name is internal")
p(members("dsa-sanitizer-core-witness") == {"sanitizer-core-sidecar", "sanitizer-core-witness-relay"}, "witness-central: the witness link holds the core's namespace and the relay only — the local witness is not started (%s)" % sorted(members("dsa-sanitizer-core-witness")))
p(re_.get("RELAY_UPSTREAM") == "witness.example.invalid:50057" and re_.get("RELAY_LISTEN_HOST") == "sanitizer-core-witness-relay-link", "witness-central: the relay forwards to LUCAIRN_CENTRAL_WITNESS_ADDR only, listening on its witness-link alias")
p(not r.get("ports") and not any(v.get("target", "").startswith("/etc/lucairn") for v in r.get("volumes") or []), "witness-central: the relay publishes no port and mounts no credential")
p((r.get("depends_on") or {}).get("witness-egress-guard", {}).get("condition") == "service_completed_successfully", "witness-central: the relay is gated by the T-682 witness-egress guard")
p(r.get("image") == side.get("image"), "witness-central: the relay runs the signed sidecar image (no extra image)")
ls_ = [a for a in (core.get("command") or []) if a.startswith("--listen")]
p(ls_ == ["--listen=sanitizer-core:8790"], "witness-central: the core still listens on the ingress name only (%s)" % ls_)
NETCHECK
  printf 'services:\n  sanitizer-core-sidecar:\n    networks:\n      dsa-sanitizer-core-witness-egress: {}\n' > "$TMP/mutant-egress.yml"
  printf 'services:\n  sanitizer-core:\n    command: ["serve", "--listen=0.0.0.0:8790", "--registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn", "--sidecar=http://127.0.0.1:8765"]\n' > "$TMP/mutant-listen.yml"
  # Round 4 mutant = the r3 shape (sol r3 P1): relay and core use the relay's
  # SERVICE name, which Compose also puts on the egress link.
  printf 'services:\n  sanitizer-core:\n    environment:\n      LCR_WITNESS_ADDR: "sanitizer-core-witness-relay:50057"\n  sanitizer-core-witness-relay:\n    environment:\n      RELAY_LISTEN_HOST: "sanitizer-core-witness-relay"\n' > "$TMP/mutant-svcname.yml"
  # ... and the right alias, but ALSO on the egress link (only the
  # resolves-on-one-network check can catch this one).
  printf 'services:\n  sanitizer-core-witness-relay:\n    networks:\n      dsa-sanitizer-core-witness-egress:\n        aliases: ["sanitizer-core-witness-relay-link"]\n' > "$TMP/mutant-alias-egress.yml"
  for cell in "real|" "mutant-egress|-f $TMP/mutant-egress.yml" "mutant-listen|-f $TMP/mutant-listen.yml" "mutant-svcname|-f $TMP/mutant-svcname.yml" "mutant-alias-egress|-f $TMP/mutant-alias-egress.yml"; do
    cname="${cell%%|*}"; cextra="${cell#*|}"
    # shellcheck disable=SC2086 # cextra is "" or "-f <file>"
    if docker compose -f "$COMPOSE" -f "$ROOT/contrib/witness-central/docker-compose.witness-central.yml" $cextra --env-file "$TMP/central.env" \
         config --format json > "$TMP/central.json" 2> "$TMP/central.err"; then
      python3 "$TMP/netcheck.py" "$TMP/central.json" > "$TMP/central-check.txt"
      if [ "$cname" = real ]; then
        while IFS= read -r line; do
          case "$line" in ok\ *) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac
        done < "$TMP/central-check.txt"
      elif grep -q '^FAIL ' "$TMP/central-check.txt"; then
        pass "the witness-central checker catches $cname ($(grep '^FAIL ' "$TMP/central-check.txt" | head -1 | cut -c6-90)...)"
      else
        fail "the witness-central checker catches $cname — every check passed on the mutant"
      fi
    else
      fail "witness-central overlay renders ($cname): $(tail -2 "$TMP/central.err")"
    fi
  done
  # The relay itself, run here on the loopback (stdlib Python, no container):
  # it carries bytes both ways to its ONE upstream and binds only the address
  # its RELAY_LISTEN_HOST resolves to.
  python3 - "$ROOT/contrib/witness-central/sanitizer-core-witness-relay.py" > "$TMP/relay-check.txt" 2>&1 <<'PY'
import os, socket, subprocess, sys, threading, time
def free():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
echo = socket.socket(); echo.bind(("127.0.0.1", 0)); echo.listen(4); up = echo.getsockname()[1]
def serve():
    while True:
        c, _ = echo.accept()
        d = c.recv(65536)
        c.sendall(b"echo:" + d); c.close()
threading.Thread(target=serve, daemon=True).start()
port = free()
env = dict(os.environ, RELAY_LISTEN_HOST="127.0.0.1", RELAY_LISTEN_PORT=str(port), RELAY_UPSTREAM="127.0.0.1:%d" % up)
r = subprocess.Popen([sys.executable, "-I", sys.argv[1]], env=env, stderr=subprocess.PIPE)
try:
    for _ in range(50):
        try:
            c = socket.create_connection(("127.0.0.1", port), timeout=2); break
        except OSError:
            time.sleep(0.1)
    c.sendall(b"\x16\x03\x01mtls-bytes"); got = c.recv(65536); c.close()
    print(("ok " if got == b"echo:\x16\x03\x01mtls-bytes" else "FAIL ") + "the relay carries the bytes to its upstream and back unchanged (%r)" % got[:30])
    try:
        x = socket.create_connection(("127.0.0.2", port), timeout=1); x.close(); bound_all = True
    except OSError:
        bound_all = False
    print(("FAIL " if bound_all else "ok ") + "the relay listens on its RELAY_LISTEN_HOST address only (127.0.0.2 refused)")
finally:
    r.terminate(); r.wait(5)
bad = subprocess.run([sys.executable, "-I", sys.argv[1]], env=dict(os.environ, RELAY_LISTEN_HOST="127.0.0.1", RELAY_UPSTREAM="no-port"), capture_output=True, timeout=10)
print(("ok " if bad.returncode != 0 and b"host:port" in bad.stderr else "FAIL ") + "the relay refuses an upstream without a port")
PY
  while IFS= read -r line; do
    case "$line" in ok\ *) pass "${line#ok }" ;; FAIL\ *) fail "${line#FAIL }" ;; *) fail "relay check: $line" ;; esac
  done < "$TMP/relay-check.txt"
  # Digest variables pin both images as a pair.
  cp "$EXAMPLE_ENV" "$TMP/digest.env"
  printf '\nLUCAIRN_SANITIZER_CORE_IMAGE_DIGEST=sha256:%s\nLUCAIRN_SANITIZER_CORE_SIDECAR_IMAGE_DIGEST=sha256:%s\n' \
    "$(printf 'a%.0s' $(seq 64))" "$(printf 'b%.0s' $(seq 64))" >> "$TMP/digest.env"
  IMAGES="$(docker compose -f "$COMPOSE" --env-file "$TMP/digest.env" config --images 2>/dev/null || true)"
  if grep -qx "ghcr.io/declade/dsa-sanitizer-core:1.1.0@sha256:$(printf 'a%.0s' $(seq 64))" <<<"$IMAGES" \
     && grep -qx "ghcr.io/declade/dsa-sanitizer-core-sidecar:1.1.0@sha256:$(printf 'b%.0s' $(seq 64))" <<<"$IMAGES"; then
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
file_mode() { case "$(uname -s)" in Darwin|FreeBSD|OpenBSD|NetBSD) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac; }
echo "D. scripts/bootstrap-sanitizer-core-mtls.sh"
CD="$TMP/certs"
# Kit round 2: the deploy CA lives OUTSIDE the cert tree; for a cert directory
# that is not <dir>/.certs/sanitizer-core-mtls it is the sibling <dir>-ca.
CDCA="$TMP/certs-ca"
if bash "$BOOTSTRAP" "$CD" > "$TMP/boot.out" 2>&1; then pass "bootstrap runs"; else fail "bootstrap runs: $(tail -2 "$TMP/boot.out")"; fi
verify_leaf() { # <name> <crt> <purpose> <san>
  if openssl verify -CAfile "$CDCA/ca.crt" -purpose "$3" "$2" >/dev/null 2>&1 \
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
if openssl verify -CAfile "$CDCA/ca.crt" -purpose sslserver "$CD/gateway/dsa-gateway.crt" >/dev/null 2>&1; then
  fail "gateway client leaf is NOT a server leaf"
else
  pass "gateway client leaf is NOT a server leaf"
fi
[ ! -e "$CD/sanitizer-core/ca.key" ] && [ ! -e "$CD/gateway/ca.key" ] && [ ! -e "$CD/veil-witness/ca.key" ] \
  && pass "no CA key in a mounted directory" || fail "no CA key in a mounted directory"
[ ! -e "$CD/ca" ] && [ -f "$CDCA/ca.key" ] && [ "$(file_mode "$CDCA")" = 700 ] \
  && pass "round 2: the CA lives outside the cert tree, in the 0700 sibling <cert dir>-ca" \
  || fail "round 2: the CA lives outside the cert tree (ca/ in tree: $([ -e "$CD/ca" ] && echo yes || echo no); $CDCA/ca.key: $([ -f "$CDCA/ca.key" ] && echo yes || echo no))"
BAD_MODES="$(find "$CD" -name '*.key' -perm -004 | wc -l | tr -d ' ')"
check_eq "every private key is 0600" "0" "$BAD_MODES"
BEFORE="$(find "$CD" "$CDCA" -type f -exec cat {} + | openssl dgst -sha256 | awk '{print $NF}')"
bash "$BOOTSTRAP" "$CD" > /dev/null 2>&1
AFTER="$(find "$CD" "$CDCA" -type f -exec cat {} + | openssl dgst -sha256 | awk '{print $NF}')"
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
expect_writer_refuses "unsafe password (a literal \$ in single quotes)" "POSTGRES_SANITIZER_CORE_PASSWORD='has\$dollar'" "$WD/x1/f" "cannot carry safely"
expect_writer_refuses "unsafe password (space)" 'POSTGRES_SANITIZER_CORE_PASSWORD=has space' "$WD/x2/f" "cannot carry safely"
expect_writer_refuses "missing password" 'OTHER=1' "$WD/x3/f" "POSTGRES_SANITIZER_CORE_PASSWORD is not set"
expect_writer_refuses "off-enum sslmode" "$(printf 'POSTGRES_SANITIZER_CORE_PASSWORD=okpassword123\nPOSTGRES_SSLMODE=on')" "$WD/x4/f" "POSTGRES_SSLMODE must be one of"
mkdir -p "$WD/x5/f"
expect_writer_refuses "a directory at the path (Docker's auto-created bind source)" 'POSTGRES_SANITIZER_CORE_PASSWORD=okpassword123' "$WD/x5/f" "is a directory"
mkdir -p "$WD/x6"; chmod 0755 "$WD/x6"
expect_writer_refuses "a directory open to group/others" 'POSTGRES_SANITIZER_CORE_PASSWORD=okpassword123' "$WD/x6/f" "must keep group and others out"
[ ! -e "$WD/x6/f" ] && pass "nothing written into the open directory" || fail "nothing written into the open directory"
if grep -q 'dollar\|okpassword123' "$WD/r.all"; then fail "refusals never print the password"; else pass "refusals never print the password"; fi

# Fix rounds 1 + 2 (sol r1 finding 1, sol r2 finding e): customer.env is read
# THROUGH Docker Compose (bin/compose-env.sh; no hand-written reader is left):
# only a MATCHING pair of outer quotes is removed, and escapes, interpolation
# and a line feed inside quotes are exactly what Compose hands Postgres.
expect_writer_refuses "a lone trailing apostrophe inside double quotes (Compose keeps it)" \
  "POSTGRES_SANITIZER_CORE_PASSWORD=\"BoundaryProbe4829'\"" "$WD/q1/f" "cannot carry safely"
expect_writer_refuses "mismatched quotes (Compose refuses the file)" \
  "POSTGRES_SANITIZER_CORE_PASSWORD=\"BoundaryProbe4829'" "$WD/q2/f" "Docker Compose cannot read"
expect_writer_refuses "an unquoted value ending in a quote (Compose keeps it)" \
  "POSTGRES_SANITIZER_CORE_PASSWORD=BoundaryProbe4829\"" "$WD/q3/f" "cannot carry safely"
# RED on 6547a8c (sol r2 e): the quoted value ends in a line feed. `$(...)`
# dropped it before validation, so writer and doctor accepted the truncated
# password while Compose handed Postgres the line feed.
expect_writer_refuses "a quoted password ending in a literal line feed (Compose keeps the LF)" \
  "$(printf 'POSTGRES_SANITIZER_CORE_PASSWORD="LineFeedPassword4829\n"\nOTHER=1')" "$WD/q6/f" "cannot carry safely"
expect_writer_refuses "a \\n escape in double quotes (Compose turns it into a line feed)" \
  'POSTGRES_SANITIZER_CORE_PASSWORD="LineFeedPassword4829\n"' "$WD/q7/f" "cannot carry safely"
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
# RED on 6547a8c (sol r2 e): the old reader refused what Compose accepts and
# could never agree with it on an escape; now the value IS Compose's.
writer_gets "an octal escape in double quotes is decoded by Compose (\\0101 = A)" \
  'POSTGRES_SANITIZER_CORE_PASSWORD="Boundary\0101Probe4829"' "BoundaryAProbe4829"
writer_gets "\$-interpolation is resolved by Compose (an earlier key of the file)" \
  "$(printf 'OTHER_SECRET=InterpolatedPassword4829\nPOSTGRES_SANITIZER_CORE_PASSWORD=${OTHER_SECRET}')" "InterpolatedPassword4829"
# The shell beats the file in Compose: an exported value that differs from
# customer.env would reach Postgres while the DSN file carried the file's.
printf 'POSTGRES_SANITIZER_CORE_PASSWORD=FilePassword4829\n' > "$WD/sh.env"
if POSTGRES_SANITIZER_CORE_PASSWORD=ShellPassword4829 bash "$WRITER" --env-file "$WD/sh.env" "$WD/sh/f" > "$WD/sh.out" 2>&1; then
  fail "a differing exported POSTGRES_SANITIZER_CORE_PASSWORD is refused — writer accepted it"
elif grep -q 'exported in this shell with a value other than' "$WD/sh.out" && ! grep -q 'Password4829' "$WD/sh.out"; then
  pass "a differing exported POSTGRES_SANITIZER_CORE_PASSWORD is refused (no value printed)"
else
  fail "a differing exported POSTGRES_SANITIZER_CORE_PASSWORD is refused — $(tail -1 "$WD/sh.out")"
fi
# No Docker Compose where the writer runs: it refuses, never guesses.
# (docker and docker-compose shims that are not Compose, ahead of the real ones)
NOCOMPOSE="$TMP/no-compose-bin"
mkdir -p "$NOCOMPOSE"
printf '#!/bin/sh\necho "no compose here" >&2\nexit 127\n' > "$NOCOMPOSE/docker"
cp "$NOCOMPOSE/docker" "$NOCOMPOSE/docker-compose"
chmod 0755 "$NOCOMPOSE/docker" "$NOCOMPOSE/docker-compose"
printf 'POSTGRES_SANITIZER_CORE_PASSWORD=NoComposePassword4829\n' > "$WD/nc.env"
if PATH="$NOCOMPOSE:$BASE_PATH" bash "$WRITER" --env-file "$WD/nc.env" "$WD/nc/f" > "$WD/nc.out" 2>&1; then
  fail "no Docker Compose on PATH -> the writer refuses (it wrote a DSN from a guessed value)"
elif grep -q 'Docker Compose is not available here' "$WD/nc.out" && [ ! -e "$WD/nc/f" ]; then
  pass "no Docker Compose on PATH -> the writer refuses (fail closed, nothing written)"
else
  fail "no Docker Compose on PATH -> the writer refuses — $(tail -1 "$WD/nc.out")"
fi

echo ""
echo "D3. One env source: every value is Docker Compose's own (fix round 2)"
[ ! -e "$ROOT/bin/compose-env-lib.sh" ] && pass "the hand-written env reader (bin/compose-env-lib.sh) is gone" \
  || fail "the hand-written env reader (bin/compose-env-lib.sh) is gone"
# (code lines only: a comment may name the removed file)
grep -rnE 'compose_env_get|compose-env-lib|sanitizer_core_env_get|sanitizer_core_read_dsn|sanitizer_core_expected_dsn' \
  "$ROOT/bin" "$ROOT/scripts" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' > "$TMP/d3-grep.txt"
if [ -s "$TMP/d3-grep.txt" ]; then
  fail "no kit script keeps a hand-written reader of these values: $(head -2 "$TMP/d3-grep.txt" | tr '\n' ' ')"
else
  pass "no kit script keeps a hand-written reader of these values"
fi
for f in scripts/write-sanitizer-core-registry-dsn.sh bin/lucairn bin/lucairn-init; do
  grep -q 'bin/compose-env.sh' "$ROOT/$f" && pass "$f reads through bin/compose-env.sh" || fail "$f reads through bin/compose-env.sh"
done
# The writer against Docker Compose itself on a corpus: whatever Compose hands
# Postgres for POSTGRES_SANITIZER_CORE_PASSWORD (a direct one-service render,
# here in the test), the writer either writes exactly that value encoded, or
# refuses it for the stated reason. No case may disagree.
if [ "$HAVE_COMPOSE" -ne 1 ]; then
  skip "docker compose CLI not available — section D3 corpus"
else
  PD="$TMP/envprobe"; mkdir -p "$PD"
  printf 'services:\n  p:\n    image: scratch\n    environment:\n      V: "${POSTGRES_SANITIZER_CORE_PASSWORD-}"\n' > "$PD/probe.yml"
  D3_N=0; D3_BAD=""
  d3() { # <env file content (printf %b)>
    printf '%b' "$1" > "$PD/t.env"
    rm -rf "$PD/out"
    local want got rc=0
    want="$(docker compose -f "$PD/probe.yml" --project-directory "$PD" --env-file "$PD/t.env" config --format json 2>/dev/null \
      | python3 -c 'import json, sys, urllib.parse
try:
    v = json.load(sys.stdin)["services"]["p"]["environment"]["V"].replace("$$", "$")
except Exception:
    print("refuse:Docker Compose cannot read"); sys.exit(0)
if v == "": print("refuse:is not set")
elif any(not ("\x21" <= c <= "\x7e") or c in "$\x27\"\\`#" for c in v): print("refuse:cannot carry safely")
else: print("dsn:postgres://dsa:" + urllib.parse.quote(v, safe="-._~") + "@postgres-sanitizer-core:5432/sanitizer_core?sslmode=disable")')"
    bash "$WRITER" --env-file "$PD/t.env" "$PD/out/f" > "$PD/w.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then got="dsn:$(cat "$PD/out/f")"; else got="refused"; fi
    D3_N=$((D3_N + 1))
    case "$want" in
      dsn:*) [ "$got" = "$want" ] || D3_BAD="$D3_BAD [$1 => writer '$got']" ;;
      refuse:*) { [ "$got" = refused ] && grep -Fq "${want#refuse:}" "$PD/w.out"; } || D3_BAD="$D3_BAD [$1 => writer '$got', want $want]" ;;
    esac
  }
  K=POSTGRES_SANITIZER_CORE_PASSWORD
  d3 "$K=\"BoundaryProbe4829\x27\"\n"; d3 "$K=\x27abcdefgh123\x27\n"; d3 "$K=\"abc\n"; d3 "$K=\x27abc\"\n"; d3 "$K=abcdefgh123\"\n"
  d3 "$K=a=b=c12345\n"; d3 "$K=abcdefg # c\n"; d3 "$K=abc#not-a-comment\n"; d3 "$K=\"abcdefg\" # c\n"; d3 "$K=\"abcdefg\"junk\n"
  d3 "$K=1first\n$K=\"2second\"\n"; d3 "export $K=exported1\n"; d3 "$K: yamlstyle1\n"; d3 "$K = spaced1 \n"; d3 "$K=crlf12345\r\n"
  d3 "\xef\xbb\xbf$K=bomvalue1\n"; d3 "$K=nofinalnl1"; d3 "$K=\n"; d3 "$K=\"\"\n"; d3 "$K=real12345\nX=\x27\n$K=fake\n\x27\n"
  d3 "$K=\x27it\\\x27s\x27\n"; d3 "$K=\"q\\\"q\"\n"; d3 "$K=\x27a\\\\b\x27\n"; d3 "$K=\"Boundary\\\\0101Probe\"\n"; d3 "$K=\"tab\\\\tvalue\"\n"
  d3 "$K=\"lf-at-end\n\"\n"; d3 "X=fromx12345\n$K=\${X}\n"; d3 "X=fromx12345\n$K=\x27\${X}\x27\n"; d3 "$K=dollar\$\$dollar\n"; d3 "$K=\${UNSET_D3_VAR:-defaultpw1}\n"
  d3 "KE Y=x\n$K=after12345\n"; d3 "$K=\xc2\xa0nbsp1\n"; d3 "$K=\xc3\xa4umlaut1\n"; d3 "$K=\"multi\nline\"\n"
  if [ -z "$D3_BAD" ]; then
    pass "writer == Docker Compose on $D3_N corpus files (same value encoded, or the stated refusal)"
  else
    fail "writer disagrees with Docker Compose:$D3_BAD"
  fi
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
  " version --format "*) [ -n "${STUB_ENGINE_VERSION:-}" ] && { echo "$STUB_ENGINE_VERSION"; exit 0; }; exit 1 ;;
esac
if [ "${1:-}" = compose ]; then
  case "$a" in
    # bin/compose-env.sh's one-service probes read customer.env through the
    # REAL Compose CLI (client side, no daemon): never stubbed.
    *"/lucairn-env-probe."*) exec "$STUB_REAL_DOCKER" "$@" ;;
    *" version "*) exit 0 ;;
    *" config --quiet "*) exit 0 ;;
    *" config --format json "*)
      if [ -n "${STUB_CONFIG_JSON:-}" ]; then cat "$STUB_CONFIG_JSON"; exit 0; fi
      [ -n "${STUB_REAL_DOCKER:-}" ] && exec "$STUB_REAL_DOCKER" "$@"
      exit 0 ;;
    *" ps -a "*) [ -n "${STUB_PS:-}" ] && cat "$STUB_PS"; exit 0 ;;
    # support-bundle's log collection (online bundle cases in F).
    *" logs --tail 300 --no-color"*) [ -n "${STUB_BUNDLE_LOG:-}" ] && cat "$STUB_BUNDLE_LOG"; exit 0 ;;
    *" exec -T postgres-sanitizer-core "*) echo "${STUB_LEDGER_OUT:-7}"; exit 0 ;;
    *" logs --no-color sanitizer-core "*) [ -n "${STUB_CORE_LOG:-}" ] && cat "$STUB_CORE_LOG"; exit 0 ;;
    *" logs --no-color veil-witness "*) [ -n "${STUB_WITNESS_LOG:-}" ] && cat "$STUB_WITNESS_LOG"; exit 0 ;;
  esac
fi
exit 1
STUBDOCKER
printf '#!/bin/sh\nprintf 000\n' > "$DBIN/curl"
STUB_REAL_DOCKER="$(PATH="$BASE_PATH" command -v docker 2>/dev/null || true)"
export STUB_REAL_DOCKER
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
env_drop() { # <env file> <KEY> — remove every assignment of KEY
  sed -i.bak "/^$2=/d" "$1" && rm -f "$1.bak"
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
# Final-read M1: a --dev install (plaintext mesh) is no longer a warning that
# every core claim is dropped; init unlatches the core (three empty client-leaf
# lines) and the hop is plaintext on both sides. Section H drives the RED cases.
grep -Fq "sanitizer core witness hop: ok (development: GRPC_TLS_ENABLED=false" "$TMP/doc.out" \
  && pass "dev install (GRPC_TLS_ENABLED=false): the core's witness hop is plaintext on both sides (ok, not a dropped-claims warning)" \
  || fail "dev install (GRPC_TLS_ENABLED=false): the core's witness hop is plaintext on both sides: $(grep 'witness hop' "$TMP/doc.out")"

V="$(variant nowitnesscert)"; rm -f "$V/.certs/sanitizer-core-mtls/sanitizer-core/witness-client.crt"
expect_doctor_red "RED witness client cert missing" "$V" "core witness client certificate missing"

V="$(variant badsan)"
W="$V/.certs/sanitizer-core-mtls"
printf 'basicConstraints = critical, CA:FALSE\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = serverAuth\nsubjectAltName = DNS:veil-witness\n' > "$TMP/badsan.ext"
openssl req -new -key "$W/veil-witness/dsa-veil-witness.key" -subj "/CN=veil-witness" -out "$TMP/badsan.csr" 2>/dev/null
openssl x509 -req -in "$TMP/badsan.csr" -CA "$V/.secrets/sanitizer-core-mtls-ca/ca.crt" -CAkey "$V/.secrets/sanitizer-core-mtls-ca/ca.key" -set_serial 0x1234 -days 30 -extfile "$TMP/badsan.ext" -out "$W/veil-witness/dsa-veil-witness.crt" 2>/dev/null
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
openssl x509 -req -sha1 -in "$TMP/sha1.csr" -CA "$V/.secrets/sanitizer-core-mtls-ca/ca.crt" -CAkey "$V/.secrets/sanitizer-core-mtls-ca/ca.key" -set_serial 0x4321 -days 30 -extfile "$TMP/sha1.ext" -out "$W/gateway/dsa-gateway.crt" 2>/dev/null
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

V="$(variant badpw)"; sed -i.bak "s/^POSTGRES_SANITIZER_CORE_PASSWORD=.*/POSTGRES_SANITIZER_CORE_PASSWORD='has\$dollar-in-it'/" "$V/customer.env"; rm -f "$V/customer.env.bak"
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
expect_doctor_red "RED mismatched quotes (Compose refuses the file)" "$V" "customer.env could not be read through Docker Compose: Docker Compose cannot read"
V="$(pw_variant pwquoted "POSTGRES_SANITIZER_CORE_PASSWORD=\"${INIT_PW}\"")"
if doctor_offline "$V/customer.env" && grep -Fq "sanitizer core registry DSN: ok" "$TMP/doc.out"; then
  pass "GREEN a matching pair of quotes is removed (doctor and the DSN file agree)"
else
  fail "GREEN a matching pair of quotes is removed — $(grep 'sanitizer core registry' "$TMP/doc.out" | tr '\n' ' ')"
fi
if POSTGRES_SANITIZER_CORE_PASSWORD=exportedOtherPassword42 doctor_offline "$ENVF"; then
  fail "RED a differing exported POSTGRES_SANITIZER_CORE_PASSWORD (Compose would use it) — doctor stayed green"
elif grep -Fq "exported in this shell with a value other than" "$TMP/doc.out" && ! grep -Fq "exportedOtherPassword42" "$TMP/doc.out"; then
  pass "RED a differing exported POSTGRES_SANITIZER_CORE_PASSWORD (Compose would use it; no value printed)"
else
  fail "RED a differing exported POSTGRES_SANITIZER_CORE_PASSWORD — $(grep 'registry DB password' "$TMP/doc.out" | tr '\n' ' ')"
fi

# Fix round 2 (sol r2 e): RED on 6547a8c — the quoted password ends in a line
# feed. The old reader handed it on through `$(...)`, which dropped the LF:
# doctor said ok and matched the DSN file, while Compose gave Postgres the LF.
V="$(pw_variant pwlf "$(printf 'POSTGRES_SANITIZER_CORE_PASSWORD="%s\n"' "$INIT_PW")")"
expect_doctor_red "RED a quoted registry password ending in a line feed (Compose keeps the LF)" "$V" "a line feed or another control character"
# GREEN: an escape Compose decodes is no longer refused — doctor and the writer
# both see Compose's value (here the password itself, spelled with \0101 = A).
ESC_PW="$(printf '%s' "$INIT_PW" | sed 's/^./A/')"
V="$(pw_variant pwesc "POSTGRES_SANITIZER_CORE_PASSWORD=\"\\0101${ESC_PW#A}\"")"
bash "$KIT/scripts/write-sanitizer-core-registry-dsn.sh" --env-file "$V/customer.env" > /dev/null 2>&1
if doctor_offline "$V/customer.env" && grep -Fq "sanitizer core registry DSN: ok" "$TMP/doc.out" \
   && grep -Fq "dsa:${ESC_PW}@" "$V/.secrets/sanitizer-core/registry-dsn"; then
  pass "GREEN an octal escape Compose decodes: writer + doctor agree on Compose's value"
else
  fail "GREEN an octal escape Compose decodes — $(grep 'sanitizer core registry' "$TMP/doc.out" | tr '\n' ' ')"
fi
# No Docker Compose where doctor runs: the registry checks fail closed.
if PATH="$NOCOMPOSE:$BASE_PATH" bash "$KIT/bin/lucairn" doctor --env "$ENVF" --compose "$KIT_COMPOSE" --offline --skip-image-check > "$TMP/doc.out" 2>&1; then
  fail "RED no Docker Compose on PATH — doctor stayed green"
elif grep -Fq "sanitizer core registry DB password: failed (customer.env could not be read through Docker Compose: Docker Compose is not available here" "$TMP/doc.out"; then
  pass "RED no Docker Compose on PATH — doctor fails closed with the reason"
else
  fail "RED no Docker Compose on PATH — $(grep 'sanitizer core registry' "$TMP/doc.out" | head -2 | tr '\n' ' ')"
fi
# The rendered project is the last word: an overlay that hands the registry DB
# another password than POSTGRES_SANITIZER_CORE_PASSWORD makes the DSN file
# wrong even though it matches customer.env.
mkdir -p "$TMP/remap"
for e in "$KIT"/* "$KIT"/.[!.]*; do
  [ -e "$e" ] && ln -s "$e" "$TMP/remap/$(basename "$e")"
done
rm -f "$TMP/remap/docker-compose.customer.yml"
sed 's#POSTGRES_PASSWORD: "${POSTGRES_SANITIZER_CORE_PASSWORD:?#POSTGRES_PASSWORD: "remapped${POSTGRES_SANITIZER_CORE_PASSWORD:?#' "$KIT_COMPOSE" > "$TMP/remap/docker-compose.customer.yml"
if PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" doctor --env "$ENVF" --compose "$TMP/remap/docker-compose.customer.yml" --offline --skip-image-check > "$TMP/doc.out" 2>&1; then
  fail "RED a compose file that hands the registry DB another password — doctor stayed green"
elif grep -Fq "the rendered project hands postgres-sanitizer-core or migrate-sanitizer-core a password or sslmode other than" "$TMP/doc.out"; then
  pass "RED a compose file that hands the registry DB another password — the rendered-project cross-check fails it"
else
  fail "RED a compose file that hands the registry DB another password — $(grep 'sanitizer core registry' "$TMP/doc.out" | head -2 | tr '\n' ' ')"
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
  # Undeclared state (the helpers declare this uid on a Linux test host).
  LUCAIRN_CONTAINER_UID='' expect_doctor_red "RED DSN file 0400 owned by this user (the core's uid 10001 cannot read it)" "$V" "is not readable by the core, which runs as uid 10001"
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
# The core's rendered witness wiring (production shape: the local witness
# serves TLS and the core is latched with its kit client leaf — final-read M1),
# and its rendered DSN wiring, shared by every stub below.
W_ENV='"LCR_WITNESS_ADDR":"veil-witness:50057","LCR_WITNESS_MTLS_CA_BUNDLE_PATH":"/etc/sanitizer-core-mtls/ca.crt","LCR_WITNESS_MTLS_CLIENT_CERT_PATH":"/etc/sanitizer-core-mtls/witness-client.crt","LCR_WITNESS_MTLS_CLIENT_KEY_PATH":"/etc/sanitizer-core-mtls/witness-client.key",'
W_SVC=',"veil-witness":{"environment":{"GRPC_TLS_ENABLED":"true"}}'
# The core's rendered DSN wiring, shared by every stub below.
CORE_DSN_WIRING='"command":["serve","--listen=sanitizer-core:8790","--registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn","--sidecar=http://127.0.0.1:8765"],"volumes":[{"type":"bind","source":"'"$DSNF"'","target":"/run/secrets/sanitizer-core/registry-dsn","read_only":true}]'
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar",'"$CORE_DSN_WIRING"',"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true"}}'"$W_SVC"'}}' > "$TMP/config.ok.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar",'"$CORE_DSN_WIRING"',"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true","LCR_PROFILE":"hosted"}}'"$W_SVC"'}}' > "$TMP/config.hosted.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--dsn=postgres://dsa:k158OnlineCanary@postgres-sanitizer-core:5432/sanitizer_core"],"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true"}}'"$W_SVC"'}}' > "$TMP/config.dsnflag.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--listen=sanitizer-core:8790"],"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true"}}'"$W_SVC"'}}' > "$TMP/config.nodsn.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--registry-dsn-file=/run/secrets/sanitizer-core/registry-dsn"],"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true"}}'"$W_SVC"'}}' > "$TMP/config.unmounted.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve","--registry-dsn-file","postgres://dsa:k158OnlineCanary@db/x"],"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true"}}'"$W_SVC"'}}' > "$TMP/config.dsnpath.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar","command":["serve"],"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true","DSA_SANITIZER_CORE_REGISTRY_DSN":"postgres://dsa:k158OnlineCanary@postgres-sanitizer-core:5432/sanitizer_core"}}'"$W_SVC"'}}' > "$TMP/config.envdsn.json"
# K-C: without the opt-in, the opt-in's own value and its control client stay red too.
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar",'"$CORE_DSN_WIRING"',"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true","LCR_PROFILE":"kit-servicenow"}}'"$W_SVC"'}}' > "$TMP/config.kitsn.json"
printf '%s' '{"services":{"sanitizer-core":{"network_mode":"service:sanitizer-core-sidecar",'"$CORE_DSN_WIRING"',"environment":{'"$W_ENV"'"LCR_WITNESS_REQUIRE_MTLS":"true","LCR_SERVICENOW_CONTROL_PEER_URL":"https://gateway.servicenow-control:18443"}}'"$W_SVC"'}}' > "$TMP/config.ctl.json"

doctor_online() { # env assignments for the stub...
  env PATH="$DBIN:$BASE_PATH" STUB_MEM_BYTES=34359738368 STUB_PS="$TMP/ps.ok" STUB_NETMODE="container:$SIDE_ID" STUB_ENGINE_VERSION=26.1.4 \
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
online_case "RED kit-servicenow without the opt-in" "LCR_PROFILE is forwarded with a non-kit value" red STUB_CONFIG_JSON="$TMP/config.kitsn.json"
online_case "RED control client forwarded without the opt-in" "the ServiceNow control client is forwarded" red STUB_CONFIG_JSON="$TMP/config.ctl.json"
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
# Fix round 2 (sol r2 f), RED on 6547a8c each: the needle set is every value
# Compose would hand on, read by Compose. (1) An escape Compose decodes: the
# audit DB password spelled "Boundary\0101Probe4829" IS BoundaryAProbe4829 to
# Compose; the old reader skipped it, so that value under a non-secret key
# survived redaction and the scan.
# (Round 5: the existing assignment is REPLACED — a variable assigned twice
# now refuses the bundle on its own, which would hide what this case tests.)
V="$(variant sbleakesc)"; env_drop "$V/customer.env" POSTGRES_AUDIT_PASSWORD
printf 'POSTGRES_AUDIT_PASSWORD="Boundary\\0101Probe4829"\nOPERATOR_NOTE=BoundaryAProbe4829\n' >> "$V/customer.env"
bundle_refuses "an escape-decoded secret (\\0101 = A) planted under a non-secret key" "$V" leakesc "BoundaryAProbe4829"
# (2) An exported shell override: Compose run from this shell hands the
# containers the EXPORTED value, so it is a needle too.
V="$(variant sbleakexp)"; printf 'OPERATOR_NOTE=ExportedAuditPassword4829\n' >> "$V/customer.env"
if POSTGRES_AUDIT_PASSWORD=ExportedAuditPassword4829 PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$V/customer.env" --compose "$KIT_COMPOSE" --output "$BUN/leakexp" --offline > "$TMP/sb.out" 2>&1; then
  fail "RED an exported override of a secret, planted under a non-secret key — it archived"
elif grep -Fq "support bundle: refused" "$TMP/sb.out" && ! grep -Fq "ExportedAuditPassword4829" "$TMP/sb.out"; then
  pass "RED an exported override of a secret, planted under a non-secret key — refused (no value printed)"
else
  fail "RED an exported override of a secret — $(tail -1 "$TMP/sb.out")"
fi
# (3) A secret only the compose files carry (a literal in an overlay), under
# a secret-named container variable: Compose hands it to a container.
mkdir -p "$TMP/litkit"
for e in "$KIT"/* "$KIT"/.[!.]*; do
  [ -e "$e" ] && ln -s "$e" "$TMP/litkit/$(basename "$e")"
done
rm -f "$TMP/litkit/docker-compose.customer.yml"
awk '{ print } $0 == "      LCR_WITNESS_ADDR: \"veil-witness:50057\"" { print "      OVERLAY_SERVICE_TOKEN: \"ComposeOnlyTokenValue4829\"" }' "$KIT_COMPOSE" > "$TMP/litkit/docker-compose.customer.yml"
V="$(variant sbleaklit)"; printf 'OPERATOR_NOTE=ComposeOnlyTokenValue4829\n' >> "$V/customer.env"
if grep -q 'ComposeOnlyTokenValue4829' "$TMP/litkit/docker-compose.customer.yml" \
   && ! PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$V/customer.env" --compose "$TMP/litkit/docker-compose.customer.yml" --output "$BUN/leaklit" --offline > "$TMP/sb.out" 2>&1 \
   && grep -Fq "support bundle: refused" "$TMP/sb.out"; then
  pass "RED a secret only a compose file hands a container (secret-named), planted under a non-secret key — refused"
else
  fail "RED a secret only a compose file hands a container — $(tail -1 "$TMP/sb.out")"
fi
# (4) No Docker Compose where the bundle is built: refused (the scan is never skipped).
if PATH="$NOCOMPOSE:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$ENVF" --compose "$KIT_COMPOSE" --output "$BUN/nocompose" --offline > "$TMP/sb.out" 2>&1; then
  fail "RED no Docker Compose on PATH — the bundle was archived without a scan"
elif grep -Fq "could not be read through Docker Compose (Docker Compose is not available here" "$TMP/sb.out" \
     && ! find "$BUN/nocompose" -mindepth 1 2>/dev/null | grep -q .; then
  pass "RED no Docker Compose on PATH — support-bundle refuses, nothing left behind"
else
  fail "RED no Docker Compose on PATH — $(tail -1 "$TMP/sb.out")"
fi
# Fix round 4 (sol r3), RED on 93766db each.
# (5) The bundle compares DECODED values (class-deleting: no escaped needle
# variant list). sol's synthetic secret 'alpha'beta$deltalong, exported over
# customer.env, is printed by Compose as '''alpha''beta$$deltalong' (YAML ''
# doubling AND Compose's $$ in one value), which no raw needle matches. Here
# it sits literally in the collected compose file under a non-secret key; the
# online case below has Compose itself emit it into compose-resolved.yml.
SOLV="'alpha'beta\$deltalong"
SOLY="OPERATOR_NOTE: '''alpha''beta\$\$deltalong'"
mkdir -p "$TMP/esckit"
for e in "$KIT"/* "$KIT"/.[!.]*; do
  [ -e "$e" ] && ln -s "$e" "$TMP/esckit/$(basename "$e")"
done
rm -f "$TMP/esckit/docker-compose.customer.yml"
awk -v line="      $SOLY" '{ print } $0 == "      LCR_WITNESS_ADDR: \"veil-witness:50057\"" && !done { print line; done = 1 }' "$KIT_COMPOSE" > "$TMP/esckit/docker-compose.customer.yml"
if grep -Fxq "      $SOLY" "$TMP/esckit/docker-compose.customer.yml" \
   && ! POSTGRES_AUDIT_PASSWORD="$SOLV" PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$ENVF" --compose "$TMP/esckit/docker-compose.customer.yml" --output "$BUN/esc" --offline > "$TMP/sb.out" 2>&1 \
   && grep -Fq "support bundle: refused" "$TMP/sb.out" && grep -Fq "found after decoding" "$TMP/sb.out" \
   && ! grep -Fq "alpha''beta" "$TMP/sb.out" && ! find "$BUN/esc" -mindepth 1 2>/dev/null | grep -q .; then
  pass "RED a secret YAML-escaped ('' doubling + Compose \$\$) in a collected file — refused after decoding, nothing left behind"
else
  fail "RED a secret YAML-escaped ('' doubling + Compose \$\$) — $(tail -1 "$TMP/sb.out")"
fi
# The same class in a collected ENV file: the secret written with an escape
# only Compose's env-file parser undoes ("\0101" is "A"; no JSON, YAML or
# percent form spells it so), under a non-secret key.
# Round 5: an octal escape in double quotes can yield a `$` that Compose then
# interpolates ("\0044"), so such a line is not decoded exactly: refused,
# naming the line (before round 5 it was found after decoding).
V="$(variant sbleakenvq)"; env_drop "$V/customer.env" POSTGRES_AUDIT_PASSWORD
printf '%s\n' 'POSTGRES_AUDIT_PASSWORD=OctalAProbe4829x' 'OPERATOR_NOTE="Octal\0101Probe4829x"' >> "$V/customer.env"
bundle_refuses "a secret written with an env-file escape (\\0101 = A) under a non-secret key" "$V" leakenvq 'OctalAProbe4829x'
grep -Fq "the value changes when \`\$\` is taken literally" "$TMP/sb.out" \
  && pass "the octal-escape line is refused as not exactly decodable, naming the line" \
  || fail "the octal-escape line is refused as not exactly decodable: $(tail -1 "$TMP/sb.out")"
# (6) The install's project MUST render: an unrelated required variable that
# is missing used to drop every secret only the compose files carry (the
# bundle went on with the env probes alone and archived such a secret).
mkdir -p "$TMP/reqkit"
for e in "$KIT"/* "$KIT"/.[!.]*; do
  [ -e "$e" ] && ln -s "$e" "$TMP/reqkit/$(basename "$e")"
done
rm -f "$TMP/reqkit/docker-compose.customer.yml"
awk '{ print } $0 == "      LCR_WITNESS_ADDR: \"veil-witness:50057\"" { print "      OVERLAY_SERVICE_TOKEN: \"ComposeOnlyTokenValue4829\""; print "      UNRELATED_SETTING: \"${LUCAIRN_UNRELATED_REQUIRED:?set LUCAIRN_UNRELATED_REQUIRED}\"" }' "$KIT_COMPOSE" > "$TMP/reqkit/docker-compose.customer.yml"
V="$(variant sbleakreq)"; printf 'OPERATOR_NOTE=ComposeOnlyTokenValue4829\n' >> "$V/customer.env"
if PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$V/customer.env" --compose "$TMP/reqkit/docker-compose.customer.yml" --output "$BUN/leakreq" --offline > "$TMP/sb.out" 2>&1; then
  fail "RED the project does not render (an unrelated required variable is missing) — it archived"
elif grep -Fq "support bundle: refused" "$TMP/sb.out" && grep -Fq "cannot render this install's project: required variable LUCAIRN_UNRELATED_REQUIRED is missing a value" "$TMP/sb.out" \
     && ! grep -Fq "ComposeOnlyTokenValue4829" "$TMP/sb.out" && ! find "$BUN/leakreq" -mindepth 1 2>/dev/null | grep -q .; then
  pass "RED the project does not render (an unrelated required variable is missing) — refused, naming the variable, nothing left behind"
else
  fail "RED the project does not render — $(tail -1 "$TMP/sb.out")"
fi
# (7) The decoded comparison cannot run (python3 not usable): refused, never
# skipped.
NOPY="$TMP/no-python-bin"; mkdir -p "$NOPY"
printf '#!/bin/sh\necho "python3 unavailable" >&2\nexit 127\n' > "$NOPY/python3"; chmod 0755 "$NOPY/python3"
if PATH="$NOPY:$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$ENVF" --compose "$KIT_COMPOSE" --output "$BUN/nopy" --offline > "$TMP/sb.out" 2>&1; then
  fail "RED python3 not usable — the bundle was archived without the decoded comparison"
elif grep -Fq "could not be compared decoded (python3 (standard library) is required" "$TMP/sb.out" \
     && ! find "$BUN/nopy" -mindepth 1 2>/dev/null | grep -q .; then
  pass "RED python3 not usable — support-bundle refuses, nothing left behind"
else
  fail "RED python3 not usable — $(tail -1 "$TMP/sb.out")"
fi
# Fix round 5 (sol r4 on 5890e469; the owner's "one last fail-closed round"):
# a collected file whose decoded view is not an EXACT representation of its
# text refuses the bundle, naming the file and the construct; every log line
# is unescaped whether or not it parses; the whole value of every secret is a
# needle, and a secret too short to search for refuses. Each sol r4
# reproduction below is RED on 5890e469 (it archived) and refused here.
sb_run() { # <out name> <env file> <compose file> [env assignments...] -> SBRC, $TMP/sb.out
  local o="$1" e="$2" c="$3"; shift 3
  env "$@" PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$e" --compose "$c" --output "$BUN/$o" ${SB_ONLINE:---offline} > "$TMP/sb.out" 2>&1
  SBRC=$?
}
sb_refused() { # <name> <out name> <grep-fixed reason> <value that must not print>
  if [ "$SBRC" -eq 0 ]; then
    fail "RED $1 — it archived"
  elif grep -Fq "support bundle: refused" "$TMP/sb.out" && grep -Fq -- "$3" "$TMP/sb.out" \
       && ! grep -Fq -- "$4" "$TMP/sb.out" && ! find "$BUN/$2" -mindepth 1 2>/dev/null | grep -q .; then
    pass "RED $1 — refused ($3), nothing left behind, no value printed"
  else
    fail "RED $1 — $(tail -1 "$TMP/sb.out")"
  fi
}
plant_kit() { # <dir name> <line>... — the released kit, these lines appended to its compose file
  local d="$TMP/$1" e
  shift
  mkdir -p "$d"
  for e in "$KIT"/* "$KIT"/.[!.]*; do
    [ -e "$e" ] && ln -s "$e" "$d/$(basename "$e")"
  done
  rm -f "$d/docker-compose.customer.yml"
  { cat "$KIT_COMPOSE"; printf '%s\n' "$@"; } > "$d/docker-compose.customer.yml"
  printf '%s' "$d/docker-compose.customer.yml"
}
# The synthetic secret of sol r4, a customer.env secret (redacted in the
# bundle's own copy of customer.env, so only the planted form can carry it).
R5="AlphaSecret4829x"
# (1a) sol r4's exact merge-key case: the explicit `memo` overrides the merged
# one, so Compose's decoded view held only `memo: safe`.
V="$(variant r5merge)"; printf 'LUCAIRN_EXTRA_SECRET=%s\n' "$R5" >> "$V/customer.env"
C="$(plant_kit r5mergekit 'x-note: {<<: &a {memo: "\x41lphaSecret4829x"}, memo: safe}')"
sb_run r5merge "$V/customer.env" "$C"
sb_refused "sol r4: a secret in a YAML merge an explicit key overrides" r5merge "docker-compose.customer.yml, found after decoding" "$R5"
# (1b) `!reset` drops its value in Compose's loader: a tag refuses.
C="$(plant_kit r5resetkit 'x-note:' '  memo: !reset "\x41lphaSecret4829x"' '  keep: safe')"
sb_run r5reset "$V/customer.env" "$C"
sb_refused "sol r4: a secret under a YAML !reset tag" r5reset "docker-compose.customer.yml: a YAML tag" "$R5"
# (1c) an env assignment overwritten later: Compose keeps the last one only.
V="$(variant r5envdup)"
printf '%s\n' "LUCAIRN_EXTRA_SECRET='Alpha\"Secret4829x'" 'OPERATOR_NOTE="Alpha\"Secret4829x"' 'OPERATOR_NOTE=safe' >> "$V/customer.env"
sb_run r5envdup "$V/customer.env" "$KIT_COMPOSE"
sb_refused "sol r4: an env assignment overwritten later" r5envdup "(an assignment overwritten later)" 'Alpha"Secret'
# (2) sol r4's dotenv case: doubling `$` made Compose interpolate `\$Secret…`.
V="$(variant r5dollar)"
printf '%s\n' "LUCAIRN_EXTRA_SECRET='Alpha\$Secret4829x'" 'OPERATOR_NOTE="\0101lpha\$Secret4829x"' >> "$V/customer.env"
sb_run r5dollar "$V/customer.env" "$KIT_COMPOSE"
sb_refused "sol r4: \"\\0101lpha\\\$Secret4829x\" in customer.env" r5dollar "redacted/customer.env line $(grep -c '' "$V/customer.env"): the value changes when" 'Secret4829x'
# (4) sol r4's multi-line secret: "AlphaSecret\n4829x" (17 bytes, both lines
# under 12) gave no needle at all. Here under a non-secret key in the
# collected compose file.
V="$(variant r5multi)"; printf '%s\n' 'LUCAIRN_EXTRA_SECRET="AlphaSecret\n4829x"' >> "$V/customer.env"
C="$(plant_kit r5multikit 'x-note: {memo: "AlphaSecret\n4829x"}')"
sb_run r5multi "$V/customer.env" "$C"
sb_refused "sol r4: a multi-line secret whose lines are under 12 bytes" r5multi "docker-compose.customer.yml, found after decoding" '4829x'
# (4b) a secret that yields no needle at all refuses, naming the key.
V="$(variant r5short)"; printf 'LUCAIRN_EXTRA_SECRET=short4829\n' >> "$V/customer.env"
sb_run r5short "$V/customer.env" "$KIT_COMPOSE"
sb_refused "a secret too short to be searched for" r5short "shorter than 12 characters, so it cannot be searched for in the collected files (LUCAIRN_EXTRA_SECRET" 'short4829'
# (3) Log lines (an ONLINE bundle; the stub engine hands support-bundle this
# log): sol r4's partial JSON line, the multi-line secret JSON-escaped, and a
# line whose escape cannot be unescaped.
if [ "$HAVE_COMPOSE" -eq 1 ]; then
  printf 'svc  | started\nsvc  | {"note":"Alpha\\u003cSecret4829x"\n' > "$TMP/r5-partial.log"
  V="$(variant r5log)"; printf "LUCAIRN_EXTRA_SECRET='Alpha<Secret4829x'\n" >> "$V/customer.env"
  SB_ONLINE=" " sb_run r5log "$V/customer.env" "$KIT_COMPOSE" STUB_BUNDLE_LOG="$TMP/r5-partial.log"
  sb_refused "sol r4: a partial JSON log line" r5log "logs/compose.log, found after decoding" 'Secret4829x'
  printf 'svc  | {"msg":"AlphaSecret\\n4829x"}\n' > "$TMP/r5-multi.log"
  V="$(variant r5logm)"; printf '%s\n' 'LUCAIRN_EXTRA_SECRET="AlphaSecret\n4829x"' >> "$V/customer.env"
  SB_ONLINE=" " sb_run r5logm "$V/customer.env" "$KIT_COMPOSE" STUB_BUNDLE_LOG="$TMP/r5-multi.log"
  sb_refused "sol r4: the multi-line secret in a JSON log line" r5logm "logs/compose.log, found after decoding" '4829x'
  # The same secret split over two raw log lines with CRLF line breaks: the
  # whole value is a needle with CRLF too.
  printf 'svc  | AlphaSecret\r\n4829x\r\n' > "$TMP/r5-crlf.log"
  SB_ONLINE=" " sb_run r5logc "$V/customer.env" "$KIT_COMPOSE" STUB_BUNDLE_LOG="$TMP/r5-crlf.log"
  sb_refused "the multi-line secret with CRLF line breaks in a raw log" r5logc "appeared in a collected file (logs/compose.log)" '4829x'
  printf 'svc  | ok\nsvc  | {"note":"\\u00zz"}\n' > "$TMP/r5-bad.log"
  SB_ONLINE=" " sb_run r5logbad "$ENVF" "$KIT_COMPOSE" STUB_BUNDLE_LOG="$TMP/r5-bad.log"
  sb_refused "a log line whose escape cannot be unescaped" r5logbad "logs/compose.log line 2: an escape sequence that cannot be unescaped" 'u00zz'
  # No false refusal: an ordinary log (JSON lines, escapes, a regex) goes through.
  printf 'svc  | {"level":"info","msg":"a \\"quoted\\" word\\n","path":"\\/v1"}\nsvc  | grep -E "\\d+\\s" done\n' > "$TMP/r5-ok.log"
  SB_ONLINE=" " sb_run r5logok "$ENVF" "$KIT_COMPOSE" STUB_BUNDLE_LOG="$TMP/r5-ok.log"
  [ "$SBRC" -eq 0 ] && pass "an ordinary log (JSON lines, escapes, an unknown escape) is archived" \
    || fail "an ordinary log is archived: $(tail -1 "$TMP/sb.out")"
else
  skip "docker compose CLI not available — round 5 log cases"
fi
# The scan function on its own (no Compose needed for these files): JSON
# duplicate members, raw CRLF/LF forms of a multi-line secret, a text file's
# strictness against a comment's leniency.
SBF="$TMP/sbscan.sh"
{ echo 'have() { command -v "$1" >/dev/null 2>&1; }'; sed -n '/^support_bundle_decoded_scan() {/,/^}/p' "$ROOT/bin/lucairn"; } > "$SBF"
scan_case() { # <name> <want rc> <grep-fixed stderr or ""> <needle (printf %b)> <file name> <content (printf %b)>
  local d="$TMP/sbs-$RANDOM" rc=0
  mkdir -p "$d/b"
  printf '%b' "$4" | od -An -tx1 | tr -d ' \n' > "$d/needles"; echo >> "$d/needles"
  printf '%b' "$6" > "$d/b/$5"
  # shellcheck disable=SC1090,SC1091 # the extracted function file
  ( . "$ROOT/bin/compose-env.sh"; . "$SBF"; support_bundle_decoded_scan "$d/b" "$d/needles" ) > /dev/null 2> "$d/err" || rc=$?
  if [ "$rc" -eq "$2" ] && { [ -z "$3" ] || grep -Fq -- "$3" "$d/err"; }; then pass "scan: $1"; else fail "scan: $1 (rc $rc: $(head -1 "$d/err"))"; fi
  rm -rf "$d"
}
scan_case "a duplicate JSON member refuses" 3 "x.json: a duplicate JSON member" 'AlphaSecret4829x' x.json '{"memo":"\\u0041lphaSecret4829x","memo":"safe"}\n'
scan_case "a JSON-escaped secret in a .json file is found" 1 "decoded: x.json" 'AlphaSecret4829x' x.json '{"memo":"\\u0041lphaSecret4829x"}\n'
scan_case "a doubly escaped secret (JSON inside JSON) is found" 1 "decoded: a.log" 'Alpha<Secret4829x' a.log 'svc | {"m":"{\\"n\\":\\"Alpha\\\\u003cSecret4829x\\"}"}\n'
scan_case "a lone surrogate in a text file refuses, naming the line" 3 "a.log line 3: an escape sequence that cannot be unescaped (a lone UTF-16 surrogate)" 'AlphaSecret4829x' a.log 'a\nb\n"\\ud800x"\n'
scan_case "the same bytes in a YAML comment stay as written (no refusal)" 0 "" 'AlphaSecret4829x' a.yml '# see C:\\users\\x and "\\ud800"\nk: v\n'
scan_case "a hex-escaped secret in a YAML comment is found" 1 "decoded: a.yml" 'AlphaSecret4829x' a.yml '# old: \\x41lphaSecret4829x\nk: v\n'
scan_case "a duplicate YAML key refuses, naming the line" 3 "a.yml cannot be decoded exactly as yaml by Docker Compose: line 2: a duplicate mapping key" 'AlphaSecret4829x' a.yml 'k: "\\x41lphaSecret4829x"\nk: safe\n'
scan_case "a YAML anchor + alias loses nothing (accepted)" 0 "" 'AlphaSecret4829x' a.yml 'a: &x {m: one}\nb: *x\nc: {<<: *x, n: two}\n'
scan_case "an env value spanning lines refuses, naming the line" 3 "a.env cannot be decoded exactly as env by Docker Compose: Docker Compose cannot read line 2 on its own" 'AlphaSecret4829x' a.env 'A=1\nB="x\nC=2"\n'
scan_case "an exact env file goes through (quotes, comments, single-quoted \$)" 0 "" 'AlphaSecret4829x' a.env '# c\nA=1\nB="two words" # c\nC=\x27x$y\x27\nexport D=4\n'
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
  # (5, online) sol r3's exact reproduction: the secret exported over
  # customer.env reaches a non-secret key through a compose file, and Compose
  # ITSELF prints it into redacted/compose-resolved.yml as
  # OPERATOR_NOTE: '''alpha''beta$$deltalong'.
  mkdir -p "$TMP/esckit2"
  for e in "$KIT"/* "$KIT"/.[!.]*; do
    [ -e "$e" ] && ln -s "$e" "$TMP/esckit2/$(basename "$e")"
  done
  rm -f "$TMP/esckit2/docker-compose.customer.yml"
  awk '{ print } $0 == "      LCR_WITNESS_ADDR: \"veil-witness:50057\"" && !done { print "      OPERATOR_NOTE: \"${POSTGRES_AUDIT_PASSWORD-}\""; done = 1 }' "$KIT_COMPOSE" > "$TMP/esckit2/docker-compose.customer.yml"
  if POSTGRES_AUDIT_PASSWORD="$SOLV" docker compose -f "$TMP/esckit2/docker-compose.customer.yml" --env-file "$ENVF" config 2>/dev/null | grep -Fxq "      $SOLY"; then
    pass "precondition: Compose prints the exported secret as $SOLY"
  else
    fail "precondition: Compose prints the exported secret as $SOLY"
  fi
  if POSTGRES_AUDIT_PASSWORD="$SOLV" PATH="$BASE_PATH" bash "$KIT/bin/lucairn" support-bundle --env "$ENVF" --compose "$TMP/esckit2/docker-compose.customer.yml" --output "$BUN/esc2" > "$TMP/sb.out" 2>&1; then
    fail "RED sol r3: Compose prints the exported secret YAML-escaped into compose-resolved.yml — it archived"
  elif grep -Fq "support bundle: refused" "$TMP/sb.out" && grep -Fq "redacted/compose-resolved.yml, found after decoding" "$TMP/sb.out" \
       && ! find "$BUN/esc2" -mindepth 1 2>/dev/null | grep -q .; then
    pass "RED sol r3: Compose prints the exported secret YAML-escaped into compose-resolved.yml — refused after decoding"
  else
    fail "RED sol r3: the exported secret in compose-resolved.yml — $(tail -1 "$TMP/sb.out")"
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
rm -rf "$KITV/keys"; mkdir -p "$KITV/keys"; cp "$ROOT"/keys/* "$KITV/keys/"
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
echo "H. Final-read fix round (2026-11-03): H1 H2 M1 M2 TOB-K20-02 TOB-K20-03"
# Each case below is RED on the pre-round head (bda367c4 = a1404d06 rebased on
# main 63a26027) and GREEN here; the counts are in the PR description.

# ── H1: `bin/lucairn up` runs the capped registry migration first ───────────
UPBIN="$TMP/up-bin"; mkdir -p "$UPBIN"
cat > "$UPBIN/docker" <<'STUBUP'
#!/bin/bash
# Records every compose call; answers what lifecycle `up` needs.
[ "${1:-}" = compose ] || exit 1
a=" $* "
echo "$*" >> "$STUB_UP_LOG"
case "$a" in
  *" version "*) exit 0 ;;
  *" --profile sanitizer-core-migrate config --services "*) printf 'gateway\nsanitizer-core\nmigrate-sanitizer-core\n'; exit 0 ;;
  *" run --rm "*"migrate-sanitizer-core "*) exit "${STUB_MIGRATE_RC:-0}" ;;
  *" up -d "*) exit 0 ;;
esac
exit 1
STUBUP
chmod 0755 "$UPBIN/docker"
up_run() { # [env assignments...] -> UPRC, log in $TMP/up.log
  : > "$TMP/up.log"
  env PATH="$UPBIN:$BASE_PATH" STUB_UP_LOG="$TMP/up.log" "$@" bash "$KIT/bin/lucairn" up --env "$ENVF" --compose "$KIT_COMPOSE" > "$TMP/up.out" 2>&1
  UPRC=$?
}
up_run
MIG_LINE="$(grep -n -- '--profile sanitizer-core-migrate run --rm -T migrate-sanitizer-core' "$TMP/up.log" | head -1 | cut -d: -f1)"
UP_LINE="$(grep -n -- ' up -d' "$TMP/up.log" | head -1 | cut -d: -f1)"
if [ "$UPRC" -eq 0 ] && [ -n "$MIG_LINE" ] && [ -n "$UP_LINE" ] && [ "$MIG_LINE" -lt "$UP_LINE" ]; then
  pass "H1 bin/lucairn up runs the capped migration step (profile sanitizer-core-migrate) BEFORE up -d"
else
  fail "H1 bin/lucairn up runs the capped migration step before up -d (rc $UPRC; migrate line '${MIG_LINE:-none}', up line '${UP_LINE:-none}'): $(tr '\n' '|' < "$TMP/up.log")"
fi
grep -q -- "--env-file $ENVF --profile sanitizer-core-migrate run" "$TMP/up.log" \
  && pass "H1 the migration runs on the install's own env file and recorded compose set" \
  || fail "H1 the migration runs on the install's own env file and recorded compose set: $(grep migrate "$TMP/up.log")"
up_run STUB_MIGRATE_RC=95
if [ "$UPRC" -ne 0 ] && ! grep -q -- ' up -d' "$TMP/up.log" && grep -Fq "registry migration step failed" "$TMP/up.out"; then
  pass "H1 a failed migration (exit 95) stops up before anything starts"
else
  fail "H1 a failed migration stops up (rc $UPRC): $(tr '\n' '|' < "$TMP/up.log") / $(tail -1 "$TMP/up.out")"
fi
grep -Fq "bin/lucairn up first runs the sanitizer core's capped registry migration" "$TMP/init.out" \
  && pass "H1 lucairn-init's Next block says up runs the migration (and gives the plain-Compose command)" \
  || fail "H1 lucairn-init's Next block says up runs the migration"
H1_DOCS_BAD=""
h1_docs_check() { # <file> — every whole-stack `docker compose ... up -d`
  # (one line, or a command block continued with backslashes: kit round 2, the
  # check matched one-line commands only and missed INSTALL.md's self-hosted
  # step 6) is preceded (within 6 lines of the command's FIRST line) by the
  # migration step or says bin/lucairn up does it. Prints <file>:<first line>.
  awk -v f="$(basename "$1")" '
    function check(cmd, start,   i, ok) {
      if (cmd ~ /docker compose/ && cmd ~ /-f docker-compose\.customer\.yml/ && cmd ~ /--env-file customer\.env/ && cmd ~ /[[:space:]]up -d[[:space:]]*$/) {
        ok = 0
        for (i = start - 6; i < start; i++) if (i > 0 && (line[i] ~ /migrate-sanitizer-core/ || line[i] ~ /bin\/lucairn up/)) ok = 1
        if (!ok) print f ":" start
      }
    }
    { line[NR] = $0
      if (cont) cmd = cmd " " $0; else { cmd = $0; start = NR }
      if ($0 ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", cmd); cont = 1 } else { cont = 0; check(cmd, start) }
    }' "$1"
}
# K-E (2026-11-04): OPS.md (upgrade, rollback, disaster recovery) and
# TROUBLESHOOTING.md hold start paths a 2.0 install can take too.
for f in README.md INSTALL.md OPS.md TROUBLESHOOTING.md; do
  h1_docs_check "$KIT/$f"
done > "$TMP/h1-docs.txt"
[ -s "$TMP/h1-docs.txt" ] && H1_DOCS_BAD="$(tr '\n' ' ' < "$TMP/h1-docs.txt")"
if [ -z "$H1_DOCS_BAD" ]; then pass "H1 no documented whole-stack 'docker compose ... up -d' without the migration step before it"; else fail "H1 documented whole-stack up -d without the migration step: $H1_DOCS_BAD"; fi
grep -c 'up first runs the sanitizer core' "$KIT/README.md" | grep -qx 3 \
  && pass "H1 the three README install paths say bin/lucairn up runs the registry migration" \
  || fail "H1 the three README install paths say bin/lucairn up runs the registry migration"

# ── H2: an offline bundle can start the core (the reproduction) ─────────────
# released-kit fixture -> init --dev -> bundle create -> extract -> DELETE the
# build directory -> the customer-host steps from the bundle -> compose render
# + offline doctor.
H2B="$TMP/h2-build"; H2X="$TMP/h2-x"; mkdir -p "$H2B/models" "$H2X"
printf 'synthetic gguf bytes\n' > "$H2B/models/fixture.gguf"
H2SHA="$( (command -v sha256sum >/dev/null 2>&1 && sha256sum "$H2B/models/fixture.gguf" || shasum -a 256 "$H2B/models/fixture.gguf") | awk '{print $1}')"
cat > "$H2B/model-manifest.yaml" <<YAML
model:
  name: fixture-local-model
  format: gguf
  runtime: llama-cpp
  files:
    - path: fixture.gguf
      sha256: $H2SHA
  context_window: 8192
  gpu_required: false
  min_vram_gb: 0
  license: customer-owned
  checksum_policy: sha256-required
YAML
PATH="$DBIN:$BASE_PATH" "$KIT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
  --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$H2B/customer.env" --skip-doctor > "$TMP/h2-init.out" 2>&1 \
  || fail "H2 lucairn-init for the bundle: $(tail -2 "$TMP/h2-init.out")"
grep -q "^SANITIZER_CORE_MTLS_HOST_DIR=$H2B/" "$H2B/customer.env" \
  && pass "H2 precondition: the build-host env names an absolute build-host cert directory" \
  || fail "H2 precondition: the build-host env names an absolute build-host cert directory"
if PATH="$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" bundle create --customer-slug h2-offline --models-dir "$H2B/models" \
     --model-manifest "$H2B/model-manifest.yaml" --env "$H2B/customer.env" --output "$TMP/h2-out" > "$TMP/h2-create.out" 2>&1; then
  pass "H2 bundle create"
else
  fail "H2 bundle create: $(tail -3 "$TMP/h2-create.out")"
fi
H2TAR="$(ls "$TMP"/h2-out/lucairn-customer-bundle-h2-offline-*.tar.gz 2>/dev/null | head -1)"
tar -xzf "$H2TAR" -C "$H2X" 2>/dev/null
H2R="$(ls -d "$H2X"/lucairn-customer-bundle-h2-offline-* 2>/dev/null | head -1)"
rm -rf "$H2B"
[ -d "$H2R" ] && pass "H2 bundle extracted; the build directory is deleted" || fail "H2 bundle extracted"
H2E="$H2R/install/customer.env"
check_eq "H2 the staged env names the bundle-relative cert directory" "./.certs/sanitizer-core-mtls" "$(sed -n 's/^SANITIZER_CORE_MTLS_HOST_DIR=//p' "$H2E" | tail -1)"
check_eq "H2 the staged env names the bundle-relative DSN file" "./.secrets/sanitizer-core/registry-dsn" "$(sed -n 's/^SANITIZER_CORE_REGISTRY_DSN_FILE=//p' "$H2E" | tail -1)"
# (the generated header's "# Regenerate:" comment names the --output path; it
# is a comment, read by nobody)
grep -v '^#' "$H2E" | grep -Fq "$H2B" && fail "H2 no build-host path left in any setting of install/customer.env" || pass "H2 no build-host path left in any setting of install/customer.env"
for t in scripts/bootstrap-sanitizer-core-mtls.sh scripts/write-sanitizer-core-registry-dsn.sh bin/compose-env.sh; do
  [ -f "$H2R/$t" ] && pass "H2 the bundle ships $t" || fail "H2 the bundle ships $t"
done
grep -Fq "scripts/write-sanitizer-core-registry-dsn.sh --env-file install/customer.env --compose install/docker-compose.customer.yml" "$H2R/INSTALL-CUSTOMER.md" \
  && grep -Fq 'scripts/bootstrap-sanitizer-core-mtls.sh "$PWD/install/.certs/sanitizer-core-mtls"' "$H2R/INSTALL-CUSTOMER.md" \
  && pass "H2 INSTALL-CUSTOMER.md names both one-time steps (mTLS bootstrap + DSN file)" \
  || fail "H2 INSTALL-CUSTOMER.md names both one-time steps (mTLS bootstrap + DSN file)"
if (cd "$H2R" && PATH="$DBIN:$BASE_PATH" bash bin/lucairn bundle verify --bundle . > "$TMP/h2-verify.out" 2>&1); then
  pass "H2 bundle verify on the extracted bundle"
else
  fail "H2 bundle verify on the extracted bundle: $(tail -2 "$TMP/h2-verify.out")"
fi
# The customer-host steps, exactly as INSTALL-CUSTOMER.md gives them (no sudo
# here: macOS needs none; on a Linux test host the helpers declare the uid).
if (cd "$H2R" && PATH="$DBIN:$BASE_PATH" bash scripts/bootstrap-sanitizer-core-mtls.sh "$PWD/install/.certs/sanitizer-core-mtls" > "$TMP/h2-boot.out" 2>&1 \
      && PATH="$DBIN:$BASE_PATH" bash scripts/write-sanitizer-core-registry-dsn.sh --env-file install/customer.env --compose install/docker-compose.customer.yml > "$TMP/h2-dsn.out" 2>&1); then
  pass "H2 the bundle's two one-time steps run on the customer host"
else
  fail "H2 the bundle's two one-time steps run: $(tail -2 "$TMP/h2-boot.out") $(tail -2 "$TMP/h2-dsn.out" 2>/dev/null)"
fi
[ -f "$H2R/install/.certs/sanitizer-core-mtls/sanitizer-core/witness-client.crt" ] && [ -f "$H2R/install/.secrets/sanitizer-core/registry-dsn" ] \
  && pass "H2 mTLS material + DSN file are inside the bundle's install/" || fail "H2 mTLS material + DSN file are inside the bundle's install/"
if [ "$HAVE_COMPOSE" -eq 1 ]; then
  if (cd "$H2R" && docker compose -f install/docker-compose.customer.yml --env-file install/customer.env config --format json > "$TMP/h2-render.json" 2> "$TMP/h2-render.err"); then
    python3 - "$TMP/h2-render.json" "$H2R/install" > "$TMP/h2-render.txt" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1])); inst = os.path.realpath(sys.argv[2])
core = d["services"]["sanitizer-core"]
srcs = [v.get("source", "") for v in core.get("volumes") or []]
ok = all(os.path.realpath(s).startswith(inst + os.sep) and os.path.exists(s) for s in srcs) and len(srcs) == 2
print(("ok " if ok else "FAIL ") + "H2 the rendered core mounts its cert directory and DSN file from the bundle, and both exist (%s)" % srcs)
PY
    while IFS= read -r line; do case "$line" in ok\ *) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac; done < "$TMP/h2-render.txt"
  else
    fail "H2 the extracted bundle renders: $(tail -2 "$TMP/h2-render.err")"
  fi
else
  skip "docker compose CLI not available — H2 render"
fi
if (cd "$H2R" && PATH="$DBIN:$BASE_PATH" bash bin/lucairn doctor --env install/customer.env --compose install/docker-compose.customer.yml --offline --skip-image-check > "$TMP/h2-doc.out" 2>&1); then
  pass "H2 the offline doctor of the extracted bundle passes"
else
  fail "H2 the offline doctor of the extracted bundle passes: $(grep -E 'failed|error' "$TMP/h2-doc.out" | head -3 | tr '\n' ' ')"
fi
for line in "sanitizer core registry DSN: ok" "sanitizer core mTLS: ok"; do
  grep -Fq "$line" "$TMP/h2-doc.out" && pass "H2 bundle doctor: $line" || fail "H2 bundle doctor: $line"
done

# ── M1: the core's witness hop follows the witness's transport ──────────────
grep -q '^LCR_WITNESS_MTLS_SANITIZER_CORE_CA_BUNDLE_PATH=$' "$ENVF" && grep -q '^LCR_WITNESS_MTLS_SANITIZER_CORE_CLIENT_KEY_PATH=$' "$ENVF" \
  && pass "M1 lucairn-init --dev writes the three client-leaf paths empty (GRPC_TLS_ENABLED=false)" \
  || fail "M1 lucairn-init --dev writes the three client-leaf paths empty"
m1_render() { # <env file> <out json> — the install's base project, real Compose
  docker compose -f "$KIT_COMPOSE" --env-file "$1" config --format json > "$2" 2> "$2.err"
}
m1_hop() { # <render json> -> "latch|leaf|witness-tls"
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["services"]; c=d["sanitizer-core"]["environment"]; w=d["veil-witness"]["environment"]
leaf=[c.get(k) or "" for k in ("LCR_WITNESS_MTLS_CA_BUNDLE_PATH","LCR_WITNESS_MTLS_CLIENT_CERT_PATH","LCR_WITNESS_MTLS_CLIENT_KEY_PATH")]
print("%s|%s|%s" % (c.get("LCR_WITNESS_REQUIRE_MTLS"), "full" if all(leaf) else ("none" if not any(leaf) else "partial"), w.get("GRPC_TLS_ENABLED")))' "$1"
}
if [ "$HAVE_COMPOSE" -eq 1 ]; then
  m1_render "$ENVF" "$TMP/m1-dev.json" && check_eq "M1 a --dev install renders an unlatched core with no client leaf beside a plaintext witness" "false|none|false" "$(m1_hop "$TMP/m1-dev.json")"
  V="$(variant m1prod)"; sed -i.bak -e 's/^GRPC_TLS_ENABLED=.*/GRPC_TLS_ENABLED=true/' -e 's/^DSA_ENV=.*/DSA_ENV=production/' -e '/^LCR_WITNESS_MTLS_SANITIZER_CORE_/d' "$V/customer.env"; rm -f "$V/customer.env.bak"
  m1_render "$V/customer.env" "$TMP/m1-prod.json" && check_eq "M1 a production env renders a latched core with its full client leaf beside a TLS witness" "true|full|true" "$(m1_hop "$TMP/m1-prod.json")"
  # The pre-fix --dev state (or a hand-flipped env per TROUBLESHOOTING without
  # the three lines): plaintext witness, core still dialing verified mTLS.
  V="$(variant m1old)"; env_drop "$V/customer.env" LCR_WITNESS_MTLS_SANITIZER_CORE_CA_BUNDLE_PATH
  env_drop "$V/customer.env" LCR_WITNESS_MTLS_SANITIZER_CORE_CLIENT_CERT_PATH; env_drop "$V/customer.env" LCR_WITNESS_MTLS_SANITIZER_CORE_CLIENT_KEY_PATH
  expect_doctor_red "M1 RED offline: plaintext witness, core still on verified mTLS (every claim dropped)" "$V" "the core still dials it with verified mTLS"
  # The online renders keep the generated install's own paths (the online
  # doctor below runs on $ENVF and cross-checks the rendered DSN mount).
  grep -v '^LCR_WITNESS_MTLS_SANITIZER_CORE_' "$ENVF" > "$TMP/m1-old.env"
  m1_render "$TMP/m1-old.env" "$TMP/m1-old.json"
  check_eq "M1 precondition: the mismatched env renders a full client leaf beside a plaintext witness" "full|false" "$(m1_hop "$TMP/m1-old.json" | cut -d'|' -f2-)"
  online_case "M1 RED online: the rendered core dials a plaintext witness with mTLS" "the local witness serves plaintext (GRPC_TLS_ENABLED is not true) but the core dials it with verified mTLS" red STUB_CONFIG_JSON="$TMP/m1-old.json"
  printf '%s\n' '2026/11/03 08:00:00 WARNING evidence: plaintext witness transport to non-loopback addr="veil-witness:50057" allowed only because DSA_ENV=development' \
    '2026/11/03 08:00:00 evidence: witness transport mode=plaintext-insecure-dev addr="veil-witness:50057"' > "$TMP/core.devplain"
  online_case "M1 GREEN online: a --dev install's plaintext hop on both sides" "sanitizer core claims: transport ok (plaintext to the local development witness" green STUB_CONFIG_JSON="$TMP/m1-dev.json" STUB_CORE_LOG="$TMP/core.devplain"
  grep -Fq "sanitizer core rendered config: ok" "$TMP/online.out" && pass "M1 GREEN online: the --dev render passes the rendered-config check" || fail "M1 GREEN online: the --dev render passes the rendered-config check: $(grep 'rendered config' "$TMP/online.out")"
  sed 's/^DSA_ENV=.*/DSA_ENV=production/' "$ENVF" > "$TMP/m1-prodplain.env"
  m1_render "$TMP/m1-prodplain.env" "$TMP/m1-prodplain.json"
  online_case "M1 RED online: a plaintext hop is never accepted for a production render" "the local witness serves plaintext with DSA_ENV=production" red STUB_CONFIG_JSON="$TMP/m1-prodplain.json"
else
  skip "docker compose CLI not available — M1 renders"
fi
V="$(variant m1empty)"; sed -i.bak 's/^GRPC_TLS_ENABLED=.*/GRPC_TLS_ENABLED=true/' "$V/customer.env"; rm -f "$V/customer.env.bak"
expect_doctor_red "M1 RED offline: GRPC_TLS_ENABLED=true with the client-leaf paths still empty (the core would not start)" "$V" "the core refuses to start without its client leaf"
# ── M2: non-root Linux bootstrap/init (simulated Linux host) ────────────────
LXB="$TMP/linux-bin"; mkdir -p "$LXB"
printf '#!/bin/sh\n[ "${1:-}" = "-s" ] && { echo Linux; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$LXB/uname"
cat > "$LXB/id" <<'STUBID'
#!/bin/sh
case "$*" in
  -u) echo "${STUB_ID_U:-1000}" ;;
  -un) echo stub-operator ;;
  *) exec /usr/bin/id "$@" ;;
esac
STUBID
cat > "$LXB/sudo" <<'STUBSUDO'
#!/bin/sh
echo "sudo $*" >> "$STUB_SUDO_LOG"
[ "${STUB_SUDO_FAIL:-0}" = 1 ] && { echo "sudo: a password is required" >&2; exit 1; }
STUB_ID_U=0; export STUB_ID_U
# Like sudo(8): the invoking user's ids (kit round 2, R1 hands folders back).
SUDO_UID="$(/usr/bin/id -u)"; SUDO_GID="$(/usr/bin/id -g)"; export SUDO_UID SUDO_GID
exec "$@"
STUBSUDO
printf '#!/bin/sh\necho "chown $*" >> "$STUB_SUDO_LOG"\n' > "$LXB/chown"
# GNU stat syntax on a BSD userland (the simulated Linux host runs on macOS).
if [ "$(/usr/bin/uname -s)" = "Darwin" ]; then
  printf '#!/bin/sh\nif [ "$1" = "-c" ]; then f="$2"; shift 2; case "$f" in %%a) exec /usr/bin/stat -f %%Lp "$@" ;; %%u) exec /usr/bin/stat -f %%u "$@" ;; %%g) exec /usr/bin/stat -f %%g "$@" ;; %%i) exec /usr/bin/stat -f %%i "$@" ;; esac; fi\nexec /usr/bin/stat "$@"\n' > "$LXB/stat"
fi
chmod 0755 "$LXB"/*
M2D="$TMP/m2-certs"
if env -u LUCAIRN_CONTAINER_UID PATH="$LXB:$BASE_PATH" bash "$BOOTSTRAP" "$M2D" > "$TMP/m2-boot.out" 2>&1; then
  fail "M2 RED Linux non-root bootstrap — it ran (keys the containers cannot read)"
elif grep -Fq "only root can hand them over" "$TMP/m2-boot.out" && [ ! -e "$M2D" ]; then
  pass "M2 Linux non-root bootstrap refuses before writing anything, naming sudo and the declared-uid escape"
else
  fail "M2 Linux non-root bootstrap refusal: $(tail -1 "$TMP/m2-boot.out"); dir exists: $([ -e "$M2D" ] && echo yes || echo no)"
fi
if env PATH="$LXB:$BASE_PATH" LUCAIRN_CONTAINER_UID=1000 bash "$BOOTSTRAP" "$M2D" > "$TMP/m2-boot.out" 2>&1 && [ -f "$M2D/sanitizer-core/witness-client.key" ]; then
  pass "M2 Linux non-root bootstrap with LUCAIRN_CONTAINER_UID = own uid (declared mapping) writes the material"
else
  fail "M2 Linux non-root bootstrap with a declared uid: $(tail -2 "$TMP/m2-boot.out")"
fi
M2I="$TMP/m2-init"; mkdir -p "$M2I"; : > "$TMP/m2-sudo.log"
if env -u LUCAIRN_CONTAINER_UID PATH="$LXB:$DBIN:$BASE_PATH" STUB_SUDO_LOG="$TMP/m2-sudo.log" "$KIT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
     --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$M2I/customer.env" --skip-doctor > "$TMP/m2-init.out" 2>&1 \
   && grep -q "^sudo env LUCAIRN_CONTAINER_UID=10001 bash .*bootstrap-sanitizer-core-mtls.sh $M2I/.certs/sanitizer-core-mtls$" "$TMP/m2-sudo.log" \
   && grep -q "^chown -R 10001:10001 " "$TMP/m2-sudo.log"; then
  pass "M2 lucairn-init on Linux as non-root runs the bootstrap step through sudo (keys handed to uid 10001)"
else
  fail "M2 lucairn-init on Linux as non-root runs the bootstrap through sudo: $(tr '\n' '|' < "$TMP/m2-sudo.log") $(grep -i 'sudo\|error' "$TMP/m2-init.out" | head -2 | tr '\n' ' ')"
fi
grep -Fq "running that one step with sudo" "$TMP/m2-init.out" && pass "M2 init says it uses sudo for that one step" || fail "M2 init says it uses sudo for that one step"
M2J="$TMP/m2-init-nosudo"; mkdir -p "$M2J"; : > "$TMP/m2-sudo.log"
if env -u LUCAIRN_CONTAINER_UID PATH="$LXB:$DBIN:$BASE_PATH" STUB_SUDO_LOG="$TMP/m2-sudo.log" STUB_SUDO_FAIL=1 "$KIT/bin/lucairn-init" --dev --runtime-mode local-runtime --local-runtime llama-cpp \
     --model-name fixture-local-model --model-file fixture.gguf --model-path . --output "$M2J/customer.env" --skip-doctor > "$TMP/m2-init.out" 2>&1; then
  fail "M2 RED init when sudo is refused — it succeeded"
elif grep -Fq "re-run: sudo scripts/bootstrap-sanitizer-core-mtls.sh" "$TMP/m2-init.out"; then
  pass "M2 init fails when sudo is refused, naming the exact sudo command"
else
  fail "M2 init when sudo is refused: $(tail -1 "$TMP/m2-init.out")"
fi
# Doctor on a Linux host (simulated with the shims on macOS; real on a non-root
# Linux test host): keys owned by this user, not uid 10001.
M2_DOC_PATH=""
case "$(/usr/bin/uname -s)" in
  Darwin) M2_DOC_PATH="$LXB:$DBIN:$BASE_PATH" ;;
  Linux) [ "$(id -u)" != "0" ] && M2_DOC_PATH="$DBIN:$BASE_PATH" ;;
esac
if [ -n "$M2_DOC_PATH" ]; then
  if env -u LUCAIRN_CONTAINER_UID PATH="$M2_DOC_PATH" bash "$KIT/bin/lucairn" doctor --env "$ENVF" --compose "$KIT_COMPOSE" --offline --skip-image-check > "$TMP/m2-doc.out" 2>&1; then
    fail "M2 RED doctor on Linux: keys owned by another uid than the containers' — doctor stayed green (the old warning)"
  elif grep -Fq "and cannot read a 0600 key owned by another uid, so the service refuses to start" "$TMP/m2-doc.out"; then
    pass "M2 doctor on Linux FAILS a key owned by another uid than the containers' (was a warning)"
  else
    fail "M2 doctor on Linux key owner: $(grep 'mTLS' "$TMP/m2-doc.out" | head -2 | tr '\n' ' ')"
  fi
  V="$(variant m2declared)"; printf 'LUCAIRN_CONTAINER_UID=%s\n' "$(id -u)" >> "$V/customer.env"
  if env -u LUCAIRN_CONTAINER_UID PATH="$M2_DOC_PATH" bash "$KIT/bin/lucairn" doctor --env "$V/customer.env" --compose "$KIT_COMPOSE" --offline --skip-image-check > "$TMP/m2-doc.out" 2>&1 \
     && grep -Fq "sanitizer core mTLS: ok" "$TMP/m2-doc.out"; then
    pass "M2 doctor on Linux accepts the keys when customer.env declares LUCAIRN_CONTAINER_UID = their owner"
  else
    fail "M2 doctor on Linux with a declared uid: $(grep -E 'mTLS|failed' "$TMP/m2-doc.out" | head -2 | tr '\n' ' ')"
  fi
else
  skip "M2 doctor key-owner cases: not run as root"
fi

# ── TOB-K20-02: the core pair is hardened like the Helm chart ───────────────
if [ "$HAVE_COMPOSE" -eq 1 ] && [ -f "$TMP/render.json" ]; then
  python3 - "$TMP/render.json" > "$TMP/k20-02.txt" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))["services"]
def p(ok, msg): print(("ok " if ok else "FAIL ") + msg)
for name, size in (("sanitizer-core-sidecar", "1g"), ("sanitizer-core", "64m")):
    x = s[name]
    p(x.get("cap_drop") == ["ALL"], "TOB-K20-02 %s drops every capability" % name)
    p("no-new-privileges:true" in (x.get("security_opt") or []), "TOB-K20-02 %s: no-new-privileges" % name)
    p(x.get("read_only") is True, "TOB-K20-02 %s: read-only root filesystem" % name)
    p(any(t.split(":")[0] == "/tmp" and ("size=" + size) in t for t in (x.get("tmpfs") or [])), "TOB-K20-02 %s: private /tmp tmpfs (size %s) (%s)" % (name, size, x.get("tmpfs")))
e = s["sanitizer-core-sidecar"].get("environment") or {}
p(e.get("HOME") == "/tmp" and e.get("XDG_CACHE_HOME") == "/tmp/.cache", "TOB-K20-02 sidecar HOME + XDG_CACHE_HOME on /tmp (as the Helm chart)")
PY
  while IFS= read -r line; do case "$line" in ok\ *) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac; done < "$TMP/k20-02.txt"
else
  skip "docker compose CLI not available — TOB-K20-02 render"
fi

# ── TOB-K20-03: Docker Engine below the CVE-2024-29018 fixes FAILS online ────
for cell in "26.0.0|ok" "26.1.4|ok" "27.3.1|ok" "25.0.5|ok" "25.1.0|ok" "23.0.11|ok" "25.0.4|failed" "24.0.7|failed" "23.0.10|failed" "20.10.24|failed"; do
  ver="${cell%%|*}"; want="${cell#*|}"
  if [ "$want" = ok ]; then
    online_case "TOB-K20-03 GREEN Docker Engine $ver" "docker engine: ok ($ver" green STUB_ENGINE_VERSION="$ver"
  else
    online_case "TOB-K20-03 RED Docker Engine $ver (CVE-2024-29018)" "docker engine: failed ($ver forwards DNS queries from internal networks" red STUB_ENGINE_VERSION="$ver"
  fi
done
grep -Fq "Docker Engine 26.0.0 or newer" "$KIT/INSTALL.md" && pass "TOB-K20-03 INSTALL.md states the Docker Engine minimum" || fail "TOB-K20-03 INSTALL.md states the Docker Engine minimum"

echo ""
echo "I. Kit round 2 (2026-11-04): R1 R2 CA-key mount, H1 multi-line docs, bundle password sentence"
# Each case is RED on the pre-round head (cf45011) and GREEN here; the counts
# are in the PR description. NON-COVERAGE: this Mac has no passwordless sudo
# and no Docker daemon, so no case changes the effective uid or boots the
# gateway. "Root" is the sudo shim (id -u = 0, SUDO_UID/SUDO_GID = this user)
# and the hand-back is asserted from the logged chown calls; folder MODES are
# real. The gateway's permission-denied crash itself is DSA veil.go
# (loadWitnessSignedManifest: only os.ErrNotExist is tolerated), read, not run.

# ── R1: a sudo bootstrap leaves ./.certs traversable and the operator's ─────
R1P="$TMP/r1-proj"; mkdir -p "$R1P/scripts"
cp "$BOOTSTRAP" "$R1P/scripts/"; cp "$COMPOSE" "$R1P/docker-compose.customer.yml"
: > "$TMP/r1-sudo.log"
if env -u LUCAIRN_CONTAINER_UID PATH="$LXB:$BASE_PATH" STUB_SUDO_LOG="$TMP/r1-sudo.log" sudo bash "$R1P/scripts/bootstrap-sanitizer-core-mtls.sh" > "$TMP/r1-boot.out" 2>&1; then
  pass "R1 the default-dir bootstrap runs under (simulated) sudo on a project without ./.certs"
else
  fail "R1 the default-dir bootstrap under sudo: $(tail -2 "$TMP/r1-boot.out")"
fi
check_eq "R1 ./.certs created under sudo is 0755 (uid 10001 traverses /certs; was 0700 from umask 077)" "755" "$(file_mode "$R1P/.certs" 2>/dev/null)"
check_eq "R1 the cert directory is 0755" "755" "$(file_mode "$R1P/.certs/sanitizer-core-mtls" 2>/dev/null)"
ME_UG="$(/usr/bin/id -u):$(/usr/bin/id -g)"
grep -qx "chown $ME_UG $R1P/.certs" "$TMP/r1-sudo.log" \
  && pass "R1 ./.certs is handed back to SUDO_UID:SUDO_GID (the operator copies the signed manifest in without sudo)" \
  || fail "R1 ./.certs handed back to the sudo user: $(tr '\n' '|' < "$TMP/r1-sudo.log")"
grep -qx "chown $ME_UG $R1P/.secrets" "$TMP/r1-sudo.log" && [ "$(file_mode "$R1P/.secrets" 2>/dev/null)" = 700 ] \
  && pass "R1 ./.secrets (created for the CA) is 0700 and handed back (the DSN writer runs as the operator)" \
  || fail "R1 ./.secrets handed back + 0700: mode $(file_mode "$R1P/.secrets" 2>/dev/null); $(tr '\n' '|' < "$TMP/r1-sudo.log")"
if grep -q "^chown $ME_UG .*sanitizer-core-mtls-ca$" "$TMP/r1-sudo.log"; then
  fail "R1 the CA directory stays root's (it was handed back)"
else
  pass "R1 the CA directory stays root's (not handed back)"
fi
# The init path (Linux, not root): the same folders through init's sudo step.
check_eq "R1 lucairn-init on Linux as non-root (sudo step): <out>/.certs is 0755" "755" "$(file_mode "$M2I/.certs" 2>/dev/null)"

# ── CA private key: no container mounts it ──────────────────────────────────
# End to end: the bootstrap writes the CA where it writes it, the real Compose
# CLI renders the project with the example env, and no service's bind-mount
# source may contain the CA key (round 1: the gateway's ./.certs:/certs).
R1KEY="$(find "$R1P" -name ca.key -type f 2>/dev/null | head -1)"
[ -n "$R1KEY" ] && pass "CA the bootstrap wrote one CA key ($R1KEY)" || fail "CA the bootstrap wrote a CA key"
if [ "$HAVE_COMPOSE" -eq 1 ] && [ -n "$R1KEY" ]; then
  if docker compose -f "$R1P/docker-compose.customer.yml" --env-file "$PINNED_ENV" config --format json > "$TMP/ca-render.json" 2> "$TMP/ca-render.err"; then
    python3 - "$TMP/ca-render.json" "$R1KEY" > "$TMP/ca-render.txt" <<'PY'
import json, os, sys
svcs = json.load(open(sys.argv[1]))["services"]
key = os.path.realpath(sys.argv[2])
hits = []
for name, svc in sorted(svcs.items()):
    for v in svc.get("volumes") or []:
        if v.get("type") != "bind":
            continue
        src = os.path.realpath(v.get("source", ""))
        if key == src or key.startswith(src.rstrip(os.sep) + os.sep):
            hits.append("%s:%s->%s" % (name, v.get("source"), v.get("target")))
print(("ok " if not hits else "FAIL ") + "CA render: no service's bind mount contains the CA private key (%s)" % (", ".join(hits) or "none"))
PY
    while IFS= read -r line; do case "$line" in ok\ *) pass "${line#ok }" ;; *) fail "${line#FAIL }" ;; esac; done < "$TMP/ca-render.txt"
  else
    fail "CA render of the bootstrapped project: $(tail -2 "$TMP/ca-render.err")"
  fi
else
  skip "docker compose CLI not available — CA render"
fi
check_eq "CA the default layout keeps the CA in <dir>/.secrets/sanitizer-core-mtls-ca" "$R1P/.secrets/sanitizer-core-mtls-ca/ca.key" "$R1KEY"
# An old-layout CA (<cert dir>/ca, round 1) moves out on the next run, and no
# leaf rotates.
R1O="$TMP/r1-old"; mkdir -p "$R1O/scripts"; cp "$BOOTSTRAP" "$R1O/scripts/"; cp "$COMPOSE" "$R1O/docker-compose.customer.yml"
bash "$R1O/scripts/bootstrap-sanitizer-core-mtls.sh" > /dev/null 2>&1
if [ -d "$R1O/.secrets/sanitizer-core-mtls-ca" ]; then
  mkdir -p "$R1O/.certs/sanitizer-core-mtls/ca"
  mv "$R1O/.secrets/sanitizer-core-mtls-ca/ca.key" "$R1O/.secrets/sanitizer-core-mtls-ca/ca.crt" "$R1O/.certs/sanitizer-core-mtls/ca/"
  rmdir "$R1O/.secrets/sanitizer-core-mtls-ca"
fi
R1O_BEFORE="$(cat "$R1O"/.certs/sanitizer-core-mtls/sanitizer-core/*.crt "$R1O"/.certs/sanitizer-core-mtls/gateway/*.crt "$R1O"/.certs/sanitizer-core-mtls/veil-witness/*.crt 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')"
bash "$R1O/scripts/bootstrap-sanitizer-core-mtls.sh" > "$TMP/r1-old.out" 2>&1
R1O_AFTER="$(cat "$R1O"/.certs/sanitizer-core-mtls/sanitizer-core/*.crt "$R1O"/.certs/sanitizer-core-mtls/gateway/*.crt "$R1O"/.certs/sanitizer-core-mtls/veil-witness/*.crt 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')"
if [ ! -e "$R1O/.certs/sanitizer-core-mtls/ca" ] && [ -f "$R1O/.secrets/sanitizer-core-mtls-ca/ca.key" ] && [ "$R1O_BEFORE" = "$R1O_AFTER" ] \
   && grep -Fq "moved the CA out of the mounted cert tree" "$TMP/r1-old.out"; then
  pass "CA a round-1 CA in <cert dir>/ca is moved out on the next run; no leaf rotates"
else
  fail "CA old-layout move: ca/ left: $([ -e "$R1O/.certs/sanitizer-core-mtls/ca" ] && echo yes || echo no); leaves same: $([ "$R1O_BEFORE" = "$R1O_AFTER" ] && echo yes || echo no); $(tail -1 "$TMP/r1-old.out")"
fi
# Doctor RED: the CA still in the cert tree (a round-1 install).
V="$(variant caintree)"
mkdir -p "$V/.certs/sanitizer-core-mtls/ca"; mv "$V/.secrets/sanitizer-core-mtls-ca/ca.key" "$V/.secrets/sanitizer-core-mtls-ca/ca.crt" "$V/.certs/sanitizer-core-mtls/ca/" 2>/dev/null
expect_doctor_red "CA RED doctor: the deploy CA still inside the cert tree (round-1 layout)" "$V" "holds the deploy CA inside the cert tree"
# Doctor RED: a CA directory the operator named inside the gateway's /certs.
V="$(variant caundercerts)"
printf 'SANDBOX_B_CERT_DIR=%s\nSANITIZER_CORE_MTLS_CA_DIR=%s\n' "$V/.certs" "$V/.certs/my-ca" >> "$V/customer.env"
expect_doctor_red "CA RED doctor: SANITIZER_CORE_MTLS_CA_DIR inside the gateway's /certs mount" "$V" "is inside the gateway's /certs (SANDBOX_B_CERT_DIR)"

# ── R1 doctor (Linux): uid 10001 must traverse /certs and read the manifest ─
r1_doctor() { # <env file> -> $TMP/r1-doc.out (simulated Linux host)
  env -u LUCAIRN_CONTAINER_UID PATH="$LXB:$DBIN:$BASE_PATH" bash "$KIT/bin/lucairn" doctor --env "$1" --compose "$KIT_COMPOSE" --offline --skip-image-check > "$TMP/r1-doc.out" 2>&1
}
V="$(variant r1certs)"
mkdir -p "$V/.certs"; printf '{"synthetic":"manifest"}\n' > "$V/.certs/witness-signed-manifest.json"
printf 'SANDBOX_B_CERT_DIR=%s\n' "$V/.certs" >> "$V/customer.env"
chmod 0700 "$V/.certs"; chmod 0644 "$V/.certs/witness-signed-manifest.json"
if r1_doctor "$V/customer.env"; then
  fail "R1 RED doctor (Linux): ./.certs 0700 owned by another uid than 10001 — doctor stayed green"
elif grep -Fq "gateway /certs mount: failed ($V/.certs is mounted at /certs and uid 10001, the gateway's user, cannot traverse it" "$TMP/r1-doc.out"; then
  pass "R1 RED doctor (Linux): ./.certs 0700 not owned by uid 10001 -> the gateway cannot traverse /certs (crash-loop) — FAILS"
else
  fail "R1 RED doctor (Linux) traverse: $(grep -E 'certs mount|failed' "$TMP/r1-doc.out" | head -3 | tr '\n' ' ')"
fi
chmod 0755 "$V/.certs"; chmod 0600 "$V/.certs/witness-signed-manifest.json"
if r1_doctor "$V/customer.env"; then
  fail "R1 RED doctor (Linux): manifest 0600 owned by another uid — doctor stayed green"
elif grep -Fq "gateway /certs mount: failed (uid 10001 cannot read $V/.certs/witness-signed-manifest.json" "$TMP/r1-doc.out"; then
  pass "R1 RED doctor (Linux): the signed manifest unreadable for uid 10001 — FAILS"
else
  fail "R1 RED doctor (Linux) manifest read: $(grep -E 'certs mount|failed' "$TMP/r1-doc.out" | head -3 | tr '\n' ' ')"
fi
chmod 0644 "$V/.certs/witness-signed-manifest.json"
r1_doctor "$V/customer.env"
grep -Fq "gateway /certs mount: ok (uid 10001 can traverse $V/.certs and read $V/.certs/witness-signed-manifest.json)" "$TMP/r1-doc.out" \
  && pass "R1 GREEN doctor (Linux): ./.certs 0755 + manifest 0644 — the /certs line is ok" \
  || fail "R1 GREEN doctor (Linux) /certs line: $(grep 'certs mount' "$TMP/r1-doc.out" | head -2 | tr '\n' ' ')"

# ── R2: the development hop accepts exactly GRPC_TLS_ENABLED=false ──────────
for v in True 1 yes TRUE; do
  V="$(variant "r2-$v")"; sed -i.bak "s/^GRPC_TLS_ENABLED=.*/GRPC_TLS_ENABLED=$v/" "$V/customer.env"; rm -f "$V/customer.env.bak"
  expect_doctor_red "R2 RED offline dev doctor: GRPC_TLS_ENABLED=$v (the core's strict parser refuses it)" "$V" "the core accepts exactly 'true' or 'false' — with '$v' it refuses to start"
done

# ── H1 leftover: the multi-line docs check catches INSTALL.md step 6 ────────
printf '```bash\ndocker compose \\\n  -f docker-compose.customer.yml \\\n  --env-file customer.env \\\n  up -d\n```\n' > "$TMP/h1-multiline.md"
check_eq "H1 the docs check flags a backslash-continued whole-stack up -d with no migration before it" "h1-multiline.md:2" "$(h1_docs_check "$TMP/h1-multiline.md")"
awk '/^For \*\*self-hosted inference\*\*/,/^If you omit the self-hosted overlay/' "$KIT/INSTALL.md" | grep -q 'run --rm migrate-sanitizer-core' \
  && pass "H1 INSTALL.md production step 6 (self-hosted start) runs the registry migration first" \
  || fail "H1 INSTALL.md production step 6 (self-hosted start) runs the registry migration first"

# ── Bundle sentence: customer.env travels as-is, with its passwords ─────────
if [ -n "${H2R:-}" ] && [ -f "$H2R/install/customer.env" ]; then
  grep -Eq '^POSTGRES_SANITIZER_CORE_PASSWORD=.+' "$H2R/install/customer.env" \
    && pass "bundle precondition: the offline bundle's install/customer.env carries the registry DB password" \
    || fail "bundle precondition: the offline bundle's install/customer.env carries the registry DB password"
  tr '\n' ' ' < "$H2R/INSTALL-CUSTOMER.md" | grep -Fq "That env file IS in this bundle as-is, with its passwords" \
    && pass "bundle INSTALL-CUSTOMER.md says install/customer.env travels with its passwords (protect the bundle like the env file)" \
    || fail "bundle INSTALL-CUSTOMER.md says install/customer.env travels with its passwords"
  if tr '\n' ' ' < "$H2R/INSTALL-CUSTOMER.md" | grep -Fq "the keys and the database password are created on this host"; then
    fail "bundle INSTALL-CUSTOMER.md no longer says the database password is created on the customer host"
  else
    pass "bundle INSTALL-CUSTOMER.md no longer says the database password is created on the customer host"
  fi
else
  fail "bundle sentence: the H2 bundle is not available"
fi
tr '\n' ' ' < "$KIT/INSTALL.md" | tr -s ' ' | grep -Fq '`install/customer.env` itself travels in the bundle as-is, with its passwords' \
  && pass "bundle INSTALL.md step 3b says install/customer.env travels with its passwords" \
  || fail "bundle INSTALL.md step 3b says install/customer.env travels with its passwords"
if grep -Fq "password stay off the archive" "$KIT/bin/lucairn"; then
  fail "bundle bin/lucairn no longer claims the DB password stays off the archive"
else
  pass "bundle bin/lucairn no longer claims the DB password stays off the archive"
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
