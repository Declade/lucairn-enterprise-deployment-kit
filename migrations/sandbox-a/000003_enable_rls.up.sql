ALTER TABLE identities ENABLE ROW LEVEL SECURITY;

-- Policy: rows visible only when vertical matches session variable.
-- If app.current_vertical is not set, no rows are visible (safe default).
CREATE POLICY vertical_isolation ON identities
    USING (vertical = current_setting('app.current_vertical', true));

-- Force RLS even for table owner (defense-in-depth)
ALTER TABLE identities FORCE ROW LEVEL SECURITY;
