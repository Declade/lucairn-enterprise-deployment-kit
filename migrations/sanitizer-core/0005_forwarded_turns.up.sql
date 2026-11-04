-- To-do item 41 (contract v0.4+12, board T-1426): the core's FORWARDED
-- record. One row per stored turn whose sanitized bytes the gateway reported
-- as reaching the vendor (after vendor evidence, PR #902). mark_mac = keyed
-- MAC of (customer, conversation, epoch, turn id, sha256 of the sanitized
-- text): no plaintext hash, no value; a row that is moved, edited or written
-- under another epoch or text never verifies (read = not forwarded). Leaves
-- with its turn (FK cascade: sweep, conversation delete). Applied as a listed
-- swap-window step, never on boot.
CREATE TABLE registry_forwarded (
    customer_id     TEXT  NOT NULL,
    conversation_id TEXT  NOT NULL,
    turn_id         TEXT  NOT NULL,
    mark_mac        BYTEA NOT NULL CHECK (length(mark_mac) = 32),
    PRIMARY KEY (customer_id, conversation_id, turn_id),
    FOREIGN KEY (customer_id, conversation_id, turn_id)
        REFERENCES registry_turns (customer_id, conversation_id, turn_id) ON DELETE CASCADE
);
