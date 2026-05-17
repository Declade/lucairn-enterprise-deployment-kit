package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness"
)

// stubResolver implements BulkCertResolver in-memory. By default it
// returns identity for every input (cert_id == request_id) so the
// concurrency + cap + CSRF tests don't need to wire a per-test mapping.
// Tests that care about the cert_id → request_id translation pass an
// explicit `mapping` of the rows they expect to drive Verify.
type stubResolver struct {
	mu       sync.Mutex
	calls    [][]string
	mapping  map[string]string
	identity bool
	err      error
}

func newIdentityResolver() *stubResolver { return &stubResolver{identity: true} }

func (s *stubResolver) GetRequestIDsByCertIDs(_ context.Context, ids []string) (map[string]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	idsCopy := make([]string, len(ids))
	copy(idsCopy, ids)
	s.calls = append(s.calls, idsCopy)
	if s.err != nil {
		return nil, s.err
	}
	out := make(map[string]string, len(ids))
	for _, id := range ids {
		if s.identity {
			out[id] = id
			continue
		}
		if v, ok := s.mapping[id]; ok {
			out[id] = v
		}
	}
	return out, nil
}

// concurrentVerifier observes peak concurrency during the bulk run so
// the worker-pool size invariant can be asserted.
type concurrentVerifier struct {
	mu          sync.Mutex
	inFlight    int
	maxInFlight int
	count       int
	verdicts    map[string]string
}

func newConcurrentVerifier(perCertVerdict map[string]string) *concurrentVerifier {
	if perCertVerdict == nil {
		perCertVerdict = map[string]string{}
	}
	return &concurrentVerifier{verdicts: perCertVerdict}
}

func (v *concurrentVerifier) Verify(ctx context.Context, certID string) (witness.VerifyResult, error) {
	v.mu.Lock()
	v.inFlight++
	if v.inFlight > v.maxInFlight {
		v.maxInFlight = v.inFlight
	}
	v.count++
	v.mu.Unlock()
	// Short artificial work so concurrency stabilizes; without it the
	// goroutines complete too quickly for the channel-based pool to
	// queue against.
	time.Sleep(20 * time.Millisecond)
	verdict := v.verdicts[certID]
	if verdict == "" {
		verdict = "verified"
	}
	v.mu.Lock()
	v.inFlight--
	v.mu.Unlock()
	return witness.VerifyResult{CertID: certID, OverallVerdict: verdict}, nil
}

func (v *concurrentVerifier) Invalidate(_ string) {}

func adminReq(method, target, body string) *http.Request {
	var r *http.Request
	if body != "" {
		r = httptest.NewRequest(method, target, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	} else {
		r = httptest.NewRequest(method, target, nil)
	}
	sess := &auth.Session{
		ID:        "s-bulk",
		User:      auth.User{Email: "admin@example.com", Role: auth.RoleAdmin},
		CreatedAt: time.Now(),
		LastSeen:  time.Now(),
	}
	return auth.WithSessionForTest(r, sess)
}

func mintCSRF(t *testing.T) (token string, cookies []*http.Cookie) {
	t.Helper()
	rec := httptest.NewRecorder()
	r := adminReq("GET", "/certs", "")
	tok, err := auth.IssueToken(rec, r)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	return tok, rec.Result().Cookies()
}

func TestBulkReverify_HandlerRedirects(t *testing.T) {
	t.Parallel()
	v := newConcurrentVerifier(nil)
	r, err := views.New()
	if err != nil {
		t.Fatalf("views: %v", err)
	}
	deps := NewBulkReverifyDeps(v, r, newIdentityResolver())

	tok, cookies := mintCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Add("cert_id", "cert-aaaaaaaa")
	form.Add("cert_id", "cert-bbbbbbbb")

	req := adminReq("POST", "/certs/bulk-reverify", form.Encode())
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	deps.BulkReverifyHandler(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status: got %d want 303; body=%s", rec.Code, rec.Body.String())
	}
	loc := rec.Header().Get("Location")
	if !strings.HasPrefix(loc, "/certs/bulk-reverify/") {
		t.Errorf("redirect: got %q want /certs/bulk-reverify/...", loc)
	}
	if !strings.HasSuffix(loc, "/progress") {
		t.Errorf("redirect must end with /progress: %q", loc)
	}
}

func TestBulkReverify_RespectsWorkerPoolCap(t *testing.T) {
	v := newConcurrentVerifier(nil)
	r, err := views.New()
	if err != nil {
		t.Fatalf("views: %v", err)
	}
	deps := NewBulkReverifyDeps(v, r, newIdentityResolver())

	tok, cookies := mintCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	// 20 IDs — pool of 5 should keep max in-flight ≤ 5.
	for i := 0; i < 20; i++ {
		form.Add("cert_id", "cert-aaaaaaaa-"+strconv.Itoa(i))
	}
	req := adminReq("POST", "/certs/bulk-reverify", form.Encode())
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	deps.BulkReverifyHandler(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status: got %d want 303", rec.Code)
	}

	// Drain progress until finished. The 20 IDs at 10/s with 20ms work
	// per cert wall-clock at ~2s+; poll with a generous timeout.
	loc := rec.Header().Get("Location")
	jobID := strings.TrimSuffix(strings.TrimPrefix(loc, "/certs/bulk-reverify/"), "/progress")
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		pr := httptest.NewRecorder()
		jr := adminReq("GET", "/certs/bulk-reverify/"+jobID+"/progress.json", "")
		deps.BulkReverifyProgressHandler(pr, jr)
		if pr.Code != http.StatusOK {
			t.Fatalf("progress status: %d", pr.Code)
		}
		var body map[string]any
		if err := json.Unmarshal(pr.Body.Bytes(), &body); err != nil {
			t.Fatalf("progress json: %v", err)
		}
		if fin, _ := body["finished"].(bool); fin {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	v.mu.Lock()
	if v.maxInFlight > bulkWorkerPool {
		t.Errorf("maxInFlight: got %d want <= %d", v.maxInFlight, bulkWorkerPool)
	}
	if v.count != 20 {
		t.Errorf("total verifies: got %d want 20", v.count)
	}
	v.mu.Unlock()
}

func TestBulkReverify_CapsAt100Certs(t *testing.T) {
	t.Parallel()
	v := newConcurrentVerifier(nil)
	r, err := views.New()
	if err != nil {
		t.Fatalf("views: %v", err)
	}
	deps := NewBulkReverifyDeps(v, r, newIdentityResolver())

	tok, cookies := mintCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	for i := 0; i < 150; i++ {
		form.Add("cert_id", "cert-aaaaaaaa-"+strconv.Itoa(i))
	}
	req := adminReq("POST", "/certs/bulk-reverify", form.Encode())
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	deps.BulkReverifyHandler(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status: %d", rec.Code)
	}
	// Wait until in-memory job stores a snapshot we can read.
	loc := rec.Header().Get("Location")
	jobID := strings.TrimSuffix(strings.TrimPrefix(loc, "/certs/bulk-reverify/"), "/progress")
	pr := httptest.NewRecorder()
	deps.BulkReverifyProgressHandler(pr, adminReq("GET", "/certs/bulk-reverify/"+jobID+"/progress.json", ""))
	if pr.Code != http.StatusOK {
		t.Fatalf("progress: %d", pr.Code)
	}
	var body map[string]any
	if err := json.Unmarshal(pr.Body.Bytes(), &body); err != nil {
		t.Fatalf("json: %v", err)
	}
	if total, _ := body["total"].(float64); total != 100 {
		t.Errorf("total in progress: got %v want 100 (cap at bulkMaxCerts)", body["total"])
	}
}

func TestBulkReverify_RejectsEmptySelection(t *testing.T) {
	t.Parallel()
	v := newConcurrentVerifier(nil)
	r, _ := views.New()
	deps := NewBulkReverifyDeps(v, r, newIdentityResolver())

	tok, cookies := mintCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	req := adminReq("POST", "/certs/bulk-reverify", form.Encode())
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	deps.BulkReverifyHandler(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status: got %d want 400", rec.Code)
	}
}

func TestBulkReverify_RejectsMissingCSRF(t *testing.T) {
	t.Parallel()
	v := newConcurrentVerifier(nil)
	r, _ := views.New()
	deps := NewBulkReverifyDeps(v, r, newIdentityResolver())

	form := url.Values{}
	form.Add("cert_id", "cert-aaaaaaaa")
	req := adminReq("POST", "/certs/bulk-reverify", form.Encode())
	rec := httptest.NewRecorder()
	deps.BulkReverifyHandler(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Errorf("status: got %d want 403 (csrf)", rec.Code)
	}
}

func TestBulkReverify_ProgressJSONIncludesAllCounters(t *testing.T) {
	t.Parallel()
	v := newConcurrentVerifier(map[string]string{
		"cert-aaaaaaaa": "verified",
		"cert-bbbbbbbb": "partial",
		"cert-cccccccc": "failed",
	})
	r, _ := views.New()
	deps := NewBulkReverifyDeps(v, r, newIdentityResolver())

	tok, cookies := mintCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Add("cert_id", "cert-aaaaaaaa")
	form.Add("cert_id", "cert-bbbbbbbb")
	form.Add("cert_id", "cert-cccccccc")
	req := adminReq("POST", "/certs/bulk-reverify", form.Encode())
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	deps.BulkReverifyHandler(rec, req)
	jobID := strings.TrimSuffix(strings.TrimPrefix(rec.Header().Get("Location"), "/certs/bulk-reverify/"), "/progress")

	// Poll until finished.
	var body map[string]any
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		pr := httptest.NewRecorder()
		deps.BulkReverifyProgressHandler(pr, adminReq("GET", "/certs/bulk-reverify/"+jobID+"/progress.json", ""))
		if pr.Code != http.StatusOK {
			t.Fatalf("progress status: %d", pr.Code)
		}
		_ = json.Unmarshal(pr.Body.Bytes(), &body)
		if fin, _ := body["finished"].(bool); fin {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	for _, key := range []string{"id", "total", "done", "verified", "partial", "failed", "finished"} {
		if _, ok := body[key]; !ok {
			t.Errorf("progress json missing key %q", key)
		}
	}
	if body["total"].(float64) != 3 {
		t.Errorf("total: got %v want 3", body["total"])
	}
	if body["verified"].(float64) != 1 {
		t.Errorf("verified: got %v want 1", body["verified"])
	}
	if body["partial"].(float64) != 1 {
		t.Errorf("partial: got %v want 1", body["partial"])
	}
	if body["failed"].(float64) != 1 {
		t.Errorf("failed: got %v want 1", body["failed"])
	}
}

// idCaptureVerifier records the IDs Verify was called with so a test
// can assert the bulk worker passed request_id values (not cert_ids)
// into the witness RPC. The lookup-key mismatch was a real BLOCKER
// caught by Codex r1: the witness RPC keys off request_id (upstream
// cert_server.go:44-53) but the bulk POST carries cert_ids.
type idCaptureVerifier struct {
	mu            sync.Mutex
	verifyIDs     []string
	invalidateIDs []string
}

func (v *idCaptureVerifier) Verify(_ context.Context, id string) (witness.VerifyResult, error) {
	v.mu.Lock()
	v.verifyIDs = append(v.verifyIDs, id)
	v.mu.Unlock()
	return witness.VerifyResult{OverallVerdict: "verified"}, nil
}
func (v *idCaptureVerifier) Invalidate(id string) {
	v.mu.Lock()
	v.invalidateIDs = append(v.invalidateIDs, id)
	v.mu.Unlock()
}

// TestBulkReverify_UsesRequestIDNotCertID locks the rule that the bulk
// worker translates each cert_id from the browser POST into the
// witness's request_id (via Resolver.GetRequestIDsByCertIDs) before
// driving Verify / Invalidate. A regression that reverts to passing
// cert_id directly into Verify would silently produce 404s for every
// cert in every bulk batch in production.
func TestBulkReverify_UsesRequestIDNotCertID(t *testing.T) {
	v := &idCaptureVerifier{}
	r, _ := views.New()
	resolver := &stubResolver{mapping: map[string]string{
		"veil_aaaaaaaa-1111-2222-3333-444444444444": "req_aaaa-1111",
		"veil_bbbbbbbb-1111-2222-3333-444444444444": "req_bbbb-2222",
	}}
	deps := NewBulkReverifyDeps(v, r, resolver)

	tok, cookies := mintCSRF(t)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Add("cert_id", "veil_aaaaaaaa-1111-2222-3333-444444444444")
	form.Add("cert_id", "veil_bbbbbbbb-1111-2222-3333-444444444444")
	req := adminReq("POST", "/certs/bulk-reverify", form.Encode())
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	deps.BulkReverifyHandler(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("status: got %d want 303; body=%s", rec.Code, rec.Body.String())
	}

	// Drain the job to completion.
	jobID := strings.TrimSuffix(strings.TrimPrefix(rec.Header().Get("Location"), "/certs/bulk-reverify/"), "/progress")
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		pr := httptest.NewRecorder()
		deps.BulkReverifyProgressHandler(pr, adminReq("GET", "/certs/bulk-reverify/"+jobID+"/progress.json", ""))
		var body map[string]any
		_ = json.Unmarshal(pr.Body.Bytes(), &body)
		if fin, _ := body["finished"].(bool); fin {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	v.mu.Lock()
	defer v.mu.Unlock()
	want := map[string]struct{}{"req_aaaa-1111": {}, "req_bbbb-2222": {}}
	gotVerify := map[string]struct{}{}
	for _, id := range v.verifyIDs {
		gotVerify[id] = struct{}{}
	}
	if len(gotVerify) != len(want) {
		t.Fatalf("Verify call IDs: got %v want %v (worker MUST pass request_id, NOT cert_id)", v.verifyIDs, want)
	}
	for w := range want {
		if _, ok := gotVerify[w]; !ok {
			t.Errorf("Verify missing request_id %q; got %v", w, v.verifyIDs)
		}
	}
	for _, got := range v.verifyIDs {
		if strings.HasPrefix(got, "veil_") {
			t.Errorf("Verify saw operator-facing cert_id %q (must be request_id only)", got)
		}
	}
	// Invalidate must also key off request_id (same cache key as Verify).
	gotInvalidate := map[string]struct{}{}
	for _, id := range v.invalidateIDs {
		gotInvalidate[id] = struct{}{}
	}
	for w := range want {
		if _, ok := gotInvalidate[w]; !ok {
			t.Errorf("Invalidate missing request_id %q; got %v", w, v.invalidateIDs)
		}
	}
	// Resolver must have been called exactly ONCE with the full batch.
	resolver.mu.Lock()
	defer resolver.mu.Unlock()
	if len(resolver.calls) != 1 {
		t.Errorf("Resolver call count: got %d want 1 (bulk worker must batch the lookup)", len(resolver.calls))
	}
}

func TestNewJobID_Unique(t *testing.T) {
	t.Parallel()
	seen := map[string]struct{}{}
	for i := 0; i < 50; i++ {
		id := newJobID()
		if _, dup := seen[id]; dup {
			t.Fatalf("duplicate job id: %s", id)
		}
		seen[id] = struct{}{}
	}
}
