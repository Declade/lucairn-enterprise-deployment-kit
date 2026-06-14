-- Conversation-level compliance reports (PRD: prd-2026-06-14-conversation-
-- reports.md § Slice 1). Adds an UNSIGNED conversation_id to veil_certificates
-- so the many per-turn certs of one logical conversation (an agentic prompt
-- that fans out into tool calls, sub-turns, and title-generation) can be
-- grouped into a single conversation report.
--
-- conversation_id is opaque presentation metadata — exactly the client_id /
-- api_key_id precedent. It is NOT folded into the witness signable (v2 7-key /
-- v3 13-key, frozen). Tamper-evidence is INDIRECT: conversation_id is also
-- carried in the dsa-bridge claim's bridge-signed canonical_payload, which IS
-- part of the witness signable via `claim_ids[]`.
--
-- Derivation (gateway): honor an `x-lucairn-conversation-id` request header
-- when present; else a per-customer-scoped fingerprint of the first user
-- message (hex(sha256(customer_id || 0x00 || first_user_message))[:32]).
-- Stamped by id-bridge into the bridge claim canonical_payload; extracted by
-- the assembler into the top-level cert.conversation_id field.
--
-- TEXT (not BYTEA): conversation_id is an opaque short string (a header value
-- or a 32-hex-char fingerprint), NOT a body blob like redaction_manifest_body
-- / sanitized_fields_body / tms_manifest_body / output_scan_body.
--
-- The column is NULLABLE because:
--   - Older certs (pre-this-migration) carry no conversation_id.
--   - Certs minted by a pre-deploy bridge image (whose claim payload has no
--     conversation_id key) write NULL.
--   - An empty conversation (no header, no first-user-message text to
--     fingerprint) writes NULL.
ALTER TABLE veil_certificates ADD COLUMN conversation_id TEXT NULL;

-- Partial index on (customer_id, conversation_id) for the Slice 2 per-conversation
-- report lookup. Partial (WHERE conversation_id IS NOT NULL) keeps write overhead
-- low — the vast majority of certs minted before this migration carry NULL and are
-- excluded from the index entirely. Reversible: see 000010_conversation_id.down.sql.
CREATE INDEX IF NOT EXISTS veil_certificates_conversation_id_idx
    ON veil_certificates (customer_id, conversation_id)
    WHERE conversation_id IS NOT NULL;
