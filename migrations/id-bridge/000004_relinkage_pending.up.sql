-- 000004_relinkage_pending.up.sql
-- Adds postgres-backed persistence for four-eyes relinkage pending requests.
-- TOB-S001 closure: in-memory loss on bridge restart = silent four-eyes
-- bypass. Every pending request must survive restarts so that the second
-- principal's ApproveRelinkage call can find and resolve it.
--
-- Schema preserves the full request envelope (token_value, legal_basis,
-- case_reference, requester_id/role, jurisdiction, ttl_minutes) plus the
-- resolution audit trail (resolved/approved/approver_id/approver_role/
-- denial_reason/resolved_at). The partial index on unresolved+expires_at
-- makes the pending-list lookup and expiry sweep cheap even with millions
-- of historical resolved rows.

CREATE TABLE IF NOT EXISTS relinkage_pending_requests (
    request_id        TEXT PRIMARY KEY,
    token_value       TEXT NOT NULL,
    legal_basis       TEXT NOT NULL,
    case_reference    TEXT,
    requester_id      TEXT NOT NULL,
    requester_role    TEXT NOT NULL,
    jurisdiction      TEXT,
    ttl_minutes       INT NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    review_due_by     TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved          BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_at       TIMESTAMPTZ,
    approved          BOOLEAN,
    approver_id       TEXT,
    approver_role     TEXT,
    denial_reason     TEXT
);

CREATE INDEX IF NOT EXISTS idx_relinkage_pending_unresolved
    ON relinkage_pending_requests (resolved, expires_at)
    WHERE resolved = FALSE;
