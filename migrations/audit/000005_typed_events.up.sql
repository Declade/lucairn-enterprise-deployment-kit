-- Add typed event support to audit_events table.
-- Existing flat-payload events continue working unchanged.
ALTER TABLE audit_events
  ADD COLUMN IF NOT EXISTS request_id TEXT,
  ADD COLUMN payload_type TEXT NOT NULL DEFAULT 'FLAT_JSON',
  ADD COLUMN payload_bytes BYTEA;

CREATE INDEX idx_audit_events_payload_type ON audit_events(payload_type);
CREATE INDEX idx_audit_events_request_id ON audit_events(request_id)
  WHERE request_id IS NOT NULL;

-- Grant permissions to least-privilege role
GRANT SELECT ON audit_events TO audit_app;
