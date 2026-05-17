package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness"
)

const (
	// bulkMaxCerts caps a single bulk-reverify job. Matches the PRD
	// success criterion ("Bulk re-verify: select up to 100 certs").
	bulkMaxCerts = 100

	// bulkWorkerPool size is the number of in-flight VerifyCertificate
	// gRPC calls. PRD failure-mode guard: "Bulk re-verify slams witness
	// with 1000 concurrent gRPC calls" — mitigation locked at 5.
	bulkWorkerPool = 5

	// bulkRateLimit is the maximum verify calls per second across the
	// entire bulk job. 10/s caps the witness blast radius without making
	// a 100-cert job feel pokey (≥10s minimum, ~20s typical).
	bulkRateLimit = 10

	// bulkJobTTL is how long the result snapshot stays addressable on
	// the SSE-lite progress endpoint after the job ends.
	bulkJobTTL = 10 * time.Minute

	// bulkPerCertTimeout matches witness.DefaultRPCTimeout. Repeated
	// here so the bulk path stays self-contained — a witness package
	// change should not silently change bulk semantics.
	bulkPerCertTimeout = 8 * time.Second
)

// BulkReverifyDeps owns the in-memory job ledger + the worker pool. The
// ledger is bounded by jobTTL and the per-handler cap; this is NOT a
// queue — the dashboard's single-pod model means we just run the job
// inline and stream progress to the originating browser tab.
type BulkReverifyDeps struct {
	Verifier witness.CertVerifier
	Renderer *views.Renderer

	mu   sync.Mutex
	jobs map[string]*bulkJob
}

// NewBulkReverifyDeps builds an empty ledger.
func NewBulkReverifyDeps(v witness.CertVerifier, r *views.Renderer) *BulkReverifyDeps {
	return &BulkReverifyDeps{
		Verifier: v,
		Renderer: r,
		jobs:     make(map[string]*bulkJob),
	}
}

// bulkJob is the per-batch state read by the progress endpoint.
//
// We use a mutex over the counters rather than atomic.Int because the
// success/partial/failed counters are read together (the progress
// response is one JSON document, not three independent atomics) and
// the mutex makes the snapshot consistent.
type bulkJob struct {
	id         string
	user       string
	total      int
	createdAt  time.Time
	finishedAt time.Time

	mu       sync.Mutex
	verified int
	partial  int
	failed   int
	done     int
	results  map[string]string // certID -> verdict or error
	finished bool
}

// progressView is the bulk-progress template data.
type progressView struct {
	views.PageData
	JobID       string
	JobTotal    int
	ProgressURL string
}

// BulkReverifyHandler is POST /certs/bulk-reverify. Body MUST be form-
// encoded with one or more "cert_id" values + the CSRF token. Returns
// a 303 redirect to /certs/bulk-reverify/{jobID}/progress; the browser
// renders the progress UI which long-polls the JSON endpoint.
func (b *BulkReverifyDeps) BulkReverifyHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
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
	if b.Verifier == nil {
		http.Error(w, "cert surface not configured", http.StatusServiceUnavailable)
		return
	}
	ids := normalizeCertIDs(r.Form["cert_id"])
	if len(ids) == 0 {
		http.Error(w, "no cert_ids", http.StatusBadRequest)
		return
	}
	if len(ids) > bulkMaxCerts {
		ids = ids[:bulkMaxCerts]
	}
	job := &bulkJob{
		id:        newJobID(),
		user:      user.Email,
		total:     len(ids),
		createdAt: time.Now().UTC(),
		results:   make(map[string]string, len(ids)),
	}
	b.mu.Lock()
	b.jobs[job.id] = job
	b.mu.Unlock()
	go b.runJob(job, ids)

	log.Printf("cert.bulk_verify_requested user_id=%s job_id=%s count=%d", user.Email, job.id, len(ids))

	http.Redirect(w, r, "/certs/bulk-reverify/"+job.id+"/progress", http.StatusSeeOther)
}

// runJob executes the bulk verify using a worker pool + a token-bucket-
// shaped rate limiter. Each Verify call also flows through the
// Verifier.Invalidate path so the cached snapshot is bypassed.
func (b *BulkReverifyDeps) runJob(job *bulkJob, ids []string) {
	workers := make(chan struct{}, bulkWorkerPool)
	tick := time.Second / bulkRateLimit
	var wg sync.WaitGroup

	for _, id := range ids {
		workers <- struct{}{}
		wg.Add(1)
		go func(certID string) {
			defer wg.Done()
			defer func() { <-workers }()

			b.Verifier.Invalidate(certID)
			ctx, cancel := context.WithTimeout(context.Background(), bulkPerCertTimeout)
			defer cancel()
			res, err := b.Verifier.Verify(ctx, certID)
			job.mu.Lock()
			job.done++
			if err != nil {
				job.failed++
				job.results[certID] = "error: " + truncErr(err.Error())
			} else {
				verdict := strings.ToLower(strings.TrimSpace(res.OverallVerdict))
				job.results[certID] = verdict
				switch verdict {
				case "verified":
					job.verified++
				case "partial":
					job.partial++
				case "failed":
					job.failed++
				default:
					// Unknown verdict (e.g. byok_exempt-as-string from a
					// future witness build); count under partial so the
					// progress UI is honest rather than silently dropping.
					job.partial++
				}
			}
			job.mu.Unlock()
		}(id)
		time.Sleep(tick)
	}
	wg.Wait()
	job.mu.Lock()
	job.finished = true
	job.finishedAt = time.Now().UTC()
	job.mu.Unlock()

	time.AfterFunc(bulkJobTTL, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		delete(b.jobs, job.id)
	})
}

// BulkReverifyProgressHandler is GET /certs/bulk-reverify/{id}/progress
// or .../progress.json. JSON variant returns the live snapshot the
// browser polls; HTML variant returns the wrapping page that drives
// the poll loop.
func (b *BulkReverifyDeps) BulkReverifyProgressHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	jobID := strings.TrimSuffix(extractCertID(r.URL.Path, "/certs/bulk-reverify/"), "/progress")
	jobID = strings.TrimSuffix(jobID, ".json")
	jobID = strings.TrimSuffix(jobID, "/progress")
	b.mu.Lock()
	job, ok := b.jobs[jobID]
	b.mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}

	if strings.HasSuffix(r.URL.Path, ".json") {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		job.mu.Lock()
		body := map[string]any{
			"id":       job.id,
			"total":    job.total,
			"done":     job.done,
			"verified": job.verified,
			"partial":  job.partial,
			"failed":   job.failed,
			"finished": job.finished,
		}
		job.mu.Unlock()
		_ = json.NewEncoder(w).Encode(body)
		return
	}

	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("bulk_progress: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	data := progressView{
		PageData: views.PageData{
			Title:      "Bulk re-verify",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "certs",
		},
		JobID:       job.id,
		JobTotal:    job.total,
		ProgressURL: "/certs/bulk-reverify/" + job.id + "/progress.json",
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if b.Renderer != nil {
		if err := b.Renderer.Render(w, "certs/progress.html.tmpl", data); err != nil {
			log.Printf("bulk_progress: render: %v", err)
		}
		return
	}
	_, _ = fmt.Fprintf(w, "<!doctype html><body>Job %s — %d certs in flight. Refresh to update.</body>", job.id, job.total)
}

// truncErr keeps gRPC error text small for the public progress JSON.
func truncErr(s string) string {
	if len(s) > 200 {
		return s[:200] + "…"
	}
	return s
}

// newJobID is a 16-hex-char ID seeded by time + a process counter.
// Cryptographic randomness is overkill for an in-process job ledger
// where the ID is already gated by the user's auth session.
var jobCounter atomic64

func newJobID() string {
	return fmt.Sprintf("%x-%x", time.Now().UnixNano(), jobCounter.add(1))
}

// atomic64 is a portable monotonic counter; sync/atomic.Int64 is the
// production form, but using a small wrapper keeps the dependency
// surface minimal + helps reviewers see exactly what state lives where.
type atomic64 struct {
	mu sync.Mutex
	n  int64
}

func (a *atomic64) add(d int64) int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.n += d
	return a.n
}

// normalizeCertIDs dedupes + validates the form values. Returns only
// IDs that pass validCertID (defense in depth before the verify path).
func normalizeCertIDs(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, id := range in {
		id = strings.TrimSpace(id)
		if !validCertID(id) {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out
}
