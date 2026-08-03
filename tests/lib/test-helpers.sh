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

# ---------------------------------------------------------------------------
# T-10 (security STOP-SHIP, 2026-08-03): chart-managed passwords have NO
# working default any more.
#
# The eight slots below (across six subcharts) used to ship a literal
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
  )
  readonly HELM_TEST_SECRET_ARGS
fi
