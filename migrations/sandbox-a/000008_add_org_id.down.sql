-- DSA-3.3: revert org_id addition. Drop index first (FK-style ordering),
-- then drop the column. Both IF EXISTS to make the down migration safe to
-- run on a partially-applied state.

DROP INDEX IF EXISTS idx_identities_org_id;
ALTER TABLE identities DROP COLUMN IF EXISTS org_id;
