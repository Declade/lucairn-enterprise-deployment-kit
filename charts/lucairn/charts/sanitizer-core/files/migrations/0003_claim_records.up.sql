-- Slice E, contract v0.4+8 item 2 (Fable seat b2 17:1x restart correction;
-- 21 Oct 07:2x revision; review round 2 decisions 4 + 7): one row per signed
-- dsa-sanitizer claim, keyed by the gateway request_id (the witness and the
-- claim id are global per request_id) and BOUND to its customer +
-- conversation: the same request_id under another customer or conversation is
-- refused, never shared. First write wins (never overwritten). The row
-- PERSISTS the first claim: its signed canonical bytes + unsigned bodies
-- (sealed, AAD = customer + conversation + request_id) and its first sign
-- time; a resend whose full sanitized turn set + map entries + request facts
-- are identical (keyed MAC, identity_mac, same binding) reuses those bytes
-- (one proof); any other resend is refused claim_id_conflict. No plaintext
-- hash of the signed bytes is stored (round 2: confirmation attack). Per
-- customer, bounded (oldest trimmed), expires with its conversation (FK
-- cascade). Applied as a listed swap-window step, never on boot; not applied
-- anywhere yet, so this file was edited in place in review round 2.
CREATE TABLE registry_claim_records (
    request_id       TEXT        NOT NULL PRIMARY KEY,
    customer_id      TEXT        NOT NULL,
    conversation_id  TEXT        NOT NULL,
    identity_mac     BYTEA       NOT NULL CHECK (length(identity_mac) = 32),
    claim_enc        BYTEA       NOT NULL,          -- sealed first claim bytes + bodies
    first_signed_at  TIMESTAMPTZ NOT NULL,          -- the claim timestamp (first sign time)
    seq              BIGSERIAL   NOT NULL,          -- trim order (oldest first)
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (customer_id, conversation_id)
        REFERENCES registry_conversations (customer_id, conversation_id) ON DELETE CASCADE
);
CREATE INDEX registry_claim_records_trim ON registry_claim_records (customer_id, seq);
CREATE INDEX registry_claim_records_conv ON registry_claim_records (customer_id, conversation_id);
