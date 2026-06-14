-- 000005_accumulator_durability.down.sql
-- Rolls back the witness accumulator durability tables created in 000005 up.
-- Grants are dropped implicitly with the tables.

DROP TABLE IF EXISTS witness_pending_claims;
DROP TABLE IF EXISTS witness_tombstones;
