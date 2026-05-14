DROP INDEX IF EXISTS idx_audit_events_request_id;
DROP INDEX IF EXISTS idx_audit_events_payload_type;
ALTER TABLE audit_events
  DROP COLUMN IF EXISTS payload_bytes,
  DROP COLUMN IF EXISTS payload_type,
  DROP COLUMN IF EXISTS request_id;
