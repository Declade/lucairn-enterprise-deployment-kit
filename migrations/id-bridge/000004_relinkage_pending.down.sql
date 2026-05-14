-- 000004_relinkage_pending.down.sql
-- Rolls back the relinkage_pending_requests table created in 000004 up.

DROP TABLE IF EXISTS relinkage_pending_requests;
