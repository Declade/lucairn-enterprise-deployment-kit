#!/usr/bin/env bash
#
# Kit 2.0 Slice K-B — the Helm path for the new sanitizer core
# (PRD Opus Advisor specs/2026-11/prd-2026-11-02-kit-2-0-new-core.md K2 + the
# bundle part of K3, ticket T-1441). The Compose twin is
# tests/test_sanitizer_core_compose.sh.
#
# WHAT THIS PROVES (render-only: `helm lint` / `helm template`, no cluster)
#   A. `helm lint` passes for the umbrella (default values) and for the
#      sanitizer-core sub-chart on its own.
#   B. The default render has the hosted shape: core + sidecar in ONE Pod
#      (shared network namespace), Recreate, the 6.5 GiB / 1 GiB limits, exec /
#      TCP probes; the registry DSN reaches the core as a FILE projected from
#      the credentials Secret and NO container of ANY workload passes --dsn; the
#      registry key and the signing seed come from secretKeyRef; the core sets
#      LCR_PROFILE=kit as a literal (K-C M2) and gets no ServiceNow control
#      client; the registry Postgres is
#      digest-pinned to the SAME image as the Compose path; the PVC is kept on
#      uninstall; the gateway carries the hosted switch set (delta, Gate
#      enforce, route posture observe, placement message, unredacted off) and
#      its mTLS client triple; the four NetworkPolicies isolate the registry to
#      the core + the migration Job and the namespace-wide identity policies
#      carve both pods out.
#   C. Variants: SANDBOX_B_MESSAGES_JSON_MAX_BYTES reaches BOTH gateway and
#      sandbox-b from one value; a pinned digest pair renders repo:tag@sha256;
#      core OFF (both switches) removes every core resource and the gateway
#      wiring; the production profile (values-prod.yaml) renders the core's
#      ExternalSecret, no Helm-owned Secret, and the latched mesh-mTLS witness
#      hop with the `sanitizer` leaf.
#   D. Refusals (each must FAIL the render, with its own message): mirror
#      mismatch both ways, empty / non-hex / all-zero / placeholder registry
#      key, non-URL-safe password, tag mismatch, half digest pair, malformed
#      digest, migration target outside 1..7, off-enum gateway switches,
#      plaintext core URL, empty gateway mTLS Secret, production k8s-native
#      backend, a Lucairn-operated witness address on the core, a non-numeric
#      message limit, the core without Sandbox A (whose Secret holds its seed).
#   E. The migration payload: chart files are byte copies of the repo-root
#      migrations + runner, the ConfigMap carries them byte-identically, the
#      ceiling equals CEILING_SANITIZER_CORE, and the RENDERED Job's own
#      environment drives the runner (against a stub psql) to one capped
#      transaction of 0001..0007.
#   F. `bin/lucairn doctor --values` RED-PROOF: green on good dev + production
#      values; red on a sidecar limit below 6500 MiB; and with
#      DOCTOR_KUBE_LIVE=1 against a stub kubectl: green on a healthy release,
#      red on a not-ready core, an incomplete migration Job, a missing mTLS
#      Secret, DROPPED claims and a non-mTLS witness hop in production.
#   G. bin/lucairn: verify-images expects the core pair from release 1.1.0 on
#      (and not for 0.5.x records); a kit 2.0 bundle carries and verifies the
#      mTLS bootstrap and its install note names both one-time steps.
#
# FIX ROUND 1 (sol r1 on PR #159: one P1 + three P2), each RED on 42f2ddb:
#   P1 the pair renders ONLY with both released, non-placeholder digests
#      (D: empty / half / malformed / repeated-character / identical), and
#      doctor --values fails on a tag-only render, a placeholder, a pending
#      manifest and a pair that differs from the manifest (F, run from a
#      released-kit fixture with SYNTHETIC signed digests).
#   P2 no registry password in any process environment: the registry DB reads
#      POSTGRES_PASSWORD_FILE, the migration Job and the wait-for-migration
#      init container build a 0600 libpq password file from a mounted Secret
#      file (B; E runs the rendered Job command's prelude for real).
#   P2 DNS: the registry DB has none, the core resolves through the cluster
#      resolver Pods only (B: allow-dns carves both out in the identity
#      namespace; the core's own rule names kube-dns, not all of kube-system).
#   P2 live doctor accepts an external registry DB (postgresql.enabled=false):
#      no bundled StatefulSet is required (F, stub kubectl).
#
# NON-COVERAGE (stated, not implied)
#   * No Pod runs: whether the 1.1.0 images boot with this spec (read-only
#     root FS of the sidecar included) is the PC Kind rehearsal (PRD criterion
#     3, scripts/test-enterprise-mtls-kind.sh), not this suite.
#   * NetworkPolicies are checked structurally, not enforced (no CNI here).
#   * The stub psql proves the runner's decisions and the SQL it hands psql,
#     not PostgreSQL's execution of the migration bodies.
#   * The live doctor checks run against a stub kubectl; they prove the
#     doctor's decisions on given cluster answers, not a cluster.
#   * The libpq password file and POSTGRES_PASSWORD_FILE are proven on the
#     rendered spec + the Job's own shell prelude here; that PostgreSQL 16
#     reads them in a running Pod is the PC Kind rehearsal.
#   * STATED LIMIT (fix rounds 3 + 4, sol r2 P2 / r3 P3): the official
#     postgres entrypoint exports the POSTGRES_PASSWORD_FILE content on EVERY
#     start to its own helpers (id, mkdir/chmod, the gosu re-exec) and, on a
#     first boot, to its initialisation processes (docker-entrypoint.sh :23,
#     :235, :338, :343, :359; cleared at :366 / :381 before the real server);
#     see templates/postgresql-statefulset.yaml.
#   * Which Pods are the cluster resolver depends on the cluster: the default
#     selector is k8s-app=kube-dns (CoreDNS and kube-dns both carry it);
#     global.clusterDNS.podLabels overrides it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
SUB="$CHART/charts/sanitizer-core"
# shellcheck source=lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE_PATH="$PATH"

FAILS=0
N=0
pass() { N=$((N + 1)); echo "  ok   — $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "  FAIL — $1"; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

if ! command -v helm >/dev/null 2>&1; then
  echo "sanitizer-core Helm tests: NOT RUN (helm not installed)"
  exit 0
fi
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null \
  || { echo "sanitizer-core Helm tests: FAIL — python3 with PyYAML is required"; exit 1; }

# The released pair (synthetic, tests/lib/test-helpers.sh): renders that do
# not take HELM_TEST_SECRET_ARGS (production values) pass it on their own.
DIGEST_ARGS=(
  --set-string "sanitizer-core.image.digest=${TEST_SANITIZER_CORE_DIGEST}"
  --set-string "sanitizer-core.sidecar.image.digest=${TEST_SANITIZER_CORE_SIDECAR_DIGEST}"
)
export TEST_SANITIZER_CORE_DIGEST TEST_SANITIZER_CORE_SIDECAR_DIGEST
COMMON=(
  "${HELM_TEST_SECRET_ARGS[@]}"
  --set global.skipPullSecretGuard=true
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
)

render() { # <name> [helm args...] — writes $TMP/<name>.yaml, returns helm's rc
  local name="$1"; shift
  helm template lucairn "$CHART" "${COMMON[@]}" "$@" >"$TMP/$name.yaml" 2>"$TMP/$name.err"
}
refuse() { # <case> <expected message fragment> [helm args...]
  local name="$1" want="$2"; shift 2
  if helm template lucairn "$CHART" "${COMMON[@]}" "$@" >/dev/null 2>"$TMP/refuse.err"; then
    fail "refused: $name (it RENDERED)"
  elif grep -Fq -- "$want" "$TMP/refuse.err"; then
    pass "refused: $name"
  else
    fail "refused: $name (refused for another reason: $(head -c 300 "$TMP/refuse.err"))"
  fi
}
assert_py() { # <render file> <python body using `docs`, `ok(cond, msg)`>
  # A block that does not run to its end (a KeyError, a syntax error, an
  # import failure) is ONE failure of its own: before fix round 4 (sol r3 P2)
  # its traceback went to stderr, no FAIL line reached run_py, and the tally
  # stayed green. The traceback still prints on stderr.
  local file="$1" body="$2" rc=0
  python3 - "$file" "$ROOT" <<PY || rc=$?
import sys, yaml, json, hashlib, os, re
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
ROOT = sys.argv[2]
def ok(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
def find(kind, name, ns=None):
    for d in docs:
        if d.get("kind") == kind and d["metadata"].get("name") == name and (ns is None or d["metadata"].get("namespace") == ns):
            return d
    return None
def env_of(c):
    return {e["name"]: e for e in (c.get("env") or [])}
def podspecs():
    for d in docs:
        ps = (d.get("spec") or {}).get("template", {}).get("spec") if isinstance(d.get("spec"), dict) else None
        if ps is None and isinstance(d.get("spec"), dict):
            ps = d["spec"].get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec")
        if ps:
            yield d, ps
$body
PY
  [ "$rc" -eq 0 ] || echo "FAIL assertion block crashed (python exit $rc) — a check that cannot complete is a failure"
}
# run_py collects PASS/FAIL lines from assert_py into this harness. It runs
# at the end of a pipe (`assert_py ... | run_py`), i.e. in a SUBSHELL, so it
# cannot bump N/FAILS itself: every result goes to $PY_TALLY, which the
# summary adds (kit 2.0 K-B fix round 3 — before, a FAIL inside any
# assert_py block was printed but never failed the suite).
PY_TALLY="$TMP/py-tally"
: > "$PY_TALLY"
run_py() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) echo "  ok   — ${line#PASS }"; echo P >> "$PY_TALLY" ;;
      "FAIL "*) echo "  FAIL — ${line#FAIL }"; echo F >> "$PY_TALLY" ;;
      *) [ -n "$line" ] && { echo "  FAIL — assertion script error: $line"; echo F >> "$PY_TALLY"; } ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────────────────────
echo "A. helm lint"
if helm lint "$CHART" "${COMMON[@]}" >"$TMP/lint.out" 2>&1; then pass "umbrella chart lints (default values)"; else fail "umbrella chart lints: $(grep -E 'ERROR|Error' "$TMP/lint.out" | head -3)"; fi
SUB_ARGS=(
  --set global.dsaEnv=development
  --set-string "secrets.values.registryKey=${TEST_REGISTRY_KEY}"
  --set-string "secrets.values.postgresPassword=${TEST_SECRET_VALUE}"
  --set-string "image.digest=${TEST_SANITIZER_CORE_DIGEST}"
  --set-string "sidecar.image.digest=${TEST_SANITIZER_CORE_SIDECAR_DIGEST}"
)
if helm lint "$SUB" "${SUB_ARGS[@]}" >"$TMP/sublint.out" 2>&1; then pass "sanitizer-core sub-chart lints on its own"; else fail "sanitizer-core sub-chart lints on its own: $(grep -E 'ERROR|Error' "$TMP/sublint.out" | head -3)"; fi
if helm template sc "$SUB" "${SUB_ARGS[@]}" >"$TMP/sub.yaml" 2>"$TMP/sub.err"; then pass "sanitizer-core sub-chart renders on its own"; else fail "sanitizer-core sub-chart renders on its own: $(head -3 "$TMP/sub.err")"; fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "B. Default render: the hosted shape"
if ! render default; then
  fail "default render: $(head -5 "$TMP/default.err")"
  echo "sanitizer-core Helm tests: FAIL (default render broke; nothing else is meaningful)"; exit 1
fi
pass "default umbrella render (core ON by default)"
assert_py "$TMP/default.yaml" '
dep = find("Deployment", "sanitizer-core", "dsa-identity")
ok(dep is not None, "Deployment sanitizer-core renders in dsa-identity")
ps = dep["spec"]["template"]["spec"]
cs = {c["name"]: c for c in ps["containers"]}
ok(sorted(cs) == ["core", "sidecar"], "ONE Pod with exactly the containers core + sidecar (the shared network namespace)")
ok(dep["spec"]["replicas"] == 1 and dep["spec"]["strategy"]["type"] == "Recreate", "one core at a time: replicas 1, strategy Recreate")
ok(ps.get("automountServiceAccountToken") is False and ps.get("enableServiceLinks") is False, "no SA token, no Service-link env vars")
core, side = cs["core"], cs["sidecar"]
ok(core["image"] == "ghcr.io/declade/dsa-sanitizer-core:1.1.0@" + os.environ["TEST_SANITIZER_CORE_DIGEST"] and side["image"] == "ghcr.io/declade/dsa-sanitizer-core-sidecar:1.1.0@" + os.environ["TEST_SANITIZER_CORE_SIDECAR_DIGEST"], "core + sidecar images: one tag (1.1.0), no fallback to global.imageTag, pulled by the signed digests")
man = yaml.safe_load(open(os.path.join(ROOT, "image-manifest.yaml")))
ok(man["services"]["dsa-sanitizer-core"]["image_tag"] == "1.1.0" == man["services"]["dsa-sanitizer-core-sidecar"]["image_tag"], "chart tag equals image-manifest.yaml services.dsa-sanitizer-core(-sidecar).image_tag")
args = core.get("args") or []
ok(args == ["serve", "--listen=0.0.0.0:8790", "--registry-dsn-file=/etc/sanitizer-core/registry/dsn", "--sidecar=http://127.0.0.1:8765"], "core args: serve, :8790, DSN from a FILE, sidecar on 127.0.0.1:8765")
bad = []
for d, p in podspecs():
    for c in (p.get("containers") or []) + (p.get("initContainers") or []):
        argv = [str(a) for a in (c.get("command") or []) + (c.get("args") or [])]
        if any(a == "--dsn" or a.startswith("--dsn=") for a in argv):
            bad.append(d["metadata"]["name"] + "/" + c["name"])
ok(not bad, "NO container of any workload passes --dsn (the password stays out of every process list): %s" % bad)
vols = {v["name"]: v for v in ps["volumes"]}
dsn = vols.get("registry-dsn", {}).get("secret", {})
ok(dsn.get("secretName") == "sanitizer-core-credentials" and dsn.get("items") == [{"key": "REGISTRY_DSN", "path": "dsn"}] and dsn.get("defaultMode") == 0o440, "DSN volume projects ONLY REGISTRY_DSN as file dsn (mode 0440)")
mounts = {m["name"]: m for m in core["volumeMounts"]}
ok(mounts["registry-dsn"]["mountPath"] == "/etc/sanitizer-core/registry" and mounts["registry-dsn"].get("readOnly") is True, "DSN file mounted read-only where --registry-dsn-file points")
e = env_of(core)
ok(e["DSA_SANITIZER_CORE_REGISTRY_KEY"].get("valueFrom", {}).get("secretKeyRef") == {"name": "sanitizer-core-credentials", "key": "DSA_SANITIZER_CORE_REGISTRY_KEY"} and "value" not in e["DSA_SANITIZER_CORE_REGISTRY_KEY"], "registry key via secretKeyRef, never a literal")
ok(e["LCR_SIGNING_KEY"].get("valueFrom", {}).get("secretKeyRef") == {"name": "sandbox-a-credentials", "key": "LCR_SIGNING_KEY"}, "claims signed with the OLD sanitizer seed (sandbox-a-credentials/LCR_SIGNING_KEY)")
ok(e.get("LCR_PROFILE") == {"name": "LCR_PROFILE", "value": "kit"} and not any(k.startswith("LCR_SERVICENOW_CONTROL_") for k in e), "K-C M2: the core sets LCR_PROFILE=kit as a literal in env: and gets no ServiceNow control client")
ok([x["name"] for x in core.get("env") or []].count("LCR_PROFILE") == 1 and "envFrom" not in core and "envFrom" not in side, "LCR_PROFILE appears once; neither container loads envFrom")
ok(e["GRPC_TLS_ENABLED"]["value"] == "false" and e["DSA_ENV"]["value"] == "development" and e["LCR_ENABLED"]["value"] == "true", "core env: legacy GRPC TLS off, DSA_ENV from global, claims on")
ok(e["LCR_WITNESS_ADDR"]["value"] == "veil-witness.dsa-witness.svc.cluster.local:50057", "core dials the witness claim port by FQDN")
ok("LCR_WITNESS_REQUIRE_MTLS" not in e, "development (no mesh): no witness latch (plaintext dev witness, the core warns)")
ok({k: e[k]["value"] for k in ("SANITIZER_CORE_MTLS_CA_BUNDLE_PATH", "SANITIZER_CORE_MTLS_SERVER_CERT_PATH", "SANITIZER_CORE_MTLS_SERVER_KEY_PATH")} == {"SANITIZER_CORE_MTLS_CA_BUNDLE_PATH": "/etc/sanitizer-core-mtls/ca.crt", "SANITIZER_CORE_MTLS_SERVER_CERT_PATH": "/etc/sanitizer-core-mtls/dsa-sanitizer-core.crt", "SANITIZER_CORE_MTLS_SERVER_KEY_PATH": "/etc/sanitizer-core-mtls/dsa-sanitizer-core.key"}, "core server mTLS family points at the bootstrap file names")
mt = vols["core-mtls"]["secret"]
ok(mt["secretName"] == "sanitizer-core-mtls" and [i["key"] for i in mt["items"]] == ["ca.crt", "dsa-sanitizer-core.crt", "dsa-sanitizer-core.key"], "core mTLS volume projects only CA + server leaf (never the witness-client or CA key)")
ok(side["resources"]["limits"]["memory"] == "6500Mi" and side["resources"]["requests"]["memory"] == "6Gi", "sidecar memory: limit 6500Mi (hosted A8), request 6Gi")
ok(core["resources"]["limits"]["memory"] == "1Gi", "core memory limit 1Gi (Compose mem_limit 1g)")
ok(all("exec" in side[p] for p in ("startupProbe", "readinessProbe", "livenessProbe")) and side["startupProbe"]["periodSeconds"] * side["startupProbe"]["failureThreshold"] >= 600, "sidecar: exec probes on its loopback health (>= 10 min startup budget)")
ok(all(core[p].get("tcpSocket", {}).get("port") == "https" for p in ("startupProbe", "readinessProbe", "livenessProbe")), "core: TCP probes on its mTLS port")
ok(side["securityContext"]["readOnlyRootFilesystem"] is True and env_of(side)["HOME"]["value"] == "/tmp", "sidecar: read-only root FS, HOME in its /tmp emptyDir")
ok(core["command"] == ["/bin/sh", "/opt/lucairn/entrypoint/core-entrypoint.sh"], "core entrypoint from a mounted script (no $(...) expansion of shell syntax)")
ent = find("ConfigMap", "sanitizer-core-entrypoint")["data"]["core-entrypoint.sh"]
ok("exec sanitizer-core \"$@\"" in ent and "127.0.0.1:8765/v1/health" in ent, "entrypoint waits for the sidecar, then execs the core")
init = {c["name"]: c for c in ps["initContainers"]}
ie = env_of(init["wait-for-migration"])
ok("wait-for-migration" in init and ie["TARGET_VERSION"]["value"] == "7", "init container holds the core until the ledger reaches 7")
# Fix round 1 (sol r1 P2): NO password in any process environment of the
# workloads of the core — RED on 42f2ddb (three secretKeyRef passwords).
pwenv = []
for d, ps_ in podspecs():
    if "sanitizer-core" not in d["metadata"]["name"]:
        continue
    for c in (ps_.get("containers") or []) + (ps_.get("initContainers") or []):
        for e in c.get("env") or []:
            ref = (e.get("valueFrom") or {}).get("secretKeyRef") or {}
            if "PASSWORD" in e["name"] and e["name"] != "POSTGRES_PASSWORD_FILE" or ref.get("key") in ("POSTGRES_PASSWORD", "REGISTRY_DSN"):
                pwenv.append("%s/%s:%s" % (d["metadata"]["name"], c["name"], e["name"]))
ok(not pwenv, "no registry password (or DSN) in any env of the core workloads (%s)" % pwenv)
def pwfile_mount(ps_, c, path):
    m = [x for x in c.get("volumeMounts") or [] if x["mountPath"] == path]
    v = {x["name"]: x for x in ps_.get("volumes") or []}.get(m[0]["name"]) if m else None
    return bool(m) and m[0].get("readOnly") is True and v is not None and v["secret"]["secretName"] == "sanitizer-core-credentials" and v["secret"]["items"] == [{"key": "POSTGRES_PASSWORD", "path": "password"}]
wcmd = init["wait-for-migration"]["command"][-1]
ok(pwfile_mount(ps, init["wait-for-migration"], "/etc/sanitizer-core/db") and "export PGPASSFILE=/tmp/.pgpass" in wcmd and "chmod 0600 /tmp/.pgpass" in wcmd and wcmd.index("PGPASSFILE") < wcmd.index("psql"), "init container: libpq password FILE built from the mounted POSTGRES_PASSWORD only, before psql runs")
sts = find("StatefulSet", "postgres-sanitizer-core")
pc = sts["spec"]["template"]["spec"]["containers"][0]
ok(env_of(pc).get("POSTGRES_PASSWORD_FILE", {}).get("value") == "/run/secrets/sanitizer-core-db/password" and "POSTGRES_PASSWORD" not in env_of(pc)
   and pwfile_mount(sts["spec"]["template"]["spec"], pc, "/run/secrets/sanitizer-core-db"), "registry DB: POSTGRES_PASSWORD_FILE from the mounted Secret file, no POSTGRES_PASSWORD env")
sec = find("Secret", "sanitizer-core-credentials")
ok(sec is not None and sorted(sec["stringData"]) == ["DSA_SANITIZER_CORE_REGISTRY_KEY", "POSTGRES_PASSWORD", "REGISTRY_DSN"], "k8s-native Secret: exactly the three keys")
pw = sec["stringData"]["POSTGRES_PASSWORD"]
ok(sec["stringData"]["REGISTRY_DSN"] == "postgres://dsa:%s@postgres-sanitizer-core:5432/sanitizer_core?sslmode=disable" % pw, "DSN built from the SAME password; bundled registry sslmode=disable")
# DSA #956 registry_dsn.go (merged rules): a file holds a postgres:// URL only;
# no @ after the authority outside the query; query keys are libpq keywords;
# the --registry-dsn-file path holds neither :// nor @.
import urllib.parse
dsn = sec["stringData"]["REGISTRY_DSN"]
u = urllib.parse.urlsplit(dsn)
rest = dsn.split("://", 1)[1]
after = rest[min([i for i in (rest.find(c) for c in "/?#") if i >= 0] or [len(rest)]):]
ok(dsn.startswith("postgres://") and u.hostname == "postgres-sanitizer-core" and u.port == 5432 and u.username == "dsa" and urllib.parse.unquote(u.password or "") == pw
   and "@" not in after.split("?")[0] and set(urllib.parse.parse_qs(u.query)) == {"sslmode"}, "REGISTRY_DSN is in the file form of the core (URL, host/port/user/password read back intact, only sslmode in the query)")
dsnarg = [a for a in args if a.startswith("--registry-dsn-file=")][0].split("=", 1)[1]
ok("://" not in dsnarg and "@" not in dsnarg, "the --registry-dsn-file path holds neither :// nor @ (the core refuses those)")
sts = find("StatefulSet", "postgres-sanitizer-core", "dsa-identity")
img = sts["spec"]["template"]["spec"]["containers"][0]["image"]
compose = yaml.safe_load(open(os.path.join(ROOT, "docker-compose.customer.yml")))
ok(re.fullmatch(r"postgres:16-alpine@sha256:[0-9a-f]{64}", img) is not None and img == compose["services"]["postgres-sanitizer-core"]["image"], "registry Postgres digest-pinned to the SAME image as the Compose path")
ok(sts["spec"]["template"]["spec"].get("enableServiceLinks") is False, "registry: no Service-link env vars (the postgres entrypoint reads POSTGRES_*)")
pvc = find("PersistentVolumeClaim", "postgres-sanitizer-core-data")
ok(pvc["metadata"]["annotations"].get("helm.sh/resource-policy") == "keep", "registry PVC survives helm uninstall")
svc = find("Service", "sanitizer-core", "dsa-identity")
ok([p["port"] for p in svc["spec"]["ports"]] == [8790], "Service sanitizer-core exposes ONLY :8790 (no sidecar port)")
gw = find("Deployment", "gateway")
g = gw["spec"]["template"]["spec"]["containers"][0]
ge = {k: v.get("value") for k, v in env_of(g).items()}
want = {"GATEWAY_SANITIZER_PROTOCOL": "delta", "SANITIZER_CORE_URL": "https://sanitizer-core.dsa-identity.svc.cluster.local:8790", "GATEWAY_SANITIZER_GATE_POSTURE": "enforce", "GATEWAY_SANITIZER_GATE_ROUTE_POSTURE": "observe", "GATEWAY_ADDED_PARTS_PLACEMENT": "message", "GATEWAY_USER_UNREDACTED_ENABLED": "false", "SANITIZER_CORE_MTLS_CA_BUNDLE_PATH": "/etc/sanitizer-core-mtls/ca.crt", "SANITIZER_CORE_MTLS_CLIENT_CERT_PATH": "/etc/sanitizer-core-mtls/dsa-gateway.crt", "SANITIZER_CORE_MTLS_CLIENT_KEY_PATH": "/etc/sanitizer-core-mtls/dsa-gateway.key"}
ok(all(ge.get(k) == v for k, v in want.items()), "gateway: the hosted switch set + its core mTLS client triple %s" % {k: ge.get(k) for k in want if ge.get(k) != want[k]})
ok("SANDBOX_B_MESSAGES_JSON_MAX_BYTES" not in ge, "gateway: no message limit by default (4 MiB)")
gv = {v["name"]: v for v in gw["spec"]["template"]["spec"]["volumes"]}
ok(gv["sanitizer-core-mtls"]["secret"]["secretName"] == "gateway-sanitizer-core-mtls" and [i["key"] for i in gv["sanitizer-core-mtls"]["secret"]["items"]] == ["ca.crt", "dsa-gateway.crt", "dsa-gateway.key"], "gateway mounts only its client leaf + CA from gateway-sanitizer-core-mtls")
nps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "NetworkPolicy"}
def sel(d): return d["spec"]["podSelector"]
eg = nps.get("edge-sanitizer-core-egress")
ok(eg and sel(eg) == {"matchLabels": {"app.kubernetes.io/name": "gateway"}} and eg["spec"]["egress"] == [{"to": [{"namespaceSelector": {"matchLabels": {"dsa.io/namespace": "identity"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "sanitizer-core"}}}], "ports": [{"port": 8790, "protocol": "TCP"}]}], "edge: only the gateway Pod may dial the core, only :8790")
ing = nps.get("identity-sanitizer-core-ingress")
ok(ing and sel(ing) == {"matchLabels": {"app.kubernetes.io/name": "sanitizer-core"}} and ing["spec"]["ingress"] == [{"from": [{"namespaceSelector": {"matchLabels": {"dsa.io/namespace": "edge"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "gateway"}}}], "ports": [{"port": 8790, "protocol": "TCP"}]}], "identity: the core admits only the gateway Pod on :8790")
ce = nps.get("identity-sanitizer-core-egress")
ports = sorted((r["to"][0].get("podSelector", {}).get("matchLabels", {}).get("app.kubernetes.io/name") or r["to"][0].get("podSelector", {}).get("matchLabels", {}).get("k8s-app"), r["ports"][0]["port"]) for r in ce["spec"]["egress"])
ok(ports == [("kube-dns", 53), ("postgres-sanitizer-core", 5432), ("veil-witness", 50057)], "core egress: its registry :5432, the witness :50057 and DNS — nothing else (%s)" % ports)
dns = [r for r in ce["spec"]["egress"] if r["ports"][0]["port"] == 53]
ok(len(dns) == 1 and dns[0]["to"] == [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}]
   and sorted(x["protocol"] for x in dns[0]["ports"]) == ["TCP", "UDP"], "core DNS: the cluster resolver Pods (k8s-app=kube-dns) only, not every kube-system Pod")
# Fix round 1 (sol r1 P2), RED on 42f2ddb: allow-dns (podSelector {} in every
# namespace) gave the core AND its registry DB every kube-system Pod on 53.
adns = {d["metadata"]["namespace"]: d for d in docs if d.get("kind") == "NetworkPolicy" and d["metadata"]["name"] == "allow-dns"}
carve_dns = {"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "NotIn", "values": ["sanitizer-core", "postgres-sanitizer-core"]}]}
ok(sel(adns["dsa-identity"]) == carve_dns, "allow-dns in the identity namespace carves out the core and its registry DB")
ok(all(sel(d) == {} for n, d in adns.items() if n != "dsa-identity"), "allow-dns elsewhere is unchanged")
rg = nps.get("identity-sanitizer-core-registry")
ok(rg and sorted(rg["spec"]["policyTypes"]) == ["Egress", "Ingress"] and not rg["spec"].get("egress") and sel(adns["dsa-identity"]) == carve_dns and rg["spec"]["ingress"][0]["from"][0]["podSelector"]["matchExpressions"][0]["values"] == ["sanitizer-core", "sanitizer-core-migrate"] and rg["spec"]["ingress"][0]["ports"] == [{"port": 5432, "protocol": "TCP"}], "registry: ingress only from the core + the migration Job on :5432, no egress at all")
carve = {"matchExpressions": [{"key": "app.kubernetes.io/name", "operator": "NotIn", "values": ["sanitizer-core", "postgres-sanitizer-core"]}]}
ok(sel(nps["identity-egress"]) == carve and sel(nps["identity-ingress"]) == carve, "namespace-wide identity-egress/-ingress carve the core + registry out (policies are unioned)")
job = find("Job", "sanitizer-core-migrate-r1", "dsa-identity")
je = {k: v.get("value") for k, v in env_of(job["spec"]["template"]["spec"]["containers"][0]).items()}
ok(job and je["MIGRATE_TARGET_VERSION"] == "7" and je["MIGRATE_CEILING_KEY"] == "SANITIZER_CORE" and je["PGHOST"] == "postgres-sanitizer-core" and je["PGSSLMODE"] == "disable", "migration Job: target 7, key SANITIZER_CORE, discrete libpq settings")
ok(job["spec"]["template"]["spec"]["containers"][0]["image"] == img, "migration Job runs the same pinned postgres image")
ok(job["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] == "sanitizer-core-migrate", "migration Job pod carries the label the registry policy admits")
jc = job["spec"]["template"]["spec"]["containers"][0]
ok(pwfile_mount(job["spec"]["template"]["spec"], jc, "/etc/sanitizer-core/db") and "PGPASSWORD" not in env_of(jc) and "export PGPASSFILE=/tmp/.pgpass" in jc["command"][-1], "migration Job: libpq password FILE from the mounted POSTGRES_PASSWORD, no PGPASSWORD env")
' | run_py

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "C. Variants"
if render maxbytes --set-string global.sandboxBMessagesJsonMaxBytes=1000000; then
  assert_py "$TMP/maxbytes.yaml" '
gw = env_of(find("Deployment", "gateway")["spec"]["template"]["spec"]["containers"][0])
sb = env_of(find("Deployment", "sandbox-b")["spec"]["template"]["spec"]["containers"][0])
ok(gw.get("SANDBOX_B_MESSAGES_JSON_MAX_BYTES", {}).get("value") == "1000000" == sb.get("SANDBOX_B_MESSAGES_JSON_MAX_BYTES", {}).get("value"), "one global value reaches BOTH gateway and sandbox-b")
' | run_py
else fail "message-limit render: $(head -3 "$TMP/maxbytes.err")"; fi
D1="sha256:$(printf 'a1%.0s' $(seq 32))"; D2="sha256:$(printf 'b2%.0s' $(seq 32))"
if render pinned --set-string "sanitizer-core.image.digest=$D1" --set-string "sanitizer-core.sidecar.image.digest=$D2"; then
  assert_py "$TMP/pinned.yaml" "
cs = {c['name']: c for c in find('Deployment', 'sanitizer-core')['spec']['template']['spec']['containers']}
ok(cs['core']['image'] == 'ghcr.io/declade/dsa-sanitizer-core:1.1.0@$D1' and cs['sidecar']['image'] == 'ghcr.io/declade/dsa-sanitizer-core-sidecar:1.1.0@$D2', 'a pinned pair renders repo:tag@sha256 for both images')
" | run_py
else fail "digest-pinned render: $(head -3 "$TMP/pinned.err")"; fi
# Fix round 3 (sol r2 P2), RED on e76b6d7: with global.dnsRestriction=true the
# namespace-wide Cilium DNS grant dns-restrict-identity (endpointSelector {})
# still gave the registry DB (and the core) resolver traffic — Cilium policies
# are additive, so the allow-dns carve-out alone did not cancel it — and every
# Cilium resolver selector was hardcoded to k8s-app=kube-dns while the
# Kubernetes rule followed global.clusterDNS.podLabels.
DNS_CHECK='
def selects(sel, labels):
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for e in sel.get("matchExpressions") or []:
        k, op, vals = e["key"], e["operator"], e.get("values") or []
        if (op == "In" and labels.get(k) not in vals) or (op == "NotIn" and labels.get(k) in vals) \
           or (op == "Exists" and k not in labels) or (op == "DoesNotExist" and k in labels):
            return False
    return True
cnps = [d for d in docs if d.get("kind") == "CiliumNetworkPolicy"]
dns_cnps = [d for d in cnps if any(str(pp.get("port")) == "53" for r in d["spec"].get("egress") or [] for tp in r.get("toPorts") or [] for pp in tp.get("ports") or [])]
ok(len(dns_cnps) >= 6, "dnsRestriction renders the Cilium DNS policies (%d)" % len(dns_cnps))
ident = [d for d in dns_cnps if d["metadata"]["namespace"] == "dsa-identity"]
reg = {"app.kubernetes.io/name": "postgres-sanitizer-core"}
core = {"app.kubernetes.io/name": "sanitizer-core"}
other = {"app.kubernetes.io/name": "sandbox-a"}
ok(not [d["metadata"]["name"] for d in ident if selects(d["spec"]["endpointSelector"], reg)], "no Cilium DNS policy selects the registry DB (%s)" % [d["metadata"]["name"] for d in ident if selects(d["spec"]["endpointSelector"], reg)])
ok([d["metadata"]["name"] for d in ident if selects(d["spec"]["endpointSelector"], core)] == ["dns-restrict-identity-sanitizer-core"], "the core is selected by its own Cilium DNS policy only (%s)" % [d["metadata"]["name"] for d in ident if selects(d["spec"]["endpointSelector"], core)])
ok([d["metadata"]["name"] for d in ident if selects(d["spec"]["endpointSelector"], other)] == ["dns-restrict-identity"], "the rest of the identity namespace keeps dns-restrict-identity")
want = dict(WANT_LABELS, **{"k8s:io.kubernetes.pod.namespace": "kube-system"})
seen = [te.get("matchLabels") for d in dns_cnps for r in d["spec"].get("egress") or [] for te in r.get("toEndpoints") or []]
ok(seen and all(m == want for m in seen), "every Cilium resolver selector = the configured resolver labels %s (%s)" % (WANT_LABELS, [m for m in seen if m != want][:2]))
# Fix round 4 (sol r3 P2), RED on 507f0323: the core Kubernetes policy also
# granted plain TCP/UDP 53 to the resolver, which overrides the Cilium name
# allowlist (Cilium admits every query an L3/L4 rule allows): with
# dnsRestriction on, the core has NO Kubernetes DNS grant at all; its DNS is
# dns-restrict-identity-sanitizer-core (its allowlist) only.
ce = find("NetworkPolicy", "identity-sanitizer-core-egress")
k8s53 = [r for r in ce["spec"]["egress"] for p in r.get("ports") or [] if p.get("port") == 53]
ok(k8s53 == [], "dnsRestriction: the core Kubernetes egress grants no port 53 (it would override the Cilium allowlist) (%s)" % k8s53)
ok(sorted(p["port"] for r in ce["spec"]["egress"] for p in r["ports"]) == [5432, 50057], "dnsRestriction: the core keeps exactly its registry :5432 and the witness :50057")
cc = [d for d in ident if d["metadata"]["name"] == "dns-restrict-identity-sanitizer-core"]
pats = sorted(rule.get("matchPattern") or rule.get("matchName") for d in cc for r in d["spec"]["egress"] for tp in r.get("toPorts") or [] for rule in (tp.get("rules") or {}).get("dns") or [])
ok(len(cc) == 1 and pats and all(x.endswith(".svc.cluster.local") for x in pats), "dnsRestriction: the core resolves only cluster names through its Cilium policy (%s)" % pats)
'
# Without dnsRestriction the core keeps its Kubernetes DNS rule, scoped to the
# configured resolver labels (a resolver labelled otherwise stays unreachable).
if render dnsl --set-json 'global.clusterDNS.podLabels={"k8s-app":"coredns","dns.example/role":"resolver"}'; then
  assert_py "$TMP/dnsl.yaml" '
ce = find("NetworkPolicy", "identity-sanitizer-core-egress")
k8s = [t.get("podSelector", {}).get("matchLabels") for r in ce["spec"]["egress"] if r["ports"][0]["port"] == 53 for t in r["to"]]
ok(k8s == [{"k8s-app": "coredns", "dns.example/role": "resolver"}], "no dnsRestriction: the core Kubernetes DNS rule uses the configured resolver labels only (%s)" % k8s)
ok(not [d for d in docs if d.get("kind") == "CiliumNetworkPolicy"], "no dnsRestriction: no Cilium policy renders")
' | run_py
else fail "custom resolver labels render: $(head -3 "$TMP/dnsl.err")"; fi
if render dnsr --set global.dnsRestriction=true; then
  assert_py "$TMP/dnsr.yaml" "WANT_LABELS = {\"k8s-app\": \"kube-dns\"}
$DNS_CHECK" | run_py
else fail "dnsRestriction render: $(head -3 "$TMP/dnsr.err")"; fi
if render dnsr2 --set global.dnsRestriction=true --set-json 'global.clusterDNS.podLabels={"k8s-app":"coredns","dns.example/role":"resolver"}'; then
  assert_py "$TMP/dnsr2.yaml" "WANT_LABELS = {\"k8s-app\": \"coredns\", \"dns.example/role\": \"resolver\"}
$DNS_CHECK" | run_py
else fail "dnsRestriction + custom resolver labels render: $(head -3 "$TMP/dnsr2.err")"; fi
if render off --set sanitizer-core.enabled=false --set global.sanitizerCore.enabled=false; then
  assert_py "$TMP/off.yaml" '
ok(not [d for d in docs if "sanitizer-core" in str(d["metadata"].get("name", ""))], "core OFF: no sanitizer-core resource renders")
ge = env_of(find("Deployment", "gateway")["spec"]["template"]["spec"]["containers"][0])
ok("GATEWAY_SANITIZER_PROTOCOL" not in ge and "SANITIZER_CORE_URL" not in ge and ge["GATEWAY_USER_UNREDACTED_ENABLED"]["value"] == "false", "core OFF: gateway not wired to a core (unredacted stays off)")
nps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "NetworkPolicy"}
ok(nps["identity-egress"]["spec"]["podSelector"] == {} and nps["identity-ingress"]["spec"]["podSelector"] == {}, "core OFF: the identity policies are exactly the pre-kit-2.0 shape")
' | run_py
else fail "core-off render: $(head -3 "$TMP/off.err")"; fi
if helm template lucairn "$CHART" -f "$CHART/values-prod.yaml" -f "$CHART/values-prod-site.example.yaml" "${DIGEST_ARGS[@]}" >"$TMP/prod.yaml" 2>"$TMP/prod.err"; then
  assert_py "$TMP/prod.yaml" '
ok(find("ExternalSecret", "sanitizer-core-credentials") is not None and not [d for d in docs if d["kind"] == "Secret"], "production: the core credentials come from an ExternalSecret, no Helm-owned Secret")
es = find("ExternalSecret", "sanitizer-core-credentials")
ok(sorted((x["secretKey"], x["remoteRef"]["property"]) for x in es["spec"]["data"]) == [("DSA_SANITIZER_CORE_REGISTRY_KEY", "registry_key"), ("POSTGRES_PASSWORD", "password"), ("REGISTRY_DSN", "registry_dsn")] and {x["remoteRef"]["key"] for x in es["spec"]["data"]} == {"sanitizer-core"}, "production ExternalSecret: registry_key / password / registry_dsn at path sanitizer-core")
dep = find("Deployment", "sanitizer-core")
ps = dep["spec"]["template"]["spec"]
core = [c for c in ps["containers"] if c["name"] == "core"][0]
e = {k: v.get("value") for k, v in env_of(core).items()}
ok(e["DSA_ENV"] == "production" and e["LCR_WITNESS_REQUIRE_MTLS"] == "true" and e["LCR_WITNESS_MTLS_CA_BUNDLE_PATH"] == "/var/run/lucairn/mtls/ca.crt" and e["LCR_WITNESS_MTLS_CLIENT_CERT_PATH"] == "/var/run/lucairn/mtls/tls.crt" and e["LCR_WITNESS_MTLS_CLIENT_KEY_PATH"] == "/var/run/lucairn/mtls/tls.key", "production: the claim hop is LATCHED verified mTLS (hosted A9)")
vols = {v["name"]: v for v in ps["volumes"]}
ok(vols["enterprise-mtls-sanitizer"]["secret"]["secretName"] == "lucairn-mtls-sanitizer", "production: the claim hop uses the `sanitizer` mesh identity (SAN dsa-sanitizer)")
je = {k: v.get("value") for k, v in env_of(find("Job", "sanitizer-core-migrate-r1")["spec"]["template"]["spec"]["containers"][0]).items()}
ok(je["PGSSLMODE"] == "disable", "production: the bundled registry keeps sslmode=disable although global.postgresqlSslmode=require (it serves no TLS)")
' | run_py
else fail "production render: $(head -5 "$TMP/prod.err")"; fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "D. Refusals"
refuse "core ON, mirror OFF" "must agree" --set global.sanitizerCore.enabled=false
refuse "core OFF, mirror ON" "must agree" --set sanitizer-core.enabled=false
refuse "empty registry key" "registryKey is empty" --set-string sanitizer-core.secrets.values.registryKey=
refuse "non-hex registry key" "exactly 64 hex" --set-string "sanitizer-core.secrets.values.registryKey=$(printf 'z%.0s' $(seq 64))"
refuse "all-zero registry key" "all zero" --set-string "sanitizer-core.secrets.values.registryKey=$(printf '0%.0s' $(seq 64))"
refuse "placeholder registry key" "shipped placeholder" --set-string sanitizer-core.secrets.values.registryKey=REPLACE_WITH_KEY
refuse "empty DB password" "postgresPassword is empty" --set-string sanitizer-core.secrets.values.postgresPassword=
refuse "non-URL-safe DB password" "URL" --set-string 'sanitizer-core.secrets.values.postgresPassword=p@ss:word/x'
# The other parts of the DSN URL the chart writes unencoded (DSA #956: the core
# takes a postgres:// URL from the file and refuses one it cannot read as written).
refuse "registry DB user with @" "registry DB user" --set-string 'sanitizer-core.postgresql.user=svc@corp'
refuse "registry database name with /" "registry database name" --set-string 'sanitizer-core.postgresql.database=core/x'
refuse "off-enum registry sslmode" "registry sslmode" --set-string sanitizer-core.postgresql.sslmode=on
EXT=(--set sanitizer-core.postgresql.enabled=false --set-string sanitizer-core.external.user=lucairn_core --set-string sanitizer-core.external.database=core)
refuse "external host with a port" "registry DB host" "${EXT[@]}" --set-string 'sanitizer-core.external.host=db.internal:5432'
refuse "external host with a user" "registry DB host" "${EXT[@]}" --set-string 'sanitizer-core.external.host=u@db.internal'
refuse "external port out of range" "registry DB port" "${EXT[@]}" --set-string sanitizer-core.external.host=db.internal --set sanitizer-core.external.port=70000
# Helm applies --set-string AFTER --set whatever the order, so the shared
# args' own --set-string of this slot would mask a numeric --set: render this
# case from the shared args WITHOUT the core's two slots.
NO_CORE=()
skip_next=0
for a in "${COMMON[@]}"; do
  if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
  if [ "$a" = "--set-string" ]; then pending="$a"; continue; fi
  if [ -n "${pending:-}" ]; then
    case "$a" in sanitizer-core.secrets.values.*) pending=""; continue ;; esac
    NO_CORE+=("$pending" "$a"); pending=""; continue
  fi
  NO_CORE+=("$a")
done
if helm template lucairn "$CHART" "${NO_CORE[@]}" --set-string "sanitizer-core.secrets.values.registryKey=${TEST_REGISTRY_KEY}" \
     --set sanitizer-core.secrets.values.postgresPassword=12345678 >/dev/null 2>"$TMP/refuse.err"; then
  fail "refused: non-string DB password (it RENDERED)"
elif grep -Fq "must be a YAML string, but a int64 was given" "$TMP/refuse.err"; then
  pass "refused: non-string DB password (--set 12345678 is an int64)"
else fail "refused: non-string DB password (other reason: $(head -c 300 "$TMP/refuse.err"))"; fi
refuse "core/sidecar tag mismatch" "ONE pair" --set-string sanitizer-core.sidecar.image.tag=1.0.0
# Fix round 1 (sol r1 P1), RED on 42f2ddb (empty digests rendered by tag):
refuse "no core digest (tag only)" "image.digest is empty" --set-string sanitizer-core.image.digest=
refuse "no sidecar digest (half a pair)" "sidecar.image.digest is empty" --set-string sanitizer-core.sidecar.image.digest=
refuse "neither digest (the pair by tag)" "image.digest is empty" --set-string sanitizer-core.image.digest= --set-string sanitizer-core.sidecar.image.digest=
refuse "malformed digest" "sha256:<64 lowercase hex>" --set-string sanitizer-core.image.digest=sha256:abc --set-string "sanitizer-core.sidecar.image.digest=$D2"
refuse "placeholder digest (one repeated character)" "is a placeholder" --set-string "sanitizer-core.image.digest=sha256:$(printf '0%.0s' $(seq 64))"
refuse "the same digest for core and sidecar" "are the same digest" --set-string "sanitizer-core.image.digest=$D1" --set-string "sanitizer-core.sidecar.image.digest=$D1"
refuse "migration target above the ceiling" "integer 1..7" --set sanitizer-core.migrations.targetVersion=8
refuse "migration target 0" "integer 1..7" --set sanitizer-core.migrations.targetVersion=0
refuse "migration target as a string" "integer 1..7" --set-string sanitizer-core.migrations.targetVersion=7
refuse "off-enum protocol" "gateway.sanitizerCore.protocol" --set-string gateway.sanitizerCore.protocol=DELTA
refuse "off-enum Gate posture" "gateway.sanitizerCore.gatePosture" --set-string gateway.sanitizerCore.gatePosture=Enforce
refuse "off-enum route posture" "gateway.sanitizerCore.routePosture" --set-string gateway.sanitizerCore.routePosture=strict
refuse "off-enum placement" "gateway.sanitizerCore.addedPartsPlacement" --set-string gateway.sanitizerCore.addedPartsPlacement=header
refuse "plaintext core URL" "https://" --set-string gateway.sanitizerCore.url=http://sanitizer-core.dsa-identity.svc:8790
refuse "empty gateway mTLS Secret" "gateway.sanitizerCore.mtls" --set-string gateway.sanitizerCore.mtls.secretName=
refuse "empty core mTLS Secret" "mtls.secretName is required" --set-string sanitizer-core.mtls.secretName=
refuse "a \$(VAR) in a core literal" "contains \"\$\"" --set-string 'sanitizer-core.veilWitnessAddr=$(DSA_ENV):50057'
refuse "Lucairn-operated witness on the core (T-682)" "sanitizer-core.veilWitnessAddr" --set-string sanitizer-core.veilWitnessAddr=witness.lucairn.eu:50057
refuse "non-numeric message limit" "positive whole number" --set-string global.sandboxBMessagesJsonMaxBytes=4MiB
refuse "core without Sandbox A (its signing seed's Secret)" "sanitizer-core is enabled but sandbox-a is not" --set sandbox-a.enabled=false
if helm template lucairn "$CHART" -f "$CHART/values-prod.yaml" -f "$CHART/values-prod-site.example.yaml" "${DIGEST_ARGS[@]}" \
     --set sanitizer-core.secrets.backend=k8s-native \
     --set-string "sanitizer-core.secrets.values.registryKey=${TEST_REGISTRY_KEY}" \
     --set-string "sanitizer-core.secrets.values.postgresPassword=${TEST_SECRET_VALUE}-long" >/dev/null 2>"$TMP/prodnative.err"; then
  fail "refused: production k8s-native core backend (it RENDERED)"
elif grep -Fq "sanitizer-core.secrets.backend must be one of vault, aws, or azure" "$TMP/prodnative.err"; then
  pass "refused: production k8s-native core backend"
else fail "refused: production k8s-native core backend (other reason: $(head -c 300 "$TMP/prodnative.err"))"; fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "E. Migration payload + the rendered Job's own environment"
for f in "$ROOT"/migrations/sanitizer-core/*.up.sql "$ROOT/migrations/sanitizer-core/SHA256SUMS"; do
  if cmp -s "$f" "$SUB/files/migrations/$(basename "$f")"; then :; else fail "chart copy differs: files/migrations/$(basename "$f")"; fi
done
check_eq "chart migrations = repo migrations (file set)" "$(cd "$ROOT/migrations/sanitizer-core" && ls *.up.sql SHA256SUMS | sort | tr '\n' ' ')" "$(cd "$SUB/files/migrations" && ls | sort | tr '\n' ' ')"
cmp -s "$ROOT/scripts/migrate-sanitizer-core.sh" "$SUB/files/migrate-sanitizer-core.sh" && pass "chart runner = scripts/migrate-sanitizer-core.sh (byte copy)" || fail "chart runner differs from scripts/migrate-sanitizer-core.sh"
REPO_CEIL="$(sed -n 's/^CEILING_SANITIZER_CORE=\([0-9][0-9]*\)$/\1/p' "$ROOT/scripts/migration-ceilings.conf" | tail -1)"
CHART_CEIL="$(sed -n 's/.*define "sanitizerCore.migrationCeiling" -}}\([0-9][0-9]*\){{- end.*/\1/p' "$SUB/templates/_helpers.tpl")"
check_eq "chart ceiling = CEILING_SANITIZER_CORE in scripts/migration-ceilings.conf" "$REPO_CEIL" "$CHART_CEIL"
# Lay the RENDERED ConfigMap out the way the Job mounts it and run the runner
# with the RENDERED Job env (paths rebased into the temp dir).
mkdir -p "$TMP/job/scripts" "$TMP/job/migrations/sanitizer-core"
python3 - "$TMP/default.yaml" "$TMP/job" "$ROOT" <<'PY' > "$TMP/job/env.txt" || fail "the rendered Job/ConfigMap extraction ran to its end (a crash is a failure)"
import sys, yaml, os
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
out, root = sys.argv[2], sys.argv[3]
cm = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "sanitizer-core-migrations")
job = next(d for d in docs if d["kind"] == "Job" and d["metadata"]["name"].startswith("sanitizer-core-migrate-"))
spec = job["spec"]["template"]["spec"]
vols = {v["name"]: v for v in spec["volumes"]}
mounts = {m["name"]: m["mountPath"] for m in spec["containers"][0]["volumeMounts"]}
for vname, dest in (("scripts", "scripts"), ("migrations", "migrations/sanitizer-core")):
    for item in vols[vname]["configMap"]["items"]:
        with open(os.path.join(out, dest, item["path"]), "wb") as f:
            f.write(cm["data"][item["key"]].encode())
same = all(open(os.path.join(out, "migrations/sanitizer-core", n), "rb").read() == open(os.path.join(root, "migrations/sanitizer-core", n), "rb").read() for n in os.listdir(os.path.join(root, "migrations/sanitizer-core")) if n.endswith(".up.sql") or n == "SHA256SUMS")
print("BYTES_SAME=%s" % same)
print("MOUNT_SCRIPTS=%s" % mounts["scripts"])
print("MOUNT_MIGRATIONS=%s" % mounts["migrations"])
for e in spec["containers"][0]["env"]:
    if "value" in e:
        print("ENV %s=%s" % (e["name"], e["value"]))
PY
check_eq "ConfigMap carries every migration + SHA256SUMS byte-identically" "BYTES_SAME=True" "$(grep '^BYTES_SAME=' "$TMP/job/env.txt")"
check_eq "Job mounts the runner + ceiling file in ONE directory" "MOUNT_SCRIPTS=/scripts" "$(grep '^MOUNT_SCRIPTS=' "$TMP/job/env.txt")"
check_eq "Job mounts the migrations where MIGRATE_PATH points" "MOUNT_MIGRATIONS=/migrations/sanitizer-core" "$(grep '^MOUNT_MIGRATIONS=' "$TMP/job/env.txt")"
STUB="$TMP/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/psql" <<'STUBPSQL'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
# Fix round 3 (sol r2 P1): which credential each psql call carries.
{ printf 'PGPASSFILE=%s\n' "${PGPASSFILE:-}"; [ -z "${PGPASSWORD+x}" ] || echo "PGPASSWORD is set"; } >> "${STUB_ENV_LOG:-/dev/null}"
case "$*" in
  *"to_regclass"*) echo "f"; exit 0 ;;
  *"SELECT name FROM registry_schema_migrations"*) exit 0 ;;
  *"SELECT count(*) FROM registry_schema_migrations"*) echo 7; exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-f" ]; then cp "$2" "$STUB_SQL"; fi
  shift
done
exit 0
STUBPSQL
chmod 0755 "$STUB/psql"
if ! command -v sha256sum >/dev/null 2>&1; then
  # The runner calls `sha256sum -c` (busybox in the postgres image). Give a
  # macOS host the same verb.
  printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$STUB/sha256sum"; chmod 0755 "$STUB/sha256sum"
fi
JOB_ENV=()
while IFS= read -r line; do
  case "$line" in
    "ENV MIGRATE_PATH="*) JOB_ENV+=("MIGRATE_PATH=$TMP/job/migrations/sanitizer-core") ;;
    "ENV MIGRATE_CEILING_FILE="*) JOB_ENV+=("MIGRATE_CEILING_FILE=$TMP/job/scripts/migration-ceilings.conf") ;;
    "ENV HOME="*) JOB_ENV+=("HOME=$TMP") ;;
    "ENV "*) JOB_ENV+=("${line#ENV }") ;;
  esac
done < "$TMP/job/env.txt"
# Fix round 3 (sol r2 P1): the rendered Job is run END TO END — its OWN shell
# prelude (paths moved into $TMP, pg_isready stubbed) execs the real runner
# with ONLY what the Job gives it: the mounted password file, turned into
# PGPASSFILE. No PGPASSWORD is injected anywhere (round 2's test injected one
# and so hid that the runner refused every Helm install with 93).
python3 - "$TMP/default.yaml" "$TMP/prelude.sh" <<'PY' || fail "the rendered Job prelude extraction ran to its end (a crash is a failure)"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
job = [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"].startswith("sanitizer-core-migrate-")][0]
open(sys.argv[2], "w").write(job["spec"]["template"]["spec"]["containers"][0]["command"][-1])
PY
mkdir -p "$TMP/pre/db" "$TMP/pre/bin"
printf '%s' 'syn:th\etic-pw' > "$TMP/pre/db/password"
printf '#!/bin/sh\nexit 0\n' > "$TMP/pre/bin/pg_isready"; chmod 0755 "$TMP/pre/bin/pg_isready"
sed -e "s#/etc/sanitizer-core/db/password#$TMP/pre/db/password#g" -e "s#/tmp/.pgpass#$TMP/pre/job-pgpass#g" \
    -e "s#exec /bin/sh /scripts/migrate-sanitizer-core.sh#exec /bin/sh $TMP/job/scripts/migrate-sanitizer-core.sh#" "$TMP/prelude.sh" > "$TMP/job-run.sh"
: > "$TMP/stub.log"; : > "$TMP/stub-env.log"
if grep -qF "exec /bin/sh $TMP/job/scripts/migrate-sanitizer-core.sh" "$TMP/job-run.sh"; then
  env -i PATH="$TMP/pre/bin:$STUB:$BASE_PATH" TMPDIR="$TMP" STUB_LOG="$TMP/stub.log" STUB_SQL="$TMP/stub.sql" STUB_ENV_LOG="$TMP/stub-env.log" \
    "${JOB_ENV[@]}" sh "$TMP/job-run.sh" > "$TMP/job.out" 2>&1
  rc=$?
else
  rc=99; echo "the Job prelude no longer execs /scripts/migrate-sanitizer-core.sh" > "$TMP/job.out"
fi
check_eq "the rendered Job (its prelude + the runner, password file only, no PGPASSWORD) migrates a fresh registry" "0" "$rc"
[ "$rc" -eq 0 ] || sed -n '1,5p' "$TMP/job.out"
check_eq "one --single-transaction apply" "1" "$(grep -c -- '--single-transaction' "$TMP/stub.log")"
check_eq "the apply inserts 0001..0007 into the core's own ledger" "7" "$(grep -c "^INSERT INTO registry_schema_migrations (name) VALUES ('" "$TMP/stub.sql" 2>/dev/null || echo 0)"
grep -q 'ceiling 7 from' "$TMP/job.out" && pass "the runner reads ceiling 7 from the chart-rendered ceiling file" || fail "the runner reads ceiling 7 from the chart-rendered ceiling file: $(tail -2 "$TMP/job.out")"
if [ -s "$TMP/stub-env.log" ] && ! grep -v "^PGPASSFILE=$TMP/pre/job-pgpass$" "$TMP/stub-env.log" | grep -q .; then
  pass "every psql call carries the Job's PGPASSFILE and no PGPASSWORD ($(grep -c . "$TMP/stub-env.log") calls)"
else
  fail "every psql call carries the Job's PGPASSFILE and no PGPASSWORD: $(sort -u "$TMP/stub-env.log" | head -3 | tr '\n' ' ')"
fi
if grep -q 'th\\etic' "$TMP/job.out" "$TMP/stub.log"; then fail "the password is never printed or passed as argv"; else pass "the password is never printed or passed as argv"; fi
# The runner still refuses to run without any credential (fail closed, 93),
# and refuses a PGPASSFILE that is not a readable file.
env -i PATH="$STUB:$BASE_PATH" TMPDIR="$TMP" STUB_LOG=/dev/null STUB_SQL=/dev/null "${JOB_ENV[@]}" sh "$TMP/job/scripts/migrate-sanitizer-core.sh" > "$TMP/nocred.out" 2>&1
check_eq "no PGPASSWORD and no PGPASSFILE -> the runner refuses (93)" "93" "$?"
grep -q 'PGPASSWORD or PGPASSFILE must be set' "$TMP/nocred.out" && pass "... naming PGPASSWORD / PGPASSFILE" || fail "... naming PGPASSWORD / PGPASSFILE: $(tail -1 "$TMP/nocred.out")"
env -i PATH="$STUB:$BASE_PATH" TMPDIR="$TMP" STUB_LOG=/dev/null STUB_SQL=/dev/null PGPASSFILE="$TMP/pre/absent-pgpass" "${JOB_ENV[@]}" sh "$TMP/job/scripts/migrate-sanitizer-core.sh" > "$TMP/nocred.out" 2>&1
check_eq "PGPASSFILE naming a missing file -> the runner refuses (93)" "93" "$?"
# Fix round 1 (sol r1 P2): the Job's OWN shell prelude, run for real (paths
# moved into $TMP, pg_isready stubbed, the runner replaced by an env dump): it
# writes a 0600 libpq password file with \ and : escaped, and the password is
# in no process environment of what it execs.
sed -e "s#/etc/sanitizer-core/db/password#$TMP/pre/db/password#g" -e "s#/tmp/.pgpass#$TMP/pre/pgpass#g" \
    -e "s#exec /bin/sh /scripts/migrate-sanitizer-core.sh#exec env#" "$TMP/prelude.sh" > "$TMP/prelude-run.sh"
if grep -q 'exec env' "$TMP/prelude-run.sh" && env -i PATH="$TMP/pre/bin:$BASE_PATH" sh "$TMP/prelude-run.sh" > "$TMP/prelude.env" 2>&1; then
  check_eq "the Job prelude writes the libpq password file (\\ and : escaped)" '*:*:*:*:syn\:th\\etic-pw' "$(cat "$TMP/pre/pgpass" 2>/dev/null)"
  case "$(uname -s)" in Darwin|*BSD) m="$(stat -f '%Lp' "$TMP/pre/pgpass")" ;; *) m="$(stat -c '%a' "$TMP/pre/pgpass")" ;; esac
  check_eq "the libpq password file is mode 0600 (libpq ignores a group/world-readable one)" "600" "$m"
  grep -q "^PGPASSFILE=$TMP/pre/pgpass$" "$TMP/prelude.env" && pass "the runner is exec'd with PGPASSFILE set" || fail "the runner is exec'd with PGPASSFILE set"
  if grep -q 'th\\etic' "$TMP/prelude.env" || grep -q '^PGPASSWORD=' "$TMP/prelude.env"; then fail "the password is in no environment of the exec'd runner"; else pass "the password is in no environment of the exec'd runner"; fi
else
  fail "the rendered Job prelude runs: $(tail -2 "$TMP/prelude.env" 2>/dev/null)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "F. bin/lucairn doctor --values (+ DOCTOR_KUBE_LIVE=1 against a stub kubectl)"
DEV_VALUES="$TMP/dev-values.yaml"
cat > "$DEV_VALUES" <<YAML
global:
  skipPullSecretGuard: true
admin: {secrets: {values: {adminPassword: ${TEST_SECRET_VALUE}}}}
audit: {secrets: {values: {postgresPassword: ${TEST_SECRET_VALUE}, auditAppPassword: ${TEST_SECRET_VALUE}}}}
id-bridge: {secrets: {values: {postgresPassword: ${TEST_SECRET_VALUE}}}}
observability: {secrets: {values: {grafanaAdminPassword: ${TEST_SECRET_VALUE}}}}
sandbox-a: {secrets: {values: {postgresPassword: ${TEST_SECRET_VALUE}}}}
veil-witness: {secrets: {values: {postgresPassword: ${TEST_SECRET_VALUE}, veilAppPassword: ${TEST_SECRET_VALUE}}}}
sanitizer-core: {secrets: {values: {registryKey: "${TEST_REGISTRY_KEY}", postgresPassword: ${TEST_SECRET_VALUE}}}}
YAML
# Fix round 1 (sol r1 P1): doctor --values compares the rendered pair with the
# signed pair image-manifest.yaml records, so the GREEN cases run from a
# RELEASED-kit fixture (synthetic signed digests, tests/lib/test-helpers.sh)
# with a values file pinning exactly that pair.
KIT="$TMP/released-kit"
lucairn_released_kit_fixture "$ROOT" "$KIT" && pass "fixture: a released kit (synthetic signed core/sidecar digests)" \
  || fail "fixture: a released kit (synthetic signed core/sidecar digests)"
DIGESTS="$TMP/digests.yaml"
printf 'sanitizer-core:\n  image:\n    digest: "%s"\n  sidecar:\n    image:\n      digest: "%s"\n' "$TEST_SANITIZER_CORE_DIGEST" "$TEST_SANITIZER_CORE_SIDECAR_DIGEST" > "$DIGESTS"
DOCTOR_KIT="$KIT"
doctor_values() { # <out> [env...] -- values files... (the digest pair is appended)
  local out="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local vargs=() v
  for v in "$@"; do vargs+=(--values "$v"); done
  [ "${NO_DIGESTS:-0}" = 1 ] || vargs+=(--values "$DIGESTS")
  env ${envs[@]+"${envs[@]}"} "$DOCTOR_KIT/bin/lucairn" doctor "${vargs[@]}" > "$out" 2>&1
}
doctor_values "$TMP/doc-dev.out" -- "$DEV_VALUES"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'sanitizer core (Helm): render ok' "$TMP/doc-dev.out"; then pass "doctor --values: development values green, core render ok"; else fail "doctor --values: development values green (rc=$rc): $(grep -i 'sanitizer core' "$TMP/doc-dev.out" | head -3)"; fi
LOWMEM="$TMP/lowmem.yaml"
printf 'sanitizer-core:\n  sidecar:\n    resources:\n      limits:\n        memory: 4Gi\n' > "$LOWMEM"
doctor_values "$TMP/doc-low.out" -- "$DEV_VALUES" "$LOWMEM"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'sidecar memory limit is 4096 MiB' "$TMP/doc-low.out"; then pass "doctor --values RED: sidecar limit below 6500 MiB"; else fail "doctor --values RED: sidecar limit below 6500 MiB (rc=$rc): $(grep -i 'sanitizer core' "$TMP/doc-low.out" | head -3)"; fi
# Fix round 1 (sol r1 P1), each RED on 42f2ddb (tag-only images were "ok"):
doc_red() { # <name> <grep> [env...] -- values...
  local name="$1" pat="$2"; shift 2
  doctor_values "$TMP/doc-red.out" "$@"; local rc=$?
  if [ "$rc" -ne 0 ] && grep -Fq -- "$pat" "$TMP/doc-red.out"; then pass "doctor --values RED: $name"; else fail "doctor --values RED: $name (rc=$rc): $(grep -iE 'sanitizer core|failed|Error' "$TMP/doc-red.out" | head -3)"; fi
}
TAGONLY="$TMP/tag-only.yaml"
printf 'sanitizer-core:\n  image:\n    digest: ""\n  sidecar:\n    image:\n      digest: ""\n' > "$TAGONLY"
NO_DIGESTS=1 doc_red "tag-only core/sidecar images (no digests)" "image.digest is empty" -- "$DEV_VALUES" "$TAGONLY"
OTHER="$TMP/other-digests.yaml"
printf 'sanitizer-core:\n  image:\n    digest: "%s"\n  sidecar:\n    image:\n      digest: "%s"\n' "$D1" "$D2" > "$OTHER"
NO_DIGESTS=1 doc_red "a pinned pair other than the manifest's" "differ from the pair image-manifest.yaml records" -- "$DEV_VALUES" "$OTHER"
# Kit 2.0.0: this checkout is a released kit; the unreleased case runs on a
# copy put back to `pending: true` (tests/lib/test-helpers.sh).
UNREL_KIT="$TMP/unreleased-kit"
lucairn_unreleased_kit_fixture "$ROOT" "$UNREL_KIT" || fail "fixture: an unreleased kit (manifest pending)"
DOCTOR_KIT="$UNREL_KIT" doc_red "an unreleased kit (manifest pending)" "records no signed digest for the core/sidecar pair yet" -- "$DEV_VALUES"
# ... and THIS checkout's chart defaults are the signed pair its manifest
# records: doctor --values is green with no digest values file.
NO_DIGESTS=1 DOCTOR_KIT="$ROOT" doctor_values "$TMP/doc-released.out" -- "$DEV_VALUES"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'sanitizer core (Helm): render ok' "$TMP/doc-released.out"; then
  pass "doctor --values: this released kit's chart defaults carry the manifest's signed pair (render ok)"
else
  fail "doctor --values: this released kit's chart defaults (rc=$rc): $(grep -iE 'sanitizer core|failed' "$TMP/doc-released.out" | head -3)"
fi
# K-C M2, moved into K-B fix round 4: the doctor requires LCR_PROFILE=kit as a
# literal in the core's env:, red-proofed on a released-kit copy without it.
KITBAD="$TMP/kit-noprofile"; cp -R "$KIT" "$KITBAD"
sed -i.bak 's/^            - name: LCR_PROFILE$/            - name: LCR_PROFILE_UNUSED/' "$KITBAD/charts/lucairn/charts/sanitizer-core/templates/deployment.yaml"
grep -q 'name: LCR_PROFILE_UNUSED' "$KITBAD/charts/lucairn/charts/sanitizer-core/templates/deployment.yaml" || fail "fixture: the LCR_PROFILE mutant applied"
DOCTOR_KIT="$KITBAD" doc_red "(M2) a render whose core does not set LCR_PROFILE=kit" "does not set LCR_PROFILE=kit as a literal" -- "$DEV_VALUES"
PLACE="$TMP/placeholder-digests.yaml"
printf 'sanitizer-core:\n  image:\n    digest: "sha256:%s"\n  sidecar:\n    image:\n      digest: "%s"\n' "$(printf 'f%.0s' $(seq 64))" "$TEST_SANITIZER_CORE_SIDECAR_DIGEST" > "$PLACE"
NO_DIGESTS=1 doc_red "a placeholder core digest" "is a placeholder" -- "$DEV_VALUES" "$PLACE"
if command -v ruby >/dev/null 2>&1; then
  doctor_values "$TMP/doc-prod.out" -- "$CHART/values-prod.yaml" "$CHART/values-prod-site.example.yaml"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'sanitizer core (Helm): render ok' "$TMP/doc-prod.out" && ! grep -q 'development render' "$TMP/doc-prod.out"; then pass "doctor --values: production values green (latched witness hop)"; else fail "doctor --values: production values green (rc=$rc): $(grep -iE 'sanitizer core|FAIL' "$TMP/doc-prod.out" | head -3)"; fi
fi
KSTUB="$TMP/kube-bin"; mkdir -p "$KSTUB"
cat > "$KSTUB/kubectl" <<'KUBE'
#!/bin/sh
# Answers the doctor's live sanitizer-core questions from STUB_* variables.
all="$*"
case "$all" in
  *"get namespace"*) exit 0 ;;
  *"get secret ${STUB_MISSING_SECRET:-__none__}"*) exit 1 ;;
  *"get secret"*) exit 0 ;;
  *"get deployment sanitizer-core"*) printf '%s' "${STUB_READY:-1}"; exit 0 ;;
  *"get statefulset postgres-sanitizer-core"*) printf '%s' "${STUB_PG_READY:-1}"; exit 0 ;;
  *"get jobs"*) printf 'sanitizer-core-migrate-r1=%s\n' "${STUB_JOB_SUCCEEDED-1}"; exit 0 ;;
  *"logs deployment/sanitizer-core"*)
    echo "serve: registry DSN from --registry-dsn-file"
    echo "evidence: witness transport mode=${STUB_MODE:-mtls} addr=\"veil-witness.dsa-witness.svc.cluster.local:50057\""
    [ -n "${STUB_DROPPED:-}" ] && echo "evidence: claim abc DROPPED after 3 attempts"
    exit 0 ;;
esac
echo "unexpected kubectl call: $all" >&2
exit 3
KUBE
chmod 0755 "$KSTUB/kubectl"
live() { # <name> <want rc 0|1> <grep> [env...] — production values, stub cluster
  local name="$1" want="$2" pat="$3"; shift 3
  doctor_values "$TMP/live.out" PATH="$KSTUB:$PATH" DOCTOR_KUBE_LIVE=1 "$@" -- "$CHART/values-prod.yaml" "$CHART/values-prod-site.example.yaml"
  local rc=$? got=0
  [ "$rc" -eq 0 ] || got=1
  if [ "$got" = "$want" ] && grep -Fq -- "$pat" "$TMP/live.out"; then pass "doctor live: $name"; else fail "doctor live: $name (rc=$rc): $(grep -i 'sanitizer core (live)' "$TMP/live.out" | head -4)"; fi
}
if command -v ruby >/dev/null 2>&1; then
  live "healthy release is green" 0 "witness transport mode=mtls"
  live "RED: core not ready" 1 "Deployment sanitizer-core not ready" STUB_READY=0
  live "RED: registry not ready" 1 "postgres-sanitizer-core not ready" STUB_PG_READY=0
  live "RED: migration Job not complete" 1 "not complete" STUB_JOB_SUCCEEDED=
  live "RED: core mTLS Secret missing" 1 "sanitizer-core-mtls missing" STUB_MISSING_SECRET=sanitizer-core-mtls
  live "RED: gateway mTLS Secret missing" 1 "gateway-sanitizer-core-mtls missing" STUB_MISSING_SECRET=gateway-sanitizer-core-mtls
  live "RED: claims DROPPED" 1 "DROPPED in the core's log" STUB_DROPPED=1
  live "RED: production witness hop not mTLS" 1 "must be mtls" STUB_MODE=plaintext-insecure-dev
  # Fix round 1 (sol r1 P2), RED on 42f2ddb: an EXTERNAL registry DB has no
  # bundled StatefulSet; the live doctor must not demand one.
  EXTV="$TMP/external-registry.yaml"
  printf 'sanitizer-core:\n  postgresql:\n    enabled: false\n  external:\n    host: db.internal\n    user: lucairn_core\n    database: core\n' > "$EXTV"
  doctor_values "$TMP/live.out" PATH="$KSTUB:$PATH" DOCTOR_KUBE_LIVE=1 STUB_PG_READY=0 -- "$CHART/values-prod.yaml" "$CHART/values-prod-site.example.yaml" "$EXTV"; rc=$?
  if [ "$rc" -eq 0 ] && grep -Fq "external registry DB (sanitizer-core.postgresql.enabled=false)" "$TMP/live.out" && ! grep -q "StatefulSet postgres-sanitizer-core not ready" "$TMP/live.out"; then
    pass "doctor live: an external registry DB is green without a bundled StatefulSet"
  else fail "doctor live: external registry DB (rc=$rc): $(grep -iE 'sanitizer core \((live|Helm)\)|FAIL' "$TMP/live.out" | head -4)"; fi
  # A PATH with helm + ruby (+ python3) but no kubectl.
  NOKUBE="$TMP/nokube-bin"; mkdir -p "$NOKUBE"
  for tool in helm ruby python3 openssl; do
    command -v "$tool" >/dev/null 2>&1 && ln -s "$(command -v "$tool")" "$NOKUBE/$tool"
  done
  if PATH=/usr/bin:/bin command -v kubectl >/dev/null 2>&1; then
    echo "  NOT RUN — doctor live: no-kubectl case (this host has kubectl in /usr/bin)"
  else
    doctor_values "$TMP/live-nokube.out" PATH="$NOKUBE:/usr/bin:/bin" DOCTOR_KUBE_LIVE=1 -- "$CHART/values-prod.yaml" "$CHART/values-prod-site.example.yaml"; rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'kubectl is not installed' "$TMP/live-nokube.out"; then pass "doctor live: asked for and no kubectl = failure, never a silent skip"; else fail "doctor live: no-kubectl case (rc=$rc): $(grep -i 'sanitizer core' "$TMP/live-nokube.out" | head -2)"; fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "G. bin/lucairn: verify-images set + bundle bootstrap"
# The pair is in EVERY verify-images set, at its own manifest tag, and fails
# closed while it is pending (K-A fix round 1 on #158; behaviour asserted end to
# end in tests/test_sanitizer_core_compose.sh section G). Here: exactly once.
grep -q 'local core_pair=(dsa-sanitizer-core dsa-sanitizer-core-sidecar)' "$ROOT/bin/lucairn" && pass "verify-images expects exactly dsa-sanitizer-core + dsa-sanitizer-core-sidecar (the K-A core_pair)" || fail "verify-images expects the core pair (core_pair)"
if grep -q 'dsa_images+=(dsa-sanitizer-core' "$ROOT/bin/lucairn"; then fail "the pair is not ALSO added at the umbrella --tag (it would be expected twice)"; else pass "the pair is not ALSO added at the umbrella --tag (it would be expected twice)"; fi
grep -q 'dsa-sanitizer-core:${core_tag}' "$ROOT/bin/lucairn" && grep -q 'dsa-sanitizer-core-sidecar:${core_tag}' "$ROOT/bin/lucairn" && pass "doctor image check pulls the core pair on its own tag" || fail "doctor image check pulls the core pair on its own tag"
# Final reads (H2): bundle create stages BOTH core operator tools in scripts/
# (not install/scripts/, T-350) from #158; the offline-bundle reproduction in
# tests/test_sanitizer_core_compose.sh § H proves the extracted bundle runs them.
grep -qx 'SANITIZER_CORE_OPERATOR_TOOLS="bootstrap-sanitizer-core-mtls.sh write-sanitizer-core-registry-dsn.sh sanitizer-core-registry-credentials.sh"' "$ROOT/bin/lucairn" \
  && [ "$(grep -c 'for _core_tool in $SANITIZER_CORE_OPERATOR_TOOLS; do' "$ROOT/bin/lucairn")" -eq 2 ] \
  && grep -q 'cp "$ROOT/scripts/$_core_tool" "$staging/scripts/$_core_tool"' "$ROOT/bin/lucairn" \
  && pass "bundle create carries the mTLS bootstrap, the DSN writer and the registry credentials helper in scripts/ (not install/scripts/, T-350)" || fail "bundle create carries the mTLS bootstrap, the DSN writer and the registry credentials helper"
grep -q 'require_file "$root/scripts/$_core_tool" "bundle sanitizer-core operator tool $_core_tool"' "$ROOT/bin/lucairn" && pass "bundle verify requires each operator tool for a kit 2.0 compose" || fail "bundle verify requires each operator tool"
grep -q -- '--profile sanitizer-core-migrate run --rm migrate-sanitizer-core' "$ROOT/bin/lucairn" && pass "bundle install note names the migration step" || fail "bundle install note names the migration step"

# Red-proof of the tally (fix round 4, sol r3 P2; RED on 507f0323): a block
# that crashes after a passing line (KeyError) is counted as a FAIL.
PY_TALLY_KEEP="$PY_TALLY"; PY_TALLY="$TMP/py-tally-selftest"; : > "$PY_TALLY"
assert_py "$TMP/default.yaml" 'ok(True, "self-test: one passing line before the crash")
{}["missing-key"]' 2>/dev/null | run_py > /dev/null
PY_TALLY="$PY_TALLY_KEEP"
if grep -qx F "$TMP/py-tally-selftest"; then pass "a crashed assertion block counts as a FAIL (KeyError self-test)"; else fail "a crashed assertion block counts as a FAIL (KeyError self-test)"; fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "H. K-C: the ServiceNow mode on the core (assembled copy, hold removed — test only)"
# Production renders with servicenowControl.enabled stay HELD
# (templates/servicenow-control-held.yaml); like tests/test_servicenow_control_helm.py
# this section removes the hold in a disposable kit copy only.
# Copied from the RELEASED-kit fixture of section F (K-B fix round 1: the core
# pair renders and doctors only with the signed digests a release records).
RELEASED_SRC="$TMP/released-kit"
KIT="$TMP/kit-on"; mkdir -p "$KIT"
cp -R "$RELEASED_SRC/bin" "$RELEASED_SRC/charts" "$RELEASED_SRC/scripts" "$RELEASED_SRC/config" "$RELEASED_SRC/keys" "$RELEASED_SRC/migrations" "$KIT/"
cp "$RELEASED_SRC/VERSION" "$RELEASED_SRC/RELEASE_DATE" "$RELEASED_SRC/image-manifest.yaml" "$KIT/"
rm "$KIT/charts/lucairn/templates/servicenow-control-held.yaml"
ON_VALUES="$TMP/sn-on.yaml"
cat > "$ON_VALUES" <<'YAML'
global:
  servicenowControl:
    enabled: true
    gatewaySecret: synthetic-gateway-control
    sanitizerSecret: synthetic-sanitizer-control
    instanceCIDRs: ["198.51.100.0/24"]
    instanceDNSNames: ["instance.synthetic.test"]
    kubernetesAPICIDRs: ["10.96.0.1/32"]
    clusterCIDRs: ["10.244.0.0/16", "10.96.0.0/12"]
YAML
if helm template lucairn "$KIT/charts/lucairn" "${COMMON[@]}" -f "$ON_VALUES" >"$TMP/sn-on.yaml.out" 2>"$TMP/sn-on.err"; then
  pass "assembled ON render (hold removed in the copy)"
  assert_py "$TMP/sn-on.yaml.out" '
dep = find("Deployment", "sanitizer-core", "dsa-identity")
ps = dep["spec"]["template"]["spec"]
cs = {c["name"]: c for c in ps["containers"]}
e = env_of(cs["core"])
ok(e["LCR_PROFILE"] == {"name": "LCR_PROFILE", "value": "kit-servicenow"}, "ON: the core sets LCR_PROFILE=kit-servicenow as a literal")
ok(e["LCR_SERVICENOW_CONTROL_PEER_URL"]["value"] == "https://gateway-servicenow-control.dsa-edge.svc.cluster.local:18443" and e["GOTRACEBACK"]["value"] == "none", "ON: the core dials the gateway control Service on :18443, GOTRACEBACK=none")
ok({k: e["LCR_SERVICENOW_CONTROL_" + k]["value"] for k in ("CA_CERT", "TLS_CERT", "TLS_KEY")} == {"CA_CERT": "/run/secrets/servicenow-control/sanitizer/ca.crt", "TLS_CERT": "/run/secrets/servicenow-control/sanitizer/tls.crt", "TLS_KEY": "/run/secrets/servicenow-control/sanitizer/tls.key"}, "ON: the core presents the sanitizer control leaf")
vols = {v["name"]: v for v in ps["volumes"]}
ok(vols["sn-control-core"]["secret"]["secretName"] == "synthetic-sanitizer-control" and [i["key"] for i in vols["sn-control-core"]["secret"]["items"]] == ["ca.crt", "tls.crt", "tls.key"], "ON: the control leaf comes from global.servicenowControl.sanitizerSecret")
core_mounts = {m["name"] for m in cs["core"]["volumeMounts"]}
side_mounts = {m["name"] for m in cs["sidecar"].get("volumeMounts") or []}
ok("sn-control-core" in core_mounts and "sn-control-core" not in side_mounts and not any(k.startswith("LCR_SERVICENOW") for k in env_of(cs["sidecar"])), "ON: the control leaf is mounted into the core container ONLY, never the sidecar")
nps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "NetworkPolicy"}
ok("servicenow-sanitizer-core-18443-egress" in nps and "servicenow-sanitizer-core-18443-ingress" in nps, "ON: NetworkPolicies let the core reach the gateway control listener :18443")
' | run_py
else
  fail "assembled ON render: $(head -3 "$TMP/sn-on.err")"
fi
refuse_kit() { # <case> <fragment> [helm args]
  local name="$1" want="$2"; shift 2
  if helm template lucairn "$KIT/charts/lucairn" "${COMMON[@]}" -f "$ON_VALUES" "$@" >/dev/null 2>"$TMP/refuse.err"; then fail "refused: $name (it RENDERED)"
  elif grep -Fq -- "$want" "$TMP/refuse.err"; then pass "refused: $name"
  else fail "refused: $name (other reason: $(head -c 300 "$TMP/refuse.err"))"; fi
}
# (the namespace split-brain validator or the K-C check refuses first; both name sanitizer-core)
refuse_kit "ON with the core outside the sanitizer namespace" "sanitizer-core" --set sanitizer-core.namespace=dsa-other
refuse_kit "ON with two gateway replicas (the reused single-replica guard)" "replicaCount=1" --set gateway.replicaCount=2
refuse_kit "ON with HPA on the gateway (the reused guard)" "HPA disabled" --set gateway.hpa.enabled=true
if helm template lucairn "$CHART" "${COMMON[@]}" -f "$ON_VALUES" >/dev/null 2>"$TMP/held.err"; then fail "the REAL chart rendered with the mode on (hold removed?)"
else grep -q "held" "$TMP/held.err" && pass "the real chart still holds every ON render" || fail "hold reason: $(head -c 200 "$TMP/held.err")"; fi
if command -v ruby >/dev/null 2>&1; then
  env "$KIT/bin/lucairn" doctor --values "$DEV_VALUES" --values "$ON_VALUES" > "$TMP/doc-on.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'sanitizer core (Helm): render ok' "$TMP/doc-on.out" && ! grep -q 'LCR_PROFILE' "$TMP/doc-on.out"; then pass "doctor --values: ON render accepted with LCR_PROFILE=kit-servicenow + the control client"; else fail "doctor --values ON (rc=$rc): $(grep -iE 'sanitizer core|FAIL' "$TMP/doc-on.out" | head -3)"; fi
  # The doctor's render check, red-proofed on a copy whose core profile is wrong.
  KITBAD="$TMP/kit-bad"; cp -R "$KIT" "$KITBAD"
  sed -i.bak 's/"kit-servicenow"{{ else }}"kit"{{ end }}/"kit"{{ else }}"kit"{{ end }}/' "$KITBAD/charts/lucairn/charts/sanitizer-core/templates/deployment.yaml"
  env "$KITBAD/bin/lucairn" doctor --values "$DEV_VALUES" --values "$ON_VALUES" > "$TMP/doc-bad.out" 2>&1; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'does not set LCR_PROFILE=kit-servicenow as a literal' "$TMP/doc-bad.out"; then pass "doctor --values RED: the mode on but the core profile kit"; else fail "doctor --values RED profile (rc=$rc): $(grep -iE 'sanitizer core' "$TMP/doc-bad.out" | head -2)"; fi
  sed -i.bak 's/^            - name: LCR_PROFILE$/            - name: LCR_PROFILE_UNUSED/' "$KITBAD/charts/lucairn/charts/sanitizer-core/templates/deployment.yaml"
  env "$KITBAD/bin/lucairn" doctor --values "$DEV_VALUES" > "$TMP/doc-bad.out" 2>&1; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'does not set LCR_PROFILE=kit as a literal' "$TMP/doc-bad.out"; then pass "doctor --values RED (M2): a default render whose core does not set LCR_PROFILE"; else fail "doctor --values RED M2 (rc=$rc): $(grep -iE 'sanitizer core' "$TMP/doc-bad.out" | head -2)"; fi
  # Live: the render guard refuses replicaCount=2, `kubectl scale` does not.
  cat > "$KSTUB/kubectl-gw" <<'KUBE'
#!/bin/sh
case "$*" in *"get deployment gateway"*) printf '%s' "${STUB_GW_REPLICAS:-1/1}"; exit 0 ;; esac
exec "$(dirname "$0")/kubectl.real" "$@"
KUBE
  mv "$KSTUB/kubectl" "$KSTUB/kubectl.real"; mv "$KSTUB/kubectl-gw" "$KSTUB/kubectl"; chmod 0755 "$KSTUB/kubectl"
  live_on() { # <name> <want 0|1> <grep> [env...]
    local name="$1" want="$2" pat="$3"; shift 3
    env PATH="$KSTUB:$PATH" DOCTOR_KUBE_LIVE=1 "$@" "$KIT/bin/lucairn" doctor --values "$CHART/values-prod.yaml" --values "$CHART/values-prod-site.example.yaml" --values "$ON_VALUES" > "$TMP/live-on.out" 2>&1
    local rc=$? got=0; [ "$rc" -eq 0 ] || got=1
    if [ "$got" = "$want" ] && grep -Fq -- "$pat" "$TMP/live-on.out"; then pass "doctor live (ON): $name"; else fail "doctor live (ON): $name (rc=$rc): $(grep -iE 'sanitizer core|FAIL' "$TMP/live-on.out" | head -4)"; fi
  }
  live_on "one gateway replica is green" 0 "ServiceNow mode — one gateway replica"
  live_on "RED: two gateway replicas after kubectl scale" 1 "needs exactly one gateway replica; Deployment gateway spec/status replicas = 2/2" STUB_GW_REPLICAS=2/2
  live_on "RED: scaled to 2, one still starting" 1 "spec/status replicas = 2/1" STUB_GW_REPLICAS=2/1
fi

echo ""
N=$((N + $(grep -c . "$PY_TALLY" || true)))
FAILS=$((FAILS + $(grep -c '^F$' "$PY_TALLY" || true)))
if [ "$FAILS" -eq 0 ]; then
  echo "sanitizer-core Helm tests: ok ($N checks)"
  exit 0
fi
echo "sanitizer-core Helm tests: FAIL ($FAILS of $N checks)"
exit 1
