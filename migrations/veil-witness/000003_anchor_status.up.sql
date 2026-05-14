-- CC-017 P3: Veil Witness anchor status tracking.
--
-- Records are inserted with anchor_status='PENDING_ANCHOR'. An async retry
-- scheduler (immediate → +30s → +5m) attempts TSA/Rekor attestation and
-- then transitions status to 'ANCHORED' or 'ANCHOR_FAILED'. This turns the
-- pre-CC-017 fire-and-forget attestor into a real Option-B async path with
-- a visible degraded state when the transparency log is unreachable.

ALTER TABLE veil_certificates
    ADD COLUMN IF NOT EXISTS anchor_status    TEXT NOT NULL DEFAULT 'PENDING_ANCHOR',
    ADD COLUMN IF NOT EXISTS anchor_attempts  INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS anchor_last_error TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS anchor_human_note TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_veil_certs_anchor_status ON veil_certificates (anchor_status);

-- Extend the append-only role so the attestor can transition anchor_status
-- and update the attempt counter / last-error / human-readable note. This is
-- status metadata, structurally parallel to the existing UPDATE grant for
-- attestation_raw. The cryptographic payload (certificate_raw) stays
-- immutable.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'veil_app') THEN
        GRANT UPDATE (anchor_status, anchor_attempts, anchor_last_error, anchor_human_note, attestation_raw)
            ON veil_certificates TO veil_app;
    END IF;
END
$$;
