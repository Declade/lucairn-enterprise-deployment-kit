-- Remove any existing duplicates deterministically before adding the
-- constraint. Keep the largest certificate payload for each request_id and
-- use timestamps / id as stable tie-breakers for equal-sized payloads.
WITH ranked AS (
  SELECT
    ctid,
    row_number() OVER (
      PARTITION BY request_id
      ORDER BY
        octet_length(certificate_raw) DESC,
        issued_at DESC,
        created_at DESC,
        certificate_id DESC
    ) AS rn
  FROM veil_certificates
)
DELETE FROM veil_certificates v
USING ranked r
WHERE v.ctid = r.ctid
  AND r.rn > 1;

-- Add unique constraint (idempotent — won't fail if already applied manually).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'veil_certificates_request_id_unique'
  ) THEN
    ALTER TABLE veil_certificates ADD CONSTRAINT veil_certificates_request_id_unique UNIQUE (request_id);
  END IF;
END$$;
