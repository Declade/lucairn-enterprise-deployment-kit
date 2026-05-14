CREATE TABLE IF NOT EXISTS audit_events (
    id              BIGSERIAL PRIMARY KEY,
    event_id        TEXT NOT NULL UNIQUE,
    event_type      TEXT NOT NULL,
    source_service  TEXT NOT NULL,
    actor           TEXT NOT NULL,
    timestamp       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    previous_event_hash TEXT NOT NULL DEFAULT '',
    event_hash      TEXT NOT NULL,
    payload         BYTEA,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_events_timestamp ON audit_events (timestamp);
CREATE INDEX idx_audit_events_event_type ON audit_events (event_type);
CREATE INDEX idx_audit_events_source_service ON audit_events (source_service);
CREATE INDEX idx_audit_events_actor ON audit_events (actor);

COMMENT ON TABLE audit_events IS 'Append-only audit log. Application user must have INSERT + SELECT only.';
