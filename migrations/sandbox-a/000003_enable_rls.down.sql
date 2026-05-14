DROP POLICY IF EXISTS vertical_isolation ON identities;
ALTER TABLE identities DISABLE ROW LEVEL SECURITY;
