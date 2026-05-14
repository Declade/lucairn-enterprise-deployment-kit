-- Append-only usage tracking (one row per request, preserves audit DB constraints)
CREATE TABLE IF NOT EXISTS usage_events (
    id            BIGSERIAL PRIMARY KEY,
    api_key_hash  TEXT NOT NULL,
    month         TEXT NOT NULL,
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_usage_events_key_month ON usage_events (api_key_hash, month);

-- Grant permissions to audit_app role (INSERT + SELECT only, consistent with append-only)
GRANT INSERT, SELECT ON usage_events TO audit_app;
GRANT USAGE, SELECT ON SEQUENCE usage_events_id_seq TO audit_app;
