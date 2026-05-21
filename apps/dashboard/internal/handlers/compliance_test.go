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
