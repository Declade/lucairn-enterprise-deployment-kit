CREATE TABLE IF NOT EXISTS veil_certificates (
    certificate_id   TEXT PRIMARY KEY,
    request_id       TEXT NOT NULL UNIQUE,
    customer_id      TEXT NOT NULL DEFAULT '',
    issued_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    verdict          TEXT NOT NULL,
    protocol_version INTEGER NOT NULL DEFAULT 1,
    certificate_raw  BYTEA NOT NULL,
    attestation_raw  BYTEA,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_veil_certs_request_id ON veil_certificates (request_id);
CREATE INDEX idx_veil_certs_customer_issued ON veil_certificates (customer_id, issued_at);
