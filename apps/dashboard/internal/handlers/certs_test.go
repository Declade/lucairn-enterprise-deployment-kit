package handlers

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness"
	"github.com/jackc/pgx/v5"
)

// stubStore is a deterministic CertStorer for handler tests.
type stubStore struct {
	listRows  []store.CertSummary
	listTotal int
	listErr   error
	getRow    store.CertSummary
	getErr    error
}

func (s *stubStore) List(ctx context.Context, _ store.CertFilter, _ store.Page) ([]store.CertSummary, int, error) {
	return s.listRows, s.listTotal, s.listErr
}
func (s *stubStore) Stream(ctx context.Context, _ store.CertFilter) (pgx.Rows, error) {
	return nil, errors.New("stream not implemented in this stub")
}
func (s *stubStore) Get(ctx context.Context, _ string) (store.CertSummary, error) {
	return s.getRow, s.getErr
}

// stubVerifier is a deterministic CertVerifier for handler tests.
type stubVerifier struct {
	result witness.VerifyResult
	err    error
	invalidated []string
}

func (v *stubVerifier) Verify(_ context.Context, certID string) (witness.VerifyResult, error) {
	out := v.result
	out.CertID = certID
	return out, v.err
}
func (v *stubVerifier) Invalidate(certID string) {
	v.invalidated = append(v.invalidated, certID)
}

func newDeps(t *testing.T, s CertStorer, v witness.CertVerifier) *CertsDeps {
	t.Helper()
	r, err := views.New()
	if err != nil {
		t.Fatalf("views.New: %v", err)
	}
	return &CertsDeps{
		Renderer:   r,
		Store:      s,
		Verifier:   v,
		Configured: true,
	}
}

// fakeSessionRequest builds a request with a populated admin user in
// context so the cert handlers' auth gate passes. We avoid driving the
// full session middleware (load → require → handler) because that
// requires a SessionStore + a generated cookie; the handler reads only
// auth.CurrentUser, which is itself a ctx accessor.
func fakeSessionRequest(method, target string, body string) *http.Request {
	var r *http.Request
	if body != "" {
		r = httptest.NewRequest(method, target, strings.NewReader(body))
	} else {
		r = httptest.NewRequest(method, target, nil)
	}
	if method == http.MethodPost {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	sess := &auth.Session{ID: "s1", User: auth.User{Email: "admin@example.com", Role: auth.RoleAdmin}, CreatedAt: time.Now(), LastSeen: time.Now()}
	r = auth.WithSessionForTest(r, sess)
	// Issue + post a CSRF token so VerifyToken succeeds for POSTs.
	return r
}

func TestBrowserHandler_RendersList(t *testing.T) {
	t.Parallel()
	store := &stubStore{
		listRows: []store.CertSummary{
			{ID: "cert-aaaaaaaa-1111", CustomerID: "cust-1", CreatedAt: time.Now(), Verdict: "verified"},
			{ID: "cert-bbbbbbbb-2222", CustomerID: "cust-1", CreatedAt: time.Now(), Verdict: "partial"},
		},
		listTotal: 2,
	}
	v := &stubVerifier{}
	d := newDeps(t, store, v)

	rec := httptest.NewRecorder()
	r := fakeSessionRequest("GET", "/certs", "")
	d.BrowserHandler(rec, r)
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "cert-aaaaaaaa-1111") {
		t.Errorf("expected first cert id in HTML; body=%s", body[:min(800, len(body))])
	}
	if !strings.Contains(body, "cert-bbbbbbbb-2222") {
		t.Errorf("expected second cert id in HTML")
	}
	if !strings.Contains(body, "verified") {
		t.Errorf("expected verdict rendering")
	}
}

func TestBrowserHandler_NotConfiguredFlash(t *testing.T) {
	t.Parallel()
	d := newDeps(t, &stubStore{}, &stubVerifier{})
	d.Configured = false
	rec := httptest.NewRecorder()
	d.BrowserHandler(rec, fakeSessionRequest("GET", "/certs", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200; body=%s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "not configured") {
		t.Errorf("expected not-configured copy; body=%s", body[:min(400, len(body))])
	}
}

func TestInspectorHandler_RendersAllSixClaimsAndBYOKBadge(t *testing.T) {
	t.Parallel()
	store := &stubStore{getRow: store.CertSummary{
		ID:         "cert-abcdef12",
		CustomerID: "cust-1",
		CreatedAt:  time.Now(),
		Verdict:    "verified",
	}}
	v := &stubVerifier{result: witness.VerifyResult{
		OverallVerdict:    "verified",
		Completeness:      "partial",
		SignaturesValid:   true,
		ByokExempt:        true,
		IsolationVerified: true,
		TSATimestamp:      "https://freetsa.org/tsr/123",
		RekorUUID:         "rekor-uuid-xyz",
		PerClaim: []witness.ClaimVerdict{
			{ClaimType: "gateway", Verdict: "ok", PubKeyFingerprint: "g-fp-aaaaaaaa", SignatureHex: "g-sig-aaaaaaaa"},
			{ClaimType: "bridge", Verdict: "ok", PubKeyFingerprint: "b-fp-aaaaaaaa", SignatureHex: "b-sig-aaaaaaaa"},
			{ClaimType: "sanitizer", Verdict: "ok", PubKeyFingerprint: "s-fp-aaaaaaaa", SignatureHex: "s-sig-aaaaaaaa"},
			{ClaimType: "sandbox_a", Verdict: "ok", PubKeyFingerprint: "sa-fp-aaaaaaa", SignatureHex: "sa-sig-aaaaaaa"},
			{ClaimType: "sandbox_b", Verdict: "ok", PubKeyFingerprint: "sb-fp-aaaaaaa", SignatureHex: "sb-sig-aaaaaaa"},
			{ClaimType: "witness", Verdict: "ok", PubKeyFingerprint: "w-fp-aaaaaaaa", SignatureHex: "w-sig-aaaaaaaa"},
		},
	}}
	d := newDeps(t, store, v)
	rec := httptest.NewRecorder()
	d.InspectorHandler(rec, fakeSessionRequest("GET", "/certs/cert-abcdef12", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200; body=%s", rec.Code, rec.Body.String()[:min(400, len(rec.Body.String()))])
	}
	body := rec.Body.String()
	// Verdicts + BYOK badge MUST surface.
	if !strings.Contains(body, "verified") {
		t.Errorf("expected overall verdict in HTML")
	}
	if !strings.Contains(body, "BYOK_EXEMPT") {
		t.Errorf("expected BYOK_EXEMPT badge")
	}
	// 6 per-claim rows MUST render.
	for _, claim := range []string{"gateway", "bridge", "sanitizer", "sandbox_a", "sandbox_b", "witness"} {
		if !strings.Contains(body, claim) {
			t.Errorf("expected claim row %s in HTML", claim)
		}
	}
	// Rekor deep link MUST render with the public Rekor API URL.
	if !strings.Contains(body, "https://rekor.sigstore.dev/api/v1/log/entries/rekor-uuid-xyz") {
		t.Errorf("expected Rekor deep-link")
	}
}

func TestInspectorHandler_404OnMissingCert(t *testing.T) {
	t.Parallel()
	d := newDeps(t, &stubStore{getErr: pgx.ErrNoRows}, &stubVerifier{})
	rec := httptest.NewRecorder()
	d.InspectorHandler(rec, fakeSessionRequest("GET", "/certs/cert-deadbeef", ""))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status: got %d want 404", rec.Code)
	}
}

func TestInspectorHandler_RejectsBadID(t *testing.T) {
	t.Parallel()
	d := newDeps(t, &stubStore{}, &stubVerifier{})
	for _, bad := range []string{
		"/certs/abc",                         // too short
		"/certs/" + strings.Repeat("a", 100), // too long
		"/certs/has.dot",                     // disallowed char
		"/certs/has/slash",                   // path traversal
	} {
		rec := httptest.NewRecorder()
		d.InspectorHandler(rec, fakeSessionRequest("GET", bad, ""))
		if rec.Code != http.StatusNotFound {
			t.Errorf("%q: got %d want 404", bad, rec.Code)
		}
	}
}

func TestInspectorHandler_WitnessUnreachableDoesNotCrash(t *testing.T) {
	t.Parallel()
	store := &stubStore{getRow: store.CertSummary{
		ID:         "cert-abcdef12",
		CustomerID: "cust-1",
		CreatedAt:  time.Now(),
	}}
	v := &stubVerifier{err: errors.New("witness gRPC connection refused")}
	d := newDeps(t, store, v)
	rec := httptest.NewRecorder()
	d.InspectorHandler(rec, fakeSessionRequest("GET", "/certs/cert-abcdef12", ""))
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d want 200 (degraded badge, not crash)", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Witness unreachable") {
		t.Errorf("expected degraded-mode badge; body=%s", body[:min(800, len(body))])
	}
}

func TestReverifyHandler_InvalidatesCacheAndRedirects(t *testing.T) {
	t.Parallel()
	v := &stubVerifier{}
	d := newDeps(t, &stubStore{}, v)
	form := url.Values{}
	form.Set("csrf", "x") // CSRF token only — VerifyToken is permissive in the unit env

	// Issue token + replay so VerifyToken passes; the simplest path is
	// to issue via auth.IssueToken on the recorder before posting.
	preRec := httptest.NewRecorder()
	preReq := fakeSessionRequest("GET", "/certs/cert-abcdef12", "")
	tok, err := auth.IssueToken(preRec, preReq)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	form.Set("csrf", tok)

	r := fakeSessionRequest("POST", "/certs/cert-abcdef12/reverify", form.Encode())
	// Carry the CSRF cookie from the preRec onto the POST request so
	// VerifyToken sees the matching pair.
	for _, c := range preRec.Result().Cookies() {
		r.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	d.ReverifyHandler(rec, r)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status: got %d want 303; body=%s", rec.Code, rec.Body.String())
	}
	loc := rec.Header().Get("Location")
	if loc != "/certs/cert-abcdef12" {
		t.Errorf("redirect: got %q want /certs/cert-abcdef12", loc)
	}
	if len(v.invalidated) != 1 || v.invalidated[0] != "cert-abcdef12" {
		t.Errorf("Invalidate calls: got %v want [cert-abcdef12]", v.invalidated)
	}
}

func TestParseCertFilter_VerdictAllowlistRejectsUnknown(t *testing.T) {
	t.Parallel()
	r := httptest.NewRequest("GET", "/certs?verdict=verified&verdict=evil", nil)
	f, v := parseCertFilter(r)
	if len(f.Verdicts) != 1 {
		t.Fatalf("verdicts after allowlist: got %d want 1", len(f.Verdicts))
	}
	if f.Verdicts[0] != "verified" {
		t.Errorf("expected verified to survive, got %v", f.Verdicts)
	}
	if v.Verdicts["evil"] {
		t.Errorf("evil verdict must be dropped from view")
	}
	if !v.Verdicts["verified"] {
		t.Errorf("verified should be true in view")
	}
}

func TestParseCertFilter_DatesParseToUTCAndUpperBoundShifts(t *testing.T) {
	t.Parallel()
	r := httptest.NewRequest("GET", "/certs?from=2026-05-01&to=2026-05-18", nil)
	f, _ := parseCertFilter(r)
	if !f.From.Equal(time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("from: got %v want 2026-05-01 UTC", f.From)
	}
	// Upper bound is exclusive; we shift forward 24h to make the UI
	// behavior inclusive ("to=2026-05-18" includes rows on that day).
	if !f.To.Equal(time.Date(2026, 5, 19, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("to: got %v want 2026-05-19 UTC (24h shift)", f.To)
	}
}

func TestParseCertFilter_RedactionMinClampedToRange(t *testing.T) {
	t.Parallel()
	r := httptest.NewRequest("GET", "/certs?redaction_min=999999", nil)
	f, v := parseCertFilter(r)
	if f.RedactionMin != 0 {
		t.Errorf("out-of-range RedactionMin must be dropped: got %d", f.RedactionMin)
	}
	if v.RedactionMin != "" {
		t.Errorf("view RedactionMin must be cleared when dropped: got %q", v.RedactionMin)
	}

	r2 := httptest.NewRequest("GET", "/certs?redaction_min=3", nil)
	f2, v2 := parseCertFilter(r2)
	if f2.RedactionMin != 3 {
		t.Errorf("RedactionMin: got %d want 3", f2.RedactionMin)
	}
	if v2.RedactionMin != "3" {
		t.Errorf("view RedactionMin: got %q want \"3\"", v2.RedactionMin)
	}
}

func TestRekorDeepLink(t *testing.T) {
	t.Parallel()
	if rekorDeepLink("") != "" {
		t.Errorf("empty rekor uuid must yield empty deep-link")
	}
	got := rekorDeepLink("uuid-1")
	if got != "https://rekor.sigstore.dev/api/v1/log/entries/uuid-1" {
		t.Errorf("rekor deep-link: got %q", got)
	}
}

func TestNormalizeCertIDs_DedupesAndDrops(t *testing.T) {
	t.Parallel()
	got := normalizeCertIDs([]string{"cert-abcdefgh", "cert-abcdefgh", "bad space", "cert-zzzzzzzz"})
	if len(got) != 2 {
		t.Fatalf("dedup + drop: got %d want 2", len(got))
	}
	if got[0] != "cert-abcdefgh" || got[1] != "cert-zzzzzzzz" {
		t.Errorf("normalize order: got %v", got)
	}
}

func TestValidCertID(t *testing.T) {
	t.Parallel()
	cases := []struct {
		id string
		ok bool
	}{
		{"abcdefgh", true},
		{"abcdefgh-12345678", true},
		{strings.Repeat("a", 64), true},
		{strings.Repeat("a", 65), false},
		{"abc", false},
		{"has space", false},
		{"has/slash", false},
		{"has.dot", false},
	}
	for _, c := range cases {
		if got := validCertID(c.id); got != c.ok {
			t.Errorf("validCertID(%q): got %v want %v", c.id, got, c.ok)
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
