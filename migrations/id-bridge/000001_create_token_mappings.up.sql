CREATE TABLE IF NOT EXISTS token_mappings (
    id              BIGSERIAL PRIMARY KEY,
    identity_id     TEXT NOT NULL,
    token_value     TEXT NOT NULL UNIQUE,
    purpose         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    valid_until     TIMESTAMPTZ,
    grace_period_ends TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_token_mappings_identity ON token_mappings (identity_id);
CREATE INDEX idx_token_mappings_token ON token_mappings (token_value);
CREATE INDEX idx_token_mappings_status ON token_mappings (status);
CREATE UNIQUE INDEX idx_token_mappings_identity_purpose_active
    ON token_mappings (identity_id, purpose)
    WHERE status = 'active';

CREATE TABLE IF NOT EXISTS redaction_maps (
    id              BIGSERIAL PRIMARY KEY,
    token_value     TEXT NOT NULL,
    redaction_map   JSONB NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_token FOREIGN KEY (token_value) REFERENCES token_mappings(token_value) ON DELETE CASCADE
);

CREATE INDEX idx_redaction_maps_token ON redaction_maps (token_value);
