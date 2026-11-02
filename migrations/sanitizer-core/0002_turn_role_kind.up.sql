-- Contract v0.4+2 (slice 3, for slice 4's ServiceNow rules): every stored turn
-- keeps the role and block kind the gateway sent. Bounded vocabulary, no value
-- (checked by the core before the write); rows written before this get ''.
ALTER TABLE registry_turns
    ADD COLUMN role TEXT NOT NULL DEFAULT '' CHECK (role IN ('', 'user', 'assistant', 'system')),
    ADD COLUMN kind TEXT NOT NULL DEFAULT '' CHECK (kind IN ('', 'text', 'tool_use', 'tool_result'));
