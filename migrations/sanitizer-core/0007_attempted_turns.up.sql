-- Item 95 redesign: a pre-transmission attempt is a conversation-wide rewrite
-- veto, NOT vendor-confirmed evidence. It also covers send-unredacted turns that
-- have no registry_turns row. Removed only with the conversation.
CREATE TABLE registry_attempted (
    customer_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    PRIMARY KEY (customer_id, conversation_id, turn_id),
    FOREIGN KEY (customer_id, conversation_id)
        REFERENCES registry_conversations (customer_id, conversation_id) ON DELETE CASCADE
);
