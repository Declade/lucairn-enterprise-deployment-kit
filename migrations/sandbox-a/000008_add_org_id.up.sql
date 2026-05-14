-- DSA-3.3: add org_id to identities for session-level org filtering.
-- Nullable so existing rows (no org membership yet) remain valid.
-- Partial index excludes soft-deleted rows, matching the convention of the
-- other identities indexes (see 000001_create_identities.up.sql).

ALTER TABLE identities ADD COLUMN org_id UUID DEFAULT NULL;
CREATE INDEX idx_identities_org_id ON identities(org_id) WHERE deleted_at IS NULL;
