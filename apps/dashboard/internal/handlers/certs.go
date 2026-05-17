package handlers

import (
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness"
	"github.com/jackc/pgx/v5"
)

// CertsDeps groups the cert-browser/inspector/validator surface's
// runtime collaborators. The CertStore + Verifier are the only stateful
// pieces; the Renderer ships static templates.
//
// Configured is a small honesty bit: when the customer did NOT wire an
// audit DB connection string + witness endpoint, the cert routes still
// register but every handler returns a friendly 503 explaining what to
// set in Helm values / customer.env. Versus a hard panic at startup,
// this lets the Slice 3 dashboard image boot on a kit that has not yet
// opted into the cert surface.
type CertsDeps struct {
	Renderer  *views.Renderer
	Store     CertStorer
	Verifier  witness.CertVerifier
	Configured bool
}

// CertStorer narrows the *store.CertStore API to what handlers use.
type CertStorer interface {
	List(ctx context.Context, filter store.CertFilter, page store.Page) ([]store.CertSummary, int, error)
	Stream(ctx context.Context, filter store.CertFilter) (pgx.Rows, error)
	Get(ctx context.Context, id string) (store.CertSummary, error)
}

// browserPageData carries the data the browser template renders.
type browserPageData struct {
	views.PageData
	Filter            certFilterView
	Rows              []store.CertSummary
	Total             int
	Page              int
	TotalPages        int
	PageSize          int
	HasPrevPage       bool
	HasNextPage       bool
	PrevPageQuery     string
	NextPageQuery     string
	CSVExportQuery    string
}

// certFilterView is the user-facing surface for the browser filter
// form. The dates are rendered as YYYY-MM-DD strings (browser
// <input type=date>); verdict checkboxes are an EnumSet by value.
type certFilterView struct {
	From         string
	To           string
	CustomerID   string
	RedactionMin string
	Verdicts     map[string]bool
}

// inspectorPageData is the cert-inspector + validator page.
type inspectorPageData struct {
	views.PageData
	Cert       store.CertSummary
	Result     witness.VerifyResult
	WitnessErr string
	RekorURL   string
}

// BrowserHandler is GET /certs.
func (d *CertsDeps) BrowserHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("certs_browser: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if !d.Configured {
		d.renderNotConfigured(w, user, tok, "certs")
		return
	}
	filter, fv := parseCertFilter(r)
	pageSize := 50
	pageNum := parsePageNum(r)
	page := store.Page{Limit: pageSize, Offset: (pageNum - 1) * pageSize}

	rows, total, err := d.Store.List(r.Context(), filter, page)
	if err != nil {
		log.Printf("certs_browser: list: %v", err)
		http.Error(w, "cert store unavailable", http.StatusServiceUnavailable)
		return
	}
	totalPages := (total + pageSize - 1) / pageSize
	if totalPages < 1 {
		totalPages = 1
	}

	q := buildFilterQuery(filter, fv)
	prev, next := "", ""
	if pageNum > 1 {
		prev = appendPage(q, pageNum-1)
	}
	if pageNum < totalPages {
		next = appendPage(q, pageNum+1)
	}

	data := browserPageData{
		PageData: views.PageData{
			Title:      "Certs",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "certs",
		},
		Filter:         fv,
		Rows:           rows,
		Total:          total,
		Page:           pageNum,
		TotalPages:     totalPages,
		PageSize:       pageSize,
		HasPrevPage:    prev != "",
		HasNextPage:    next != "",
		PrevPageQuery:  prev,
		NextPageQuery:  next,
		CSVExportQuery: "/certs.csv?" + q,
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "certs/browser.html.tmpl", data); err != nil {
		log.Printf("certs_browser: render: %v", err)
	}
}

// InspectorHandler is GET /certs/{id}.
func (d *CertsDeps) InspectorHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("certs_inspector: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if !d.Configured {
		d.renderNotConfigured(w, user, tok, "certs")
		return
	}
	id := extractCertID(r.URL.Path, "/certs/")
	if !validCertID(id) {
		http.NotFound(w, r)
		return
	}
	cert, err := d.Store.Get(r.Context(), id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		log.Printf("certs_inspector: get: %v", err)
		http.Error(w, "cert store unavailable", http.StatusServiceUnavailable)
		return
	}

	// The witness's GetCertificate RPC looks up by request_id (upstream
	// cert_server.go:44-53), not certificate_id. cert.RequestID comes
	// from the audit-DB Get() above (Get's SELECT includes request_id).
	result, vErr := d.Verifier.Verify(r.Context(), cert.RequestID)
	data := inspectorPageData{
		PageData: views.PageData{
			Title:      "Cert",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "certs",
		},
		Cert: cert,
	}
	if vErr != nil {
		log.Printf("certs_inspector: verify: %v", vErr)
		data.WitnessErr = "Witness unreachable. The cert chain renders from the audit DB, but live signature re-verification is unavailable. Retry once connectivity is restored."
	} else {
		data.Result = result
		data.RekorURL = rekorDeepLink(result.RekorUUID)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "certs/inspector.html.tmpl", data); err != nil {
		log.Printf("certs_inspector: render: %v", err)
	}
}

// ValidatorHandler is GET /certs/{id}/validator. Renders the audit-grade
// per-claim signature breakdown for a single cert. Same data path as the
// inspector (Get + Verify on the witness, same cache) but the template
// omits the summary card — the validator page is the URL an auditor
// hands off when the body is meant to be purely cryptographic evidence,
// not an operator overview.
//
// Cache + singleflight semantics are inherited from the witness client,
// so two adjacent /inspector + /validator views of the same cert serve
// from the same in-memory snapshot.
func (d *CertsDeps) ValidatorHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("certs_validator: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if !d.Configured {
		d.renderNotConfigured(w, user, tok, "certs")
		return
	}
	id := extractCertID(r.URL.Path, "/certs/")
	id = strings.TrimSuffix(id, "/validator")
	if !validCertID(id) {
		http.NotFound(w, r)
		return
	}
	cert, err := d.Store.Get(r.Context(), id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		log.Printf("certs_validator: get: %v", err)
		http.Error(w, "cert store unavailable", http.StatusServiceUnavailable)
		return
	}
	// Witness lookup key = request_id (cf. InspectorHandler comment).
	result, vErr := d.Verifier.Verify(r.Context(), cert.RequestID)
	data := inspectorPageData{
		PageData: views.PageData{
			Title:      "Cert validator",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "certs",
		},
		Cert: cert,
	}
	if vErr != nil {
		log.Printf("certs_validator: verify: %v", vErr)
		data.WitnessErr = "Witness unreachable. The cert chain renders from the audit DB, but live signature re-verification is unavailable. Retry once connectivity is restored."
	} else {
		data.Result = result
		data.RekorURL = rekorDeepLink(result.RekorUUID)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "certs/validator.html.tmpl", data); err != nil {
		log.Printf("certs_validator: render: %v", err)
	}
}

// ReverifyHandler is POST /certs/{id}/reverify. Bypasses cache and
// returns the inspector page rendered with a fresh witness response.
//
// Audit log: every reverify call emits a `cert.verify_requested`
// log line including the admin user_id so post-hoc forensics can answer
// "who re-verified cert X at 14:23?".
func (d *CertsDeps) ReverifyHandler(w http.ResponseWriter, r *http.Request) {
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
	if !d.Configured {
		http.Error(w, "cert surface not configured", http.StatusServiceUnavailable)
		return
	}
	id := extractCertID(r.URL.Path, "/certs/")
	id = strings.TrimSuffix(id, "/reverify")
	if !validCertID(id) {
		http.NotFound(w, r)
		return
	}
	// Resolve request_id (witness lookup + cache key) before invalidating.
	// Without this step the Invalidate call would target the wrong cache
	// key and the next InspectorHandler render would still serve a stale
	// cached entry — the "Re-verify now" button would visibly do nothing.
	cert, err := d.Store.Get(r.Context(), id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		log.Printf("certs_reverify: get: %v", err)
		http.Error(w, "cert store unavailable", http.StatusServiceUnavailable)
		return
	}
	log.Printf("cert.verify_requested user_id=%s cert_id=%s request_id=%s", user.Email, id, cert.RequestID)
	d.Verifier.Invalidate(cert.RequestID)
	http.Redirect(w, r, "/certs/"+id, http.StatusSeeOther)
}

// CSVExportHandler is GET /certs.csv. Streams a CSV body for the
// visible filter. Same filter rules as the browser; no pagination.
func (d *CertsDeps) CSVExportHandler(w http.ResponseWriter, r *http.Request) {
	if _, ok := auth.CurrentUser(r); !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.Configured {
		http.Error(w, "cert surface not configured", http.StatusServiceUnavailable)
		return
	}
	filter, _ := parseCertFilter(r)
	rows, err := d.Store.Stream(r.Context(), filter)
	if err != nil {
		log.Printf("certs_csv: stream: %v", err)
		http.Error(w, "cert store unavailable", http.StatusServiceUnavailable)
		return
	}
	defer rows.Close()

	stamp := time.Now().UTC().Format("2006-01-02")
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"lucairn-certs-%s.csv\"", stamp))
	w.Header().Set("Cache-Control", "no-store")
	cw := csv.NewWriter(w)
	defer cw.Flush()
	if err := cw.Write([]string{
		"cert_id",
		"customer_id",
		"created_at_utc",
		"verdict",
		"redaction_count",
		"claim_count",
	}); err != nil {
		log.Printf("certs_csv: header: %v", err)
		return
	}
	for rows.Next() {
		// Honour client-disconnect: stop writing as soon as the request
		// context is done. csv.Writer's Flush below will drain whatever
		// was buffered.
		select {
		case <-r.Context().Done():
			return
		default:
		}
		var (
			id, cid, verdict string
			createdAt        time.Time
			redactions       int
			claims           int
		)
		if err := rows.Scan(&id, &cid, &createdAt, &verdict, &redactions, &claims); err != nil {
			log.Printf("certs_csv: scan: %v", err)
			return
		}
		if err := cw.Write([]string{
			id,
			cid,
			createdAt.UTC().Format(time.RFC3339),
			verdict,
			strconv.Itoa(redactions),
			strconv.Itoa(claims),
		}); err != nil {
			log.Printf("certs_csv: write: %v", err)
			return
		}
	}
	if err := rows.Err(); err != nil {
		log.Printf("certs_csv: iter: %v", err)
	}
}

// renderNotConfigured shows a friendly explainer when the cert surface
// is wired in the binary but the customer has not configured the audit
// DB + witness endpoint. The page is gated by auth so unauthenticated
// fetches still flow through /login.
func (d *CertsDeps) renderNotConfigured(w http.ResponseWriter, user auth.User, tok string, active string) {
	data := views.PageData{
		Title:      "Certs",
		User:       user,
		CSRFToken:  tok,
		ActivePage: active,
		Flash:      "Cert browser is not configured on this install. Set LUCAIRN_DASHBOARD_AUDIT_DB_URL and LUCAIRN_DASHBOARD_WITNESS_ENDPOINT (or the matching Helm values) and restart the dashboard.",
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "certs/notconfigured.html.tmpl", data); err != nil {
		log.Printf("certs_notconfigured: render: %v", err)
	}
}

// rekorDeepLink builds the Sigstore Rekor entry URL the inspector links
// to. Empty uuid yields empty string (renderer hides the link). Pinned
// to the public Rekor API endpoint per CLAUDE.md sub-processors.
func rekorDeepLink(uuid string) string {
	if uuid == "" {
		return ""
	}
	// The current public endpoint is the Sigstore Rekor REST API entry
	// path. Operators have asked for a "human-friendlier" search URL in
	// the past, but the search site moves; the REST entry URL has been
	// stable across Sigstore version bumps and renders a JSON document
	// any forensics workflow can verify offline.
	return "https://rekor.sigstore.dev/api/v1/log/entries/" + uuid
}

// parseCertFilter pulls filter values from the request query string,
// applying defensive caps + the verdict allowlist.
func parseCertFilter(r *http.Request) (store.CertFilter, certFilterView) {
	q := r.URL.Query()
	var f store.CertFilter
	v := certFilterView{
		From:         strings.TrimSpace(q.Get("from")),
		To:           strings.TrimSpace(q.Get("to")),
		CustomerID:   strings.TrimSpace(q.Get("customer_id")),
		RedactionMin: strings.TrimSpace(q.Get("redaction_min")),
		Verdicts: map[string]bool{
			"verified": false,
			"partial":  false,
			"failed":   false,
		},
	}
	if t, err := time.Parse("2006-01-02", v.From); err == nil {
		f.From = t.UTC()
	}
	if t, err := time.Parse("2006-01-02", v.To); err == nil {
		// Inclusive upper bound: shift forward by 24h so a UI selection
		// of "to=2026-05-18" includes rows created on 2026-05-18.
		f.To = t.UTC().Add(24 * time.Hour)
	}
	if v.CustomerID != "" && len(v.CustomerID) <= 128 {
		f.CustomerID = v.CustomerID
	} else {
		v.CustomerID = ""
	}
	if v.RedactionMin != "" {
		if n, err := strconv.Atoi(v.RedactionMin); err == nil && n > 0 && n < 100000 {
			f.RedactionMin = n
		} else {
			v.RedactionMin = ""
		}
	}
	for _, val := range q["verdict"] {
		val = strings.TrimSpace(val)
		if _, ok := store.VerdictAllowed[val]; ok {
			v.Verdicts[val] = true
			f.Verdicts = append(f.Verdicts, val)
		}
	}
	return f, v
}

// buildFilterQuery converts a CertFilter back into the canonical query
// string the pagination links + the CSV-export anchor consume. Kept in
// alphabetical key order so the rendered URLs stay byte-stable across
// page renders (helps cache validators + diff tooling).
func buildFilterQuery(_ store.CertFilter, v certFilterView) string {
	parts := make([]string, 0, 8)
	if v.CustomerID != "" {
		parts = append(parts, "customer_id="+v.CustomerID)
	}
	if v.From != "" {
		parts = append(parts, "from="+v.From)
	}
	if v.RedactionMin != "" {
		parts = append(parts, "redaction_min="+v.RedactionMin)
	}
	if v.To != "" {
		parts = append(parts, "to="+v.To)
	}
	for _, k := range []string{"failed", "partial", "verified"} {
		if v.Verdicts[k] {
			parts = append(parts, "verdict="+k)
		}
	}
	return strings.Join(parts, "&")
}

func appendPage(q string, page int) string {
	if q == "" {
		return fmt.Sprintf("/certs?page=%d", page)
	}
	return fmt.Sprintf("/certs?%s&page=%d", q, page)
}

func parsePageNum(r *http.Request) int {
	if v := r.URL.Query().Get("page"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n < 10000 {
			return n
		}
	}
	return 1
}

// extractCertID returns the URL segment after prefix and strips trailing
// path elements. Used by the inspector + reverify routes.
func extractCertID(path, prefix string) string {
	s := strings.TrimPrefix(path, prefix)
	if i := strings.Index(s, "/"); i >= 0 {
		s = s[:i]
	}
	return s
}

// validCertID enforces a conservative shape: 8-128 chars, alphanumeric +
// dash + underscore only. Defends against URL-injection that pierces the
// audit DB read path; the SQL layer also binds positionally but
// defense-in-depth pays here.
//
// Underscore is required because upstream witness assembler at
// dual-sandbox-architecture/services/veil-witness/internal/assembler/
// assembler.go:71 mints IDs as "veil_" + uuid.NewV7() (e.g.
// "veil_0190d3a1-2b4c-7000-9abc-def012345678"). Before this widening
// every production cert URL returned 404 from validCertID's pre-flight
// shape check. Max length lifted to 128 to comfortably cover veil_<uuid>
// (41 chars) plus any future ID-format growth without re-touching this
// gate.
func validCertID(id string) bool {
	if len(id) < 8 || len(id) > 128 {
		return false
	}
	for _, c := range id {
		switch {
		case c >= 'a' && c <= 'z',
			c >= 'A' && c <= 'Z',
			c >= '0' && c <= '9',
			c == '-',
			c == '_':
			// ok
		default:
			return false
		}
	}
	return true
}
