#!/usr/bin/env bash
set -euo pipefail

# T-573 — the kit gateway must be able to WRITE its evidence gap store.
#
# THE DEFECT (verified 2026-08-07 on this chart, and measured live on a Kind
# install): charts/lucairn/charts/gateway/values.yaml sets
# `containerSecurityContext.readOnlyRootFilesystem: true` and the deployment
# mounted only verticals / readiness-bundle / witness-manifest / mTLS certs /
# keystore. Nothing was mounted at the evidence-gap path. The gateway opens
# that path at startup and the admission gate treats an unwritable store as a
# degraded evidence path, so the pod came up **1/1 Ready** while logging
#
#   evidence gap store at /data/evidence-gaps.jsonl is not writable...
#   read-only file system
#
# and then degraded silently: permissive boot mode + the LOG posture admit
# every request while recording NOTHING durably. `kubectl get pods` stays
# green. Under ENFORCE the same chart would refuse ALL healthy traffic.
# Upstream twin: dual-sandbox-architecture T-571 HIGH-1
# (PRD specs/2026-08/prd-2026-08-06-evidence-pipeline-fail-closed.md);
# this suite is the kit port of tests/invariant/helm_evidence_gap_volume_test.sh.
#
# ─── WHAT THIS PROVES ────────────────────────────────────────────────────────
#   1. The gateway container declares GATEWAY_EVIDENCE_GAP_PATH at all.
#   2. Some volumeMount's mountPath is a PARENT DIRECTORY of that path — the
#      relationship, not a mount that merely happens to be named "evidence-gap"
#      (the name is ours to rename; the relationship is what the kernel cares
#      about).
#   3. That covering mount is not readOnly.
#   4. The referenced volume EXISTS in the pod spec and is a writable KIND.
#      configMap / secret / projected / downwardAPI are read-only at the
#      kubelet no matter what the mount flag says.
#   5. The container's UID can actually create a file in it: a non-root pod
#      needs fsGroup, because a PVC arrives root:root 0755. Dropping fsGroup
#      must NOT leave this suite green — assertion E proves it does not.
#   6. Enabling persistence on a multi-replica gateway ABORTS the render, for
#      the RIGHT REASON (the abort token is grepped, not just the exit status),
#      and an `existingClaim` is not an escape hatch from that abort.
#   7. The abort message does not steer operators onto a ReadWriteMany shared
#      claim.
#
# ─── WHAT THIS DOES NOT PROVE ────────────────────────────────────────────────
#   * That the gateway IMAGE actually honours GATEWAY_EVIDENCE_GAP_PATH. The
#     kit pins dsa-gateway 0.5.4, which predates T-571; on that image these env
#     vars are inert. This suite proves the chart is correct the day the kit
#     tracks a gateway that has the feature — it cannot prove the running
#     binary writes anything.
#   * That a gap record is ever WRITTEN, or that the admission gate consults
#     the store. That is upstream Go-test territory.
#   * ⚑ Most importantly: a render guard CANNOT catch a chart that lacks the
#     feature entirely. Before this commit the kit chart set no
#     GATEWAY_EVIDENCE_GAP_PATH at all, so a "is the configured path writable"
#     guard would have had nothing to look at and would have passed vacuously.
#     That is exactly how this defect survived. Assertion 1 (the env var must be
#     present) is the part that closes that hole, and it only closes it for THIS
#     env var — a future writable-path requirement gets the same free pass
#     unless someone writes its own assertion.
#   * That an emptyDir survives pod rescheduling. It does not, by design; the
#     honest statement lives in values.yaml.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"

# shellcheck source=tests/lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

TMPDIR_T573="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_T573"; }
trap cleanup EXIT

ABORT_TOKEN="EVIDENCE-GAP-MULTI-REPLICA"

fail() {
  echo "T-573 evidence gap volume: $*" >&2
  exit 1
}

render() {
  helm template lucairn "$CHART" \
    "${HELM_TEST_SECRET_ARGS[@]}" \
    --set global.skipPullSecretGuard=true \
    --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
    "$@"
}

CHECKER="$TMPDIR_T573/check.py"
cat >"$CHECKER" <<'PYEOF'
"""Assert the gateway can actually write its evidence gap store.

Reads a rendered Helm manifest on stdin. argv[1] is a label for messages.
Exit 0 when the invariant holds, 1 when it does not.
"""
import sys
import yaml

label = sys.argv[1] if len(sys.argv) > 1 else "render"
ENV_NAME = "GATEWAY_EVIDENCE_GAP_PATH"
# Kinds the workload can actually write. Everything else (configMap, secret,
# projected, downwardAPI) is read-only at the kubelet regardless of the mount.
WRITABLE_KINDS = {"emptyDir", "persistentVolumeClaim", "hostPath", "ephemeral"}

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
failures = []
found_gateway = False

for doc in docs:
    if doc.get("kind") != "Deployment":
        continue
    name = doc.get("metadata", {}).get("name", "")
    spec = doc.get("spec", {}).get("template", {}).get("spec", {})
    volumes = {v.get("name"): v for v in spec.get("volumes", []) or []}
    pod_sc = spec.get("securityContext") or {}
    for c in spec.get("containers", []) or []:
        env = {e.get("name"): e.get("value") for e in c.get("env", []) or []}
        if ENV_NAME not in env:
            continue
        found_gateway = True
        gap_path = env[ENV_NAME] or ""
        where = f"{name}/{c.get('name')}"
        if not gap_path.startswith("/"):
            failures.append(
                f"{where}: {ENV_NAME}={gap_path!r} is not an absolute path")
            continue

        ro_root = bool((c.get("securityContext") or {})
                       .get("readOnlyRootFilesystem"))

        covering = None
        for m in c.get("volumeMounts", []) or []:
            mp = (m.get("mountPath") or "").rstrip("/")
            if not mp:
                continue
            if gap_path == mp or gap_path.startswith(mp + "/"):
                if covering is None or len(mp) > len(
                        (covering.get("mountPath") or "").rstrip("/")):
                    covering = m
        if covering is None:
            failures.append(
                f"{where}: NO volumeMount covers {ENV_NAME}={gap_path} "
                f"(readOnlyRootFilesystem={ro_root}). The gateway opens this "
                f"path at startup; with no writable mount the store cannot be "
                f"opened, the pod still reports Ready, and every gap goes "
                f"unrecorded (T-573).")
            continue

        if covering.get("readOnly"):
            failures.append(
                f"{where}: the mount covering {gap_path} "
                f"({covering.get('mountPath')}) is readOnly:true — the store "
                f"needs to WRITE there.")

        vol_name = covering.get("name")
        vol = volumes.get(vol_name)
        if vol is None:
            failures.append(
                f"{where}: volumeMount {vol_name!r} references a volume the "
                f"pod spec does not define")
            continue
        kinds = [k for k in vol.keys() if k != "name"]
        if not any(k in WRITABLE_KINDS for k in kinds):
            failures.append(
                f"{where}: volume {vol_name!r} is of kind(s) {kinds} — none is "
                f"writable by the workload, so mounting it read-write changes "
                f"nothing.")

        # Ownership. A read-write mount of a writable kind is still unopenable
        # if the volume's ownership excludes the workload UID. Kubernetes only
        # chowns the volume when the POD securityContext sets fsGroup, so for a
        # non-root workload fsGroup is not hardening — it is what makes the
        # store openable at all.
        run_as_user = pod_sc.get("runAsUser")
        if (c.get("securityContext") or {}).get("runAsUser") is not None:
            run_as_user = (c.get("securityContext") or {}).get("runAsUser")
        non_root = bool(pod_sc.get("runAsNonRoot")) or (
            run_as_user is not None and int(run_as_user) != 0)
        if non_root and pod_sc.get("fsGroup") is None:
            failures.append(
                f"{where}: the pod runs as non-root "
                f"(runAsNonRoot={pod_sc.get('runAsNonRoot')}, "
                f"runAsUser={run_as_user}) but the pod securityContext sets NO "
                f"fsGroup. The volume backing {gap_path} then arrives owned by "
                f"root and the gateway cannot create the file in it — the mount "
                f"is present, read-write, of a writable kind, and the store is "
                f"STILL unopenable.")

if not found_gateway:
    failures.append(
        f"no container in the render declares {ENV_NAME}. Either the gateway "
        f"chart stopped setting it — in which case the process falls back to a "
        f"compiled default that NOTHING in this chart guarantees is mounted, "
        f"which is the original T-573 defect — or this script is pointed at "
        f"the wrong chart.")

if failures:
    print(f"FAIL [{label}]:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"OK [{label}]: the evidence gap path is covered by a writable, existing volume")
PYEOF

echo "=== T-573 gateway evidence gap volume invariant ==="

# ---------------------------------------------------------------------------
# A. The shipped default render (emptyDir).
# ---------------------------------------------------------------------------
render >"$TMPDIR_T573/default.yaml" || fail "default helm template failed"
python3 "$CHECKER" "default values" <"$TMPDIR_T573/default.yaml" \
  || fail "the DEFAULT gateway render cannot write its evidence gap store"

# The default must NOT provision a PVC — an opt-in feature that silently
# demands storage on every install is not opt-in.
if grep -q "name: gateway-evidence-gap" "$TMPDIR_T573/default.yaml"; then
  fail "the default render provisions an evidence-gap PVC; the default must be emptyDir"
fi
echo "OK [default]: emptyDir-backed, no PVC provisioned"

# The emptyDir must be bounded, or a gap flood eats node ephemeral storage.
python3 - "$TMPDIR_T573/default.yaml" <<'PYEOF' || exit 1
import sys, yaml
for doc in (d for d in yaml.safe_load_all(open(sys.argv[1])) if d):
    if doc.get("kind") != "Deployment":
        continue
    spec = doc.get("spec", {}).get("template", {}).get("spec", {})
    for v in spec.get("volumes") or []:
        if v.get("name") != "evidence-gap":
            continue
        ed = v.get("emptyDir")
        if ed is None:
            continue
        if not ed.get("sizeLimit"):
            print("FAIL: the evidence-gap emptyDir has no sizeLimit — a gap "
                  "flood would consume node ephemeral storage", file=sys.stderr)
            sys.exit(1)
        print(f"OK [sizeLimit]: evidence-gap emptyDir bounded at {ed['sizeLimit']}")
PYEOF

# ---------------------------------------------------------------------------
# B. The PVC-backed (opt-in persistence) render.
# ---------------------------------------------------------------------------
render --set gateway.evidenceGap.persistence.enabled=true \
       --set gateway.replicaCount=1 \
       --set gateway.hpa.enabled=false >"$TMPDIR_T573/pvc.yaml" \
  || fail "the persistence.enabled=true render failed"
python3 "$CHECKER" "persistence.enabled=true" <"$TMPDIR_T573/pvc.yaml" \
  || fail "the PVC-backed render cannot write its evidence gap store"
grep -q "name: gateway-evidence-gap" "$TMPDIR_T573/pvc.yaml" \
  || fail "persistence.enabled=true rendered no PersistentVolumeClaim — the mount would bind nothing"
echo "OK [persistence]: a PersistentVolumeClaim is rendered when persistence is enabled"

# An operator-supplied existingClaim must NOT also provision our own PVC.
render --set gateway.evidenceGap.persistence.enabled=true \
       --set gateway.evidenceGap.persistence.existingClaim=my-claim \
       --set gateway.replicaCount=1 \
       --set gateway.hpa.enabled=false >"$TMPDIR_T573/existing.yaml" \
  || fail "the existingClaim render failed"
if grep -q "name: gateway-evidence-gap" "$TMPDIR_T573/existing.yaml"; then
  fail "an existingClaim was supplied and the chart still provisions its own PVC"
fi
grep -q "claimName: my-claim" "$TMPDIR_T573/existing.yaml" \
  || fail "existingClaim was supplied but the deployment does not reference it"
echo "OK [existingClaim]: honoured, and no duplicate PVC is provisioned"

# ---------------------------------------------------------------------------
# C. Multi-replica + persistence must ABORT, with the right message.
#
# ReadWriteOnce cannot be shared, and ReadWriteMany is NOT an escape hatch:
# compaction rebuilds the whole file from ONE pod's in-memory map and renames
# it over the shared path, destroying the other replicas' records.
# ---------------------------------------------------------------------------
assert_aborts_with_token() {
  local label="$1"; shift
  if render "$@" >"$TMPDIR_T573/abort.yaml" 2>"$TMPDIR_T573/abort.err"; then
    fail "[$label] the render SUCCEEDED. A gateway that can scale past one replica must not get a shared evidence gap store; this has to fail loudly at render time."
  fi
  if ! grep -q "$ABORT_TOKEN" "$TMPDIR_T573/abort.err"; then
    echo "stderr was:" >&2
    sed 's/^/    /' "$TMPDIR_T573/abort.err" >&2
    fail "[$label] the render failed, but NOT with the evidence-gap multi-replica abort (expected the message to contain '$ABORT_TOKEN'). A check that accepts ANY failure proves only that something is broken, not that the guard fired."
  fi
  echo "OK [$label]: aborts with the evidence-gap multi-replica message"
}

assert_aborts_with_token "multi-replica via replicaCount" \
  --set gateway.evidenceGap.persistence.enabled=true \
  --set gateway.replicaCount=4

assert_aborts_with_token "multi-replica via HPA" \
  --set gateway.evidenceGap.persistence.enabled=true \
  --set gateway.hpa.enabled=true \
  --set gateway.hpa.maxReplicas=3

assert_aborts_with_token "multi-replica with an existingClaim (RWX is not an escape hatch)" \
  --set gateway.evidenceGap.persistence.enabled=true \
  --set gateway.evidenceGap.persistence.existingClaim=shared-rwx \
  --set gateway.replicaCount=4 \
  --set gateway.hpa.enabled=true \
  --set gateway.hpa.maxReplicas=3

if grep -qi "ReadWriteMany" "$TMPDIR_T573/abort.err" \
   && ! grep -qi "UNSUPPORTED\|NOT an escape hatch\|is NOT a way" "$TMPDIR_T573/abort.err"; then
  fail "the abort message mentions ReadWriteMany without marking it unsupported — it would steer operators onto the shape that silently destroys records"
fi
echo "OK [abort wording]: the message does not steer operators onto a shared RWX volume"

# The evidence-gap abort must not be the thing that BANS scaling. This kit
# already locks the gateway to one replica for an unrelated reason (the v1.0
# file-keystore is on a ReadWriteOnce PVC — charts/lucairn/templates/validators.yaml).
# So a multi-replica render WITHOUT persistence must still fail — but on the
# pre-existing v1.0 keystore lock, NOT on the evidence-gap token. If this
# assertion ever flips to the evidence-gap token, the new guard has widened
# beyond its scope and is blocking the v2.0 HA path for the wrong reason.
if render --set gateway.replicaCount=4 >"$TMPDIR_T573/multi-emptydir.yaml" 2>"$TMPDIR_T573/multi-emptydir.err"; then
  # If the v1.0 lock is ever lifted, per-pod emptyDir IS the supported
  # multi-replica shape and must still be writable.
  python3 "$CHECKER" "multi-replica emptyDir" <"$TMPDIR_T573/multi-emptydir.yaml" \
    || fail "the multi-replica emptyDir render cannot write its evidence gap store"
  echo "OK [multi-replica emptyDir]: renders and is writable (v1.0 replica lock appears to have been lifted)"
else
  if grep -q "$ABORT_TOKEN" "$TMPDIR_T573/multi-emptydir.err"; then
    fail "multi-replica WITHOUT persistence aborted on the EVIDENCE-GAP guard. Per-pod emptyDir is the supported multi-replica shape; the abort must fire only when persistence is enabled."
  fi
  grep -q "replicaCount" "$TMPDIR_T573/multi-emptydir.err" \
    || fail "multi-replica without persistence failed for an unrecognised reason: $(head -2 "$TMPDIR_T573/multi-emptydir.err")"
  echo "OK [multi-replica emptyDir]: blocked by the pre-existing v1.0 keystore replica lock, NOT by the evidence-gap guard"
fi

# ---------------------------------------------------------------------------
# D. POSITIVE CONTROL — strip the mount out of the rendered manifest and
#    require the checker to go RED. This reproduces the pre-fix tree exactly.
# ---------------------------------------------------------------------------
python3 - "$TMPDIR_T573/default.yaml" >"$TMPDIR_T573/stripped.yaml" <<'PYEOF' || exit 1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
touched = False
for doc in docs:
    if doc.get("kind") != "Deployment":
        continue
    spec = doc.get("spec", {}).get("template", {}).get("spec", {})
    for c in spec.get("containers", []) or []:
        if "GATEWAY_EVIDENCE_GAP_PATH" not in {
                e.get("name") for e in (c.get("env") or [])}:
            continue
        c["volumeMounts"] = [
            m for m in (c.get("volumeMounts") or [])
            if m.get("name") != "evidence-gap"]
        spec["volumes"] = [
            v for v in (spec.get("volumes") or [])
            if v.get("name") != "evidence-gap"]
        touched = True
if not touched:
    print("positive control found no gateway container to strip — it would be "
          "vacuous", file=sys.stderr)
    sys.exit(1)
print(yaml.safe_dump_all(docs))
PYEOF

if python3 "$CHECKER" "POSITIVE CONTROL (mount stripped)" \
     <"$TMPDIR_T573/stripped.yaml" >"$TMPDIR_T573/control.out" 2>&1; then
  cat "$TMPDIR_T573/control.out" >&2
  fail "the positive control PASSED. With the evidence-gap mount removed this check MUST go red; as written it proves nothing about the deployment."
fi
echo "OK [positive control]: removing the writable mount turns this check RED"

# ---------------------------------------------------------------------------
# E. POSITIVE CONTROL for the ownership check — drop fsGroup and require RED.
#    Without this, assertion 5 is indistinguishable from a no-op, because the
#    shipped chart happens to set fsGroup.
# ---------------------------------------------------------------------------
python3 - "$TMPDIR_T573/default.yaml" >"$TMPDIR_T573/no-fsgroup.yaml" <<'PYEOF' || exit 1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
touched = False
for doc in docs:
    if doc.get("kind") != "Deployment":
        continue
    spec = doc.get("spec", {}).get("template", {}).get("spec", {})
    if not any("GATEWAY_EVIDENCE_GAP_PATH" in {
            e.get("name") for e in (c.get("env") or [])}
            for c in (spec.get("containers") or [])):
        continue
    sc = spec.get("securityContext") or {}
    if "fsGroup" not in sc:
        print("positive control: the gateway pod already has no fsGroup — the "
              "control cannot distinguish anything", file=sys.stderr)
        sys.exit(1)
    sc.pop("fsGroup", None)
    touched = True
if not touched:
    print("positive control found no gateway pod spec", file=sys.stderr)
    sys.exit(1)
print(yaml.safe_dump_all(docs))
PYEOF

if python3 "$CHECKER" "POSITIVE CONTROL (fsGroup stripped)" \
     <"$TMPDIR_T573/no-fsgroup.yaml" >"$TMPDIR_T573/control-fsgroup.out" 2>&1; then
  cat "$TMPDIR_T573/control-fsgroup.out" >&2
  fail "the fsGroup positive control PASSED. With fsGroup removed the non-root gateway cannot create its gap file in the mounted volume, so this check MUST go red — as written it is a no-op."
fi
echo "OK [positive control]: removing fsGroup turns the ownership check RED"

echo
echo "T-573 gateway evidence gap volume: PASS"
