-- Reverse 000006: drop the redaction_manifest_body column.
--
-- WARNING: applying this down migration permanently destroys any persisted
-- redaction_manifest_body values (the dedicated durability-backup column).
-- The proto-embedded copy inside certificate_raw is unaffected, so the
-- primary retrieval path via GetCertificate gRPC continues to work — but
-- defense-in-depth durability for high-PII certs is lost until a re-up.
-- Only apply this in coordinated rollback windows.
ALTER TABLE veil_certificates DROP COLUMN redaction_manifest_body;
