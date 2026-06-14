-- WARNING: applying this down migration permanently destroys any persisted
-- output_scan_body values (the dedicated durability-backup column). The
-- proto-embedded copy inside certificate_raw is unaffected, so the primary
-- retrieval path via GetCertificate gRPC continues to work — but defense-in-
-- depth durability for the output-provenance attestation is lost until a
-- re-up. Only apply this in coordinated rollback windows.
ALTER TABLE veil_certificates DROP COLUMN output_scan_body;
