package handlers

import (
	"bytes"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/compliance"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// fakeQuerier is a pgx-shaped fake (defined in audit_test.go path
// imports it indirectly via interface; here we redefine locally to
// keep coverage clean).
//
// Rather than duplicate pgx.Rows machinery for the compliance handler
// test, we directly inject a fully-populated *compliance.Aggregator
// whose DB layers are stubbed via compliance package internals.
// Simpler path: tests pass nil for both DBs (aggregator returns
// zero-value summaries) then assert on the resulting PDF + audit
// emit. The aggregator_test.go covers the DB-shape contract.

func newComplianceAggregator() *compliance.Aggregator {
	return compliance.NewAggregator(nil, nil, compliance.AggregatorOpts{
		MaxWindowDays: 365,
		Now:           func() time.Time { return time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC) },
	})
}

func newComplianceDeps(t *testing.T, emitter audit.Emitter, configured bool) *ComplianceDeps {
	t.Helper()
	agg := newComplianceAggregator()
	if !configured {
		agg = nil
	}
	return NewComplianceDeps(
		newRenderer(t),
		agg,
		emitter,
		"1.4.0-dashboard",
		"0.7.0",
		map[string]string{"lucairn-dashboard": "0.7.0", "dsa-gateway": "0.4.0"},
		365,
		"",
		configured,
	)
}

func TestCompliance_NotConfigured_GETRendersExplainer(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), false)
	req := withUser(httptest.NewRequest(http.MethodGet, "/compliance", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPage(rr, req)
	if rr.Code != 200 {
		t.Fatalf("GET /compliance code = %d, want 200", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "Compliance export is not configured") {
		t.Errorf("not-configured copy missing in body: %s", rr.Body.String()[:min(500, len(rr.Body.String()))])
	}
}

func TestCompliance_NotConfigured_POSTReturns404(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), false)
	form := url.Values{}
	form.Set("customer_name", "Acme")
	form.Set("from", "2026-04-01")
	form.Set("to", "2026-04-30")
	req := withUser(httptest.NewRequest(http.MethodPost, "/compliance/export", strings.NewReader(form.Encode())), newAdminUser())
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != 404 {
		t.Errorf("POST when unconfigured code = %d, want 404", rr.Code)
	}
}

func TestCompliance_Configured_GETRendersForm(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/compliance", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPage(rr, req)
	if rr.Code != 200 {
		t.Fatalf("GET configured code = %d, want 200", rr.Code)
	}
	body := rr.Body.String()
	for _, must := range []string{
		`name="from"`,
		`name="to"`,
		`name="customer_name"`,
		`name="csrf"`,
		"Generate PDF",
	} {
		if !strings.Contains(body, must) {
			t.Errorf("form body missing %q", must)
		}
	}
}

// withCSRFAndUser issues a fresh CSRF token + binds it to the form
// + attaches the test session.
func withCSRFAndUser(t *testing.T, method, target string, form url.Values, user auth.User) *http.Request {
	t.Helper()
	// Issue a CSRF token via a GET handshake.
	probeReq := httptest.NewRequest(http.MethodGet, "/compliance", nil)
	probeRR := httptest.NewRecorder()
	tok, err := auth.IssueToken(probeRR, probeReq)
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	if form == nil {
		form = url.Values{}
	}
	form.Set("csrf", tok)

	req := httptest.NewRequest(method, target, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range probeRR.Result().Cookies() {
		req.AddCookie(c)
	}
	return withUser(req, user)
}

func TestCompliance_POST_CSRFRequired(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	form := url.Values{}
	form.Set("customer_name", "Acme")
	form.Set("from", "2026-04-01")
	form.Set("to", "2026-04-30")
	// NO csrf token in form.
	req := withUser(httptest.NewRequest(http.MethodPost, "/compliance/export", strings.NewReader(form.Encode())), newAdminUser())
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Errorf("POST without CSRF code = %d, want 403", rr.Code)
	}
}

func TestCompliance_POST_InvalidDateRangeReturns400(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	form := url.Values{}
	form.Set("customer_name", "Acme")
	form.Set("from", "2026-05-30")
	form.Set("to", "2026-04-01") // inverted
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("inverted date code = %d, want 400", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "date range") {
		t.Errorf("error body missing 'date range': %s", rr.Body.String())
	}
}

func TestCompliance_POST_DateRangeTooLargeReturns400(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	d.MaxWindowDays = 30
	form := url.Values{}
	form.Set("customer_name", "Acme")
	form.Set("from", "2026-01-01")
	form.Set("to", "2026-03-31")
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("excessive window code = %d, want 400", rr.Code)
	}
}

func TestCompliance_POST_BannedLiteralInCustomerNameReturns400(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	form := url.Values{}
	form.Set("customer_name", "Acme HIPAA Corp")
	form.Set("from", "2026-04-01")
	form.Set("to", "2026-04-30")
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("banned literal in customer name code = %d, want 400", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "banned literal") {
		t.Errorf("error body missing 'banned literal': %s", rr.Body.String())
	}
}

func TestCompliance_POST_SuccessReturnsPDFWithMagicBytes_AndEmitsAuditEvent(t *testing.T) {
	emitter := audit.NewMemoryEmitter()
	d := newComplianceDeps(t, emitter, true)
	form := url.Values{}
	form.Set("customer_name", "Acme Corp GmbH")
	form.Set("from", "2026-04-01")
	form.Set("to", "2026-04-30")
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != 200 {
		t.Fatalf("success code = %d, want 200 (body: %s)", rr.Code, rr.Body.String()[:min(500, len(rr.Body.String()))])
	}
	if ct := rr.Header().Get("Content-Type"); ct != "application/pdf" {
		t.Errorf("Content-Type = %q, want application/pdf", ct)
	}
	if cd := rr.Header().Get("Content-Disposition"); !strings.Contains(cd, "attachment") || !strings.HasSuffix(cd, `.pdf"`) {
		t.Errorf("Content-Disposition = %q (should be attachment + .pdf filename)", cd)
	}
	if !bytes.HasPrefix(rr.Body.Bytes(), []byte("%PDF-1.")) {
		t.Errorf("body missing %%PDF-1. magic; got prefix: %q", rr.Body.Bytes()[:min(20, rr.Body.Len())])
	}

	// Audit event MUST have been emitted exactly once.
	if got := emitter.CountByEventType("audit.compliance_pdf_generated"); got != 1 {
		t.Errorf("audit.compliance_pdf_generated count = %d, want 1", got)
	}
	events := emitter.Events()
	if len(events) != 1 {
		t.Fatalf("emitter events = %d, want 1", len(events))
	}
	ev := events[0]
	if ev.Actor != "admin@lucairn.local" {
		t.Errorf("actor = %q, want admin@lucairn.local", ev.Actor)
	}
	if ev.Payload["customer_name"] != "Acme Corp GmbH" {
		t.Errorf("payload customer_name = %v, want Acme Corp GmbH", ev.Payload["customer_name"])
	}
	if _, ok := ev.Payload["page_count"]; !ok {
		t.Errorf("payload missing page_count")
	}
	if _, ok := ev.Payload["byte_size"]; !ok {
		t.Errorf("payload missing byte_size")
	}
}

// TestCompliance_POST_EmitFailureReturns500NoPDF is the Slice 6
// fail-closed mirror: if the audit emit fails, the handler MUST
// return 500 AND NO PDF bytes to the wire (the audit-trail-vs-leak
// invariance carries from reveal-raw into the PDF surface).
func TestCompliance_POST_EmitFailureReturns500NoPDF(t *testing.T) {
	emitter := audit.NewMemoryEmitter()
	emitter.SetEmitErr(errors.New("simulated DB outage"))
	d := newComplianceDeps(t, emitter, true)
	form := url.Values{}
	form.Set("customer_name", "Acme Corp GmbH")
	form.Set("from", "2026-04-01")
	form.Set("to", "2026-04-30")
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusInternalServerError {
		t.Errorf("emit-fail code = %d, want 500", rr.Code)
	}
	// Must NOT have leaked PDF bytes (Content-Type stays non-PDF; body
	// is a plain error message).
	if bytes.HasPrefix(rr.Body.Bytes(), []byte("%PDF-1.")) {
		t.Errorf("emit-fail body began with %%PDF-1.; want NO PDF bytes on the wire")
	}
}

func TestCompliance_POST_BadDateFormatReturns400(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	form := url.Values{}
	form.Set("customer_name", "Acme")
	form.Set("from", "2026/04/01")
	form.Set("to", "2026-04-30")
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("malformed-date code = %d, want 400", rr.Code)
	}
}

func TestCompliance_POST_EmptyCustomerNameRejected(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	form := url.Values{}
	form.Set("customer_name", "")
	form.Set("from", "2026-04-01")
	form.Set("to", "2026-04-30")
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	// Default customer is "" in the test deps so the rejection
	// path fires (empty + empty default => required).
	if rr.Code != http.StatusBadRequest {
		t.Errorf("empty customer code = %d, want 400", rr.Code)
	}
}

// TestCompliance_BrowserViewer_Returns404 drives a viewer-session through
// the production middleware chain to assert a viewer's GET /compliance
// resolves to 404 (RequireRole pattern). BH-M1 fix-up r1 — closes the
// tautological-test gap (Slice 4 C33 / Slice 5 BH-H2 / Slice 6 H2
// recurrence) where every prior compliance test called the handler
// directly without exercising the route-level role gate.
func TestCompliance_BrowserViewer_Returns404(t *testing.T) {
	t.Parallel()
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)

	sessStore := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer sessStore.Close()
	sess, err := sessStore.Create(auth.User{Email: "viewer@lucairn.local", Role: auth.RoleViewer})
	if err != nil {
		t.Fatalf("create viewer session: %v", err)
	}
	complianceMux := http.NewServeMux()
	complianceMux.HandleFunc("/compliance", d.ExportPage)
	mux := auth.LoadSession(sessStore)(auth.RequireSession()(auth.RequireRole(auth.RoleAdmin, complianceMux)))

	req := httptest.NewRequest(http.MethodGet, "/compliance", nil)
	req.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: sess.ID})
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("viewer GET /compliance via middleware chain: got %d want 404", rr.Code)
	}
}

// TestCompliance_ExportPOSTViewer_Returns404 mirrors BrowserViewer for
// the POST surface. The route-level RequireRole gate MUST return 404 to
// viewers BEFORE the handler runs (no PDF bytes can leak, no audit row
// emitted). BH-M1 fix-up r1.
func TestCompliance_ExportPOSTViewer_Returns404(t *testing.T) {
	t.Parallel()
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)

	sessStore := auth.NewMemorySessionStore(time.Hour, time.Hour)
	defer sessStore.Close()
	sess, err := sessStore.Create(auth.User{Email: "viewer@lucairn.local", Role: auth.RoleViewer})
	if err != nil {
		t.Fatalf("create viewer session: %v", err)
	}
	complianceMux := http.NewServeMux()
	complianceMux.HandleFunc("/compliance/export", d.ExportPDF)
	mux := auth.LoadSession(sessStore)(auth.RequireSession()(auth.RequireRole(auth.RoleAdmin, complianceMux)))

	form := url.Values{}
	form.Set("customer_name", "Acme")
	form.Set("from", "2026-04-01")
	form.Set("to", "2026-04-30")
	req := httptest.NewRequest(http.MethodPost, "/compliance/export", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(&http.Cookie{Name: auth.SessionCookieName, Value: sess.ID})
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("viewer POST /compliance/export via middleware chain: got %d want 404", rr.Code)
	}
}

// TestCompliance_POST_ExactMaxWindow_Accepted exercises the BH-H1 fix-up
// boundary: an exact MaxWindowDays-visible-day window MUST be accepted
// (the +1 off-by-one rejected 365-day annual exports at the default cap).
// 365 visible days inclusive: from=2026-01-01 / to=2026-12-31 → half-open
// [2026-01-01, 2027-01-01) → to.Sub(from) == 365 * 24h → spanDays == 365.
func TestCompliance_POST_ExactMaxWindow_Accepted(t *testing.T) {
	emitter := audit.NewMemoryEmitter()
	d := newComplianceDeps(t, emitter, true)
	d.MaxWindowDays = 365
	form := url.Values{}
	form.Set("customer_name", "Acme Corp GmbH")
	form.Set("from", "2026-01-01")
	form.Set("to", "2026-12-31") // 365 visible days inclusive
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("365-visible-day window code = %d, want 200; body: %s", rr.Code,
			rr.Body.String()[:min(500, len(rr.Body.String()))])
	}
	if !bytes.HasPrefix(rr.Body.Bytes(), []byte("%PDF-1.")) {
		t.Errorf("365-day body missing %%PDF-1. magic")
	}
}

// TestCompliance_POST_OneOverMaxWindow_Rejected anchors the upper
// boundary: a 366-visible-day window at the default 365-day cap MUST
// be rejected. Pairs with ExactMaxWindow_Accepted to lock the exact
// boundary (≤365 accept, >365 reject) so future refactors don't
// regress either side. BH-H1 fix-up r1.
func TestCompliance_POST_OneOverMaxWindow_Rejected(t *testing.T) {
	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	d.MaxWindowDays = 365
	form := url.Values{}
	form.Set("customer_name", "Acme")
	form.Set("from", "2026-01-01")
	form.Set("to", "2027-01-01") // 366 visible days inclusive
	req := withCSRFAndUser(t, http.MethodPost, "/compliance/export", form, newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPDF(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("366-visible-day window code = %d, want 400", rr.Code)
	}
}

// TestPageData_VersionRendered_FromLdflag asserts the ldflag-injected
// version string flows from views.SetDashboardVersion into the sidebar
// footer rendered on every page. BH-H2 fix-up r1 — closes the v0.6.0
// hardcoded literal that was visible on every dashboard page.
func TestPageData_VersionRendered_FromLdflag(t *testing.T) {
	// Snapshot + restore the package-level version so this test stays
	// hermetic regardless of other tests' ordering.
	prev := views.DashboardVersion()
	views.SetDashboardVersion("0.7.0")
	defer views.SetDashboardVersion(prev)

	d := newComplianceDeps(t, audit.NewMemoryEmitter(), true)
	req := withUser(httptest.NewRequest(http.MethodGet, "/compliance", nil), newAdminUser())
	rr := httptest.NewRecorder()
	d.ExportPage(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET /compliance code = %d, want 200", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Lucairn Dashboard v0.7.0") {
		t.Errorf("sidebar footer missing 'Lucairn Dashboard v0.7.0' (ldflag-injected version did not reach the template)")
	}
	if strings.Contains(body, "Lucairn Dashboard v0.6.0") {
		t.Errorf("sidebar footer still renders hardcoded 'Lucairn Dashboard v0.6.0' — BH-H2 regression")
	}
}

func TestParseComplianceDateRange(t *testing.T) {
	cases := []struct {
		name     string
		from     string
		to       string
		maxDays  int
		wantErr  bool
		fromUTC  time.Time
		toUTC    time.Time
	}{
		{
			name:    "happy_path_30_day_window",
			from:    "2026-04-01",
			to:      "2026-04-30",
			maxDays: 365,
			fromUTC: time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
			toUTC:   time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		},
		{
			name:    "inverted",
			from:    "2026-04-30",
			to:      "2026-04-01",
			maxDays: 365,
			wantErr: true,
		},
		{
			name:    "bad_from_format",
			from:    "garbage",
			to:      "2026-04-01",
			maxDays: 365,
			wantErr: true,
		},
		{
			name:    "exceeds_max",
			from:    "2026-01-01",
			to:      "2026-06-30",
			maxDays: 30,
			wantErr: true,
		},
		{
			// BH-H1 fix-up r1: an exact 365-visible-day annual window
			// MUST pass at the default 365-day cap. The previous +1
			// off-by-one rejected this canonical case.
			name:    "exact_365_visible_days_accepted",
			from:    "2026-01-01",
			to:      "2026-12-31",
			maxDays: 365,
			fromUTC: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
			toUTC:   time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC),
		},
		{
			// Companion boundary: 366 visible days at cap=365 MUST reject.
			name:    "one_over_max_rejected",
			from:    "2026-01-01",
			to:      "2027-01-01",
			maxDays: 365,
			wantErr: true,
		},
		{
			// Exact match at small cap: 30-visible-day window with cap=30.
			name:    "exact_30_visible_days_accepted",
			from:    "2026-04-01",
			to:      "2026-04-30",
			maxDays: 30,
			fromUTC: time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
			toUTC:   time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			from, to, err := parseComplianceDateRange(tc.from, tc.to, tc.maxDays)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("err = nil, want non-nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("err = %v, want nil", err)
			}
			if !from.Equal(tc.fromUTC) {
				t.Errorf("from = %v, want %v", from, tc.fromUTC)
			}
			if !to.Equal(tc.toUTC) {
				t.Errorf("to = %v, want %v", to, tc.toUTC)
			}
		})
	}
}
