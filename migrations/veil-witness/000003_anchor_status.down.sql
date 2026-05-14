-- CC-017 P3 rollback: drop the anchor_status columns and revert the role
-- grant to the pre-P3 attestation_raw-only shape.

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'veil_app') THEN
        REVOKE UPDATE (anchor_status, anchor_attempts, anchor_last_error, anchor_human_note)
            ON veil_certificates FROM veil_app;
    END IF;
END
$$;

DROP INDEX IF EXISTS idx_veil_certs_anchor_status;

ALTER TABLE veil_certificates
    DROP COLUMN IF EXISTS anchor_human_note,
    DROP COLUMN IF EXISTS anchor_last_error,
    DROP COLUMN IF EXISTS anchor_attempts,
    DROP COLUMN IF EXISTS anchor_status;
