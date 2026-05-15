#!/usr/bin/env sh
#
# render-migrations.sh — copy /migrations-src/<tree> to /migrations-rendered/<tree>,
# rendering any *.up.sql.tmpl through targeted sed substitution into *.up.sql so
# the role-password CREATE ROLE statements get the runtime password instead of
# the historical hardcoded literal ('audit_app_password' / 'veil_app_password').
#
# Why: migrations/audit/000003_least_privilege_role.up.sql and
# migrations/veil-witness/000002_restrict_veil_role.up.sql historically shipped
# hardcoded passwords. Operators randomizing AUDIT_APP_PASSWORD / VEIL_APP_PASSWORD
# in customer.env (good hygiene) then hit
#   pq: password authentication failed for user "audit_app" (28P01)
# because the role's password stayed at the migration literal while the
# application connection string used the customer.env value. This script bridges
# the gap: sed writes the templated SQL with the runtime password into a named
# volume that the migrate/migrate runner mounts read-only.
#
# Why sed instead of envsubst: keeps the prep image dependency-free (busybox
# sed only). envsubst lives in the gettext apk package; alpine doesn't ship
# it by default and we don't want to require network access at deploy time.
# We only need exactly two substitutions, both well-bounded literal strings.
#
# Invoked by the prep-migrations service in docker-compose.customer.yml. Should
# not be invoked directly outside of the compose flow.

set -eu

SRC_ROOT="${SRC_ROOT:-/migrations-src}"
OUT_ROOT="${OUT_ROOT:-/migrations-rendered}"

if [ -z "${AUDIT_APP_PASSWORD:-}" ]; then
  echo "render-migrations: AUDIT_APP_PASSWORD is empty — refusing to render with an empty role password" >&2
  exit 2
fi
if [ -z "${VEIL_APP_PASSWORD:-}" ]; then
  echo "render-migrations: VEIL_APP_PASSWORD is empty — refusing to render with an empty role password" >&2
  exit 2
fi

# Reject single quotes in passwords — they would break the SQL string and could
# allow SQL-injection via the migration. Customer-side passwords should be
# alphanumeric-plus-special-character random tokens; if the operator chooses a
# password with a single quote, fail loudly here rather than silently corrupt
# the migration.
case "${AUDIT_APP_PASSWORD}" in
  *\'*) echo "render-migrations: AUDIT_APP_PASSWORD contains a single quote — refusing" >&2; exit 3 ;;
esac
case "${VEIL_APP_PASSWORD}" in
  *\'*) echo "render-migrations: VEIL_APP_PASSWORD contains a single quote — refusing" >&2; exit 3 ;;
esac

# Also reject backslashes for the same reason (SQL string-escape boundary).
case "${AUDIT_APP_PASSWORD}" in
  *\\*) echo "render-migrations: AUDIT_APP_PASSWORD contains a backslash — refusing" >&2; exit 3 ;;
esac
case "${VEIL_APP_PASSWORD}" in
  *\\*) echo "render-migrations: VEIL_APP_PASSWORD contains a backslash — refusing" >&2; exit 3 ;;
esac

for tree in audit veil-witness id-bridge sandbox-a; do
  src_dir="${SRC_ROOT}/${tree}"
  out_dir="${OUT_ROOT}/${tree}"
  if [ ! -d "${src_dir}" ]; then
    continue
  fi
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"

  for f in "${src_dir}"/*; do
    [ -f "${f}" ] || continue
    base="$(basename "${f}")"
    case "${base}" in
      *.up.sql.tmpl|*.down.sql.tmpl)
        out_base="${base%.tmpl}"
        # Only substitute these two placeholders; everything else (including
        # PostgreSQL dollar-quoting like DO $$ ... $$) is passed through.
        sed -e "s|\${AUDIT_APP_PASSWORD}|${AUDIT_APP_PASSWORD}|g" \
            -e "s|\${VEIL_APP_PASSWORD}|${VEIL_APP_PASSWORD}|g" \
            "${f}" > "${out_dir}/${out_base}"
        ;;
      *)
        cp "${f}" "${out_dir}/${base}"
        ;;
    esac
  done

  echo "render-migrations: ${tree} rendered to ${out_dir}" >&2
done

echo "render-migrations: done" >&2
