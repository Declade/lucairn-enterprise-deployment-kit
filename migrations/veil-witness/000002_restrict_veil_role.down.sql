REVOKE ALL ON veil_certificates FROM veil_app;
REVOKE USAGE ON SCHEMA public FROM veil_app;
REVOKE CONNECT ON DATABASE veil FROM veil_app;
DROP ROLE IF EXISTS veil_app;
