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
		ID:       "s-bulk",
		User:     auth.User{Email: "admin@example.com", Role: auth.RoleAdmin},
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
	deps := NewBulkReverifyDeps(v, r)

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
	deps := NewBulkReverifyDeps(v, r)

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
	deps := NewBulkReverifyDeps(v, r)

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
	deps := NewBulkReverifyDeps(v, r)

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
	deps := NewBulkReverifyDeps(v, r)

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
	deps := NewBulkReverifyDeps(v, r)

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
