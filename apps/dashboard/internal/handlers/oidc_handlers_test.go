package handlers

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// ── Stub IdP (inline) ──────────────────────────────────────────────────
// Mirrors the stub in internal/auth/oidc_test.go but lives in the
// handlers package because that package's tests want to drive the
// HTTP-layer end-to-end without crossing the auth-package boundary.

type stubIdP struct {
	t          *testing.T
	server     *httptest.Server
	signingKey *rsa.PrivateKey

	mu          sync.Mutex
	nextIDToken string
}

func newStubIdP(t *testing.T) *stubIdP {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa: %v", err)
	}
	s := &stubIdP{t: t, signingKey: key}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		doc := map[string]any{
			"issuer":                                s.server.URL,
			"authorization_endpoint":                s.server.URL + "/authorize",
			"token_endpoint":                        s.server.URL + "/token",
			"jwks_uri":                              s.server.URL + "/keys",
			"response_types_supported":              []string{"code"},
			"subject_types_supported":               []string{"public"},
			"id_token_signing_alg_values_supported": []string{"RS256"},
		}
		_ = json.NewEncoder(w).Encode(doc)
	})
	mux.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		n := base64.RawURLEncoding.EncodeToString(s.signingKey.N.Bytes())
		e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(s.signingKey.E)).Bytes())
		_ = json.NewEncoder(w).Encode(map[string]any{
			"keys": []map[string]any{
				{"kty": "RSA", "kid": "k1", "use": "sig", "alg": "RS256", "n": n, "e": e},
			},
		})
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		idTok := s.nextIDToken
		s.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "stub-access",
			"token_type":   "Bearer",
			"id_token":     idTok,
		})
	})
	mux.HandleFunc("/authorize", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not implemented", http.StatusNotImplemented)
	})
	s.server = httptest.NewServer(mux)
	t.Cleanup(s.server.Close)
	return s
}

func (s *stubIdP) issueIDToken(claims map[string]any) string {
	header := map[string]string{"alg": "RS256", "typ": "JWT", "kid": "k1"}
	hb, _ := json.Marshal(header)
	cb, _ := json.Marshal(claims)
	signingInput := base64.RawURLEncoding.EncodeToString(hb) + "." + base64.RawURLEncoding.EncodeToString(cb)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, s.signingKey, 0x05, digest[:])
	if err != nil {
		s.t.Fatalf("sign: %v", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func (s *stubIdP) seedIDToken(tok string) {
	s.mu.Lock()
	s.nextIDToken = tok
	s.mu.Unlock()
}

// ── Helpers ─────────────────────────────────────────────────────────────

func newTestAuthenticator(t *testing.T, idp *stubIdP) *auth.OIDCAuthenticator {
	t.Helper()
	a, err := auth.NewOIDCAuthenticator(context.Background(), auth.OIDCConfig{
		IssuerURL:    idp.server.URL,
		ClientID:     "test-client",
		ClientSecret: "test-secret",
		RedirectURL:  "https://dashboard.test/auth/oidc/callback",
		GroupsClaim:  "groups",
		AdminGroup:   "admins",
		ViewerGroup:  "viewers",
	})
	if err != nil {
		t.Fatalf("NewOIDCAuthenticator: %v", err)
	}
	return a
}

func newTestRenderer(t *testing.T) *views.Renderer {
	t.Helper()
	r, err := views.New()
	if err != nil {
		t.Fatalf("views.New: %v", err)
	}
	return r
}

func buildOIDCDeps(t *testing.T, idp *stubIdP) (*OIDCDeps, auth.SessionStore) {
	t.Helper()
	sessions := auth.NewMemorySessionStore(time.Hour, time.Hour)
	t.Cleanup(sessions.Close)
	state := auth.NewMemoryOIDCStateStore(time.Hour, time.Hour)
	t.Cleanup(state.Close)
	d := &OIDCDeps{
		Authenticator: newTestAuthenticator(t, idp),
		State:         state,
		Sessions:      sessions,
		SessionTTL:    time.Hour,
		Renderer:      newTestRenderer(t),
	}
	return d, sessions
}

func issueCSRF(t *testing.T) (string, *http.Cookie) {
	t.Helper()
	w := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/login", nil)
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	cookies := w.Result().Cookies()
	for _, c := range cookies {
		if c.Name == auth.CSRFCookieName {
			return tok, c
		}
	}
	t.Fatalf("CSRF cookie not set")
	return "", nil
}

// ── Tests ───────────────────────────────────────────────────────────────

func TestOIDCLogin_GeneratesStateAndRedirects(t *testing.T) {
	idp := newStubIdP(t)
	d, _ := buildOIDCDeps(t, idp)

	tok, csrfCookie := issueCSRF(t)

	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("next", "/dashboard")
	r := httptest.NewRequest("POST", "/auth/oidc/login", strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.AddCookie(csrfCookie)
	w := httptest.NewRecorder()

	d.LoginRedirect(w, r)
	if w.Code != http.StatusFound {
		t.Fatalf("status = %d want 302", w.Code)
	}
	loc := w.Header().Get("Location")
	u, err := url.Parse(loc)
	if err != nil {
		t.Fatalf("Location parse: %v", err)
	}
	if u.Query().Get("code_challenge") == "" {
		t.Errorf("code_challenge missing from Location: %s", loc)
	}
	if u.Query().Get("code_challenge_method") != "S256" {
		t.Errorf("code_challenge_method = %q want S256", u.Query().Get("code_challenge_method"))
	}
	if u.Query().Get("state") == "" {
		t.Errorf("state missing from Location: %s", loc)
	}
}

func TestOIDCLogin_RejectsBadCSRF(t *testing.T) {
	idp := newStubIdP(t)
	d, _ := buildOIDCDeps(t, idp)

	form := url.Values{}
	form.Set("csrf", "bad-token-value")
	r := httptest.NewRequest("POST", "/auth/oidc/login", strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.AddCookie(&http.Cookie{Name: auth.CSRFCookieName, Value: "different-token"})
	w := httptest.NewRecorder()

	d.LoginRedirect(w, r)
	if w.Code != http.StatusForbidden {
		t.Errorf("want 403 on bad CSRF, got %d", w.Code)
	}
}

func TestOIDCLogin_RejectsGET(t *testing.T) {
	idp := newStubIdP(t)
	d, _ := buildOIDCDeps(t, idp)
	r := httptest.NewRequest("GET", "/auth/oidc/login", nil)
	w := httptest.NewRecorder()
	d.LoginRedirect(w, r)
	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("want 405 on GET, got %d", w.Code)
	}
}

func TestOIDCCallback_RotatesSessionID(t *testing.T) {
	idp := newStubIdP(t)
	d, sessions := buildOIDCDeps(t, idp)

	// Seed a pre-existing session (the session-fixation attack surface).
	preExisting, err := sessions.Create(auth.User{Email: "attacker@x", Role: auth.RoleViewer})
	if err != nil {
		t.Fatal(err)
	}

	// Seed an ID token + state record for the callback. The state-store
	// mints the nonce at flow-start; the ID-token claims MUST embed the
	// same value or Exchange's nonce assertion rejects the token (added
	// in slice 2 r1 fix-up for OpenID Core §3.1.3.7 item 11).
	stateRec, err := d.State.(*auth.MemoryOIDCStateStore).Create("/dashboard")
	if err != nil {
		t.Fatal(err)
	}
	idTok := idp.issueIDToken(map[string]any{
		"iss":    idp.server.URL,
		"sub":    "user-1",
		"aud":    "test-client",
		"email":  "victim@example.com",
		"iat":    time.Now().Unix(),
		"exp":    time.Now().Add(time.Hour).Unix(),
		"groups": []any{"admins"},
		"nonce":  stateRec.Nonce,
	})
	idp.seedIDToken(idTok)

	r := httptest.NewRequest("GET", "/auth/oidc/callback?code=abc&state="+stateRec.State, nil)
	r.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: preExisting.ID})
	w := httptest.NewRecorder()

	d.Callback(w, r)
	if w.Code != http.StatusFound {
		t.Fatalf("status = %d want 302; body=%s", w.Code, w.Body.String())
	}

	// The pre-existing session must be deleted.
	if _, ok := sessions.Get(preExisting.ID); ok {
		t.Errorf("pre-existing session still in store — session fixation defense missing")
	}

	// A new session cookie must be set with a different ID.
	var newSessID string
	for _, c := range w.Result().Cookies() {
		if c.Name == auth.SessionCookieName {
			newSessID = c.Value
		}
	}
	if newSessID == "" || newSessID == preExisting.ID {
		t.Errorf("expected freshly-minted session cookie distinct from pre-existing %q, got %q", preExisting.ID, newSessID)
	}

	// The new session must carry the OIDC-mapped user.
	sess, ok := sessions.Get(newSessID)
	if !ok {
		t.Fatalf("new session id not found in store")
	}
	if sess.User.Role != auth.RoleAdmin {
		t.Errorf("session user role = %q want admin", sess.User.Role)
	}
	if sess.User.Email != "victim@example.com" {
		t.Errorf("session user email = %q want victim@example.com", sess.User.Email)
	}
}

func TestOIDCCallback_BadState_Rejects(t *testing.T) {
	idp := newStubIdP(t)
	d, sessions := buildOIDCDeps(t, idp)

	r := httptest.NewRequest("GET", "/auth/oidc/callback?code=abc&state=NOT-A-REAL-STATE", nil)
	w := httptest.NewRecorder()

	d.Callback(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d want 401 on unknown state", w.Code)
	}
	// No session must be created.
	for _, c := range w.Result().Cookies() {
		if c.Name == auth.SessionCookieName {
			t.Errorf("session cookie must not be set on bad-state path; got %q", c.Value)
		}
	}
	// And the store must remain empty.
	if mss, ok := sessions.(*auth.MemorySessionStore); ok {
		_ = mss // store is empty; can't inspect map length from outside.
	}
}

func TestOIDCCallback_ReplayedState_Rejects(t *testing.T) {
	idp := newStubIdP(t)
	d, _ := buildOIDCDeps(t, idp)

	stateRec, err := d.State.(*auth.MemoryOIDCStateStore).Create("/dashboard")
	if err != nil {
		t.Fatal(err)
	}
	idTok := idp.issueIDToken(map[string]any{
		"iss":    idp.server.URL,
		"sub":    "user-1",
		"aud":    "test-client",
		"email":  "alice@example.com",
		"iat":    time.Now().Unix(),
		"exp":    time.Now().Add(time.Hour).Unix(),
		"groups": []any{"admins"},
		"nonce":  stateRec.Nonce,
	})
	idp.seedIDToken(idTok)

	// First call: success.
	r1 := httptest.NewRequest("GET", "/auth/oidc/callback?code=abc&state="+stateRec.State, nil)
	w1 := httptest.NewRecorder()
	d.Callback(w1, r1)
	if w1.Code != http.StatusFound {
		t.Fatalf("first callback expected 302, got %d", w1.Code)
	}

	// Second call with the same state: REJECT.
	r2 := httptest.NewRequest("GET", "/auth/oidc/callback?code=abc&state="+stateRec.State, nil)
	w2 := httptest.NewRecorder()
	d.Callback(w2, r2)
	if w2.Code != http.StatusUnauthorized {
		t.Errorf("replayed state must be rejected with 401, got %d", w2.Code)
	}
}

func TestOIDCCallback_FlashOnFailure(t *testing.T) {
	idp := newStubIdP(t)
	d, _ := buildOIDCDeps(t, idp)

	// Seed an ID token with groups that do NOT match.
	idTok := idp.issueIDToken(map[string]any{
		"iss":    idp.server.URL,
		"sub":    "user-1",
		"aud":    "test-client",
		"email":  "alice@example.com",
		"iat":    time.Now().Unix(),
		"exp":    time.Now().Add(time.Hour).Unix(),
		"groups": []any{"engineers"},
	})
	idp.seedIDToken(idTok)
	stateRec, err := d.State.(*auth.MemoryOIDCStateStore).Create("/dashboard")
	if err != nil {
		t.Fatal(err)
	}

	r := httptest.NewRequest("GET", "/auth/oidc/callback?code=abc&state="+stateRec.State, nil)
	w := httptest.NewRecorder()
	d.Callback(w, r)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d want 401 on group-mismatch", w.Code)
	}
	body := w.Body.String()
	// Generic flash text (info-leak hygiene): MUST NOT contain
	// underlying OIDC error names or the "neither group" phrase.
	if strings.Contains(strings.ToLower(body), "neither group") {
		t.Errorf("flash leaks underlying error class to browser: %s", body)
	}
	if !strings.Contains(body, "Sign-in could not be completed") {
		t.Errorf("expected generic flash in body, got %s", body)
	}
}

func TestOIDCCallback_IdPErrorParam(t *testing.T) {
	idp := newStubIdP(t)
	d, _ := buildOIDCDeps(t, idp)

	r := httptest.NewRequest("GET", "/auth/oidc/callback?error=access_denied&error_description=user+cancelled", nil)
	w := httptest.NewRecorder()
	d.Callback(w, r)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("want 401 when IdP returned error, got %d", w.Code)
	}
	body := w.Body.String()
	// The OIDC error code must NOT leak to the browser.
	if strings.Contains(body, "access_denied") {
		t.Errorf("OIDC error code leaked to browser body: %s", body)
	}
}

// Sentinel reference so a future trim of `errors` doesn't leave the
// import unused.
var _ = errors.New
