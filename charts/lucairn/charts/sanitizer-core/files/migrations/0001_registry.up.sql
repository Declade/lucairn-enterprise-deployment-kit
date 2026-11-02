-- sanitizer-core registry (PRD slice 2, ADR annex option A), own database.
-- Keyed by (customer_id, conversation_id) in every key and query; rows leave
-- only by a counted DELETE; a missing row is resync_required, never empty.
-- PII at rest (Amendment 1): *_enc = AES-256-GCM bound to row + epoch; key_hmac
-- = keyed lookup; state_mac = keyed MAC of epoch, version, replayable set.

CREATE SEQUENCE registry_epoch_seq;  -- epochs are global and never reused

CREATE TABLE registry_conversations (
    customer_id     TEXT        NOT NULL,
    conversation_id TEXT        NOT NULL,
    epoch           BIGINT      NOT NULL,
    version         BIGINT      NOT NULL,          -- compare-and-set token, +1 per write
    next_n          JSONB       NOT NULL,          -- next free number per type (whole registry)
    norm_rev        TEXT        NOT NULL,
    state_mac       BYTEA       NOT NULL,          -- wrong key or edited replayable set = error
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (customer_id, conversation_id)
);
CREATE INDEX registry_conversations_expires ON registry_conversations (expires_at);

CREATE TABLE registry_entries (
    customer_id     TEXT    NOT NULL,
    conversation_id TEXT    NOT NULL,
    type            TEXT    NOT NULL,
    n               INTEGER NOT NULL CHECK (n > 0),
    key_hmac        BYTEA   NOT NULL,              -- HMAC(customer, conversation, sha256(type NUL canonical key))
    value_enc       BYTEA   NOT NULL,              -- AES-GCM {canonical, surfaces, experts, first turn}
    replayable      BOOLEAN NOT NULL,              -- loaded every request (set in state_mac); rest by key
    PRIMARY KEY (customer_id, conversation_id, type, n),   -- a number is never given twice
    UNIQUE (customer_id, conversation_id, key_hmac),     -- a value never gets two numbers
    FOREIGN KEY (customer_id, conversation_id)
        REFERENCES registry_conversations (customer_id, conversation_id) ON DELETE CASCADE
);

CREATE INDEX registry_entries_replayable ON registry_entries (customer_id, conversation_id) WHERE replayable;

CREATE TABLE registry_turns (
    customer_id      TEXT   NOT NULL,
    conversation_id  TEXT   NOT NULL,
    seq              BIGINT NOT NULL,
    turn_id          TEXT   NOT NULL,
    sha_enc          BYTEA  NOT NULL,              -- AES-GCM sha256 of the ORIGINAL turn text
    sanitized_enc    BYTEA  NOT NULL,              -- AES-GCM text as sent to the vendor; never rewritten (O2)
    PRIMARY KEY (customer_id, conversation_id, turn_id),
    UNIQUE (customer_id, conversation_id, seq),
    FOREIGN KEY (customer_id, conversation_id)
        REFERENCES registry_conversations (customer_id, conversation_id) ON DELETE CASCADE
);

-- One row per conversation that was swept or deleted: ids, epoch and reason
-- only (no value). Lets the next request say WHY it must resync.
CREATE TABLE registry_tombstones (
    customer_id     TEXT        NOT NULL,
    conversation_id TEXT        NOT NULL,
    epoch           BIGINT      NOT NULL,
    reason          TEXT        NOT NULL,
    at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, conversation_id)
);
CREATE INDEX registry_tombstones_at ON registry_tombstones (at);
