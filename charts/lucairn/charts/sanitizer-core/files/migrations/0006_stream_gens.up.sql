-- To-do item 5 (slice 5, contract v0.4+13): the live generation of every reply
-- stream (design-2026-10-25-stream-package-v2.md § 2 i, #909 Env.Gen). One row per
-- (customer, conversation, stream id); each release call moves gen by one with a
-- compare-and-set, so a re-presented, forked or transplanted stream state is refused
-- on EVERY core instance (no sticky routing). refused_gen = the generation a refused or
-- timed-out call moved the row to (a close may then present the state before it).
-- closed = terminal: no further call and no second close (one claim per stream). No value,
-- no hash of a value. Leaves with its conversation (FK cascade: sweep, delete).
-- Applied as a listed swap-window step, never on boot.
CREATE TABLE registry_stream_gens (
    customer_id     TEXT        NOT NULL,
    conversation_id TEXT        NOT NULL,
    stream_id       TEXT        NOT NULL CHECK (length(stream_id) BETWEEN 16 AND 128),
    gen             BIGINT      NOT NULL CHECK (gen > 0),
    refused_gen     BIGINT      NOT NULL DEFAULT 0,  -- the generation whose call was refused or timed out (0 = none)
    done_gen        BIGINT      NOT NULL DEFAULT 0,  -- the generation whose call delivered a success (0 = none)
    final           BOOLEAN     NOT NULL DEFAULT false, -- a Final call ran: no further call, only the close (terminal-pending)
    closed          BOOLEAN     NOT NULL DEFAULT false,
    close_request_id TEXT,                           -- the ONE request whose close signed this stream
    expires_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (customer_id, conversation_id, stream_id),
    FOREIGN KEY (customer_id, conversation_id)
        REFERENCES registry_conversations (customer_id, conversation_id) ON DELETE CASCADE
);
CREATE INDEX registry_stream_gens_expires ON registry_stream_gens (expires_at);
-- One request id closes ONE stream (its claim id is f(request_id)): a close that would bind a request id
-- another stream holds fails here, before that stream is marked closed (sol final read).
CREATE UNIQUE INDEX registry_stream_gens_close_request ON registry_stream_gens (close_request_id) WHERE close_request_id IS NOT NULL;

-- The numbers a reply stream LEASED (store.PG.Lease, written in the same transaction that moves next_n):
-- a stream-local placeholder the client echoes in a later request has a number below next_n and no
-- registry row; this record tells /v1/turns it is a stream local (text, never relinked), not a lost row
-- (map_incomplete). Bound to the epoch; leaves with its conversation. No value.
CREATE TABLE registry_stream_leases (
    customer_id     TEXT    NOT NULL,
    conversation_id TEXT    NOT NULL,
    epoch           BIGINT  NOT NULL,
    type            TEXT    NOT NULL,
    lo              INTEGER NOT NULL CHECK (lo > 0),
    hi              INTEGER NOT NULL CHECK (hi > lo),
    PRIMARY KEY (customer_id, conversation_id, type, lo),
    FOREIGN KEY (customer_id, conversation_id)
        REFERENCES registry_conversations (customer_id, conversation_id) ON DELETE CASCADE
);
