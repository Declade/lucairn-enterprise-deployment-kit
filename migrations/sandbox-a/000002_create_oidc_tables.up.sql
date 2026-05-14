CREATE TABLE oidc_clients (
    id TEXT PRIMARY KEY,
    secret_hash TEXT NOT NULL,
    redirect_uris TEXT[] NOT NULL DEFAULT '{}',
    application_type TEXT NOT NULL DEFAULT 'web',
    grant_types TEXT[] NOT NULL DEFAULT '{authorization_code}',
    response_types TEXT[] NOT NULL DEFAULT '{code}',
    scopes TEXT[] NOT NULL DEFAULT '{openid,profile,email}',
    login_url TEXT NOT NULL DEFAULT '/login',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE oidc_auth_requests (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES oidc_clients(id),
    scopes TEXT[] NOT NULL,
    redirect_uri TEXT NOT NULL,
    state TEXT,
    nonce TEXT,
    response_type TEXT NOT NULL,
    code_challenge TEXT,
    code_challenge_method TEXT,
    identity_id UUID,
    auth_time TIMESTAMPTZ,
    code TEXT,
    done BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_oidc_auth_requests_code ON oidc_auth_requests (code) WHERE code IS NOT NULL;

CREATE TABLE oidc_refresh_tokens (
    id TEXT PRIMARY KEY,
    token TEXT UNIQUE NOT NULL,
    client_id TEXT NOT NULL REFERENCES oidc_clients(id),
    identity_id UUID NOT NULL,
    scopes TEXT[] NOT NULL,
    auth_time TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE oidc_sessions (
    id TEXT PRIMARY KEY,
    identity_id UUID NOT NULL,
    client_id TEXT NOT NULL REFERENCES oidc_clients(id),
    scopes TEXT[] NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_oidc_sessions_identity ON oidc_sessions (identity_id);

CREATE TABLE oidc_signing_keys (
    id TEXT PRIMARY KEY,
    private_key BYTEA NOT NULL,
    public_key BYTEA NOT NULL,
    algorithm TEXT NOT NULL DEFAULT 'RS256',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ
);
