CREATE TABLE request_identities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id TEXT NOT NULL,
    vertical TEXT NOT NULL,
    request_id TEXT NOT NULL,
    field_name TEXT NOT NULL,
    field_value_encrypted BYTEA NOT NULL,
    field_value_hash BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_request_identities_customer
    ON request_identities(customer_id, vertical);

CREATE UNIQUE INDEX idx_request_identities_dedup
    ON request_identities(customer_id, vertical, field_name, field_value_hash);

ALTER TABLE request_identities ENABLE ROW LEVEL SECURITY;

CREATE POLICY request_identities_isolation ON request_identities
    USING (vertical = current_setting('app.current_vertical', true));
