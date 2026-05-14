-- Rollback: restore plaintext email column as primary
DROP INDEX IF EXISTS idx_identities_email_hash_vertical;
CREATE UNIQUE INDEX idx_identities_email_vertical ON identities (email, vertical) WHERE deleted_at IS NULL;
ALTER TABLE identities DROP COLUMN IF EXISTS email_encrypted;
