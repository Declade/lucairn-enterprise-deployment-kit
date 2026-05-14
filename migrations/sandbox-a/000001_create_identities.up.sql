CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE identities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    vertical TEXT NOT NULL,
    email TEXT NOT NULL,
    email_hash BYTEA NOT NULL,
    password_hash TEXT NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    sensitive_fields BYTEA,
    sensitive_hash BYTEA,
    vertical_data JSONB DEFAULT '{}',
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_identities_email_vertical ON identities (email, vertical) WHERE deleted_at IS NULL;
CREATE INDEX idx_identities_email_hash ON identities (email_hash) WHERE deleted_at IS NULL;
CREATE INDEX idx_identities_vertical ON identities (vertical) WHERE deleted_at IS NULL;
CREATE INDEX idx_identities_sensitive_hash ON identities (sensitive_hash) WHERE deleted_at IS NULL;
