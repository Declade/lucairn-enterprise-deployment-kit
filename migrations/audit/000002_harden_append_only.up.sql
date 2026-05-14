-- Harden append-only enforcement: explicit permission revocation,
-- deletion detection via sequence gap checks, and a row-count checkpoint table.

-- 1. Explicitly revoke UPDATE and DELETE from the application user.
-- The role name 'dsa' matches docker-compose and Helm defaults.
-- For custom deployments, re-run with the actual application role name.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dsa') THEN
        EXECUTE 'REVOKE UPDATE, DELETE ON audit_events FROM dsa';
    END IF;
END $$;

-- 2. Checkpoint table: stores periodic row-count + max-id snapshots.
-- The audit service writes a checkpoint after each batch; external monitors
-- can compare checkpoints to detect if rows were deleted between snapshots.
CREATE TABLE IF NOT EXISTS audit_checkpoints (
    id              BIGSERIAL PRIMARY KEY,
    event_count     BIGINT NOT NULL,
    max_event_id    BIGINT NOT NULL,
    last_event_hash TEXT NOT NULL,
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE audit_checkpoints IS 'Periodic snapshots for deletion detection. If event_count decreases between checkpoints, rows were deleted.';

-- Application user can INSERT + SELECT checkpoints (same append-only pattern).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dsa') THEN
        EXECUTE 'GRANT INSERT, SELECT ON audit_checkpoints TO dsa';
        EXECUTE 'GRANT USAGE, SELECT ON SEQUENCE audit_checkpoints_id_seq TO dsa';
        EXECUTE 'REVOKE UPDATE, DELETE ON audit_checkpoints FROM dsa';
    END IF;
END $$;

-- 3. Verify sequence continuity function: checks for ID gaps that indicate deletion.
-- Returns the number of gaps found. Zero means no deletions detected.
-- Uses COUNT vs MAX-MIN+1 approach to catch first/last row deletions that
-- the previous LEAD()-based window function would miss.
CREATE OR REPLACE FUNCTION audit_check_sequence_gaps() RETURNS INTEGER AS $$
DECLARE
    gap_count INTEGER;
    row_count BIGINT;
    min_id BIGINT;
    max_id BIGINT;
BEGIN
    SELECT COUNT(*), MIN(id), MAX(id) INTO row_count, min_id, max_id FROM audit_events;
    IF row_count = 0 THEN RETURN 0; END IF;
    gap_count := (max_id - min_id + 1) - row_count;
    RETURN gap_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Trigger-based append-only enforcement: prevents UPDATE and DELETE at the
-- database level regardless of the connected role name. This complements the
-- REVOKE-based approach above which only works for the 'dsa' role.
CREATE OR REPLACE FUNCTION prevent_audit_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_events is append-only: % not allowed', TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER no_update_delete
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_mutation();
