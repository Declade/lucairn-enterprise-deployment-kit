-- Revert: drop the least-privilege application role
REVOKE ALL ON audit_events FROM audit_app;
REVOKE ALL ON audit_checkpoints FROM audit_app;
REVOKE ALL ON SEQUENCE audit_events_id_seq FROM audit_app;
REVOKE ALL ON SEQUENCE audit_checkpoints_id_seq FROM audit_app;
DO $$
BEGIN
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM audit_app', current_database());
END $$;
DROP ROLE IF EXISTS audit_app;
