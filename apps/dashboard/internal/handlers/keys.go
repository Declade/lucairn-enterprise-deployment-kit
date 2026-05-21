package handlers

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/gateway"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"golang.org/x/sync/singleflight"
	"golang.org/x/time/rate"
)

// KeysDeps groups the API-key-management surface's runtime collaborators.
//
// Configured is the honesty bit identical to the Slice 3 cert surface:
// when the operator has not wired LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL +
// LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN, the routes still register but
// every handler returns the "not configured" explainer. The gateway
// admin token is the operator's blast-radius lever; failing-closed at
// boot if it's missing would prevent operators from running the
// dashboard at all.
//
// Audit is mandatory in production (production main.go passes a
// LogEmitter). Tests pass MemoryEmitter so assertions on audit-event
// emit can branch deterministically.
//
// Per Slice 5 architecture pattern: the bulk worker pool + global rate
// limit live at package scope so the dashboard's blast radius against
// the gateway admin surface stays bounded regardless of how many
// bulk-revoke jobs run in parallel.
type KeysDeps struct {
	Renderer   *views.Renderer
	Admin      AdminClient
	Audit      audit.Emitter
	Configured bool

	// customerCache is a 5-minute snapshot of the gateway's customer
	// list. Populated lazily on first /keys hit; refreshed on TTL miss
	// or explicit invalidation. Single-flight guards against the
	// cache-miss stampede when N concurrent /keys requests race on a
	// fresh boot.
	cacheMu       sync.RWMutex
	cachedAt      time.Time
	cachedList    []gateway.CustomerEntry
	cacheTTL      time.Duration
	cacheFlight   singleflight.Group
	clock         func() time.Time // injectable for tests
	revokePool    chan struct{}    // bulk-revoke worker semaphore
	revokeLimiter *rate.Limiter    // bulk-revoke RPC rate-limiter
}

// AdminClient narrows the *gateway.AdminClient API to what handlers
// use. Tests inject a fake; production wires the real client.
type AdminClient interface {
	ListCustomers(ctx context.Context) ([]gateway.CustomerEntry, error)
	ListKeys(ctx context.Context, customerID string, reveal bool) (*gateway.ListKeysResult, error)
	MintKey(ctx context.Context, customerID string) (*gateway.MintKeyResult, error)
	RevokeKey(ctx context.Context, customerID, keyID string) (*gateway.RevokeKeyResult, error)
}

// NewKeysDeps constructs a configured deps bag. Pass admin=nil and
// configured=false for the disabled-path render.
func NewKeysDeps(renderer *views.Renderer, admin AdminClient, emitter audit.Emitter, configured bool) *KeysDeps {
	if emitter == nil {
		emitter = audit.NewLogEmitter()
	}
	return &KeysDeps{
		Renderer:      renderer,
		Admin:         admin,
		Audit:         emitter,
		Configured:    configured,
		cacheTTL:      5 * time.Minute,
		clock:         time.Now,
		revokePool:    make(chan struct{}, keysBulkRevokePool),
		revokeLimiter: rate.NewLimiter(keysBulkRevokeEvery, keysBulkRevokeBurst),
	}
}

// keysBulkRevokePool caps in-flight RevokeKey HTTP calls per bulk
// job. Slice 3 pattern #24 — workers + global limit prevent the
// dashboard from slamming the gateway admin surface even when many
// admins run bulk revoke concurrently.
const keysBulkRevokePool = 5

// keysBulkRevokeInterval is the minimum time between successive
// RevokeKey calls the dashboard issues against the gateway admin
// API. The BINDING constraint upstream is the OUTER per-IP admin
// limiter at
// `dual-sandbox-architecture/services/gateway/cmd/server/main.go:823`
// (`middleware.NewRateLimiter(20, time.Minute, IPKeyFunc)`) — 20
// req/min per source IP across ALL `/api/v1/admin/*` routes. The
// inner `customerKeysLimiter` at `admin.go:216` allows 60/min on the
// per-customer-keys subset but is gated by the outer 20/min — it
// never executes when the outer limiter is already rejecting the
// request.
//
// 4s/call ≈ 15/min sustained, leaving headroom for other dashboard
// surfaces (cert browser, server-health probes) sharing the same IP
// bucket against the gateway. Burst=1 means a fresh bulk job pays
// the full 4s per the first call, which is load-bearing — bursting
// past the outer limiter only converts a graceful queue into 429s
// the dashboard cannot recover from.
const keysBulkRevokeInterval = 4 * time.Second

// keysBulkRevokeBurst is intentionally 1; see keysBulkRevokeInterval.
const keysBulkRevokeBurst = 1

// keysBulkRevokeEvery wraps rate.Every(keysBulkRevokeInterval) — kept
// as a package-scope helper so tests can reach for the same value
// without re-computing it.
var keysBulkRevokeEvery = rate.Every(keysBulkRevokeInterval)

// keysPageData carries the render shape for /keys.
type keysPageData struct {
	views.PageData
	Configured    bool
	NotConfigured string

	// Multi-tenant state.
	Customers     []gateway.CustomerEntry
	SelectedID    string
	ShowSelector  bool
	NoCustomers   bool
	CustomersWarn string // e.g. "Showing 1 of 1 customer (auto-detected)"

	// Per-key surface.
	KeysResult *gateway.ListKeysResult
	KeysErr    string

	// One-shot post-mint modal state. RawKey is intentionally only
	// populated on the mint POST round-trip — list refreshes never
	// surface it.
	JustMinted *gateway.MintKeyResult
}

// BrowserHandler is GET /keys. Renders the customer-scoped key table.
//
// Admin role required — viewers reach this only via direct URL typing
// and middleware returns 404 (per the locked Slice 1 RequireRole
// pattern at apps/dashboard/internal/auth/middleware.go:77-91).
func (d *KeysDeps) BrowserHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	// Defense-in-depth: middleware ALREADY enforces admin (RequireRole),
	// but if the route is ever wired without the middleware (regression
	// path) this guard fail-closes. 404 matches the middleware so the
	// externally-observable contract is consistent.
	if user.Role != auth.RoleAdmin {
		http.NotFound(w, r)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("keys_browser: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	data := keysPageData{
		PageData: views.PageData{
			Title:      "API keys",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "keys",
		},
		Configured: d.Configured,
	}
	if !d.Configured {
		data.NotConfigured = "API key management is not configured on this install. Set LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL and LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN (or the matching Helm values) and restart the dashboard. See INSTALL.md § \"Enable API key management (Slice 5)\"."
		d.render(w, data)
		return
	}

	// Customer list — cached snapshot first, refresh on TTL miss.
	customers, err := d.getCustomers(r.Context())
	if err != nil {
		log.Printf("keys_browser: list customers: %v", err)
		http.Error(w, "gateway admin unavailable", http.StatusBadGateway)
		return
	}
	d.populateCustomerState(&data, customers, r.URL.Query().Get("customer_id"))
	if data.NoCustomers {
		d.render(w, data)
		return
	}

	keys, err := d.Admin.ListKeys(r.Context(), data.SelectedID, false)
	if err != nil {
		if errors.Is(err, gateway.ErrCustomerNotFound) {
			data.KeysErr = "Customer not found in the gateway keystore. The customer-list cache may be stale; reload to refresh."
		} else {
			log.Printf("keys_browser: list keys: %v", err)
			data.KeysErr = "Gateway admin temporarily unreachable. Keys cannot be listed right now."
		}
	} else {
		data.KeysResult = keys
	}
	d.render(w, data)
}

// MintHandler is POST /keys/mint. CSRF-required. Mints a fresh key
// against the selected customer, emits a per-key audit event, and
// renders the browser page with JustMinted set so the post-mint modal
// shows the plaintext key ONCE.
//
// Response headers: Cache-Control: no-store + Pragma: no-cache prevent
// any intermediate proxy or browser back-button from re-surfacing the
// plaintext key after the user navigates away.
func (d *KeysDeps) MintHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if user.Role != auth.RoleAdmin {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf failure", http.StatusForbidden)
		return
	}
	if !d.Configured {
		http.Error(w, "API key management not configured", http.StatusServiceUnavailable)
		return
	}
	customerID := strings.TrimSpace(r.PostFormValue("customer_id"))
	if customerID == "" {
		// Fall back to the auto-detected customer when the form omits
		// the explicit selection. Common case: single-tenant install
		// where the form has no selector at all.
		customers, err := d.getCustomers(r.Context())
		if err != nil {
			log.Printf("keys_mint: customer-list lookup: %v", err)
			http.Error(w, "gateway admin unavailable", http.StatusBadGateway)
			return
		}
		if len(customers) == 0 {
			http.Error(w, "no customers configured in gateway keystore", http.StatusConflict)
			return
		}
		customerID = customers[0].CustomerID
	}

	minted, err := d.Admin.MintKey(r.Context(), customerID)
	if err != nil {
		if errors.Is(err, gateway.ErrMaxKeysReached) {
			http.Error(w, "Customer is already at the per-tier key cap. Revoke one before minting a fresh key.", http.StatusConflict)
			return
		}
		if errors.Is(err, gateway.ErrAdminTokenRejected) {
			http.Error(w, "Gateway admin token rejected. Check LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN.", http.StatusBadGateway)
			return
		}
		log.Printf("keys_mint: mint: %v", err)
		http.Error(w, "Gateway admin temporarily unreachable.", http.StatusBadGateway)
		return
	}

	// Audit event — payload carries identifiers only. raw_key never
	// enters the audit emitter (the LogEmitter would print it; the
	// MemoryEmitter would expose it via Events()).
	d.Audit.Emit("key.mint_requested", user.Email, map[string]string{
		"customer_id": customerID,
		"key_id":      minted.KeyID,
		"key_prefix":  minted.KeyPrefix,
	})

	// Re-fetch the (now updated) list so the post-mint view shows the
	// new key inline. Best-effort — if the gateway hiccups between
	// mint and list, render the modal anyway so the operator can copy
	// the raw_key.
	var listResult *gateway.ListKeysResult
	if list, lerr := d.Admin.ListKeys(r.Context(), customerID, false); lerr == nil {
		listResult = list
	}
	customers, _ := d.getCustomers(r.Context())

	data := keysPageData{
		PageData: views.PageData{
			Title:      "API keys",
			User:       user,
			CSRFToken:  r.PostFormValue(auth.CSRFFormField), // reuse — modal stays one-shot
			ActivePage: "keys",
		},
		Configured: true,
		KeysResult: listResult,
		JustMinted: minted,
	}
	d.populateCustomerState(&data, customers, customerID)

	// Plaintext is bearer-equivalent — no caching anywhere.
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	w.Header().Set("Referrer-Policy", "no-referrer")
	d.render(w, data)
}

// RevokeHandler is POST /keys/{key_id}/revoke. CSRF-required.
func (d *KeysDeps) RevokeHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if user.Role != auth.RoleAdmin {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf failure", http.StatusForbidden)
		return
	}
	if !d.Configured {
		http.Error(w, "API key management not configured", http.StatusServiceUnavailable)
		return
	}
	keyID := extractKeyIDFromRevokePath(r.URL.Path)
	if keyID == "" {
		http.Error(w, "missing key_id in path", http.StatusBadRequest)
		return
	}
	customerID, err := d.resolveCustomerID(r)
	if err != nil {
		log.Printf("keys_revoke: resolve customer: %v", err)
		http.Error(w, "gateway admin unavailable", http.StatusBadGateway)
		return
	}

	if _, err := d.Admin.RevokeKey(r.Context(), customerID, keyID); err != nil {
		if errors.Is(err, gateway.ErrKeyNotFound) {
			// Idempotent: already gone is success from the operator's POV.
			d.Audit.Emit("key.revoke_requested", user.Email, map[string]string{
				"customer_id": customerID,
				"key_id":      keyID,
				"outcome":     "already_revoked",
			})
			http.Redirect(w, r, redirectBackToBrowser(customerID), http.StatusSeeOther)
			return
		}
		if errors.Is(err, gateway.ErrAdminTokenRejected) {
			http.Error(w, "Gateway admin token rejected.", http.StatusBadGateway)
			return
		}
		log.Printf("keys_revoke: revoke: %v", err)
		http.Error(w, "Gateway admin temporarily unreachable.", http.StatusBadGateway)
		return
	}

	d.Audit.Emit("key.revoke_requested", user.Email, map[string]string{
		"customer_id": customerID,
		"key_id":      keyID,
		"outcome":     "revoked",
	})
	http.Redirect(w, r, redirectBackToBrowser(customerID), http.StatusSeeOther)
}

// BulkRevokeHandler is POST /keys/bulk-revoke. CSRF-required.
//
// Per Slice 3 pattern #5: bulk operations emit ONE
// `key.revoke_requested` event PER key — NOT one bulk event. This
// keeps the audit stream join-able with single-revoke events without
// special-casing the bulk path.
//
// Worker pool size = 5, RPC rate-limit = 10/s. Both bounds shared at
// package scope so concurrent bulk jobs share the same blast budget
// against the gateway (Slice 3 pattern #24).
func (d *KeysDeps) BulkRevokeHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if user.Role != auth.RoleAdmin {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf failure", http.StatusForbidden)
		return
	}
	if !d.Configured {
		http.Error(w, "API key management not configured", http.StatusServiceUnavailable)
		return
	}
	customerID, err := d.resolveCustomerID(r)
	if err != nil {
		log.Printf("keys_bulk_revoke: resolve customer: %v", err)
		http.Error(w, "gateway admin unavailable", http.StatusBadGateway)
		return
	}
	keyIDs := r.PostForm["key_id"]
	if len(keyIDs) == 0 {
		http.Error(w, "no key_id values supplied", http.StatusBadRequest)
		return
	}
	// Cap mirrors Slice 3 bulkMaxCerts to bound a single job's blast.
	if len(keyIDs) > 100 {
		http.Error(w, "bulk job too large (max 100 keys per request)", http.StatusRequestEntityTooLarge)
		return
	}

	// Normalise + de-dupe keyIDs up front so the loop body operates on
	// a flat list. Empty entries are silently dropped (same as before
	// this fix-up); any caller submitting an empty + non-empty mix
	// will see exactly len(non_empty) audit events.
	normalized := make([]string, 0, len(keyIDs))
	for _, kid := range keyIDs {
		kid = strings.TrimSpace(kid)
		if kid == "" {
			continue
		}
		normalized = append(normalized, kid)
	}

	var wg sync.WaitGroup
	// Slice 5 fix-up r1 BH-M3: the original loop unconditionally
	// blocked on `d.revokePool <- struct{}{}` — if the request ctx
	// cancelled mid-loop, the operator's browser already moved on but
	// this handler kept spinning until every worker slot freed up,
	// silently dropping audit events for the still-queued keys.
	//
	// The ctx-aware acquire turns the cancellation into a clean
	// "abort + audit the remainder as cancelled" pattern. Audit
	// events still cover EVERY key the operator submitted, so the
	// audit stream stays joinable with single-revoke entries (per
	// Slice 3 pattern #5). Bulk=true + outcome=cancelled tells the
	// downstream analyst this was the user's abort, not a gateway
	// fault.
	cancelRemainder := func(from int) {
		for _, remaining := range normalized[from:] {
			d.Audit.Emit("key.revoke_requested", user.Email, map[string]string{
				"customer_id": customerID,
				"key_id":      remaining,
				"outcome":     "cancelled",
				"bulk":        "true",
			})
		}
	}

loop:
	for i, kid := range normalized {
		select {
		case d.revokePool <- struct{}{}:
		case <-r.Context().Done():
			cancelRemainder(i)
			break loop
		}
		wg.Add(1)
		go func(kid string) {
			defer wg.Done()
			defer func() { <-d.revokePool }()
			// Honour the package-wide rate limiter before issuing
			// each call. WaitN(1) blocks until a token is available
			// or ctx cancels. If the wait returns an error (ctx
			// done while metered), audit outcome=cancelled so the
			// stream stays consistent with cancelRemainder.
			if err := d.revokeLimiter.Wait(r.Context()); err != nil {
				d.Audit.Emit("key.revoke_requested", user.Email, map[string]string{
					"customer_id": customerID,
					"key_id":      kid,
					"outcome":     "cancelled",
					"bulk":        "true",
				})
				return
			}
			_, err := d.Admin.RevokeKey(r.Context(), customerID, kid)
			outcome := "revoked"
			if err != nil {
				if errors.Is(err, gateway.ErrKeyNotFound) {
					outcome = "already_revoked"
				} else if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
					outcome = "cancelled"
				} else {
					outcome = "failed"
					log.Printf("keys_bulk_revoke: revoke %s: %v", kid, err)
				}
			}
			d.Audit.Emit("key.revoke_requested", user.Email, map[string]string{
				"customer_id": customerID,
				"key_id":      kid,
				"outcome":     outcome,
				"bulk":        "true",
			})
		}(kid)
	}
	wg.Wait()
	http.Redirect(w, r, redirectBackToBrowser(customerID), http.StatusSeeOther)
}

// getCustomers returns the cached customer list, refreshing on TTL
// expiry. Single-flight on cache-miss prevents the boot stampede.
func (d *KeysDeps) getCustomers(ctx context.Context) ([]gateway.CustomerEntry, error) {
	now := d.clock()

	d.cacheMu.RLock()
	if !d.cachedAt.IsZero() && now.Sub(d.cachedAt) < d.cacheTTL {
		out := append([]gateway.CustomerEntry(nil), d.cachedList...)
		d.cacheMu.RUnlock()
		return out, nil
	}
	d.cacheMu.RUnlock()

	v, err, _ := d.cacheFlight.Do("customers", func() (interface{}, error) {
		// Recheck once we own the flight slot — another goroutine may
		// have refreshed while we were waiting.
		d.cacheMu.RLock()
		if !d.cachedAt.IsZero() && d.clock().Sub(d.cachedAt) < d.cacheTTL {
			cached := append([]gateway.CustomerEntry(nil), d.cachedList...)
			d.cacheMu.RUnlock()
			return cached, nil
		}
		d.cacheMu.RUnlock()

		// Detach the inner gateway-call ctx from the caller's ctx.
		// singleflight.Do passes the FIRST caller's closure to every
		// coalesced caller; if caller A's request ctx cancels mid-
		// fetch, caller B (and any others coalesced on the same key)
		// would otherwise receive the cancellation and surface a
		// spurious 502 to the operator. The 10s timeout matches the
		// gateway admin-call SLO and bounds the worst-case wait so
		// coalesced callers cannot block forever if the gateway hangs.
		inner, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		fresh, err := d.Admin.ListCustomers(inner)
		if err != nil {
			return nil, err
		}
		d.cacheMu.Lock()
		d.cachedList = fresh
		d.cachedAt = d.clock()
		d.cacheMu.Unlock()
		return append([]gateway.CustomerEntry(nil), fresh...), nil
	})
	if err != nil {
		return nil, err
	}
	return v.([]gateway.CustomerEntry), nil
}

// populateCustomerState fills in SelectedID, ShowSelector, NoCustomers
// on the page data.
func (d *KeysDeps) populateCustomerState(data *keysPageData, customers []gateway.CustomerEntry, requested string) {
	data.Customers = customers
	if len(customers) == 0 {
		data.NoCustomers = true
		return
	}
	if len(customers) >= 2 {
		data.ShowSelector = true
	}
	if requested != "" {
		for _, c := range customers {
			if c.CustomerID == requested {
				data.SelectedID = requested
				return
			}
		}
	}
	data.SelectedID = customers[0].CustomerID
	if len(customers) == 1 {
		data.CustomersWarn = "Single customer auto-detected (" + customers[0].CustomerID + ")."
	}
}

// resolveCustomerID extracts the customer_id form field or falls back
// to the auto-detected single customer.
func (d *KeysDeps) resolveCustomerID(r *http.Request) (string, error) {
	if v := strings.TrimSpace(r.PostFormValue("customer_id")); v != "" {
		return v, nil
	}
	customers, err := d.getCustomers(r.Context())
	if err != nil {
		return "", err
	}
	if len(customers) == 0 {
		return "", errors.New("no customers configured in gateway keystore")
	}
	return customers[0].CustomerID, nil
}

// extractKeyIDFromRevokePath returns the key_id segment from
// /keys/<key_id>/revoke. Returns "" on unexpected shapes so the handler
// surfaces a 400.
func extractKeyIDFromRevokePath(path string) string {
	const prefix = "/keys/"
	const suffix = "/revoke"
	if !strings.HasPrefix(path, prefix) || !strings.HasSuffix(path, suffix) {
		return ""
	}
	mid := strings.TrimPrefix(path, prefix)
	mid = strings.TrimSuffix(mid, suffix)
	// Reject any embedded slashes — the key_id is a single path segment.
	if strings.Contains(mid, "/") {
		return ""
	}
	return mid
}

// redirectBackToBrowser builds the canonical /keys URL preserving the
// active customer selection.
func redirectBackToBrowser(customerID string) string {
	if customerID == "" {
		return "/keys"
	}
	// The customer_id is gateway-side-validated input echoed back here;
	// we still URL-escape to defeat any future shape that lets a hostile
	// gateway response inject a redirect.
	return "/keys?customer_id=" + escapeQueryValue(customerID)
}

// escapeQueryValue is a tiny inline percent-encoder for the limited
// query-value byte set the dashboard uses. Avoids pulling net/url for
// a one-call site. Mirrors strings the dashboard's other handlers
// reach for; see handlers/certs.go for the wider precedent.
func escapeQueryValue(v string) string {
	const safe = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-."
	var b strings.Builder
	for i := 0; i < len(v); i++ {
		c := v[i]
		if strings.IndexByte(safe, c) >= 0 {
			b.WriteByte(c)
			continue
		}
		// Hex-encode.
		b.WriteByte('%')
		const hex = "0123456789ABCDEF"
		b.WriteByte(hex[c>>4])
		b.WriteByte(hex[c&0x0F])
	}
	return b.String()
}

func (d *KeysDeps) render(w http.ResponseWriter, data keysPageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "keys/browser.html.tmpl", data); err != nil {
		log.Printf("keys_browser: render: %v", err)
	}
}
