#!/usr/bin/env bash
#
# T-10 — chart-managed passwords have no working default.
#
# THE DEFECT THIS PINS. Six sub-charts shipped the literal placeholder
# `CHANGE-ME…` as a *functioning* password in a PUBLIC repository. Nothing
# rejected it — not the chart, not Postgres, not the services — so
# `helm install` on untouched values produced a running system whose database,
# admin and Grafana credentials are readable on GitHub. Five of the six charts
# had no `fail` guard of any kind in their `secret.yaml`; the one guard that
# existed (postgres-gateway) only checked EMPTINESS, which a non-empty
# placeholder passes silently.
#
# Every case below is a POSITIVE CONTROL: it fails against the pre-change tree,
# or against a tree where the specific guard it names has been removed. A case
# that would pass either way is not evidence and does not belong in this file.
#
#   1. Each of the 8 live slots, left EMPTY -> render aborts naming that slot.
#      Whitespace-only counts as empty: the guards `trim` before checking.
#   2. Each of the 8 live slots, set to the shipped placeholder -> render
#      aborts. This is the half the old postgres-gateway pattern missed.
#      A leading space does not help: the value is trimmed before the
#      `^`-anchored placeholder match.
#   3. The guards are NOT `global.dsaEnv`-gated. The umbrella default is
#      `dsaEnv: development` (charts/lucairn/values.yaml), so a
#      production-only guard would never fire on the install path that
#      actually shipped the weak credential. Both environments are asserted.
#   4. `observability.grafana.adminPassword` — a DEAD key no template ever
#      read — is REMOVED, and its removal is loud: a values file that still
#      sets it gets an actionable error naming the live key, never silence.
#   5. NEGATIVE controls, equally load-bearing: a fully-populated install
#      still renders; the External-Secrets production overlay still renders
#      with every inline slot empty; and an external-Postgres install still
#      renders without the bundled-database passwords. A guard that breaks
#      these is a broken customer install, not a security fix.
#   6. T-490 (2026-08-04): each of the 8 live slots, set via `--set slot=true`
#      or `--set slot=12345678` -> render aborts naming the offending YAML
#      type (bool / int64). Helm's --set infers a type from the literal, so
#      the OLD `toString`-based guard silently accepted a boolean or numeric
#      value as if it were the intended string password. Positive control,
#      equally load-bearing: the SAME numeric-looking value quoted via
#      --set-string still renders — the fix rejects the TYPE, not the shape.
#   7. T-488 (2026-08-04): admin.secrets.backend=vault, with NO adminPassword
#      set at all, renders CLEANLY and produces an ExternalSecret named
#      admin-credentials (not the k8s-native Secret). Before this fix, admin
#      had no externalsecret.yaml, so a vault-backend install rendered
#      "clean" with nothing to ever populate admin-credentials.
#   8. T-490b (2026-08-04): each of the 8 live slots, set to the EXACT
#      `REPLACE_WITH_*` literal customer-values.yaml.example ships for that
#      slot -> render aborts. The old placeholder regex only matched the
#      `CHANGE-ME…` FINDING's literal, not the guard's own RATIONALE ("is
#      this value published in a public repo?") — customer-values.yaml.example
#      ships ~46 REPLACE_WITH_* slots, several of them these same passwords.
#      Positive control, equally load-bearing: a real-looking string that
#      merely CONTAINS "replace" (but is not shaped like `REPLACE[-_ ]?WITH`
#      at the start) still renders — the fix rejects the SHAPE, not the
#      substring.
#
# NOTE ON THE LITERAL. This file must never contain the placeholder string
# contiguously: the T-10 acceptance gate is
# `git grep -c "CHANGE-ME-IN-PRO""DUCTION"` returning 0 across the repository.
# The constant is therefore assembled with printf at runtime. The chart-side
# guards match a case-insensitive `change[-_ ]?me` prefix rather than the exact
# literal for the same reason, which also catches `changeme`, `CHANGE_ME_...`
# and the sandbox-b `CHANGE-ME-generate-...` shape.
#
# Requires: helm. No cluster, Docker, or network.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/lucairn"
# shellcheck source=lib/test-helpers.sh
source "$ROOT/tests/lib/test-helpers.sh"

if ! command -v helm >/dev/null 2>&1; then
  echo "default-password guard tests: skipped (helm not installed)"
  exit 0
fi

# Assembled at runtime — see NOTE ON THE LITERAL above.
PLACEHOLDER="$(printf 'CHANGE-ME-IN-%s' 'PRODUCTION')"

BASE=(
  --set global.skipPullSecretGuard=true
  --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}"
)

# The 8 slots that are actually rendered into a Kubernetes Secret. The 9th
# occurrence of the old placeholder, `observability.grafana.adminPassword`, was
# dead and is covered by its own removal case below.
GUARDED_SLOTS=(
  "admin.secrets.values.adminPassword"
  "audit.secrets.values.postgresPassword"
  "audit.secrets.values.auditAppPassword"
  "id-bridge.secrets.values.postgresPassword"
  "observability.secrets.values.grafanaAdminPassword"
  "sandbox-a.secrets.values.postgresPassword"
  "veil-witness.secrets.values.postgresPassword"
  "veil-witness.secrets.values.veilAppPassword"
)

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

# ---------------------------------------------------------------------------
# NEGATIVE control first: if the fully-populated render does not work, every
# rejection below proves nothing.
# ---------------------------------------------------------------------------
FULL_RENDER="$(mktemp)"
FULL_ERR="$(mktemp)"
if ! helm template lucairn "$CHART" "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
     >"$FULL_RENDER" 2>"$FULL_ERR"; then
  echo "FAIL: a fully-populated install must still render" >&2
  cat "$FULL_ERR" >&2
  rm -f "$FULL_RENDER" "$FULL_ERR"
  exit 1
fi
rm -f "$FULL_ERR"
echo "ok  fully-populated umbrella install renders"

# The rendered Secrets must not carry the placeholder in any form (the audit
# and veil-witness DSNs interpolate it into a connection string, so a values
# default that slipped back in would show up here even if the guard was bypassed).
if grep -q "CHANGE-ME" "$FULL_RENDER"; then
  fail "rendered manifests still contain a CHANGE-ME placeholder"
else
  echo "ok  rendered manifests carry no placeholder"
fi
rm -f "$FULL_RENDER"

# ---------------------------------------------------------------------------
# 1 + 2: empty and placeholder are BOTH refused, for every slot, in BOTH
# environments. dsaEnv is asserted explicitly because the whole finding is that
# the shipped default environment is `development`.
# ---------------------------------------------------------------------------
assert_render_refused() {
  local label="$1" expect="$2"; shift 2
  local err; err="$(mktemp)"
  if helm template lucairn "$CHART" "$@" >/dev/null 2>"$err"; then
    fail "$label: render SUCCEEDED — the guard is missing or bypassed"
    rm -f "$err"
    return
  fi
  if ! grep -Fq "$expect" "$err"; then
    fail "$label: refused, but not with the expected diagnostic ($expect): $(head -2 "$err")"
    rm -f "$err"
    return
  fi
  rm -f "$err"
  echo "ok  $label"
}

for env in development production; do
  # `dsaEnv=production` arms a PRE-EXISTING production-only guard on the
  # bundled sandbox-b Redis password, which is empty by default and would
  # abort the render before ours is reached — masking the very thing this
  # sweep asserts. Supply a disposable value solely to get past it. Same
  # rationale (and same value shape) as the sandbox-b carve-out already in
  # tests/test_enterprise_mtls_helm.sh.
  ENV_ARGS=(--set "global.dsaEnv=$env")
  if [ "$env" = production ]; then
    ENV_ARGS+=(--set-string "sandbox-b.redis.password=${TEST_SECRET_VALUE}")
  fi

  for slot in "${GUARDED_SLOTS[@]}"; do
    assert_render_refused "empty $slot (dsaEnv=$env)" "$slot is empty" \
      "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" "${ENV_ARGS[@]}" \
      --set-string "${slot}="

    assert_render_refused "placeholder $slot (dsaEnv=$env)" "$slot is still a shipped" \
      "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" "${ENV_ARGS[@]}" \
      --set-string "${slot}=${PLACEHOLDER}"
  done
done

# A bare `changeme` (the shape bin/lucairn's own doctor already rejects in the
# Compose path) must be refused too — the guard matches the placeholder SHAPE,
# not one exact string.
assert_render_refused "lowercase changeme variant" "adminPassword is still a shipped" \
  "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
  --set-string "admin.secrets.values.adminPassword=changeme123"

# ---------------------------------------------------------------------------
# 1b + 2b: WHITESPACE. Both of these rendered CLEANLY against the first revision of
# this branch (found by the pre-merge bug-hunter pass), and both defeat the
# guard with a single character:
#
#   * Go template truthiness treats ANY non-empty string as true, so an
#     untrimmed "   " sails past `if not $value` and lands verbatim in the
#     rendered Secret as the real password.
#   * The placeholder regex is `^`-anchored, so " CHANGE-ME-IN-PRO""DUCTION"
#     — the exact shipped literal with one leading space — sails past the
#     placeholder check.
#
# The guards now `trim` before BOTH checks. These two cases are the regression
# guard against that trim being dropped.
# ---------------------------------------------------------------------------
for slot in "${GUARDED_SLOTS[@]}"; do
  assert_render_refused "whitespace-only $slot" "$slot is empty" \
    "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
    --set-string "${slot}=   "

  assert_render_refused "space-prefixed placeholder $slot" "$slot is still a shipped" \
    "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
    --set-string "${slot}= ${PLACEHOLDER} "
done

# ---------------------------------------------------------------------------
# 6 (T-490, 2026-08-04): the `default "" .value | toString | trim` coercion
# cannot tell "the operator wrote a real secret" apart from "Helm's --set
# parsed a non-string YAML type". `--set $slot=true` is parsed as the
# BOOLEAN `true`, not the string "true"; the OLD guard's `toString` turned
# it into the non-empty, non-placeholder-shaped string "true" and let it
# straight through into the rendered Secret as a 4-character password. Same
# failure mode for a bare int (`--set $slot=12345678`, parsed as int64).
# Every guarded slot's requireSecretValue now runs an explicit
# `typeIs "string"` check before the coercion and names the offending kind
# in its error — these two cases are the regression guard for that check.
#
# The positive control is equally load-bearing: quoting the SAME
# numeric-looking value via --set-string keeps it a string, and the guard
# must render it exactly like any other password. A fix that also rejected
# quoted numeric strings would just be a different, more annoying bug.
# ---------------------------------------------------------------------------
assert_render_ok() {
  local label="$1"; shift
  local err; err="$(mktemp)"
  if ! helm template lucairn "$CHART" "$@" >/dev/null 2>"$err"; then
    fail "$label: render FAILED — expected a clean render: $(head -2 "$err")"
    rm -f "$err"
    return
  fi
  rm -f "$err"
  echo "ok  $label"
}

for slot in "${GUARDED_SLOTS[@]}"; do
  assert_render_refused "boolean (--set true) $slot" "must be a YAML string, but a bool was given" \
    "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
    --set "${slot}=true"

  assert_render_refused "int (--set 12345678) $slot" "must be a YAML string, but a int64 was given" \
    "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
    --set "${slot}=12345678"

  assert_render_ok "quoted numeric-looking string $slot renders (positive control)" \
    "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
    --set-string "${slot}=12345678"
done

# ---------------------------------------------------------------------------
# 8 (T-490b, 2026-08-04): the placeholder regex now also rejects the kit's
# OWN published REPLACE_WITH_* shape, not just the CHANGE-ME… shape T-10
# closed. Each case below uses the EXACT literal customer-values.yaml.example
# ships for that slot — the truest regression test, since it directly pins
# "copy the example, miss this slot" rather than a synthetic value.
# ---------------------------------------------------------------------------
replace_with_literal_for_slot() {
  case "$1" in
    admin.secrets.values.adminPassword) echo "REPLACE_WITH_ADMIN_PASSWORD" ;;
    audit.secrets.values.postgresPassword) echo "REPLACE_WITH_AUDIT_POSTGRES_PASSWORD" ;;
    audit.secrets.values.auditAppPassword) echo "REPLACE_WITH_AUDIT_APP_PASSWORD" ;;
    id-bridge.secrets.values.postgresPassword) echo "REPLACE_WITH_BRIDGE_POSTGRES_PASSWORD" ;;
    observability.secrets.values.grafanaAdminPassword) echo "REPLACE_WITH_GRAFANA_ADMIN_PASSWORD" ;;
    sandbox-a.secrets.values.postgresPassword) echo "REPLACE_WITH_SANDBOX_A_POSTGRES_PASSWORD" ;;
    veil-witness.secrets.values.postgresPassword) echo "REPLACE_WITH_VEIL_POSTGRES_PASSWORD" ;;
    veil-witness.secrets.values.veilAppPassword) echo "REPLACE_WITH_VEIL_APP_PASSWORD" ;;
    *) echo "unmapped slot: $1" >&2; return 1 ;;
  esac
}

for slot in "${GUARDED_SLOTS[@]}"; do
  literal="$(replace_with_literal_for_slot "$slot")" || { fail "no REPLACE_WITH_* literal mapped for $slot"; continue; }

  assert_render_refused "published REPLACE_WITH_* literal $slot" "$slot is still a shipped" \
    "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
    --set-string "${slot}=${literal}"
done

# Separator + case tolerance, same idiom as the "lowercase changeme variant"
# case above — the regex is `replace[-_ ]?with`, matching the SAME
# hyphen/underscore/none tolerance as `change[-_ ]?me`.
assert_render_refused "lowercase replace_with variant" "adminPassword is still a shipped" \
  "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
  --set-string "admin.secrets.values.adminPassword=replace_with_something"

assert_render_refused "hyphenated REPLACE-WITH variant" "adminPassword is still a shipped" \
  "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
  --set-string "admin.secrets.values.adminPassword=REPLACE-WITH-SOMETHING"

assert_render_refused "no-separator REPLACEWITH variant" "adminPassword is still a shipped" \
  "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
  --set-string "admin.secrets.values.adminPassword=REPLACEWITH_SOMETHING"

# Positive control: a real-looking string that CONTAINS "replace" but is not
# shaped like `REPLACE[-_ ]?WITH` at the start must still render — the fix
# rejects the SHAPE, not the substring "replace".
assert_render_ok "string containing but not starting with replace-with renders (positive control)" \
  "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
  --set-string "admin.secrets.values.adminPassword=ReplacementToken-8f3a2b91-not-a-placeholder"

# ---------------------------------------------------------------------------
# 7 (T-488, 2026-08-04): admin used to be the one credential-bearing subchart
# with NO templates/externalsecret.yaml, while templates/deployment.yaml
# mounts the admin-credentials Secret unconditionally via envFrom.secretRef.
# `--set admin.secrets.backend=vault` therefore used to render "clean" (the
# k8s-native Secret was correctly suppressed) while leaving nothing to ever
# create admin-credentials — a CreateContainerConfigError at first schedule
# that this static harness cannot reach, but the render-time SHAPE of the
# defect (no Secret, no ExternalSecret, deployment.yaml still references
# admin-credentials) is fully checkable here. admin.validateSecretValues is
# now gated on secrets.backend == k8s-native (parity with the other five
# guarded subcharts), so this must render CLEANLY with no adminPassword set
# at all, and the new externalsecret.yaml must be the thing that supplies
# admin-credentials instead of the k8s-native Secret.
# ---------------------------------------------------------------------------
ADMIN_VAULT_RENDER="$(mktemp)"
ADMIN_VAULT_ERR="$(mktemp)"
if ! helm template lucairn "$CHART" \
     --set global.skipPullSecretGuard=true \
     --set "veil-witness.secrets.values.signingKey=${TEST_SIGNING_KEY}" \
     --set "audit.secrets.values.postgresPassword=${TEST_SECRET_VALUE}" \
     --set "audit.secrets.values.auditAppPassword=${TEST_SECRET_VALUE}" \
     --set "id-bridge.secrets.values.postgresPassword=${TEST_SECRET_VALUE}" \
     --set "observability.secrets.values.grafanaAdminPassword=${TEST_SECRET_VALUE}" \
     --set "sandbox-a.secrets.values.postgresPassword=${TEST_SECRET_VALUE}" \
     --set "veil-witness.secrets.values.postgresPassword=${TEST_SECRET_VALUE}" \
     --set "veil-witness.secrets.values.veilAppPassword=${TEST_SECRET_VALUE}" \
     --set admin.secrets.backend=vault \
     --set admin.secrets.vault.path=dsa/admin \
     >"$ADMIN_VAULT_RENDER" 2>"$ADMIN_VAULT_ERR"; then
  fail "admin.secrets.backend=vault must render cleanly with no adminPassword set: $(head -3 "$ADMIN_VAULT_ERR")"
else
  echo "ok  admin.secrets.backend=vault renders with no adminPassword set (T-488 guard gating)"
fi
rm -f "$ADMIN_VAULT_ERR"

ADMIN_ES_NAME="$(awk '/^kind: ExternalSecret$/{f=1} f&&/name: admin-credentials/{print; exit}' "$ADMIN_VAULT_RENDER")"
if [ -z "$ADMIN_ES_NAME" ]; then
  fail "admin.secrets.backend=vault render is missing an ExternalSecret named admin-credentials"
else
  echo "ok  admin.secrets.backend=vault render includes an ExternalSecret named admin-credentials"
fi
for key in ADMIN_PASSWORD DSA_SERVICE_TOKEN; do
  grep -q "secretKey: $key" "$ADMIN_VAULT_RENDER" \
    || fail "admin ExternalSecret is missing secretKey: $key"
done
echo "ok  admin ExternalSecret carries both ADMIN_PASSWORD and DSA_SERVICE_TOKEN"

ADMIN_SECRET_BLOCK="$(awk '
  /^kind: Secret$/{inb=1; buf=""}
  inb{buf=buf"\n"$0}
  /^---/{ if (inb && buf ~ /name: admin-credentials/) print buf; inb=0 }
  END{ if (inb && buf ~ /name: admin-credentials/) print buf }' "$ADMIN_VAULT_RENDER")"
if [ -n "$ADMIN_SECRET_BLOCK" ]; then
  fail "admin.secrets.backend=vault must NOT also render the k8s-native admin-credentials Secret (double-write)"
else
  echo "ok  admin.secrets.backend=vault suppresses the k8s-native admin-credentials Secret"
fi
rm -f "$ADMIN_VAULT_RENDER"

# ---------------------------------------------------------------------------
# 4: the dead key's removal is loud, not silent.
# ---------------------------------------------------------------------------
assert_render_refused "removed dead key observability.grafana.adminPassword" \
  "observability.grafana.adminPassword is REMOVED" \
  "${HELM_TEST_SECRET_ARGS[@]}" "${BASE[@]}" \
  --set-string "observability.grafana.adminPassword=anything"

# ---------------------------------------------------------------------------
# 5: NEGATIVE controls for the two topologies that legitimately leave these
# slots empty. Either one breaking is a broken customer install.
# ---------------------------------------------------------------------------
PROD_ERR="$(mktemp)"
if helm template lucairn "$CHART" \
     -f "$CHART/values-prod.yaml" -f "$CHART/values-prod-site.example.yaml" \
     --set global.skipPullSecretGuard=true >/dev/null 2>"$PROD_ERR"; then
  echo "ok  External-Secrets production overlay renders with every inline slot empty"
else
  fail "production overlay (secrets.backend: vault) no longer renders: $(head -2 "$PROD_ERR")"
fi
rm -f "$PROD_ERR"

EXT_ERR="$(mktemp)"
if helm template lucairn "$CHART" "${BASE[@]}" \
     --set-string "admin.secrets.values.adminPassword=${TEST_SECRET_VALUE}" \
     --set-string "observability.secrets.values.grafanaAdminPassword=${TEST_SECRET_VALUE}" \
     --set audit.postgresql.enabled=false \
     --set-string "audit.external.databaseUrl=postgres://u:p@db.example:5432/audit" \
     --set id-bridge.postgresql.enabled=false \
     --set-string "id-bridge.external.databaseUrl=postgres://u:p@db.example:5432/bridge" \
     --set sandbox-a.postgresql.enabled=false \
     --set-string "sandbox-a.external.databaseUrl=postgres://u:p@db.example:5432/sandbox_a" \
     --set veil-witness.postgresql.enabled=false \
     --set-string "veil-witness.external.databaseUrl=postgres://u:p@db.example:5432/veil" \
     >/dev/null 2>"$EXT_ERR"; then
  echo "ok  external-Postgres install renders without the bundled-database passwords"
else
  fail "external-Postgres install no longer renders: $(head -2 "$EXT_ERR")"
fi
rm -f "$EXT_ERR"

# ---------------------------------------------------------------------------
# The acceptance gate itself: the placeholder literal is gone from the tree.
# ---------------------------------------------------------------------------
if git -C "$ROOT" grep -q "$PLACEHOLDER" -- .; then
  fail "the placeholder literal is still present in the repository:"
  git -C "$ROOT" grep -n "$PLACEHOLDER" -- . >&2
else
  echo "ok  placeholder literal absent from the tracked tree"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "default-password guard tests: FAILED" >&2
  exit 1
fi
echo "default-password guard tests: ok"
