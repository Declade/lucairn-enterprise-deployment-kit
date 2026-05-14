-- 000002_bridge_envelope_encryption.up.sql
-- Adds encrypted column variants for identity_id and redaction_map.
-- When encryption is enabled, plaintext columns are NULL and encrypted columns are populated.
-- When encryption is disabled, the reverse is true. A single deployment uses one mode.

ALTER TABLE token_mappings
    ADD COLUMN identity_id_encrypted BYTEA,
    ADD COLUMN identity_id_hmac TEXT;

ALTER TABLE token_mappings ALTER COLUMN identity_id DROP NOT NULL;

ALTER TABLE redaction_maps
    ADD COLUMN redaction_map_encrypted BYTEA;

ALTER TABLE redaction_maps ALTER COLUMN redaction_map DROP NOT NULL;

CREATE INDEX idx_token_mappings_identity_hmac
    ON token_mappings (identity_id_hmac)
    WHERE identity_id_hmac IS NOT NULL;

CREATE UNIQUE INDEX idx_token_mappings_hmac_purpose_active
    ON token_mappings (identity_id_hmac, purpose)
    WHERE status = 'active' AND identity_id_hmac IS NOT NULL;
