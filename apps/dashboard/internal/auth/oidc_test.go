package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ── Stub OIDC issuer ────────────────────────────────────────────────────
//
// Inline httptest.Server that satisfies the subset of OIDC discovery the
// go-oidc library consumes:
//
//   - GET /.well-known/openid-configuration → discovery doc
//   - GET /keys                              → JWKS (single RS256 key)
//   - POST /token                            → token exchange
//
// Tests construct stubIssuer once per test, build an ID token via
// stubIssuer.signIDToken(...), seed the next /token response, then call
// OIDCAuthenticator.Exchange. The single-test-server approach avoids
// pulling Keycloak into the unit test path — that surface lives in the
// orchestrator's edge-verify script.

type stubIssuer struct {
	t          *testing.T
	server     *httptest.Server
	signingKey *rsa.PrivateKey
	keyID      string

	mu         sync.Mutex
	tokenResp  tokenResponse // seeded for the next /token call
	idToken    string
	tokenError string // if non-empty, /token returns 400 with this error
}

type tokenResponse struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	IDToken     string `json:"id_token,omitempty"`
}

func newStubIssuer(t *testing.T) *stubIssuer {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa generate: %v", err)
	}
	s := &stubIssuer{
		t:          t,
		signingKey: key,
		keyID:      "stub-test-key-1",
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", s.discoveryHandler)
	mux.HandleFunc("/keys", s.jwksHandler)
	mux.HandleFunc("/token", s.tokenHandler)
	mux.HandleFunc("/authorize", func(w http.ResponseWriter, r *http.Request) {
		// Discovery requires an authorize endpoint but the test path
		// jumps straight to /token; a stub that returns 501 is fine.
		http.Error(w, "stub authorize", http.StatusNotImplemented)
	})
	s.server = httptest.NewServer(mux)
	t.Cleanup(s.server.Close)
	return s
}

func (s *stubIssuer) discoveryHandler(w http.ResponseWriter, r *http.Request) {
	doc := map[string]any{
		"issuer":                                s.server.URL,
		"authorization_endpoint":                s.server.URL + "/authorize",
		"token_endpoint":                        s.server.URL + "/token",
		"jwks_uri":                              s.server.URL + "/keys",
		"response_types_supported":              []string{"code"},
		"subject_types_supported":               []string{"public"},
		"id_token_signing_alg_values_supported": []string{"RS256"},
		"scopes_supported":                      []string{"openid", "profile", "email", "groups"},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(doc)
}

func (s *stubIssuer) jwksHandler(w http.ResponseWriter, r *http.Request) {
	n := base64.RawURLEncoding.EncodeToString(s.signingKey.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(s.signingKey.E)).Bytes())
	jwks := map[string]any{
		"keys": []map[string]any{
			{
				"kty": "RSA",
				"kid": s.keyID,
				"use": "sig",
				"alg": "RS256",
				"n":   n,
				"e":   e,
			},
		},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(jwks)
}

func (s *stubIssuer) tokenHandler(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	tokenError := s.tokenError
	resp := s.tokenResp
	resp.IDToken = s.idToken
	s.mu.Unlock()

	if tokenError != "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": tokenError})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// signIDToken builds + RS256-signs an ID token with the supplied claim
// map. Some test helpers tweak claim names (aud, exp, iss) to cover the
// rejection paths.
func (s *stubIssuer) signIDToken(claims map[string]any) string {
	header := map[string]string{
		"alg": "RS256",
		"typ": "JWT",
		"kid": s.keyID,
	}
	headerBytes, _ := json.Marshal(header)
	claimBytes, _ := json.Marshal(claims)
	signingInput := base64.RawURLEncoding.EncodeToString(headerBytes) + "." + base64.RawURLEncoding.EncodeToString(claimBytes)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, s.signingKey, 0x05, digest[:]) // 0x05 = crypto.SHA256
	if err != nil {
		s.t.Fatalf("sign: %v", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// seedExchange seeds the next /token response: success path with the
// supplied ID token.
func (s *stubIssuer) seedExchange(idToken string) {
	s.mu.Lock()
	s.tokenResp = tokenResponse{AccessToken: "stub-access-token", TokenType: "Bearer"}
	s.idToken = idToken
	s.tokenError = ""
	s.mu.Unlock()
}

func (s *stubIssuer) seedExchangeError(errCode string) {
	s.mu.Lock()
	s.tokenError = errCode
	s.tokenResp = tokenResponse{}
	s.idToken = ""
	s.mu.Unlock()
}

// signKey is signing helper used by tests that need to break the
// signature on purpose.
func (s *stubIssuer) generateRogueKey() *rsa.PrivateKey {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		s.t.Fatalf("rogue rsa: %v", err)
	}
	return key
}

// signTokenWithKey re-signs the same header+claims with a different RSA
// key. Used to assert the verifier rejects an otherwise well-formed
// token whose signature was minted under the wrong issuer.
func (s *stubIssuer) signTokenWithKey(claims map[string]any, key *rsa.PrivateKey) string {
	header := map[string]string{
		"alg": "RS256",
		"typ": "JWT",
		"kid": s.keyID,
	}
	headerBytes, _ := json.Marshal(header)
	claimBytes, _ := json.Marshal(claims)
	signingInput := base64.RawURLEncoding.EncodeToString(headerBytes) + "." + base64.RawURLEncoding.EncodeToString(claimBytes)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, 0x05, digest[:])
	if err != nil {
		s.t.Fatalf("rogue sign: %v", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// Silence "imported and not used" complaints if a future test trims pem/x509 wiring.
var _ = pem.Block{}
var _ = x509.SystemCertPool

// ── Helpers ─────────────────────────────────────────────────────────────

func newTestAuthenticator(t *testing.T, s *stubIssuer) *OIDCAuthenticator {
	t.Helper()
	auth, err := NewOIDCAuthenticator(context.Background(), OIDCConfig{
		IssuerURL:    s.server.URL,
		ClientID:     "test-client",
		ClientSecret: "test-secret",
		RedirectURL:  "https://dashboard.example.com/auth/oidc/callback",
		GroupsClaim:  "groups",
		AdminGroup:   "lucairn-admins",
		ViewerGroup:  "lucairn-viewers",
	})
	if err != nil {
		t.Fatalf("NewOIDCAuthenticator: %v", err)
	}
	return auth
}

func defaultClaims(s *stubIssuer, groups []any, audience any) map[string]any {
	now := time.Now()
	c := map[string]any{
		"iss":   s.server.URL,
		"sub":   "user-sub-1",
		"email": "alice@example.com",
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
	if audience != nil {
		c["aud"] = audience
	} else {
		c["aud"] = "test-client"
	}
	if groups != nil {
		c["groups"] = groups
	}
	return c
}

// ── Tests ───────────────────────────────────────────────────────────────

func TestNewOIDCAuthenticator_DiscoveryRoundTrip(t *testing.T) {
	s := newStubIssuer(t)
	if _, err := NewOIDCAuthenticator(context.Background(), OIDCConfig{
		IssuerURL:    s.server.URL,
		ClientID:     "test-client",
		ClientSecret: "test-secret",
		RedirectURL:  "https://dashboard.example.com/auth/oidc/callback",
		AdminGroup:   "lucairn-admins",
		ViewerGroup:  "lucairn-viewers",
	}); err != nil {
		t.Fatalf("discovery: %v", err)
	}
}

func TestNewOIDCAuthenticator_RejectsBadConfig(t *testing.T) {
	cases := []struct {
		name string
		cfg  OIDCConfig
	}{
		{"missing issuer", OIDCConfig{ClientID: "c", ClientSecret: "s", RedirectURL: "https://x.local/cb", AdminGroup: "a", ViewerGroup: "v"}},
		{"missing client_id", OIDCConfig{IssuerURL: "https://idp.local", ClientSecret: "s", RedirectURL: "https://x.local/cb", AdminGroup: "a", ViewerGroup: "v"}},
		{"missing client_secret", OIDCConfig{IssuerURL: "https://idp.local", ClientID: "c", RedirectURL: "https://x.local/cb", AdminGroup: "a", ViewerGroup: "v"}},
		{"missing redirect_url", OIDCConfig{IssuerURL: "https://idp.local", ClientID: "c", ClientSecret: "s", AdminGroup: "a", ViewerGroup: "v"}},
		{"missing admin_group", OIDCConfig{IssuerURL: "https://idp.local", ClientID: "c", ClientSecret: "s", RedirectURL: "https://x.local/cb", ViewerGroup: "v"}},
		{"missing viewer_group", OIDCConfig{IssuerURL: "https://idp.local", ClientID: "c", ClientSecret: "s", RedirectURL: "https://x.local/cb", AdminGroup: "a"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := NewOIDCAuthenticator(context.Background(), c.cfg); err == nil {
				t.Errorf("expected error for %s", c.name)
			}
		})
	}
}

func TestLoginURL_GeneratesPKCEChallenge(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	u := a.LoginURL("state-x", "verifier-y")
	if !strings.Contains(u, "code_challenge=") {
		t.Errorf("missing code_challenge in %q", u)
	}
	if !strings.Contains(u, "code_challenge_method=S256") {
		t.Errorf("missing code_challenge_method=S256 in %q", u)
	}
	if !strings.Contains(u, "state=state-x") {
		t.Errorf("state token not propagated in %q", u)
	}
}

func TestExchange_Success_AdminGroup(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	id := s.signIDToken(defaultClaims(s, []any{"lucairn-admins"}, nil))
	s.seedExchange(id)

	user, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if user.Role != RoleAdmin {
		t.Errorf("role = %q want %q", user.Role, RoleAdmin)
	}
	if user.Email != "alice@example.com" {
		t.Errorf("email = %q want alice@example.com", user.Email)
	}
}

func TestExchange_Success_ViewerGroup(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	id := s.signIDToken(defaultClaims(s, []any{"lucairn-viewers"}, nil))
	s.seedExchange(id)

	user, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if user.Role != RoleViewer {
		t.Errorf("role = %q want %q", user.Role, RoleViewer)
	}
}

func TestExchange_Failure_NeitherGroup(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	id := s.signIDToken(defaultClaims(s, []any{"unrelated-group"}, nil))
	s.seedExchange(id)

	_, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	if !errors.Is(err, ErrNeitherGroup) {
		t.Errorf("want ErrNeitherGroup, got %v", err)
	}
}

func TestExchange_Failure_BothGroups_AdminWins(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	id := s.signIDToken(defaultClaims(s, []any{"lucairn-viewers", "lucairn-admins"}, nil))
	s.seedExchange(id)

	user, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if user.Role != RoleAdmin {
		t.Errorf("expected RoleAdmin to win when user is in both groups, got %q", user.Role)
	}
}

func TestExchange_Failure_BadSignature(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	rogue := s.generateRogueKey()
	id := s.signTokenWithKey(defaultClaims(s, []any{"lucairn-admins"}, nil), rogue)
	s.seedExchange(id)

	_, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	var iderr *ErrInvalidIDToken
	if !errors.As(err, &iderr) {
		t.Errorf("want ErrInvalidIDToken, got %v", err)
	}
}

func TestExchange_Failure_BadAudience(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	id := s.signIDToken(defaultClaims(s, []any{"lucairn-admins"}, "WRONG-CLIENT"))
	s.seedExchange(id)

	_, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	var iderr *ErrInvalidIDToken
	if !errors.As(err, &iderr) {
		t.Errorf("want ErrInvalidIDToken on aud mismatch, got %v", err)
	}
}

func TestExchange_Failure_Expired(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	claims := defaultClaims(s, []any{"lucairn-admins"}, nil)
	claims["exp"] = time.Now().Add(-time.Hour).Unix()
	id := s.signIDToken(claims)
	s.seedExchange(id)

	_, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	var iderr *ErrInvalidIDToken
	if !errors.As(err, &iderr) {
		t.Errorf("want ErrInvalidIDToken on expired token, got %v", err)
	}
}

func TestExchange_Failure_IdPError(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	s.seedExchangeError("invalid_grant")

	_, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	if err == nil {
		t.Fatalf("expected error when token endpoint returns invalid_grant")
	}
}

func TestGroupsClaim_StringFallback(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	claims := defaultClaims(s, nil, nil)
	claims["groups"] = "lucairn-admins" // single-string instead of array
	id := s.signIDToken(claims)
	s.seedExchange(id)

	user, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if user.Role != RoleAdmin {
		t.Errorf("expected single-string groups claim to normalize, got role %q", user.Role)
	}
}

func TestGroupsClaim_Missing(t *testing.T) {
	s := newStubIssuer(t)
	a := newTestAuthenticator(t, s)
	claims := defaultClaims(s, nil, nil) // no groups
	id := s.signIDToken(claims)
	s.seedExchange(id)

	_, err := a.Exchange(context.Background(), "code-xyz", "verifier-y")
	if !errors.Is(err, ErrGroupsClaimMissing) {
		t.Errorf("want ErrGroupsClaimMissing, got %v", err)
	}
}

func TestMapGroupsToRole_DirectInvariants(t *testing.T) {
	// Exercise MapGroupsToRole without going through the issuer. Confirms
	// the role-mapping rules are decoupled from token I/O.
	a := &OIDCAuthenticator{cfg: OIDCConfig{
		AdminGroup:  "admins",
		ViewerGroup: "viewers",
		GroupsClaim: "groups",
	}}
	cases := []struct {
		name   string
		groups any
		want   Role
		errIs  error
	}{
		{"admin only", []any{"admins"}, RoleAdmin, nil},
		{"viewer only", []any{"viewers"}, RoleViewer, nil},
		{"both", []any{"viewers", "admins"}, RoleAdmin, nil},
		{"neither", []any{"engineers"}, "", ErrNeitherGroup},
		{"empty slice", []any{}, "", ErrNeitherGroup},
		{"single string", "admins", RoleAdmin, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r, err := a.MapGroupsToRole(map[string]any{"groups": c.groups})
			if c.errIs != nil {
				if !errors.Is(err, c.errIs) {
					t.Fatalf("want %v, got %v", c.errIs, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if r != c.want {
				t.Errorf("role = %q want %q", r, c.want)
			}
		})
	}
}

// TestPKCEChallenge_S256Matches asserts the LoginURL-emitted challenge
// matches the SHA-256(verifier) base64-url-no-pad form. Locks the
// implementation against a future drift to plain or sha-512.
func TestPKCEChallenge_S256Matches(t *testing.T) {
	verifier := "verifier-string-for-deterministic-check"
	want := pkceS256Challenge(verifier)
	sum := sha256.Sum256([]byte(verifier))
	got := base64.RawURLEncoding.EncodeToString(sum[:])
	if got != want {
		t.Errorf("S256 mismatch: got %q want %q", got, want)
	}
}

// Use a sentinel function reference to suppress imported-but-unused lint
// if a future trim removes the only callsite of fmt within this file.
var _ = fmt.Sprintf
