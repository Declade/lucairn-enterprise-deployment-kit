-- Dashboard saved-filter persistence (Slice 6).
--
-- This migration runs against the audit-log Postgres instance
-- (postgres-audit, schema `public`) the same DB host the
-- audit_events table lives on. The role the dashboard connects as
-- (default: audit_app) gains INSERT / SELECT / UPDATE / DELETE on
-- this NEW table only — audit_events itself remains INSERT + SELECT
-- (matches the immutable-log policy at
-- /Users/marcschuelke/dual-sandbox-architecture/services/audit/migrations/
--   000003_least_privilege_role.up.sql).
--
-- Operators uncomfortable with widening audit_app's surface may
-- create a dedicated role (e.g. dashboard_app) with these grants
-- and wire LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL to a
-- separate connection string. See OPS.md § "Rotating the audit log
-- DB credentials".

CREATE TABLE IF NOT EXISTS dashboard_saved_filters (
    id          BIGSERIAL PRIMARY KEY,
    user_email  TEXT        NOT NULL,
    name        TEXT        NOT NULL,
    filter_json JSONB       NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT dashboard_saved_filters_name_length CHECK (char_length(name) BETWEEN 1 AND 100),
    CONSTRAINT dashboard_saved_filters_user_length CHECK (char_length(user_email) BETWEEN 1 AND 254),
    CONSTRAINT dashboard_saved_filters_unique UNIQUE (user_email, name)
);

CREATE INDEX IF NOT EXISTS idx_dashboard_saved_filters_user
    ON dashboard_saved_filters (user_email);

COMMENT ON TABLE dashboard_saved_filters IS
    'Per-user persisted audit-browser filter dropdowns. Slice 6 ship. '
    'audit_app role REQUIRES INSERT/SELECT/UPDATE/DELETE on this table; see OPS.md.';

-- Grants. Idempotent — re-running is safe.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_app') THEN
        EXECUTE 'GRANT INSERT, SELECT, UPDATE, DELETE ON dashboard_saved_filters TO audit_app';
        EXECUTE 'GRANT USAGE, SELECT ON SEQUENCE dashboard_saved_filters_id_seq TO audit_app';
    END IF;
END $$;
