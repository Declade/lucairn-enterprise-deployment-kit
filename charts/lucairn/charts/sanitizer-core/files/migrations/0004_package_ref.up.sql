-- Slice 4 (PRD prd-2026-10-20-sanitizer-core-slice4-servicenow-expert.md, In
-- scope 4, row 16): the instance package that served the conversation's last
-- mode request = its package digest H(instance, generation, bundle tag,
-- companion digest, companion tag); '' = none; 'dropped:'<digest> = generic
-- turns were committed after that package (the next mode request resyncs). No key byte, no fingerprint,
-- no value; bound into state_mac when set.
ALTER TABLE registry_conversations
    ADD COLUMN package_ref TEXT NOT NULL DEFAULT '' CHECK (package_ref ~ '^((dropped:)?[0-9a-f]{64})?$');
