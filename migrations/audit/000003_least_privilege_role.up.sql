-- Create a least-privilege application role for the audit service.
-- The default 'dsa' user created by POSTGRES_USER is a superuser,
-- which can bypass triggers and execute TRUNCATE/DROP TABLE.
-- This migration creates a restricted 'audit_app' role with only
-- the permissions needed: INSERT + SELECT on audit tables.
--
-- Note: This migration runs as the superuser (dsa). The audit service
-- should be configured to connect as 'audit_app' instead of 'dsa'
-- via the AUDIT_DB_USER environment variable.

-- Create the application role if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_app') THEN
        CREATE ROLE audit_app WITH LOGIN PASSWORD 'audit_app_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END $$;

-- Grant connect on whichever database this migration is running against.
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO audit_app', current_database());
END $$;

-- Grant schema usage
GRANT USAGE ON SCHEMA public TO audit_app;

-- audit_events: INSERT + SELECT only (append-only)
GRANT INSERT, SELECT ON audit_events TO audit_app;
GRANT USAGE, SELECT ON SEQUENCE audit_events_id_seq TO audit_app;

-- audit_checkpoints: INSERT + SELECT only
GRANT INSERT, SELECT ON audit_checkpoints TO audit_app;
GRANT USAGE, SELECT ON SEQUENCE audit_checkpoints_id_seq TO audit_app;

-- Explicitly deny destructive operations
REVOKE UPDATE, DELETE, TRUNCATE ON audit_events FROM audit_app;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_checkpoints FROM audit_app;

-- Deny DDL
REVOKE CREATE ON SCHEMA public FROM audit_app;
