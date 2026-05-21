package handlers

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/gateway"
)

// fakeAdmin is the in-memory test double for the handlers.AdminClient
// interface. Tests prepopulate ListCustomersOut + ListKeysOut and assert
// against the captured RevokedKeys slice + MintCalls counter.
type fakeAdmin struct {
	mu sync.Mutex

	ListCustomersOut []gateway.CustomerEntry
	ListCustomersErr error

	ListKeysOut map[string]*gateway.ListKeysResult
	ListKeysErr error

	MintOut *gateway.MintKeyResult
	MintErr error

	RevokeErr map[string]error // keyed by key_id

	// Captured state.
	MintCalls   []string // customer ids
	RevokedKeys []revokeCall
}

type revokeCall struct {
	CustomerID string
	KeyID      string
}

func (f *fakeAdmin) ListCustomers(ctx context.Context) ([]gateway.CustomerEntry, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.ListCustomersErr != nil {
		return nil, f.ListCustomersErr
	}
	return append([]gateway.CustomerEntry(nil), f.ListCustomersOut...), nil
}

func (f *fakeAdmin) ListKeys(ctx context.Context, customerID string, reveal bool) (*gateway.ListKeysResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.ListKeysErr != nil {
		return nil, f.ListKeysErr
	}
	if r, ok := f.ListKeysOut[customerID]; ok {
		return r, nil
	}
	return nil, gateway.ErrCustomerNotFound
}

func (f *fakeAdmin) MintKey(ctx context.Context, customerID string) (*gateway.MintKeyResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.MintCalls = append(f.MintCalls, customerID)
	if f.MintErr != nil {
		return nil, f.MintErr
	}
	if f.MintOut != nil {
		return f.MintOut, nil
	}
	return &gateway.MintKeyResult{
		KeyID:     "k_new_" + customerID,
		KeyPrefix: "lcr_live_new" + customerID,
		RawKey:    "lcr_live_" + strings.Repeat("a", 32),
		CreatedAt: time.Now(),
	}, nil
}

func (f *fakeAdmin) RevokeKey(ctx context.Context, customerID, keyID string) (*gateway.RevokeKeyResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.RevokedKeys = append(f.RevokedKeys, revokeCall{CustomerID: customerID, KeyID: keyID})
	if err, ok := f.RevokeErr[keyID]; ok {
		return nil, err
	}
	return &gateway.RevokeKeyResult{Revoked: true, KeyID: keyID, KeyPrefix: "lcr_live_" + keyID}, nil
}

func newKeysSession(role auth.Role) *auth.Session {
	return &auth.Session{ID: "sess-" + string(role), User: auth.User{Email: string(role) + "@lucairn.local", Role: role}}
}

func withKeysSession(r *http.Request, sess *auth.Session) *http.Request {
	return auth.WithSessionForTest(r, sess)
}

// chain wraps a handler in the production middleware chain so tests
// observe the same status code an unauthenticated browser would see
// (Slice 4 C33 lesson — never call handlers directly to assert 401).
func chain(h http.Handler) http.Handler {
	return auth.RequireSession()(auth.RequireRole(auth.RoleAdmin, h))
}

func newKeysDeps(t *testing.T, admin AdminClient) (*KeysDeps, *audit.MemoryEmitter) {
	t.Helper()
	em := audit.NewMemoryEmitter()
	d := NewKeysDeps(mustRenderer(t), admin, em, admin != nil)
	return d, em
}

func TestKeys_BrowserUnauth_RedirectsToLogin(t *testing.T) {
	t.Parallel()
	d, _ := newKeysDeps(t, &fakeAdmin{})
	// Drive through the production middleware chain — viewers reach
	// the route via direct typing; unauthenticated requests redirect.
	req := httptest.NewRequest(http.MethodGet, "/keys", nil)
	rr := httptest.NewRecorder()
	chain(http.HandlerFunc(d.BrowserHandler)).ServeHTTP(rr, req)

	if rr.Code != http.StatusFound {
		t.Fatalf("status: %d want 302", rr.Code)
	}
	loc := rr.Header().Get("Location")
	if !strings.HasPrefix(loc, "/login?next=") {
		t.Errorf("Location=%q, want /login?next=...", loc)
	}
	if !strings.Contains(loc, "%2Fkeys") {
		t.Errorf("next= missing URL-encoded /keys: %q", loc)
	}
}

func TestKeys_BrowserViewer_Returns404(t *testing.T) {
	t.Parallel()
	d, _ := newKeysDeps(t, &fakeAdmin{})
	// Use the auth.SessionStore-fed middleware chain so RequireRole's
	// 404 path actually fires (RequireRole reads CurrentUser, which is
	// set by LoadSession off the cookie).
	store := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()
	sess, err := store.Create(auth.User{Email: "viewer@lucairn.local", Role: auth.RoleViewer})
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	mux := auth.LoadSession(store)(auth.RequireSession()(auth.RequireRole(auth.RoleAdmin, http.HandlerFunc(d.BrowserHandler))))
	req := httptest.NewRequest(http.MethodGet, "/keys", nil)
	req.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: sess.ID})
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("viewer status: %d want 404 (per Slice 1 RequireRole pattern)", rr.Code)
	}
}

func TestKeys_BrowserAdmin_NotConfigured_RendersBanner(t *testing.T) {
	t.Parallel()
	d, _ := newKeysDeps(t, nil) // configured=false
	req := httptest.NewRequest(http.MethodGet, "/keys", nil)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if !strings.Contains(body, "API key management is not configured") {
		t.Errorf("missing 'not configured' banner in body")
	}
}

func TestKeys_BrowserAdmin_SingleCustomer_Renders(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{
			{CustomerID: "cust_a", Tier: "enterprise"},
		},
		ListKeysOut: map[string]*gateway.ListKeysResult{
			"cust_a": {
				CustomerID: "cust_a",
				Tier:       "enterprise",
				MaxKeys:    5,
				Keys: []gateway.KeyEntry{
					{KeyID: "k1", KeyPrefix: "lcr_live_aaaa1111", CreatedAt: time.Date(2026, 5, 20, 8, 0, 0, 0, time.UTC)},
					{KeyID: "k2", KeyPrefix: "lcr_live_bbbb2222", CreatedAt: time.Date(2026, 5, 21, 8, 0, 0, 0, time.UTC)},
				},
			},
		},
	}
	d, _ := newKeysDeps(t, admin)
	req := httptest.NewRequest(http.MethodGet, "/keys", nil)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if !strings.Contains(body, "<table") {
		t.Errorf("missing <table>")
	}
	if !strings.Contains(body, "lcr_live_aaaa1111") || !strings.Contains(body, "lcr_live_bbbb2222") {
		t.Errorf("missing key prefixes in body")
	}
	// Single-customer auto-detect blurb.
	if !strings.Contains(body, "cust_a") {
		t.Errorf("missing customer id render: body=%s", body)
	}
	// Customer selector hidden when count==1.
	if strings.Contains(body, "onchange=\"this.form.submit()\"") {
		t.Errorf("selector should be hidden for single-customer install")
	}
}

func TestKeys_BrowserAdmin_MultiCustomer_RendersSelector(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{
			{CustomerID: "cust_a", Tier: "enterprise"},
			{CustomerID: "cust_b", Tier: "pro"},
		},
		ListKeysOut: map[string]*gateway.ListKeysResult{
			"cust_a": {CustomerID: "cust_a", Tier: "enterprise"},
			"cust_b": {CustomerID: "cust_b", Tier: "pro"},
		},
	}
	d, _ := newKeysDeps(t, admin)
	req := httptest.NewRequest(http.MethodGet, "/keys?customer_id=cust_b", nil)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "<select") {
		t.Errorf("multi-customer selector missing")
	}
	if !strings.Contains(body, "cust_b") {
		t.Errorf("selected customer not rendered: %s", body)
	}
}

func TestKeys_BrowserAdmin_NoCustomers_RendersEmptyState(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{}, // explicitly empty
	}
	d, _ := newKeysDeps(t, admin)
	req := httptest.NewRequest(http.MethodGet, "/keys", nil)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "No customers are configured") {
		t.Errorf("missing empty-customers banner")
	}
}

func TestKeys_MintAdmin_ShowsPlaintextOnce_WithNoCacheHeaders(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a", Tier: "enterprise"}},
		ListKeysOut: map[string]*gateway.ListKeysResult{
			"cust_a": {CustomerID: "cust_a", Tier: "enterprise"},
		},
		MintOut: &gateway.MintKeyResult{
			KeyID:     "k_new_a",
			KeyPrefix: "lcr_live_freshpfx",
			RawKey:    "lcr_live_freshpfx" + strings.Repeat("a", 24),
			CreatedAt: time.Now(),
		},
	}
	d, em := newKeysDeps(t, admin)
	tok, cookie := issueCSRF(t)

	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	req := httptest.NewRequest(http.MethodPost, "/keys/mint", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.MintHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if !strings.Contains(body, "lcr_live_freshpfx") {
		t.Errorf("plaintext prefix not surfaced in mint response body")
	}
	// Plaintext must be in the modal (template embeds it via Alpine `plaintext` data attr).
	if !strings.Contains(body, "plaintext") {
		t.Errorf("mint modal missing")
	}

	// Headers — bearer-equivalent material must NOT be cached anywhere.
	if got := rr.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control=%q want no-store", got)
	}
	if got := rr.Header().Get("Pragma"); got != "no-cache" {
		t.Errorf("Pragma=%q want no-cache", got)
	}

	// Audit event was emitted with key_id + key_prefix BUT NO raw_key.
	events := em.Events()
	if len(events) != 1 {
		t.Fatalf("want 1 audit event, got %d", len(events))
	}
	if events[0].EventType != "key.mint_requested" {
		t.Errorf("event type=%s", events[0].EventType)
	}
	if v := events[0].Payload["key_prefix"]; v != "lcr_live_freshpfx" {
		t.Errorf("payload key_prefix=%q", v)
	}
	for k, v := range events[0].Payload {
		if strings.Contains(v, "freshpfx") && k != "key_prefix" && k != "key_id" {
			t.Errorf("raw key fragment leaked into audit payload key=%s value=%s", k, v)
		}
	}

	// SECOND list-only render must NOT contain the plaintext anywhere
	// (modal is one-shot per response).
	req2 := httptest.NewRequest(http.MethodGet, "/keys", nil)
	req2 = withKeysSession(req2, newKeysSession(auth.RoleAdmin))
	rr2 := httptest.NewRecorder()
	d.BrowserHandler(rr2, req2)
	if strings.Contains(rr2.Body.String(), strings.Repeat("a", 24)) {
		t.Errorf("plaintext key leaked into a second list render")
	}
}

func TestKeys_MintCSRFMissing_Returns403(t *testing.T) {
	t.Parallel()
	d, _ := newKeysDeps(t, &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
	})
	form := url.Values{}
	form.Set("customer_id", "cust_a")
	req := httptest.NewRequest(http.MethodPost, "/keys/mint", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.MintHandler(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Errorf("status=%d want 403", rr.Code)
	}
}

func TestKeys_MintViewer_RejectedByMiddleware_404(t *testing.T) {
	t.Parallel()
	d, _ := newKeysDeps(t, &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
	})
	// Mint as a viewer; full middleware chain returns 404 per Slice 1.
	store := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()
	sess, err := store.Create(auth.User{Email: "viewer@lucairn.local", Role: auth.RoleViewer})
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	mux := auth.LoadSession(store)(auth.RequireSession()(auth.RequireRole(auth.RoleAdmin, http.HandlerFunc(d.MintHandler))))
	req := httptest.NewRequest(http.MethodPost, "/keys/mint", nil)
	req.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: sess.ID})
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("viewer mint status: %d want 404", rr.Code)
	}
}

func TestKeys_RevokeAdmin_EmitsPerKeyAudit(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
	}
	d, em := newKeysDeps(t, admin)
	tok, cookie := issueCSRF(t)

	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	req := httptest.NewRequest(http.MethodPost, "/keys/k_target/revoke", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.RevokeHandler(rr, req)

	if rr.Code != http.StatusSeeOther {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	if loc := rr.Header().Get("Location"); !strings.HasPrefix(loc, "/keys") {
		t.Errorf("Location=%q want /keys", loc)
	}

	if em.CountByEventType("key.revoke_requested") != 1 {
		t.Errorf("want 1 revoke audit event, got %d", em.CountByEventType("key.revoke_requested"))
	}

	if len(admin.RevokedKeys) != 1 || admin.RevokedKeys[0].KeyID != "k_target" {
		t.Errorf("revoke called with wrong key: %+v", admin.RevokedKeys)
	}
}

func TestKeys_BulkRevokeAdmin_EmitsPerKeyAudit(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
	}
	d, em := newKeysDeps(t, admin)
	tok, cookie := issueCSRF(t)

	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	form.Add("key_id", "k1")
	form.Add("key_id", "k2")
	form.Add("key_id", "k3")
	req := httptest.NewRequest(http.MethodPost, "/keys/bulk-revoke", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.BulkRevokeHandler(rr, req)

	if rr.Code != http.StatusSeeOther {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	if em.CountByEventType("key.revoke_requested") != 3 {
		t.Errorf("want 3 per-key audit events, got %d", em.CountByEventType("key.revoke_requested"))
	}
	// MUST NOT emit a bulk-aggregate event under a different name —
	// the audit stream stays joinable with single revoke entries.
	if em.CountByEventType("key.bulk_revoke_requested") != 0 {
		t.Errorf("bulk revoke must not emit aggregate event")
	}
	if len(admin.RevokedKeys) != 3 {
		t.Errorf("admin client called %d times, want 3", len(admin.RevokedKeys))
	}
}

func TestKeys_BulkRevokeAdmin_TooLarge_413(t *testing.T) {
	t.Parallel()
	d, _ := newKeysDeps(t, &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
	})
	tok, cookie := issueCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	for i := 0; i < 101; i++ {
		form.Add("key_id", "k_"+strings.Repeat("x", i%8+1))
	}
	req := httptest.NewRequest(http.MethodPost, "/keys/bulk-revoke", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.BulkRevokeHandler(rr, req)
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("status=%d want 413", rr.Code)
	}
}

func TestKeys_PlaintextNeverLogged(t *testing.T) {
	// NOTE: intentionally NOT t.Parallel — log.SetOutput is process-
	// global; running this test in parallel with other handlers tests
	// that also call log.Printf would race on the buffer. Serial
	// execution closes the race without weakening the assertion.
	var buf safeBuffer
	oldOut := log.Writer()
	oldFlags := log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(oldOut)
		log.SetFlags(oldFlags)
	})

	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
		ListKeysOut: map[string]*gateway.ListKeysResult{
			"cust_a": {CustomerID: "cust_a"},
		},
		MintOut: &gateway.MintKeyResult{
			KeyID:     "k_logleak",
			KeyPrefix: "lcr_live_secret_prefix",
			RawKey:    "lcr_live_secret_prefix_DO_NOT_LEAK_TO_LOG_ZZZZ",
			CreatedAt: time.Now(),
		},
	}
	// Use a real LogEmitter (production wiring) — not the MemoryEmitter
	// — so this test actually verifies the logger-path.
	d := NewKeysDeps(mustRenderer(t), admin, audit.NewLogEmitter(), true)
	tok, cookie := issueCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	req := httptest.NewRequest(http.MethodPost, "/keys/mint", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.MintHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d", rr.Code)
	}
	if strings.Contains(buf.String(), "DO_NOT_LEAK_TO_LOG_ZZZZ") {
		t.Errorf("raw key suffix leaked into log output: %q", buf.String())
	}
	// The log MUST include the audit event (key.mint_requested) — proves
	// the LogEmitter path executed.
	if !strings.Contains(buf.String(), "key.mint_requested") {
		t.Errorf("audit log line missing; full log: %q", buf.String())
	}
}

func TestKeys_BrowserCustomerListCached(t *testing.T) {
	t.Parallel()
	calls := 0
	var mu sync.Mutex
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
		ListKeysOut: map[string]*gateway.ListKeysResult{
			"cust_a": {CustomerID: "cust_a", Tier: "enterprise"},
		},
	}
	// Wrap to count ListCustomers calls.
	countingAdmin := &countingAdmin{inner: admin, calls: &calls, mu: &mu}
	d, _ := newKeysDeps(t, countingAdmin)
	for i := 0; i < 5; i++ {
		req := httptest.NewRequest(http.MethodGet, "/keys", nil)
		req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
		rr := httptest.NewRecorder()
		d.BrowserHandler(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("call %d: status=%d", i, rr.Code)
		}
	}
	mu.Lock()
	got := calls
	mu.Unlock()
	if got != 1 {
		t.Errorf("expected ListCustomers called 1x (cache hit), got %d", got)
	}
}

type countingAdmin struct {
	inner *fakeAdmin
	calls *int
	mu    *sync.Mutex
}

func (c *countingAdmin) ListCustomers(ctx context.Context) ([]gateway.CustomerEntry, error) {
	c.mu.Lock()
	*c.calls++
	c.mu.Unlock()
	return c.inner.ListCustomers(ctx)
}
func (c *countingAdmin) ListKeys(ctx context.Context, customerID string, reveal bool) (*gateway.ListKeysResult, error) {
	return c.inner.ListKeys(ctx, customerID, reveal)
}
func (c *countingAdmin) MintKey(ctx context.Context, customerID string) (*gateway.MintKeyResult, error) {
	return c.inner.MintKey(ctx, customerID)
}
func (c *countingAdmin) RevokeKey(ctx context.Context, customerID, keyID string) (*gateway.RevokeKeyResult, error) {
	return c.inner.RevokeKey(ctx, customerID, keyID)
}

func TestKeys_MintGracefulOnMaxKeysReached(t *testing.T) {
	t.Parallel()
	d, em := newKeysDeps(t, &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
		ListKeysOut:      map[string]*gateway.ListKeysResult{"cust_a": {CustomerID: "cust_a"}},
		MintErr:          gateway.ErrMaxKeysReached,
	})
	tok, cookie := issueCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	req := httptest.NewRequest(http.MethodPost, "/keys/mint", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.MintHandler(rr, req)
	if rr.Code != http.StatusConflict {
		t.Fatalf("status=%d want 409", rr.Code)
	}
	if em.CountByEventType("key.mint_requested") != 0 {
		t.Errorf("audit event emitted despite mint failure")
	}
}

func TestKeys_RevokeIdempotent_AlreadyRevokedStillRedirectsAndAudits(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
		RevokeErr:        map[string]error{"k_missing": gateway.ErrKeyNotFound},
	}
	d, em := newKeysDeps(t, admin)
	tok, cookie := issueCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	req := httptest.NewRequest(http.MethodPost, "/keys/k_missing/revoke", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()
	d.RevokeHandler(rr, req)
	if rr.Code != http.StatusSeeOther {
		t.Errorf("status=%d want 303 (idempotent)", rr.Code)
	}
	events := em.Events()
	if len(events) != 1 {
		t.Fatalf("want 1 audit, got %d", len(events))
	}
	if events[0].Payload["outcome"] != "already_revoked" {
		t.Errorf("outcome=%q want already_revoked", events[0].Payload["outcome"])
	}
}

func TestExtractKeyIDFromRevokePath(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"/keys/k_target/revoke": "k_target",
		"/keys/k1/revoke":       "k1",
		// "/keys/revoke" — would parse as keyid="revoke" because the
		// suffix-trim is a no-op; the router itself never dispatches
		// this path to RevokeHandler. The extractor stays permissive
		// since the handler downstream consults the gateway, which
		// rejects unknown key_ids with 404 anyway.
		"/keys/":               "",
		"/keys/foo/bar/revoke": "", // multi-segment is rejected
		"":                     "",
		"/keys":                "",
	}
	for in, want := range cases {
		if got := extractKeyIDFromRevokePath(in); got != want {
			t.Errorf("extractKeyIDFromRevokePath(%q)=%q want %q", in, got, want)
		}
	}
}

// safeBuffer wraps bytes.Buffer with a mutex so log.SetOutput
// targeting it doesn't race with parallel sibling-test log.Printf
// calls during the brief window before t.Cleanup restores the
// original writer.
type safeBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *safeBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *safeBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// stubBodyDrainer is unused; kept to satisfy go vet on io import in
// case future tests stream large bodies.
var _ = io.Discard
var _ = errors.New
