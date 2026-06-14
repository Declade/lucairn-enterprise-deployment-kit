-- WARNING: applying this down migration permanently destroys any persisted
-- conversation_id values, which un-groups conversation reports for affected
-- certs. The proto-embedded copy inside certificate_raw is unaffected, so the
-- primary GetCertificate gRPC retrieval path still surfaces conversation_id —
-- but the dedicated column (used by the cert-list grouping query + the
-- per-conversation report fetch) is gone until a re-up. Only apply this in
-- coordinated rollback windows.
DROP INDEX IF EXISTS veil_certificates_conversation_id_idx;
ALTER TABLE veil_certificates DROP COLUMN conversation_id;
