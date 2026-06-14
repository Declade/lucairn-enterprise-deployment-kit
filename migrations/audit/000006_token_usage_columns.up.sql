-- WS4 Slice A1 (token-usage visibility): make per-event token counts queryable.
--
-- Token counts already arrive on the gateway's *_INFERENCE_COMPLETED /
-- *_INFERENCE_STREAMED audit events, but only as opaque strings inside
-- audit_events.payload BYTEA — unqueryable for dashboard-scale aggregation.
-- This migration adds dedicated, queryable token columns on audit_events. They
-- are populated by the SAME INSERT that already records the completion event
-- (tokens RIDE the existing fail-closed audit emit; there is NO new write path).
--
-- Aggregation (GetTokenUsage) does SUM(...) GROUP BY token_model over these
-- columns, keyed on token_api_key_hash (NOT actor: actor is customer_id on the
-- sync *_INFERENCE_COMPLETED events but the bridge-token hash on the streaming
-- *_INFERENCE_STREAMED events, so it cannot be the per-key aggregation key).
--
-- cache_read_tokens / cache_creation_tokens are stored but never summed into
-- in/out and never displayed (WS4 Slice A1 shows in/out only). They future-proof
-- Slice 2's prompt-cache-savings panel so it needs no later audit migration.
-- They are 0 today (the upstream Anthropic cache-token block is dropped inside
-- sandbox-b before it reaches the gateway — separate sandbox_b plumbing).
--
-- All columns default to 0 / '' so every existing row + every non-completion
-- event remains valid. Append-only invariant preserved: no UPDATE/DELETE.

ALTER TABLE audit_events
  ADD COLUMN IF NOT EXISTS input_tokens          INT  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS output_tokens         INT  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cache_read_tokens     INT  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cache_creation_tokens INT  NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS token_model           TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS token_api_key_hash    TEXT NOT NULL DEFAULT '';

-- Aggregation index: GetTokenUsage filters by token_api_key_hash + a month
-- window on timestamp, then groups by token_model. The partial index skips the
-- overwhelming majority of rows that carry no token attribution (admin events,
-- non-completion events, legacy rows) so the SUM/GROUP-BY scan stays small.
CREATE INDEX IF NOT EXISTS idx_audit_events_token_usage
  ON audit_events (token_api_key_hash, timestamp)
  WHERE token_api_key_hash <> '';

-- The audit_app least-privilege role already has SELECT on audit_events
-- (migration 000003 + 000005). New columns inherit table-level SELECT, so no
-- additional grant is needed. INSERT into the new columns is likewise covered
-- by the existing table-level INSERT grant.
