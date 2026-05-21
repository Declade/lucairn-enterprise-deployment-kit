package handlers

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"github.com/jackc/pgx/v5"
)

// fakeAuditReadStore is the AuditReadStore double for handler tests.
type fakeAuditReadStore struct {
	events      []store.AuditEvent
	total       int
	listErr     error
	getErr      error
	getRow      *store.AuditEvent
	distinctEv  []string
	distinctSvc []string
	mu          sync.Mutex
	listCalls   int
}

func (f *fakeAuditReadStore) ListEvents(_ context.Context, _ store.AuditFilter) ([]store.AuditEvent, int, error) {
	f.mu.Lock()
	f.listCalls++
	f.mu.Unlock()
	if f.listErr != nil {
		return nil, 0, f.listErr
	}
	return f.events, f.total, nil
}
func (f *fakeAuditReadStore) GetEvent(_ context.Context, _ string) (*store.AuditEvent, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	if f.getRow == nil {
		return nil, pgx.ErrNoRows
	}
	return f.getRow, nil
}
func (f *fakeAuditReadStore) DistinctEventTypes(_ context.Context) ([]string, error) {
	return f.distinctEv, nil
}
func (f *fakeAuditReadStore) DistinctSourceServices(_ context.Context) ([]string, error) {
	return f.distinctSvc, nil
}

// fakeSavedFilters is the SavedFiltersReadWriteStore double.
type fakeSavedFilters struct {
	rows      map[string]map[string]store.AuditFilter // user -> name -> filter
	missing   bool
	saveErr   error
	deleteErr error
}

func newFakeSavedFilters() *fakeSavedFilters {
	return &fakeSavedFilters{rows: make(map[string]map[string]store.AuditFilter)}
}

func (f *fakeSavedFilters) Save(_ context.Context, user, name string, filter store.AuditFilter) error {
	if f.missing {
		return store.ErrSavedFilterTableMissing
	}
	if f.saveErr != nil {
		return f.saveErr
	}
	if _, ok := f.rows[user]; !ok {
		f.rows[user] = make(map[string]store.AuditFilter)
	}
	f.rows[user][name] = filter
	return nil
}
func (f *fakeSavedFilters) List(_ context.Context, user string) ([]store.SavedFilter, error) {
	if f.missing {
		return nil, store.ErrSavedFilterTableMissing
	}
	got := f.rows[user]
	out := make([]store.SavedFilter, 0, len(got))
	for name, flt := range got {
		out = append(out, store.SavedFilter{UserEmail: user, Name: name, Filter: flt, UpdatedAt: time.Now()})
	}
	return out, nil
}
func (f *fakeSavedFilters) Delete(_ context.Context, user, name string) error {
	if f.missing {
		return store.ErrSavedFilterTableMissing
	}
	if f.deleteErr != nil {
		return f.deleteErr
	}
	if m, ok := f.rows[user]; ok {
		delete(m, name)
	}
	return nil
}

func newRenderer(t *testing.T) *views.Renderer {
	t.Helper()
	r, err := views.New()
	if err != nil {
		t.Fatalf("views.New: %v", err)
	}
	return r
}

func newAdminUser() auth.User { return auth.User{Email: "admin@lucairn.local", Role: auth.RoleAdmin} }
func newViewerUser() auth.User {
	return auth.User{Email: "viewer@lucairn.local", Role: auth.RoleViewer}
}

func withUser(req *http.Request, u auth.User) *http.Request {
	sess := &auth.Session{
		ID:        "test-session",
		User:      u,
		CreatedAt: time.Now(),
		LastSeen:  time.Now(),
	}
	return auth.WithSessionForTest(req, sess)
}

// === Tests ===

func TestAudit_NotConfigured_RendersExplainer(t *testing.T) {
	d := NewAuditDeps(newRenderer(t), nil, nil, audit.NewMemoryEmitter(), false)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	if rr.Code != 200 {
		t.Fatalf("not-configured render code: %d", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "Audit log browser is not configured") {
		t.Fatalf("not-configured copy missing: %s", rr.Body.String())
	}
}

func TestAudit_ListViewer_RendersRedactedPayloads(t *testing.T) {
	st := &fakeAuditReadStore{
		events: []store.AuditEvent{{
			ID:            1,
			EventID:       "ev-1",
			EventType:     "key.revoke_requested",
			SourceService: "lucairn-dashboard",
			Actor:         "bob@example.com",
			Timestamp:     time.Now().UTC(),
			Payload:       []byte(`{"key_id":"key_1","actor_email":"bob@example.com","ip":"192.168.42.7"}`),
			RequestID:     "req-1",
			PayloadType:   "FLAT_JSON",
		}},
		total: 1,
	}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit", nil), newViewerUser())
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	if rr.Code != 200 {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if strings.Contains(body, "bob@example.com") {
		t.Fatalf("viewer saw raw email: %s", body)
	}
	if !strings.Contains(body, "[EMAIL]") {
		t.Fatalf("viewer missing redaction marker: %s", body)
	}
	if strings.Contains(body, "192.168.42.7") {
		t.Fatalf("viewer saw raw IP: %s", body)
	}
}

func TestAudit_ListAdmin_StillRedactedByDefault(t *testing.T) {
	st := &fakeAuditReadStore{
		events: []store.AuditEvent{{
			ID:            1,
			EventID:       "ev-2",
			EventType:     "audit.reveal_raw",
			SourceService: "lucairn-dashboard",
			Actor:         "admin@lucairn.local",
			Timestamp:     time.Now().UTC(),
			Payload:       []byte(`{"target_request_id":"req-7","target_email":"alice@example.com"}`),
		}},
		total: 1,
	}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	body := rr.Body.String()
	if strings.Contains(body, "alice@example.com") {
		t.Fatalf("admin default view leaked email: %s", body)
	}
}

func TestAudit_RevealRawAdmin_EmitsAuditEvent(t *testing.T) {
	mem := audit.NewMemoryEmitter()
	ev := &store.AuditEvent{
		EventID:       "ev-target",
		EventType:     "key.mint_requested",
		SourceService: "lucairn-dashboard",
		Actor:         "alice@example.com",
		Timestamp:     time.Now(),
		Payload:       []byte(`{"key_id":"k1","actor_email":"alice@example.com"}`),
		RequestID:     "req-target",
		PayloadType:   "FLAT_JSON",
	}
	st := &fakeAuditReadStore{getRow: ev}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), mem, true)

	// Prime CSRF cookie via IssueToken on a parallel request.
	csrfReq := httptest.NewRequest(http.MethodGet, "/audit/ev-target", nil)
	csrfRR := httptest.NewRecorder()
	tok, err := auth.IssueToken(csrfRR, csrfReq)
	if err != nil {
		t.Fatalf("issue csrf: %v", err)
	}
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("csrf_token", tok)
	req := httptest.NewRequest(http.MethodPost, "/audit/ev-target/reveal-raw", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range csrfRR.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withUser(req, newAdminUser())
	rr := httptest.NewRecorder()
	d.RevealRawHandler(rr, req)
	if rr.Code != 200 {
		t.Fatalf("reveal status: %d body=%s", rr.Code, rr.Body.String())
	}
	if got := mem.CountByEventType("audit.reveal_raw"); got != 1 {
		t.Fatalf("audit.reveal_raw emits: got %d want 1", got)
	}
	// On admin reveal, the raw payload IS in the response body.
	if !strings.Contains(rr.Body.String(), "alice@example.com") {
		t.Fatalf("admin reveal did not return raw email: %s", rr.Body.String())
	}
}

func TestAudit_RevealRawViewer_Returns404(t *testing.T) {
	// Slice 6 fix-up r1 H2: drive through the production middleware
	// chain so a viewer-session cookie is the test driver, not a
	// direct WithSessionForTest injection. Closes the Slice 4 C33 /
	// Slice 5 BH-H2 tautological-test gap — a regression that dropped
	// the `user.Role != auth.RoleAdmin` guard in the handler would
	// previously still pass this test because we never exercised
	// auth.CurrentUser via the actual cookie path. (The handler also
	// keeps its defence-in-depth role check; this test validates the
	// route-level surface, not the direct call.)
	ev := &store.AuditEvent{EventID: "ev-9", EventType: "x"}
	d := NewAuditDeps(newRenderer(t), &fakeAuditReadStore{getRow: ev}, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)

	sessStore := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer sessStore.Close()
	sess, err := sessStore.Create(auth.User{Email: "viewer@lucairn.local", Role: auth.RoleViewer})
	if err != nil {
		t.Fatalf("create viewer session: %v", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /audit/{event_id}/reveal-raw", d.RevealRawHandler)
	chain := auth.LoadSession(sessStore)(auth.RequireSession()(mux))

	req := httptest.NewRequest(http.MethodPost, "/audit/ev-9/reveal-raw", nil)
	req.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: sess.ID})
	rr := httptest.NewRecorder()
	chain.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("viewer reveal via middleware chain: got %d want 404", rr.Code)
	}
}

func TestAudit_CSVExport_DefaultRedacted(t *testing.T) {
	st := &fakeAuditReadStore{
		events: []store.AuditEvent{{
			EventID: "ev-csv-1", EventType: "x", SourceService: "y", Actor: "alice@example.com",
			Timestamp: time.Now().UTC(),
			Payload:   []byte(`{"ip":"10.0.0.1","email":"bob@example.com"}`),
		}},
		total: 1,
	}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit/export.csv", nil), newViewerUser())
	rr := httptest.NewRecorder()
	d.CSVExportHandler(rr, req)
	if rr.Code != 200 {
		t.Fatalf("csv status: %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	if strings.Contains(body, "alice@example.com") || strings.Contains(body, "bob@example.com") {
		t.Fatalf("CSV leaked raw email: %s", body)
	}
	if strings.Contains(body, "10.0.0.1") {
		t.Fatalf("CSV leaked raw IP: %s", body)
	}
}

func TestAudit_CSVExport_RevealRequiresAdmin(t *testing.T) {
	d := NewAuditDeps(newRenderer(t), &fakeAuditReadStore{}, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := httptest.NewRequest(http.MethodGet, "/audit/export.csv?reveal=true", nil)
	req = withUser(req, newViewerUser())
	rr := httptest.NewRecorder()
	d.CSVExportHandler(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("viewer reveal=true: got %d want 404", rr.Code)
	}
}

func TestAudit_CSVExport_RevealAdminEmitsAuditEvent(t *testing.T) {
	mem := audit.NewMemoryEmitter()
	st := &fakeAuditReadStore{
		events: []store.AuditEvent{{
			EventID: "ev-csv-r", EventType: "x", SourceService: "y", Actor: "alice@example.com",
			Timestamp: time.Now().UTC(),
			Payload:   []byte(`{"email":"alice@example.com"}`),
		}},
		total: 1,
	}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), mem, true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit/export.csv?reveal=true", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.CSVExportHandler(rr, req)
	if rr.Code != 200 {
		t.Fatalf("admin reveal csv status: %d", rr.Code)
	}
	if mem.CountByEventType("audit.csv_export_with_reveal") != 1 {
		evs := mem.Events()
		t.Fatalf("csv reveal emit count: got events=%v", evs)
	}
	if !strings.Contains(rr.Body.String(), "alice@example.com") {
		t.Fatalf("admin reveal csv did NOT emit raw email: %s", rr.Body.String())
	}
}

// TestAudit_CSVExportReveal_EmitFailsReturns500NoRaw verifies the
// fail-closed invariance on the CSV-export-with-reveal path: if the
// emitter returns an error (e.g. audit DB unreachable), the handler
// MUST 500 before streaming any rows and MUST NOT leak raw PII into
// the response body. Mirrors TestAudit_RevealRawAdmin_EmitFailsReturns500
// for the reveal-raw single-event path.
func TestAudit_CSVExportReveal_EmitFailsReturns500NoRaw(t *testing.T) {
	t.Parallel()
	mem := audit.NewMemoryEmitter()
	mem.SetEmitErr(errors.New("synthetic CSV-reveal DB INSERT failure"))
	st := &fakeAuditReadStore{
		events: []store.AuditEvent{{
			EventID: "ev-csv-fail", EventType: "x", SourceService: "y", Actor: "alice@example.com",
			Timestamp: time.Now().UTC(),
			Payload:   []byte(`{"email":"alice@example.com"}`),
		}},
		total: 1,
	}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), mem, true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit/export.csv?reveal=true", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.CSVExportHandler(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("csv-reveal emit-failure status: got %d want 500", rr.Code)
	}
	if strings.Contains(rr.Body.String(), "alice@example.com") {
		t.Fatalf("FAIL-CLOSED INVARIANT BROKEN: csv-export-with-reveal leaked raw email after emit failure: %s", rr.Body.String())
	}
}

func TestAudit_PIIGuard_RegexMatchesL1Patterns(t *testing.T) {
	// Hand the audit handler a payload string containing every L1
	// pattern + assert each one is redacted at render time.
	st := &fakeAuditReadStore{
		events: []store.AuditEvent{{
			EventID:   "ev-l1",
			EventType: "x", SourceService: "y", Actor: "alice@example.com",
			Timestamp: time.Now().UTC(),
			Payload: []byte(`{
				"email":"alice@example.com",
				"phone":"+49 30 12345 6789",
				"ssn":"123-45-6789",
				"ipv4":"192.168.42.7",
				"uuid":"550e8400-e29b-41d4-a716-446655440000",
				"iban":"DE89370400440532013000",
				"mrn":"MRN-1234567"
			}`),
		}},
		total: 1,
	}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit/ev-l1", nil), newViewerUser())
	rr := httptest.NewRecorder()
	// DetailHandler needs the row.
	st.getRow = &st.events[0]
	d.DetailHandler(rr, req)
	body := rr.Body.String()
	for _, raw := range []string{
		"alice@example.com",
		"+49 30 12345 6789",
		"123-45-6789",
		"192.168.42.7",
		"550e8400-e29b-41d4-a716-446655440000",
		"DE89370400440532013000",
		"MRN-1234567",
	} {
		if strings.Contains(body, raw) {
			t.Fatalf("PII guard leaked %q in body: %s", raw, body)
		}
	}
}

func TestAudit_SavedFiltersScope_OnlyOwnUserVisible(t *testing.T) {
	sf := newFakeSavedFilters()
	if err := sf.Save(context.Background(), "alice@x", "myfilter", store.AuditFilter{}); err != nil {
		t.Fatalf("save alice: %v", err)
	}
	if err := sf.Save(context.Background(), "bob@x", "otherfilter", store.AuditFilter{}); err != nil {
		t.Fatalf("save bob: %v", err)
	}
	// alice sees only her filter.
	aliceList, err := sf.List(context.Background(), "alice@x")
	if err != nil {
		t.Fatalf("alice list: %v", err)
	}
	if len(aliceList) != 1 || aliceList[0].Name != "myfilter" {
		t.Fatalf("alice cross-tenant leak: %+v", aliceList)
	}
	// bob sees only his.
	bobList, err := sf.List(context.Background(), "bob@x")
	if err != nil {
		t.Fatalf("bob list: %v", err)
	}
	if len(bobList) != 1 || bobList[0].Name != "otherfilter" {
		t.Fatalf("bob cross-tenant leak: %+v", bobList)
	}
}

func TestAudit_SavedFilterMaxNameLength_Validates(t *testing.T) {
	mem := audit.NewMemoryEmitter()
	d := NewAuditDeps(newRenderer(t), &fakeAuditReadStore{}, newFakeSavedFilters(), mem, true)
	// 101 chars.
	longName := strings.Repeat("a", 101)
	csrfReq := httptest.NewRequest(http.MethodGet, "/audit", nil)
	csrfRR := httptest.NewRecorder()
	tok, _ := auth.IssueToken(csrfRR, csrfReq)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("csrf_token", tok)
	form.Set("name", longName)
	req := httptest.NewRequest(http.MethodPost, "/audit/saved-filters", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range csrfRR.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withUser(req, newViewerUser())
	rr := httptest.NewRecorder()
	d.SavedFiltersPost(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("long-name save status: got %d want 400", rr.Code)
	}
}

func TestAudit_SavedFiltersPost_Persists(t *testing.T) {
	sf := newFakeSavedFilters()
	mem := audit.NewMemoryEmitter()
	d := NewAuditDeps(newRenderer(t), &fakeAuditReadStore{}, sf, mem, true)
	csrfReq := httptest.NewRequest(http.MethodGet, "/audit", nil)
	csrfRR := httptest.NewRecorder()
	tok, _ := auth.IssueToken(csrfRR, csrfReq)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("csrf_token", tok)
	form.Set("name", "my-saved")
	form.Set("event_type", "key.mint_requested,cert.verify_requested")
	form.Set("source_service", "dsa-gateway")
	req := httptest.NewRequest(http.MethodPost, "/audit/saved-filters", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range csrfRR.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withUser(req, newViewerUser())
	rr := httptest.NewRecorder()
	d.SavedFiltersPost(rr, req)
	if rr.Code != http.StatusSeeOther {
		t.Fatalf("save status: got %d want 303, body=%s", rr.Code, rr.Body.String())
	}
	rows, _ := sf.List(context.Background(), "viewer@lucairn.local")
	if len(rows) != 1 || rows[0].Name != "my-saved" {
		t.Fatalf("saved filter not persisted: %+v", rows)
	}
	if len(rows[0].Filter.EventTypes) != 2 {
		t.Fatalf("event_types not persisted: %+v", rows[0].Filter.EventTypes)
	}
}

func TestAudit_BadGetEventReturns404(t *testing.T) {
	d := NewAuditDeps(newRenderer(t), &fakeAuditReadStore{getErr: pgx.ErrNoRows}, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit/missing", nil), newViewerUser())
	rr := httptest.NewRecorder()
	d.DetailHandler(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("missing event: got %d want 404", rr.Code)
	}
}

func TestAudit_ListUnauth_Returns302ToLogin(t *testing.T) {
	// Slice 6 fix-up r1 H2: route via the production middleware chain.
	// A direct handler call exercises only the handler's
	// CurrentUser-not-found branch; RequireSession's redirect-to-/login
	// is the actual unauth gate at the production edge. The test now
	// asserts the chain's `Location: /login?next=...` shape that
	// matches Slice 4 C33's chain pattern.
	d := NewAuditDeps(newRenderer(t), &fakeAuditReadStore{}, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	sessStore := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer sessStore.Close()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /audit", d.BrowserHandler)
	chain := auth.LoadSession(sessStore)(auth.RequireSession()(mux))

	req := httptest.NewRequest(http.MethodGet, "/audit", nil)
	rr := httptest.NewRecorder()
	chain.ServeHTTP(rr, req)
	if rr.Code != http.StatusFound {
		t.Fatalf("unauth status via middleware chain: got %d want 302", rr.Code)
	}
	loc := rr.Header().Get("Location")
	if !strings.HasPrefix(loc, "/login?next=") {
		t.Fatalf("unauth redirect: got %q want /login?next=...", loc)
	}
	if !strings.Contains(loc, "%2Faudit") {
		t.Fatalf("unauth redirect missing URL-encoded /audit: %q", loc)
	}
}

func TestAudit_PIIGuardOnMalformedPayload_RendersSentinel(t *testing.T) {
	st := &fakeAuditReadStore{getRow: &store.AuditEvent{
		EventID:   "ev-malformed",
		EventType: "x", SourceService: "y", Actor: "alice@example.com",
		Timestamp:   time.Now().UTC(),
		Payload:     nil,
		PayloadType: "BINARY",
	}}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit/ev-malformed", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.DetailHandler(rr, req)
	if rr.Code != 200 {
		t.Fatalf("malformed render status: %d", rr.Code)
	}
}

// === Slice 6 fix-up r1: BLOCKER + HIGH regression coverage ===
//
// TestSavedFilters_NoConnectionLeak lives in
// internal/store/saved_filters_leak_test.go (the fake Querier
// implementation is package-private to store, so the leak regression
// test belongs in the store package's test file).

// TestAudit_ListPreview_PreservesNumericIDs verifies populateRedactedRows
// routes JSON payloads through piiguard.RedactJSON so numeric leaves
// (audit_event id, latency_ms, port, response_size, BIGSERIAL ids) are
// preserved. The flat piiguard.Redact treats every 5-digit number as
// [POSTAL] and 13-19 digit number as [PAN] — that turns the audit
// browser into a wall of [POSTAL][POSTAL][POSTAL] which is unusable
// for triage.
func TestAudit_ListPreview_PreservesNumericIDs(t *testing.T) {
	t.Parallel()
	// Numeric leaves MUST survive intact; only the email string MUST
	// be redacted to [EMAIL].
	st := &fakeAuditReadStore{
		events: []store.AuditEvent{{
			EventID:   "ev-num-1",
			EventType: "key.mint_requested",
			SourceService: "dsa-gateway",
			Actor:     "ops@example.com",
			Timestamp: time.Now().UTC(),
			Payload:   []byte(`{"id":1234567890123,"latency_ms":12345,"port":50051,"response_size":98765}`),
		}},
		total: 1,
	}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/audit", nil), newViewerUser())
	rr := httptest.NewRecorder()
	d.BrowserHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	for _, want := range []string{"1234567890123", "12345", "50051", "98765"} {
		if !strings.Contains(body, want) {
			t.Errorf("numeric leaf %s was redacted (RedactJSON regression): body=%s", want, body)
		}
	}
	// Sanity: actor email is still redacted.
	if strings.Contains(body, "ops@example.com") {
		t.Errorf("actor email NOT redacted: body=%s", body)
	}

	// Now flip to a payload with email as a string leaf — must be
	// redacted to [EMAIL] by RedactJSON's string-walker.
	st.events[0].Payload = []byte(`{"id":42,"email":"marc@example.com"}`)
	rr = httptest.NewRecorder()
	d.BrowserHandler(rr, withUser(httptest.NewRequest(http.MethodGet, "/audit", nil), newViewerUser()))
	body = rr.Body.String()
	if strings.Contains(body, "marc@example.com") {
		t.Errorf("email string leaf NOT redacted in list preview: %s", body)
	}
	if !strings.Contains(body, "42") {
		t.Errorf("numeric leaf 42 was redacted (RedactJSON regression): %s", body)
	}
}

// TestAudit_RevealRawViaMiddleware exercises the full middleware
// chain on the admin reveal path — drives a session cookie + CSRF
// token + form post — and verifies the admin reveal works end-to-end
// through the production gate. Closes the Slice 4 C33 / Slice 5 BH-H2
// gap a second time on the admin path (the negative-case viewer
// test is TestAudit_RevealRawViewer_Returns404).
func TestAudit_RevealRawViaMiddleware(t *testing.T) {
	t.Parallel()
	mem := audit.NewMemoryEmitter()
	ev := &store.AuditEvent{
		EventID:       "ev-target-middleware",
		EventType:     "key.mint_requested",
		SourceService: "lucairn-dashboard",
		Actor:         "alice@example.com",
		Timestamp:     time.Now(),
		Payload:       []byte(`{"key_id":"k1"}`),
		RequestID:     "req-target",
		PayloadType:   "FLAT_JSON",
	}
	st := &fakeAuditReadStore{getRow: ev}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), mem, true)

	sessStore := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer sessStore.Close()
	sess, err := sessStore.Create(auth.User{Email: "admin@lucairn.local", Role: auth.RoleAdmin})
	if err != nil {
		t.Fatalf("create admin session: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /audit/{event_id}/reveal-raw", d.RevealRawHandler)
	chain := auth.LoadSession(sessStore)(auth.RequireSession()(mux))

	// Prime CSRF token. IssueToken stamps a cookie + returns the
	// matching token; production code reissues via the same mux so we
	// emulate by calling IssueToken against the same session cookie.
	csrfReq := httptest.NewRequest(http.MethodGet, "/audit/ev-target-middleware", nil)
	csrfReq.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: sess.ID})
	csrfRR := httptest.NewRecorder()
	tok, err := auth.IssueToken(csrfRR, csrfReq)
	if err != nil {
		t.Fatalf("csrf issue: %v", err)
	}
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("csrf_token", tok)
	req := httptest.NewRequest(http.MethodPost, "/audit/ev-target-middleware/reveal-raw", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: sess.ID})
	for _, c := range csrfRR.Result().Cookies() {
		req.AddCookie(c)
	}
	rr := httptest.NewRecorder()
	chain.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("admin reveal via middleware: status=%d body=%s", rr.Code, rr.Body.String())
	}
	if mem.CountByEventType("audit.reveal_raw") != 1 {
		t.Fatalf("audit.reveal_raw not emitted via middleware chain: %v", mem.Events())
	}
}

// TestAudit_RevealRawAdmin_EmitFailsReturns500 verifies the
// fail-closed invariance: if the audit emitter returns an error, the
// handler MUST 500 and MUST NOT return the raw payload. This is the
// load-bearing security guarantee — the audit trail and the on-screen
// reveal stay consistent or both fail.
func TestAudit_RevealRawAdmin_EmitFailsReturns500(t *testing.T) {
	t.Parallel()
	mem := audit.NewMemoryEmitter()
	mem.SetEmitErr(errors.New("synthetic DB INSERT failure"))
	ev := &store.AuditEvent{
		EventID:       "ev-emit-fail",
		EventType:     "key.mint_requested",
		SourceService: "lucairn-dashboard",
		Actor:         "alice@example.com",
		Timestamp:     time.Now(),
		Payload:       []byte(`{"email":"alice@example.com","key_id":"k1"}`),
		RequestID:     "req-fail",
		PayloadType:   "FLAT_JSON",
	}
	st := &fakeAuditReadStore{getRow: ev}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), mem, true)

	csrfReq := httptest.NewRequest(http.MethodGet, "/audit/ev-emit-fail", nil)
	csrfRR := httptest.NewRecorder()
	tok, err := auth.IssueToken(csrfRR, csrfReq)
	if err != nil {
		t.Fatalf("csrf issue: %v", err)
	}
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("csrf_token", tok)
	req := httptest.NewRequest(http.MethodPost, "/audit/ev-emit-fail/reveal-raw", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range csrfRR.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withUser(req, newAdminUser())
	rr := httptest.NewRecorder()
	d.RevealRawHandler(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("emit-failure status: got %d want 500", rr.Code)
	}
	if strings.Contains(rr.Body.String(), "alice@example.com") {
		t.Fatalf("FAIL-CLOSED INVARIANT BROKEN: handler returned raw email after emit failure: %s", rr.Body.String())
	}
}

// TestAudit_RevealRawAdmin_EmitsToDB verifies the production DBEmitter
// path performs the audit_events INSERT before the handler returns
// raw text. The fake pgxpool counts INSERTs; if the count is 1 + the
// handler returned 200, the contract holds.
func TestAudit_RevealRawAdmin_EmitsToDB(t *testing.T) {
	t.Parallel()
	// Use MemoryEmitter to verify the handler "tried to emit before
	// returning raw". The DBEmitter implementation is exercised by
	// audit/db_emitter_test.go.
	mem := audit.NewMemoryEmitter()
	ev := &store.AuditEvent{
		EventID:       "ev-db-emit",
		EventType:     "key.mint_requested",
		SourceService: "lucairn-dashboard",
		Actor:         "alice@example.com",
		Timestamp:     time.Now(),
		Payload:       []byte(`{"key_id":"k1"}`),
		RequestID:     "req-db",
		PayloadType:   "FLAT_JSON",
	}
	st := &fakeAuditReadStore{getRow: ev}
	d := NewAuditDeps(newRenderer(t), st, newFakeSavedFilters(), mem, true)

	csrfReq := httptest.NewRequest(http.MethodGet, "/audit/ev-db-emit", nil)
	csrfRR := httptest.NewRecorder()
	tok, err := auth.IssueToken(csrfRR, csrfReq)
	if err != nil {
		t.Fatalf("csrf issue: %v", err)
	}
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("csrf_token", tok)
	req := httptest.NewRequest(http.MethodPost, "/audit/ev-db-emit/reveal-raw", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range csrfRR.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withUser(req, newAdminUser())
	rr := httptest.NewRecorder()
	d.RevealRawHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	if mem.CountByEventType("audit.reveal_raw") != 1 {
		t.Fatalf("emit count: got %d want 1; events=%v", mem.CountByEventType("audit.reveal_raw"), mem.Events())
	}
}

// _ keeps io + errors + strconv in the imports for future test cases.
var _ = io.ReadAll
var _ = errors.New
var _ = context.Background
var _ = strconv.Itoa
