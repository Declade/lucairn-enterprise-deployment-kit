-- 000003_dek_rotation_shredding.down.sql
-- Guard: refuse to roll back if per-identity DEKs are in use.

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM token_mappings WHERE dek_version IS NOT NULL LIMIT 1) THEN
        RAISE EXCEPTION 'Cannot roll back: rows exist with dek_version set. Re-encrypt with global DEK first.';
    END IF;
END $$;

ALTER TABLE redaction_maps DROP COLUMN IF EXISTS dek_version;
ALTER TABLE token_mappings DROP COLUMN IF EXISTS dek_version;

DROP INDEX IF EXISTS idx_dek_registry_status;
DROP INDEX IF EXISTS idx_dek_registry_identity_hmac;
DROP INDEX IF EXISTS idx_dek_registry_identity_active;
DROP TABLE IF EXISTS dek_registry;
