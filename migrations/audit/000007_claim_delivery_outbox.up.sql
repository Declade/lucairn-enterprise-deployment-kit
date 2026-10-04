-- H2 evidence durability: every pipeline-completion audit event commits its
-- witness EVENTS_RECORDED delivery intent in the SAME transaction as the
-- append-only audit row. event_id is the stable idempotency key replayed by
-- the gateway spill buffer; the row records delivery progress without ever
-- changing the audit event or its hash-chain bytes.
CREATE TABLE IF NOT EXISTS audit_claim_deliveries (
    event_id         TEXT PRIMARY KEY REFERENCES audit_events(event_id) ON DELETE RESTRICT,
    request_id       TEXT NOT NULL,
    output_scan_body BYTEA NULL,
    -- Exact signed VeilClaim bytes, persisted before first submission. This
    -- makes an ACK-lost retry consumer-idempotent without changing any
    -- claim/certificate canonical content.
    claim_raw        BYTEA NULL,
    delivery_state   TEXT NOT NULL DEFAULT 'PENDING'
        CHECK (delivery_state IN ('PENDING', 'DELIVERING', 'DELIVERED', 'PARKED')),
    delivery_attempt_id TEXT NULL,
    delivery_lease_until TIMESTAMPTZ NULL,
    attempt_count    INTEGER NOT NULL DEFAULT 0,
    last_error       TEXT NOT NULL DEFAULT '',
    delivered_at     TIMESTAMPTZ NULL,
    parked_at       TIMESTAMPTZ NULL,
    next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_claim_deliveries_pending
    ON audit_claim_deliveries (next_attempt_at)
    WHERE delivery_state = 'PENDING';

CREATE INDEX IF NOT EXISTS idx_audit_claim_deliveries_lease
    ON audit_claim_deliveries (delivery_lease_until)
    WHERE delivery_state = 'DELIVERING';

-- audit_app already holds table-level SELECT/INSERT on the audit schema. The
-- delivery-state transition is intentionally the sole mutable outbox surface.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'audit_app') THEN
    GRANT SELECT, INSERT ON audit_claim_deliveries TO audit_app;
    GRANT UPDATE (claim_raw, delivery_state, delivery_attempt_id, delivery_lease_until, attempt_count, last_error, delivered_at, parked_at, next_attempt_at, updated_at)
      ON audit_claim_deliveries TO audit_app;
  END IF;
END
$$;
