package handlers

import (
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
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/testutil"
	"golang.org/x/time/rate"
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
	// Swap the production 4s-per-token limiter for an unbounded one
	// so the audit-emission semantics get tested without the
	// 12s+ rate-limit wait. The pacing itself is locked-in by
	// TestKeys_BulkRevokeRespectsGatewayOuter20PerMinLimit below.
	d.revokeLimiter = rate.NewLimiter(rate.Inf, keysBulkRevokeBurst)
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

// TestKeys_BulkRevokeRespectsGatewayOuter20PerMinLimit locks in the
// DRIFT-001 fix (Slice 5 fix-up r1): the dashboard's bulk-revoke
// RPC pacing must stay UNDER the gateway's outer per-IP admin
// limiter at services/gateway/cmd/server/main.go:823 (20 req/min).
// Previous setting (rate.Limit(10), burst=10) interpreted "10" as
// 10/SECOND = 600/min, slamming the gateway 30x over the wall.
//
// We don't drive a live gateway — instead we assert the pacing
// invariant directly: consecutive RevokeKey calls must be spaced
// at least keysBulkRevokeInterval apart once the initial burst is
// consumed.
func TestKeys_BulkRevokeRespectsGatewayOuter20PerMinLimit(t *testing.T) {
	t.Parallel()
	// Use the PRODUCTION limiter — the whole point of the test.
	admin := &timestampingAdmin{
		inner: &fakeAdmin{
			ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
		},
	}
	d, _ := newKeysDeps(t, admin)
	// Verify NewKeysDeps installed the production-shaped limiter.
	if d.revokeLimiter.Limit() != keysBulkRevokeEvery {
		t.Fatalf("limiter rate=%v want %v", d.revokeLimiter.Limit(), keysBulkRevokeEvery)
	}
	if d.revokeLimiter.Burst() != keysBulkRevokeBurst {
		t.Fatalf("limiter burst=%d want %d", d.revokeLimiter.Burst(), keysBulkRevokeBurst)
	}

	tok, cookie := issueCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	// Bulk 3 keys — enough to observe 2 inter-call gaps, both of
	// which must be ≥ keysBulkRevokeInterval (4s).
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
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	times := admin.snapshot()
	if len(times) != 3 {
		t.Fatalf("got %d RevokeKey calls, want 3", len(times))
	}
	// First call may be immediate (burst=1). Subsequent calls MUST
	// each pay the interval. Allow a small slop (200ms) for
	// goroutine scheduling jitter — the test still catches any
	// regression to rate.Limit(10) (= 100ms/call, 40x faster).
	const slop = 200 * time.Millisecond
	for i := 1; i < len(times); i++ {
		gap := times[i].Sub(times[i-1])
		minGap := keysBulkRevokeInterval - slop
		if gap < minGap {
			t.Errorf("call %d→%d gap=%v want ≥%v (limiter regression: dashboard would burst past gateway 20/min)",
				i-1, i, gap, minGap)
		}
	}
}

// TestKeys_BulkRevokeContextCancellationEmitsCancelledAudit locks in
// the BH-M3 fix (Slice 5 fix-up r1): when the request ctx cancels
// mid-bulk, the remaining keys MUST be audited with outcome=cancelled
// (NOT silently dropped from the audit stream). Slice 3 pattern #5
// invariant: every key the operator submitted appears in the audit
// stream — bulk=true + outcome={revoked|already_revoked|cancelled|
// failed} disambiguates outcomes downstream.
func TestKeys_BulkRevokeContextCancellationEmitsCancelledAudit(t *testing.T) {
	t.Parallel()
	admin := &fakeAdmin{
		ListCustomersOut: []gateway.CustomerEntry{{CustomerID: "cust_a"}},
	}
	d, em := newKeysDeps(t, admin)
	// Use production-shape limiter — cancellation must work even
	// when the limiter is metering between calls.
	tok, cookie := issueCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("customer_id", "cust_a")
	const total = 6
	for i := 0; i < total; i++ {
		form.Add("key_id", "k_"+strings.Repeat("a", i+1))
	}
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/keys/bulk-revoke", strings.NewReader(form.Encode())).WithContext(ctx)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(cookie)
	req = withKeysSession(req, newKeysSession(auth.RoleAdmin))
	rr := httptest.NewRecorder()

	// Cancel quickly so the rate limiter blocks on the 2nd+ key.
	done := make(chan struct{})
	go func() {
		time.Sleep(150 * time.Millisecond)
		cancel()
		close(done)
	}()
	d.BulkRevokeHandler(rr, req)
	<-done

	// Total audit events MUST equal total (one per key in the form).
	// Some carry outcome=revoked (the calls that landed before
	// cancellation), the rest outcome=cancelled.
	revoked := 0
	cancelled := 0
	other := 0
	for _, e := range em.Events() {
		switch e.Payload["outcome"] {
		case "revoked", "already_revoked":
			revoked++
		case "cancelled":
			cancelled++
		default:
			other++
		}
	}
	if revoked+cancelled+other != total {
		t.Fatalf("audit events: %d revoked + %d cancelled + %d other = %d, want %d (every key in the bulk MUST appear in the audit stream regardless of cancellation)",
			revoked, cancelled, other, revoked+cancelled+other, total)
	}
	if cancelled == 0 {
		t.Errorf("no cancelled audit events emitted; cancellation discipline regressed")
	}
}

// TestGetCustomers_FirstCallerCancelDoesNotPoisonCoalesced locks in
// the BH-H2 fix: when caller A's request ctx cancels mid-fetch,
// caller B (coalesced via singleflight) MUST still receive the
// customer list. The fix detaches the inner gateway-call ctx from
// any single caller's ctx so cancellation cannot poison peers.
func TestGetCustomers_FirstCallerCancelDoesNotPoisonCoalesced(t *testing.T) {
	t.Parallel()
	gate := make(chan struct{})
	admin := &slowAdmin{
		gate: gate,
		out:  []gateway.CustomerEntry{{CustomerID: "cust_a"}},
	}
	d, _ := newKeysDeps(t, admin)

	// Caller A: ctx that we'll cancel BEFORE the gateway returns.
	ctxA, cancelA := context.WithCancel(context.Background())
	// Caller B: independent ctx.
	ctxB := context.Background()

	type result struct {
		out []gateway.CustomerEntry
		err error
	}
	resA := make(chan result, 1)
	resB := make(chan result, 1)

	go func() {
		out, err := d.getCustomers(ctxA)
		resA <- result{out: out, err: err}
	}()
	// Give A a head-start so it owns the singleflight slot.
	time.Sleep(50 * time.Millisecond)
	go func() {
		out, err := d.getCustomers(ctxB)
		resB <- result{out: out, err: err}
	}()
	// Cancel A while the admin call is still gated.
	time.Sleep(50 * time.Millisecond)
	cancelA()
	// Release the admin call so the singleflight closure can
	// complete on B's behalf.
	close(gate)

	select {
	case r := <-resB:
		if r.err != nil {
			t.Fatalf("caller B err=%v (caller A's cancel poisoned the coalesced result)", r.err)
		}
		if len(r.out) != 1 || r.out[0].CustomerID != "cust_a" {
			t.Errorf("caller B got %+v, want [{cust_a}]", r.out)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("caller B never returned — coalesced fetch may be wedged on A's cancelled ctx")
	}

	// Drain caller A — its result is don't-care. It may legitimately
	// return either the value (if the inner call completed before A's
	// goroutine observed the cancel) or a cancellation error. Both
	// outcomes are acceptable; only caller B's invariant is
	// load-bearing.
	select {
	case <-resA:
	case <-time.After(2 * time.Second):
		t.Log("caller A did not return within 2s; non-fatal")
	}
}

// slowAdmin is an AdminClient stub that blocks on a channel before
// returning, letting tests stage cancellation precisely.
type slowAdmin struct {
	gate <-chan struct{}
	out  []gateway.CustomerEntry
}

func (s *slowAdmin) ListCustomers(ctx context.Context) ([]gateway.CustomerEntry, error) {
	<-s.gate
	return append([]gateway.CustomerEntry(nil), s.out...), nil
}
func (s *slowAdmin) ListKeys(ctx context.Context, customerID string, reveal bool) (*gateway.ListKeysResult, error) {
	return nil, gateway.ErrCustomerNotFound
}
func (s *slowAdmin) MintKey(ctx context.Context, customerID string) (*gateway.MintKeyResult, error) {
	return nil, errors.New("not implemented")
}
func (s *slowAdmin) RevokeKey(ctx context.Context, customerID, keyID string) (*gateway.RevokeKeyResult, error) {
	return nil, errors.New("not implemented")
}

// timestampingAdmin captures wall-clock for every RevokeKey call so
// the rate-pacing invariant can be asserted directly.
type timestampingAdmin struct {
	inner     *fakeAdmin
	mu        sync.Mutex
	callTimes []time.Time
}

func (a *timestampingAdmin) ListCustomers(ctx context.Context) ([]gateway.CustomerEntry, error) {
	return a.inner.ListCustomers(ctx)
}
func (a *timestampingAdmin) ListKeys(ctx context.Context, customerID string, reveal bool) (*gateway.ListKeysResult, error) {
	return a.inner.ListKeys(ctx, customerID, reveal)
}
func (a *timestampingAdmin) MintKey(ctx context.Context, customerID string) (*gateway.MintKeyResult, error) {
	return a.inner.MintKey(ctx, customerID)
}
func (a *timestampingAdmin) RevokeKey(ctx context.Context, customerID, keyID string) (*gateway.RevokeKeyResult, error) {
	a.mu.Lock()
	a.callTimes = append(a.callTimes, time.Now())
	a.mu.Unlock()
	return a.inner.RevokeKey(ctx, customerID, keyID)
}

// snapshot returns a defensive copy of the recorded call times so
// the test can read without holding the mutex.
func (a *timestampingAdmin) snapshot() []time.Time {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]time.Time, len(a.callTimes))
	copy(out, a.callTimes)
	return out
}

func TestKeys_PlaintextNeverLogged(t *testing.T) {
	// NOTE: intentionally NOT t.Parallel — log.SetOutput is process-
	// global; running this test in parallel with other handlers tests
	// that also call log.Printf would race on the buffer. Serial
	// execution closes the race without weakening the assertion.
	var buf testutil.SafeBuffer
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

// Slice 5 fix-up r1: safeBuffer moved to internal/testutil.SafeBuffer
// so audit/emitter_test.go (and any future test that needs to capture
// log writer output during parallel sibling-test runs) imports a single
// shared helper. Keep this comment for future readers grepping for the
// pattern.
//
// io.Discard / errors.New retained-import guards: many sibling tests
// use them already, but keeping the explicit references here means a
// future refactor that removes the last consumer still leaves the
// import in place until intentionally pruned.
var _ = io.Discard
var _ = errors.New
