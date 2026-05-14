-- Create a restricted role for the Veil Witness application.
-- Enforces append-only semantics: INSERT + SELECT on the table,
-- UPDATE only on the attestation_raw column (external attestation data).
-- DELETE is never permitted.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'veil_app') THEN
    CREATE ROLE veil_app WITH LOGIN PASSWORD 'veil_app_password';
  END IF;
END
$$;

GRANT CONNECT ON DATABASE veil TO veil_app;
GRANT USAGE ON SCHEMA public TO veil_app;

-- Read access
GRANT SELECT ON veil_certificates TO veil_app;

-- Append-only: INSERT new certificates
GRANT INSERT ON veil_certificates TO veil_app;

-- Attestation-only UPDATE: only the attestation_raw column can be updated.
-- This is the ONE allowed mutation — external TSA/Rekor data arrives async.
GRANT UPDATE (attestation_raw) ON veil_certificates TO veil_app;

-- Explicitly deny DELETE (default, but stated for clarity in audits)
REVOKE DELETE ON veil_certificates FROM veil_app;
