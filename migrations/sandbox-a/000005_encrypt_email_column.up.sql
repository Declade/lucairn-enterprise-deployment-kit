-- Migration: Encrypt email column
-- The email column currently stores plaintext. After this migration,
-- email will be stored as BYTEA (AES-256-GCM encrypted) and all lookups
-- use the existing email_hash blind index.
--
-- NOTE: This is a schema-only migration. Existing rows must be backfilled
-- by the application (encrypt plaintext email, write to email_encrypted,
-- then NULL out email). A backfill command should be run before dropping
-- the old column.

-- Step 1: Add encrypted email column
ALTER TABLE identities ADD COLUMN email_encrypted BYTEA;

-- Step 2: Drop the plaintext unique index (lookups now use email_hash)
DROP INDEX IF EXISTS idx_identities_email_vertical;

-- Step 3: Add unique constraint on blind index per vertical instead
CREATE UNIQUE INDEX idx_identities_email_hash_vertical ON identities (email_hash, vertical) WHERE deleted_at IS NULL;
