-- 000002_bridge_envelope_encryption.down.sql
-- Guard: refuse to roll back if encrypted rows exist.

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM token_mappings WHERE identity_id IS NULL LIMIT 1) THEN
        RAISE EXCEPTION 'Cannot roll back: encrypted rows exist with identity_id = NULL. Decrypt all rows first.';
    END IF;
END $$;

ALTER TABLE token_mappings ALTER COLUMN identity_id SET NOT NULL;
ALTER TABLE redaction_maps ALTER COLUMN redaction_map SET NOT NULL;

DROP INDEX IF EXISTS idx_token_mappings_hmac_purpose_active;
DROP INDEX IF EXISTS idx_token_mappings_identity_hmac;

ALTER TABLE redaction_maps DROP COLUMN IF EXISTS redaction_map_encrypted;
ALTER TABLE token_mappings DROP COLUMN IF EXISTS identity_id_hmac;
ALTER TABLE token_mappings DROP COLUMN IF EXISTS identity_id_encrypted;
