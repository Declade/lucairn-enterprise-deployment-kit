CREATE TABLE redaction_manifests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id TEXT NOT NULL,
    identity_id UUID NOT NULL REFERENCES identities(id),
    vertical TEXT NOT NULL,
    redactions JSONB NOT NULL DEFAULT '[]',
    sanitizer_version TEXT NOT NULL DEFAULT '',
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_redaction_manifests_identity ON redaction_manifests(identity_id);
CREATE INDEX idx_redaction_manifests_request ON redaction_manifests(request_id);

-- RLS: vertical isolation
ALTER TABLE redaction_manifests ENABLE ROW LEVEL SECURITY;
CREATE POLICY vertical_isolation ON redaction_manifests
    USING (vertical = current_setting('app.current_vertical', true));
ALTER TABLE redaction_manifests FORCE ROW LEVEL SECURITY;
