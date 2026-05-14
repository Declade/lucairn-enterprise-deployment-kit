-- 000003_dek_rotation_shredding.up.sql
-- Adds per-identity DEK registry for key rotation and crypto-shredding (GDPR Art. 17).
-- Each identity's tokens are encrypted with a dedicated DEK. Destroying the DEK
-- renders all associated ciphertext irrecoverable — crypto-shredding.

CREATE TABLE IF NOT EXISTS dek_registry (
    id              BIGSERIAL PRIMARY KEY,
    identity_hmac   TEXT NOT NULL,
    version         INTEGER NOT NULL DEFAULT 1,
    encrypted_dek   BYTEA NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    rotated_at      TIMESTAMPTZ,
    shredded_at     TIMESTAMPTZ,

    -- Only one active DEK per identity at a time.
    CONSTRAINT chk_dek_status CHECK (status IN ('active', 'rotated', 'shredded'))
);

CREATE UNIQUE INDEX idx_dek_registry_identity_active
    ON dek_registry (identity_hmac)
    WHERE status = 'active';

CREATE INDEX idx_dek_registry_identity_hmac
    ON dek_registry (identity_hmac);

CREATE INDEX idx_dek_registry_status
    ON dek_registry (status);

-- Track which DEK version encrypted each token mapping row.
-- NULL means encrypted with the global DEK (pre-migration rows).
ALTER TABLE token_mappings
    ADD COLUMN dek_version INTEGER;

-- Track which DEK version encrypted each redaction map row.
ALTER TABLE redaction_maps
    ADD COLUMN dek_version INTEGER;
