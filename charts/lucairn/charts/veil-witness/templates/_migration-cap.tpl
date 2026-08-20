{{- /*
  ⚠️ THIS FILE IS DUPLICATED, BYTE-FOR-BYTE, INTO ALL FOUR DB-BEARING SUBCHARTS:
     charts/lucairn/charts/{veil-witness,audit,id-bridge,sandbox-a}/templates/_migration-cap.tpl

  Why not one shared copy in the umbrella's templates/? Because Helm only makes
  a chart's own templates available when that chart is rendered DIRECTLY, and
  this repo's harness renders sandbox-a as a standalone child chart
  (tests/test_wp1_s4_helm_boundary.sh, tests/test_l3_model_upgrade_gate.sh). An
  umbrella-only helper makes those renders fail with
  `error calling include: template ... not defined`. Sub-charts also package
  independently, so a customer rendering one on its own would hit the same wall.

  The four copies are IDENTICAL on purpose — Go templates allow a `define` to be
  redefined, and identical content makes the umbrella render (which loads all
  four) unambiguous. `tests/test_migration_version_cap.sh` asserts byte-identity
  and fails if anyone edits one copy without the others.
*/ -}}

{{- /*
  Migration version cap (board T-350).

  ── THE DEFECT THIS CLOSES ─────────────────────────────────────────────────

  Every DB-bearing subchart used to run an OPEN-ENDED migration:

      migrate -path=/shared/migrations -database="$DATABASE_URL" up

  `up` with no argument applies EVERY migration file it finds, in order, with
  no ceiling. The files come from the SERVICE IMAGE's baked-in /migrations
  tree (the init container does `cp -r /migrations /shared/migrations`) — NOT
  from this repository's `migrations/` mirror. So the set of schema objects a
  kit install creates is decided by whatever image tag the operator happens to
  pin, and the kit has no say in it at all.

  That is the T-350 finding: the veil-witness image carries migrations
  `000011_certificate_persistence_outbox` and `000012_witness_claim_receipts`,
  which create tables holding un-redacted personal data, and for which NO
  deletion / retention path exists in this kit. A routine image-tag bump was
  sufficient to start creating those tables at a customer site, silently, with
  nothing in the chart or the release process positioned to notice.

  ── THE MECHANISM ──────────────────────────────────────────────────────────

  The job now migrates to an explicitly PINNED TARGET VERSION and never
  further:

    * `<subchart>.migrations.targetVersion` — the highest migration version
      this kit release has reviewed for personal-data retention impact. It is
      a target VERSION, not a count.

    * A per-chart `knownSafeMax` ceiling is baked into the chart template (not
      into values), so raising `targetVersion` past what this release reviewed
      is refused at render time. Bumping the ceiling is a deliberate code
      change gated by docs/RELEASING.md § "Migration review".

    * `<subchart>.migrations.unsafeAcknowledgeOpenEndedMigrateUp` — the single,
      deliberately-ugly escape hatch. Setting it to `true` restores the old
      open-ended `migrate up` AND bypasses the ceiling. Nothing else does.

  ── FAIL-CLOSED ────────────────────────────────────────────────────────────

  An unset, empty, zero, negative, or non-numeric `targetVersion` does NOT
  fall back to `up`. It fails the Helm render (this file's validate helper)
  and, if it somehow reaches the pod, the in-container guard exits non-zero
  having applied nothing. The same is true of a dirty `schema_migrations`
  ledger and of an unparseable `migrate version` output.

  ── NEVER MIGRATES DOWN ────────────────────────────────────────────────────

  `migrate goto <V>` migrates in EITHER direction — it will run `.down.sql`
  files when the database is ahead of V. That would be data loss on a customer
  site that had already applied more migrations under an older kit. The
  in-container guard therefore reads the current version first and exits 0
  without calling `goto` whenever `current >= target`. `goto` is only ever
  reached on the strictly-upward path.
*/ -}}

{{- /*
  lucairn.migrationCap.validate

  Render-time guard. Invoke from each migration Job template BEFORE the
  manifest body. Emits nothing on success.

  Arguments (dict):
    path         — values path prefix for messages, e.g. "veil-witness"
    migrations   — the subchart's .Values.migrations (may be nil)
    knownSafeMax — int; highest version this release reviewed for retention
*/ -}}
{{- define "lucairn.migrationCap.validate" -}}
{{- $mig := .migrations | default dict -}}
{{- $unsafe := $mig.unsafeAcknowledgeOpenEndedMigrateUp | default false -}}
{{- if not (kindIs "bool" $unsafe) -}}
{{- fail (printf "[%s] %s.migrations.unsafeAcknowledgeOpenEndedMigrateUp must be a YAML boolean, but a %s was given. Use --set \"%s.migrations.unsafeAcknowledgeOpenEndedMigrateUp=true\" (Helm parses that as a boolean) — a quoted string would be truthy in some template contexts and falsy in others, which is exactly the ambiguity a data-retention escape hatch must not have." .path .path (kindOf $unsafe) .path) -}}
{{- end -}}
{{- if not $unsafe -}}
{{- $raw := $mig.targetVersion -}}
{{- if kindIs "invalid" $raw -}}
{{- fail (printf "[%s] %s.migrations.targetVersion is not set. This chart refuses to run an open-ended `migrate up`: the set of tables an install creates would be decided by whichever service image tag is pinned, including migrations this kit release has never reviewed for personal-data retention impact (board T-350). Set it to the highest migration version this release reviewed (this chart's ceiling is %d), or — if you have genuinely reviewed and accepted every migration in your image — set %s.migrations.unsafeAcknowledgeOpenEndedMigrateUp=true. See docs/RELEASING.md § \"Migration review\"." .path .path (.knownSafeMax | int) .path) -}}
{{- end -}}
{{- $target := $raw | int -}}
{{- if lt $target 1 -}}
{{- fail (printf "[%s] %s.migrations.targetVersion must be a positive integer migration version, got %v. It is a target VERSION (as in `migrate goto N`), not a count and not a boolean. A zero/negative/non-numeric value applies NOTHING and fails the render rather than silently degrading to an open-ended `migrate up` (board T-350)." .path .path $raw) -}}
{{- end -}}
{{- if gt $target (.knownSafeMax | int) -}}
{{- fail (printf "[%s] %s.migrations.targetVersion=%d exceeds this kit release's reviewed ceiling of %d. Migrations above the ceiling have NOT been reviewed for personal-data retention impact and this kit ships no deletion path for the tables some of them create (board T-350 — the veil-witness 000011 certificate-persistence-outbox / 000012 claim-receipts class). Raising the ceiling is a deliberate code change gated by docs/RELEASING.md § \"Migration review\". If you have reviewed every migration in your image yourself and accept the retention consequences, set %s.migrations.unsafeAcknowledgeOpenEndedMigrateUp=true instead." .path .path $target (.knownSafeMax | int) .path) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
  lucairn.migrationCap.script

  The wait-and-migrate container body. Invoke with `| nindent <n>` under the
  `command: [sh, -c, |]` block of a migration Job.

  Arguments (dict):
    path         — values path prefix for messages, e.g. "veil-witness"
    waitHost     — Postgres service DNS name to wait on
    migrations   — the subchart's .Values.migrations (may be nil)
    knownSafeMax — int; highest version this release reviewed for retention
*/ -}}
{{- define "lucairn.migrationCap.script" -}}
{{- $mig := .migrations | default dict -}}
{{- $unsafe := $mig.unsafeAcknowledgeOpenEndedMigrateUp | default false -}}
{{- $target := $mig.targetVersion | default 0 | int -}}
set -eu
echo "Waiting for PostgreSQL..."
until nc -z {{ .waitHost }} 5432; do
  sleep 2
done
echo "PostgreSQL ready."

# ── T-350 migration version cap ────────────────────────────────────────────
# Rendered from {{ .path }}.migrations (chart ceiling: {{ .knownSafeMax | int }}).
MIGRATE_PATH=/shared/migrations
highest_on_disk="$(ls "$MIGRATE_PATH" 2>/dev/null | grep -E '^[0-9]{6}_.*\.up\.sql$' | cut -c1-6 | sort -n | tail -1 | sed 's/^0*//')"
[ -n "$highest_on_disk" ] || highest_on_disk=0
{{ if $unsafe -}}
# ⚠️ OPEN-ENDED BRANCH — rendered ONLY because
# {{ .path }}.migrations.unsafeAcknowledgeOpenEndedMigrateUp=true.
# Without that value this block does not exist in the manifest at all: the
# string `up` is absent from the rendered command, so no runtime condition,
# env var, or ConfigMap edit can reach it.
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
echo "!! UNSAFE OVERRIDE ACTIVE" >&2
echo "!! {{ .path }}.migrations.unsafeAcknowledgeOpenEndedMigrateUp=true" >&2
echo "!! Running OPEN-ENDED 'migrate up'. EVERY migration present in the" >&2
echo "!! service image will be applied, including migrations this kit" >&2
echo "!! release never reviewed for personal-data retention impact, and" >&2
echo "!! for some of which this kit ships NO deletion path (board T-350)." >&2
echo "!! Image ships migrations up to version ${highest_on_disk}." >&2
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
exec migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" up
{{- else }}
MIGRATE_TARGET_VERSION='{{ $target }}'

# Fail-closed: anything unparseable applies NOTHING. It never degrades to `up`.
case "$MIGRATE_TARGET_VERSION" in
  ''|*[!0-9]*)
    echo "FATAL: {{ .path }}.migrations.targetVersion is not a positive integer (got '${MIGRATE_TARGET_VERSION}'). Applying NO migrations. See docs/RELEASING.md § Migration review (T-350)." >&2
    exit 90 ;;
esac
if [ "$MIGRATE_TARGET_VERSION" -lt 1 ]; then
  echo "FATAL: {{ .path }}.migrations.targetVersion must be >= 1 (got '${MIGRATE_TARGET_VERSION}'). Applying NO migrations. See docs/RELEASING.md § Migration review (T-350)." >&2
  exit 90
fi

# `migrate version` writes to stdout or stderr depending on build/verbosity and
# exits non-zero on a fresh database, so capture both streams and never let it
# trip `set -e`.
ver_out="$(migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" version 2>&1 || true)"
# Measured: on a URL-parse error `migrate version` echoes the DSN back verbatim,
# password and all (e.g. `parse "postgres://veil:SUPER SECRET PW@host:5432/db":
# net/url: invalid userinfo`). Every branch below quotes $ver_out into a log
# line, so scrub any `scheme://user:pass@` credential before it can be printed.
ver_out="$(printf '%s' "$ver_out" | sed 's#://[^@]*@#://***:***@#g')"

case "$ver_out" in
  *dirty*|*Dirty*|*DIRTY*)
    echo "FATAL: schema_migrations is DIRTY ('${ver_out}'). A previous migration failed half-way. Applying NO migrations — resolve the dirty state deliberately (migrate force <version>) before re-running. (T-350)" >&2
    exit 92 ;;
esac

current="$(printf '%s' "$ver_out" | tr -d '[:space:]')"
case "$current" in
  ''|*[!0-9]*)
    case "$ver_out" in
      *"no migration"*|*"No migration"*|*"nil version"*) current=0 ;;
      *)
        echo "FATAL: cannot determine the current schema version; 'migrate version' said: '${ver_out}'. Applying NO migrations. (T-350)" >&2
        exit 93 ;;
    esac ;;
  *)
    current="$(printf '%s' "$current" | sed 's/^0*//')"
    [ -n "$current" ] || current=0 ;;
esac

if [ "$highest_on_disk" -gt "$MIGRATE_TARGET_VERSION" ]; then
  echo "NOTICE: the service image ships migrations up to version ${highest_on_disk}, but this kit release is capped at ${MIGRATE_TARGET_VERSION}. Versions above the cap will NOT be applied — that is deliberate (board T-350). Raising the cap is a kit-release decision that requires reviewing their personal-data retention impact first: see docs/RELEASING.md § Migration review." >&2
fi

if [ "$current" -ge "$MIGRATE_TARGET_VERSION" ]; then
  echo "Schema is at version ${current}; cap is ${MIGRATE_TARGET_VERSION}. Nothing to apply. This job NEVER migrates down."
  exit 0
fi

if [ "$MIGRATE_TARGET_VERSION" -gt "$highest_on_disk" ]; then
  echo "FATAL: cap is ${MIGRATE_TARGET_VERSION} but the service image's migrations directory only reaches version ${highest_on_disk}. Chart and image disagree — applying NO migrations rather than guessing. Pin an image that carries the migrations this chart expects, or lower {{ .path }}.migrations.targetVersion. (T-350)" >&2
  exit 94
fi

echo "Applying migrations ${current} -> ${MIGRATE_TARGET_VERSION} (capped; open-ended migration is disabled — T-350)."
exec migrate -path="$MIGRATE_PATH" -database="$DATABASE_URL" goto "$MIGRATE_TARGET_VERSION"
{{- end }}
{{- end -}}
