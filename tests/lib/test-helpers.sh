#!/usr/bin/env bash
# tests/lib/test-helpers.sh — shared constants for kit test harness
#
# Source this file at the top of any test script that calls `helm template`
# or `helm lint` to ensure the veil-witness all-zeroes signing-key guard
# passes at render time without weakening the production guard itself.
#
# The guard lives at:
#   charts/lucairn/charts/veil-witness/templates/_validate.tpl:39
#   ({{ fail }} on the all-zeroes placeholder "0000…0000")
#
# TEST_SIGNING_KEY is a fixed, obviously-non-production hex constant. Its
# value is irrelevant; it just satisfies the format check (64 hex chars,
# non-zero). It MUST NOT be the all-zeroes default.
#
# Usage:
#   source "$ROOT/tests/lib/test-helpers.sh"
#   helm template lucairn charts/lucairn \
#     --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
#     ...

# Guard against double-sourcing (e.g. static_checks.sh sources this file,
# then calls test_backup_helm.sh which also sources it).  `readonly` errors
# on re-declaration in bash, so skip the assignment when already set.
[ -n "${TEST_SIGNING_KEY:-}" ] || readonly TEST_SIGNING_KEY="1111111111111111111111111111111111111111111111111111111111111111"

# Kit 2.0 final-read M2: on Linux scripts/bootstrap-sanitizer-core-mtls.sh
# refuses an ordinary user (only root can hand the keys to the image user
# 10001), bin/lucairn-init then runs that step through sudo, and doctor FAILS a
# key owned by another uid than the containers'. No container reads the keys
# in a test, so a non-root Linux test host (the PC runner in WSL) declares the
# documented mapping — the image user = this uid — exactly as an operator on
# Docker Desktop for Linux would. A case that needs the undeclared state runs
# with LUCAIRN_CONTAINER_UID= (empty). macOS needs nothing (no uid rule there).
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "0" ] && [ -z "${LUCAIRN_CONTAINER_UID:-}" ]; then
  LUCAIRN_CONTAINER_UID="$(id -u)"
  export LUCAIRN_CONTAINER_UID
fi

# ---------------------------------------------------------------------------
# T-10 (security STOP-SHIP, 2026-08-03): chart-managed passwords have NO
# working default any more.
#
# The ten slots below (across seven subcharts) used to ship a literal
# `CHANGE-ME…` placeholder as a functioning password in this public repo.  They
# now ship EMPTY, and each subchart's templates/_validate.tpl hard-fails on an
# empty value or
# on any `CHANGE-ME…`-shaped placeholder — unconditionally, at every
# `global.dsaEnv` (the umbrella default is `development`, so a production-only
# guard would never fire on the install path that actually shipped the weak
# credential).
#
# Consequence for this harness: every `helm template` / `helm lint` of the
# UMBRELLA chart that does not otherwise supply these values must pass
# HELM_TEST_SECRET_ARGS, exactly as it already passes TEST_SIGNING_KEY.
#
# Usage (umbrella):
#   source "$ROOT/tests/lib/test-helpers.sh"
#   helm template lucairn charts/lucairn \
#     "${HELM_TEST_SECRET_ARGS[@]}" \
#     --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
#
# A subchart rendered DIRECTLY (e.g. `helm template sandbox-a
# charts/lucairn/charts/sandbox-a`) does NOT take these args — the umbrella key
# prefix is absent there.  The two suites that do a direct child render
# (tests/test_wp1_s4_helm_boundary.sh, tests/test_l3_model_upgrade_gate.sh)
# carry the unprefixed value inside their own child values fixture instead,
# because those fixtures are also the base for their invalid-input variants.
#
# TEST_SECRET_VALUE is a fixed, obviously-non-production constant.  Its value
# is irrelevant to every assertion; it exists only to satisfy the guards.  It
# MUST NOT look like a placeholder (no `change-me` / `placeholder` / `todo`
# prefix) or the guards will — correctly — reject it.
#
# Overlays that legitimately leave these slots empty (values-prod.yaml sets
# `secrets.backend: vault`, so the credentials come from ExternalSecrets) do
# NOT need these args: the guards only apply to the k8s-native backend that
# actually renders the value into a Secret.
[ -n "${TEST_SECRET_VALUE:-}" ] || readonly TEST_SECRET_VALUE="kit-harness-not-a-real-secret"
# Kit 2.0: the sanitizer core's registry key must be exactly 64 hex characters
# and not all zero (sanitizer-core/templates/_helpers.tpl), so it cannot reuse
# TEST_SECRET_VALUE. Fixed, obviously-non-production constant.
[ -n "${TEST_REGISTRY_KEY:-}" ] || readonly TEST_REGISTRY_KEY="2222222222222222222222222222222222222222222222222222222222222222"

# Kit 2.0: SYNTHETIC signed digests for the sanitizer core pair (never real,
# never pulled). Compose and Helm both refuse to start the pair without the
# digests a kit release records (see the released-kit fixture below), so every
# umbrella render in this harness passes these two.
[ -n "${TEST_SANITIZER_CORE_DIGEST:-}" ] || readonly TEST_SANITIZER_CORE_DIGEST="sha256:c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"
[ -n "${TEST_SANITIZER_CORE_SIDECAR_DIGEST:-}" ] || readonly TEST_SANITIZER_CORE_SIDECAR_DIGEST="sha256:5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c"
if [ -z "${HELM_TEST_SECRET_ARGS+x}" ]; then
  HELM_TEST_SECRET_ARGS=(
    --set "admin.secrets.values.adminPassword=${TEST_SECRET_VALUE}"
    --set "audit.secrets.values.postgresPassword=${TEST_SECRET_VALUE}"
    --set "audit.secrets.values.auditAppPassword=${TEST_SECRET_VALUE}"
    --set "id-bridge.secrets.values.postgresPassword=${TEST_SECRET_VALUE}"
    --set "observability.secrets.values.grafanaAdminPassword=${TEST_SECRET_VALUE}"
    --set "sandbox-a.secrets.values.postgresPassword=${TEST_SECRET_VALUE}"
    --set "veil-witness.secrets.values.postgresPassword=${TEST_SECRET_VALUE}"
    --set "veil-witness.secrets.values.veilAppPassword=${TEST_SECRET_VALUE}"
    # Kit 2.0 (sanitizer-core sub-chart, ON by default): --set-string, because
    # the guard refuses non-string values.
    --set-string "sanitizer-core.secrets.values.registryKey=${TEST_REGISTRY_KEY}"
    --set-string "sanitizer-core.secrets.values.postgresPassword=${TEST_SECRET_VALUE}"
    # Kit 2.0 K-B fix round 1 (sol r1 P1): the pair renders only with both
    # released digests (here the synthetic pair above).
    --set-string "sanitizer-core.image.digest=${TEST_SANITIZER_CORE_DIGEST}"
    --set-string "sanitizer-core.sidecar.image.digest=${TEST_SANITIZER_CORE_SIDECAR_DIGEST}"
  )
  readonly HELM_TEST_SECRET_ARGS
fi

# ---------------------------------------------------------------------------
# Kit 2.0 K-A fix round 1 (sol r1 finding 4): the new sanitizer core and its
# model sidecar start ONLY from the signed digests a kit RELEASE records in
# image-manifest.yaml (image_digests.signed_artifacts). Until the release step
# (K-E) records them the manifest says `pending: true`: Compose refuses to
# render without both digest variables, `bin/lucairn doctor` FAILS and
# `bin/lucairn verify-images` FAILS. A test that needs a GREEN kit 2.0 install
# runs against a RELEASED-KIT FIXTURE instead: these synthetic digests (never
# real ones, never pulled) in a copy of the manifest.
# (TEST_SANITIZER_CORE_DIGEST / TEST_SANITIZER_CORE_SIDECAR_DIGEST are defined
# above HELM_TEST_SECRET_ARGS, which passes them to every umbrella render.)

# lucairn_released_kit_fixture <kit root> <dest> — <dest> becomes a kit tree
# whose image-manifest.yaml records the synthetic pair above in place of
# `pending: true`. Everything else is a plain COPY of <kit root> (about
# 11 MB without .git), so bin/lucairn and bin/lucairn-init run as the fixture
# kit and a test that edits a kit file (a "mutant" of servicenow-directory/, a
# keys/ record) edits the copy. Directories are never symlinked: `cp -R` of a
# symlinked directory copies the link, and the edit lands in the real tree
# (found by tests/test_servicenow_optin.sh section J). Writes nothing into
# <kit root>.
lucairn_released_kit_fixture() {
  local root="$1" dest="$2" e
  mkdir -p "$dest" || return 1
  for e in "$root"/* "$root"/.[!.]*; do
    [ -e "$e" ] || continue
    # Never link install state of the real tree (.secrets/, .certs/, a
    # customer.env a test generated beside the kit): the fixture gets its own.
    case "$(basename "$e")" in .git|.worktrees|.secrets|.certs|.lucairn-*|customer.env|image-manifest.yaml) continue ;; esac
    cp -Rp "$e" "$dest/" || return 1
  done
  awk -v core="$TEST_SANITIZER_CORE_DIGEST" -v side="$TEST_SANITIZER_CORE_SIDECAR_DIGEST" '
    /^  signed_artifacts:/ { in_sa = 1; print; next }
    in_sa && /^  [^ ]/ { in_sa = 0 }
    in_sa && /^    dsa-sanitizer-core:$/ { key = "core"; print; next }
    in_sa && /^    dsa-sanitizer-core-sidecar:$/ { key = "side"; print; next }
    in_sa && /^    [^ ]/ { key = "" }
    in_sa && key != "" && /^      pending:[[:space:]]*true/ { print "      digest: \"" (key == "core" ? core : side) "\""; n++; next }
    { print }
    END { if (n != 2) exit 1 }
  ' "$root/image-manifest.yaml" > "$dest/image-manifest.yaml"
}

# lucairn_use_released_kit <tmp dir> — for a suite whose doctor/init GREEN
# cases need a RELEASED kit: builds the fixture in <tmp dir>/released-kit and
# re-points the caller's ROOT at it (the real tree stays REAL_ROOT). Call it
# right after the suite creates its temp dir; the suite's own trap removes it.
lucairn_use_released_kit() {
  REAL_ROOT="${REAL_ROOT:-$ROOT}"
  lucairn_released_kit_fixture "$REAL_ROOT" "$1/released-kit" || {
    echo "released-kit fixture: could not be built from $REAL_ROOT (image-manifest.yaml no longer has the two pending core/sidecar slots?)" >&2
    exit 1
  }
  ROOT="$1/released-kit"
}
