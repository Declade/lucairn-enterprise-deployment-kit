package handlers

import (
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit/piiguard"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
	"github.com/jackc/pgx/v5"
)

// AuditDeps groups the runtime collaborators for the audit-log browser.
//
// AuditStore + SavedFiltersStore are the data layer. AuditEmitter is
// REQUIRED in production (used for the paired `audit.reveal_raw` and
// `audit.csv_export_with_reveal` events). Configured is the honesty bit:
// when the operator hasn't wired LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL the
// routes still register but render the "not configured" explainer.
type AuditDeps struct {
	Renderer        *views.Renderer
	AuditStore      AuditReadStore
	SavedFilters    SavedFiltersReadWriteStore
	AuditEmitter    audit.Emitter
	Configured      bool
	Clock           func() time.Time
	MaxPagesAllowed int // safety cap; default 1000
}

// AuditReadStore narrows store.AuditStore to the methods handlers use.
type AuditReadStore interface {
	ListEvents(ctx context.Context, filter store.AuditFilter) ([]store.AuditEvent, int, error)
	GetEvent(ctx context.Context, eventID string) (*store.AuditEvent, error)
	DistinctEventTypes(ctx context.Context) ([]string, error)
	DistinctSourceServices(ctx context.Context) ([]string, error)
}

// SavedFiltersReadWriteStore narrows store.SavedFiltersStore.
type SavedFiltersReadWriteStore interface {
	Save(ctx context.Context, user, name string, filter store.AuditFilter) error
	List(ctx context.Context, user string) ([]store.SavedFilter, error)
	Delete(ctx context.Context, user, name string) error
}

// NewAuditDeps constructs an AuditDeps. emitter=nil falls back to the
// default LogEmitter (mirroring KeysDeps). configured=false renders
// the "not configured" page on every route.
func NewAuditDeps(renderer *views.Renderer, st AuditReadStore, sf SavedFiltersReadWriteStore, emitter audit.Emitter, configured bool) *AuditDeps {
	if emitter == nil {
		emitter = audit.NewLogEmitter()
	}
	return &AuditDeps{
		Renderer:        renderer,
		AuditStore:      st,
		SavedFilters:    sf,
		AuditEmitter:    emitter,
		Configured:      configured,
		Clock:           time.Now,
		MaxPagesAllowed: 1000,
	}
}

// auditPageData carries the render shape for /audit + /audit/{id}.
type auditPageData struct {
	views.PageData
	Configured     bool
	NotConfigured  string
	NotApplied     bool   // saved-filters table missing
	NotAppliedHint string // explainer copy

	// Filter form state — populated from query params on GET.
	Filter store.AuditFilter

	// Dropdown options.
	EventTypes     []string
	SourceServices []string

	// Result set.
	Events       []store.AuditEvent
	Total        int
	Page         int
	PageSize     int
	TotalPages   int
	PageList     []int
	HasPrev      bool
	HasNext      bool
	PrevPage     int
	NextPage     int
	StartIndex   int // 1-based
	EndIndex     int

	// Saved filters.
	SavedFilters []store.SavedFilter
	SaveError    string

	// Render-time PII guards — pre-redacted strings + JSON for the
	// list table + detail page. Filled by render path.
	RowsRedacted []renderedRow

	// Detail page state.
	DetailEvent     *store.AuditEvent
	DetailRedacted  string // pre-redacted payload JSON
	RevealEnabled   bool   // admin only; lets the template show the button
	RevealSucceeded bool
}

// renderedRow is the per-event projection the template iterates over
// to keep render-time logic out of the template itself.
type renderedRow struct {
	ID             int64
	EventID        string
	EventType      string
	SourceService  string
	Actor          string // already redacted
	ActorRaw       string // empty unless admin reveal context
	Timestamp      time.Time
	RequestID      string
	PayloadPreview string // already redacted; 80-char clip
}

// BrowserHandler is GET /audit.
//
// Both viewer + admin can access. PII is redacted in BOTH default
// renders; admin reveal requires an explicit POST per-event.
func (d *AuditDeps) BrowserHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("audit_browser: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	data := auditPageData{
		PageData: views.PageData{
			Title:      "Audit log",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "audit",
		},
		Configured:    d.Configured,
		RevealEnabled: user.Role == auth.RoleAdmin,
	}
	if !d.Configured {
		data.NotConfigured = "Audit log browser is not configured on this install. Set LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL (or the matching Helm values) and restart the dashboard. See INSTALL.md § \"Enable audit log browser\"."
		d.render(w, "audit/browser.html.tmpl", data)
		return
	}
	filter, page, pageSize := d.parseFilterFromQuery(r.URL.Query())
	data.Filter = filter
	data.Page = page
	data.PageSize = pageSize

	events, total, err := d.AuditStore.ListEvents(r.Context(), filter)
	if err != nil {
		log.Printf("audit_browser: list: %v", err)
		http.Error(w, "audit log unavailable", http.StatusBadGateway)
		return
	}
	data.Events = events
	data.Total = total
	d.populatePagination(&data)
	d.populateRedactedRows(&data)

	// Dropdown options. A failure to load the dropdowns is non-fatal
	// — the table still renders. Empty dropdowns degrade to free-text
	// filter inputs in the template.
	if types, err := d.AuditStore.DistinctEventTypes(r.Context()); err == nil {
		data.EventTypes = types
	} else {
		log.Printf("audit_browser: distinct event_types: %v", err)
	}
	if svcs, err := d.AuditStore.DistinctSourceServices(r.Context()); err == nil {
		data.SourceServices = svcs
	} else {
		log.Printf("audit_browser: distinct source_services: %v", err)
	}

	// Saved filters scoped to current user. Missing table → friendly
	// banner (saved filters are an additive feature; the rest of the
	// browser keeps working).
	if d.SavedFilters != nil {
		filters, err := d.SavedFilters.List(r.Context(), user.Email)
		if err != nil {
			if errors.Is(err, store.ErrSavedFilterTableMissing) {
				data.NotApplied = true
				data.NotAppliedHint = "Saved filters require the operator to apply the dashboard migration apps/dashboard/migrations/000001_create_saved_filters.up.sql against the audit-log DB. See OPS.md § \"Enable saved filters\"."
			} else {
				log.Printf("audit_browser: list saved filters: %v", err)
			}
		}
		data.SavedFilters = filters
	}
	d.render(w, "audit/browser.html.tmpl", data)
}

// DetailHandler is GET /audit/{event_id}.
func (d *AuditDeps) DetailHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.Configured {
		http.NotFound(w, r)
		return
	}
	eventID := extractEventIDFromPath(r.URL.Path)
	if eventID == "" {
		http.NotFound(w, r)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("audit_detail: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	ev, err := d.AuditStore.GetEvent(r.Context(), eventID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		log.Printf("audit_detail: get %q: %v", eventID, err)
		http.Error(w, "audit log unavailable", http.StatusBadGateway)
		return
	}
	// GetEvent always returns a non-nil event when err is nil (the
	// store either populates or returns pgx.ErrNoRows). The
	// staticcheck SA5011 warning is a false positive in this branch
	// but we redact the actor on a copy to keep the source row
	// untouched; the nil-guard inside the copy block stays as
	// defence-in-depth.
	data := auditPageData{
		PageData: views.PageData{
			Title:      "Audit event " + eventID,
			User:       user,
			CSRFToken:  tok,
			ActivePage: "audit",
		},
		Configured:     true,
		DetailRedacted: redactPayloadJSON(ev.Payload),
		RevealEnabled:  user.Role == auth.RoleAdmin,
	}
	evCopy := *ev
	evCopy.Actor = piiguard.Redact(evCopy.Actor)
	data.DetailEvent = &evCopy
	d.render(w, "audit/detail.html.tmpl", data)
}

// RevealRawHandler is POST /audit/{event_id}/reveal-raw. Admin only.
//
// Emits a paired `audit.reveal_raw` event BEFORE returning the raw
// payload. If the emit fails, the handler returns 500 and the client
// never sees raw text (closing the audit-trail-vs-leak invariant).
func (d *AuditDeps) RevealRawHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if user.Role != auth.RoleAdmin {
		http.NotFound(w, r)
		return
	}
	if !d.Configured {
		http.NotFound(w, r)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf invalid", http.StatusForbidden)
		return
	}
	eventID := extractEventIDFromPath(r.URL.Path)
	if eventID == "" {
		http.NotFound(w, r)
		return
	}
	ev, err := d.AuditStore.GetEvent(r.Context(), eventID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		log.Printf("audit_reveal: get %q: %v", eventID, err)
		http.Error(w, "audit log unavailable", http.StatusBadGateway)
		return
	}
	// Emit FIRST, then return raw. If emit fails we 500 + return
	// nothing — the admin has to retry (and the audit trail stays
	// consistent with the on-screen reveal).
	//
	// Slice 6 fix-up r1 H3 / DRIFT-006: Emit now returns an error.
	// LogEmitter always returns nil (pod-logs-only fallback);
	// DBEmitter returns the wrapped INSERT error when the audit DB
	// write fails. We MUST 500 in either case for fail-closed
	// invariance: if the trail loses the reveal, the screen MUST NOT
	// show the raw payload.
	if err := d.AuditEmitter.Emit(r.Context(), "audit.reveal_raw", user.Email, map[string]any{
		"target_event_id":     ev.EventID,
		"target_event_type":   ev.EventType,
		"target_source":       ev.SourceService,
		"target_request_id":   ev.RequestID,
		"target_payload_type": ev.PayloadType,
	}); err != nil {
		log.Printf("audit_reveal: emit failed (fail-closed; raw payload NOT returned): %v", err)
		http.Error(w, "audit emit failed", http.StatusInternalServerError)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("audit_reveal: csrf issue: %v", err)
	}
	data := auditPageData{
		PageData: views.PageData{
			Title:      "Audit event " + eventID,
			User:       user,
			CSRFToken:  tok,
			ActivePage: "audit",
		},
		Configured:      true,
		DetailEvent:     ev,
		DetailRedacted:  string(ev.Payload),
		RevealEnabled:   true,
		RevealSucceeded: true,
	}
	d.render(w, "audit/detail.html.tmpl", data)
}

// CSVExportHandler is GET /audit/export.csv.
//
// `?reveal=true` admin-only and emits one
// `audit.csv_export_with_reveal` event BEFORE the stream starts.
// Default (no ?reveal) streams redacted payloads to anyone with
// dashboard access (viewer + admin).
func (d *AuditDeps) CSVExportHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.Configured {
		http.NotFound(w, r)
		return
	}
	reveal := strings.EqualFold(r.URL.Query().Get("reveal"), "true")
	if reveal && user.Role != auth.RoleAdmin {
		http.NotFound(w, r)
		return
	}
	filter, _, _ := d.parseFilterFromQuery(r.URL.Query())
	// Force a tight upper bound on the streamed result count to
	// keep memory bounded. Operators wanting a fuller export can
	// adjust the date range or fetch in pages.
	filter.Page = 1
	filter.PageSize = 10000
	events, _, err := d.AuditStore.ListEvents(r.Context(), filter)
	if err != nil {
		log.Printf("audit_csv: list: %v", err)
		http.Error(w, "audit log unavailable", http.StatusBadGateway)
		return
	}
	if reveal {
		// Emit the heads-up BEFORE we begin writing the response.
		//
		// Slice 6 fix-up r1 H3 / DRIFT-006: Emit failure MUST
		// short-circuit the export — the same fail-closed invariance as
		// reveal-raw (no raw PII on the wire without a matching audit
		// row).
		if err := d.AuditEmitter.Emit(r.Context(), "audit.csv_export_with_reveal", user.Email, map[string]any{
			"row_count":    strconv.Itoa(len(events)),
			"filter_query": redactQueryForAudit(r.URL.RawQuery),
		}); err != nil {
			log.Printf("audit_csv: reveal emit failed (fail-closed; raw payload NOT streamed): %v", err)
			http.Error(w, "audit emit failed", http.StatusInternalServerError)
			return
		}
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Disposition", "attachment; filename=audit-events.csv")
	cw := csv.NewWriter(w)
	defer cw.Flush()
	header := []string{"event_id", "event_type", "source_service", "actor", "timestamp", "request_id", "previous_event_hash", "event_hash", "payload"}
	if err := cw.Write(header); err != nil {
		log.Printf("audit_csv: write header: %v", err)
		return
	}
	for _, ev := range events {
		payload := string(ev.Payload)
		actor := ev.Actor
		if !reveal {
			payload = string(redactPayloadCSV(ev.Payload))
			actor = piiguard.Redact(actor)
		}
		row := []string{
			ev.EventID,
			ev.EventType,
			ev.SourceService,
			actor,
			ev.Timestamp.UTC().Format(time.RFC3339),
			ev.RequestID,
			ev.PreviousEventHash,
			ev.EventHash,
			payload,
		}
		if err := cw.Write(row); err != nil {
			log.Printf("audit_csv: write row: %v", err)
			return
		}
	}
}

// SavedFiltersGet is GET /audit/saved-filters.
func (d *AuditDeps) SavedFiltersGet(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.Configured || d.SavedFilters == nil {
		http.Error(w, "saved filters unavailable", http.StatusServiceUnavailable)
		return
	}
	filters, err := d.SavedFilters.List(r.Context(), user.Email)
	if err != nil {
		if errors.Is(err, store.ErrSavedFilterTableMissing) {
			http.Error(w, "saved filters table missing", http.StatusServiceUnavailable)
			return
		}
		log.Printf("audit_savedfilters_get: %v", err)
		http.Error(w, "audit log unavailable", http.StatusBadGateway)
		return
	}
	// Render an HTML fragment listing the user's filters; the
	// template can be reused inline from the browser page. For
	// simplicity here, return JSON the client may consume via
	// the static script tag in browser.html.tmpl (no client
	// JS framework added).
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	var buf strings.Builder
	buf.WriteString(`{"filters":[`)
	for i, f := range filters {
		if i > 0 {
			buf.WriteString(",")
		}
		fmt.Fprintf(&buf, `{"id":%d,"name":%q,"updated_at":%q}`, f.ID, f.Name, f.UpdatedAt.UTC().Format(time.RFC3339))
	}
	buf.WriteString(`]}`)
	if _, err := w.Write([]byte(buf.String())); err != nil {
		log.Printf("audit_savedfilters_get: write: %v", err)
	}
}

// SavedFiltersPost is POST /audit/saved-filters. Form fields: name +
// each filter field replicated from the browser page (event_types,
// source_services, ...). CSRF-required.
func (d *AuditDeps) SavedFiltersPost(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.Configured || d.SavedFilters == nil {
		http.Error(w, "saved filters unavailable", http.StatusServiceUnavailable)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf invalid", http.StatusForbidden)
		return
	}
	name := strings.TrimSpace(r.PostFormValue("name"))
	if name == "" {
		http.Error(w, "filter name required", http.StatusBadRequest)
		return
	}
	if len(name) > 100 {
		http.Error(w, "filter name too long (max 100 chars)", http.StatusBadRequest)
		return
	}
	filter, _, _ := d.parseFilterFromQuery(r.PostForm)
	if err := d.SavedFilters.Save(r.Context(), user.Email, name, filter); err != nil {
		if errors.Is(err, store.ErrSavedFilterTableMissing) {
			http.Error(w, "saved filters table missing — apply the dashboard migration", http.StatusServiceUnavailable)
			return
		}
		log.Printf("audit_savedfilters_post: %v", err)
		http.Error(w, "audit log unavailable", http.StatusBadGateway)
		return
	}
	// Redirect back to /audit with the saved filter applied as a
	// confirmation banner.
	redirectURL := "/audit?saved=" + url.QueryEscape(name) + "&" + filterToQuery(filter)
	http.Redirect(w, r, redirectURL, http.StatusSeeOther)
}

// SavedFiltersDelete is DELETE /audit/saved-filters/{name}.
//
// Per the locked router pattern (no PATCH/DELETE in the existing
// http.ServeMux setup; everything goes POST + `_method=delete`), the
// route accepts POST with a hidden `_method=delete` form field. This
// keeps the same single-mux dispatch shape Slice 5's keys handler uses.
func (d *AuditDeps) SavedFiltersDelete(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.Configured || d.SavedFilters == nil {
		http.Error(w, "saved filters unavailable", http.StatusServiceUnavailable)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf invalid", http.StatusForbidden)
		return
	}
	name := strings.TrimSpace(extractSavedFilterNameFromPath(r.URL.Path))
	if name == "" {
		http.Error(w, "filter name required", http.StatusBadRequest)
		return
	}
	if err := d.SavedFilters.Delete(r.Context(), user.Email, name); err != nil {
		if errors.Is(err, store.ErrSavedFilterTableMissing) {
			http.Error(w, "saved filters table missing", http.StatusServiceUnavailable)
			return
		}
		log.Printf("audit_savedfilters_delete: %v", err)
		http.Error(w, "audit log unavailable", http.StatusBadGateway)
		return
	}
	http.Redirect(w, r, "/audit", http.StatusSeeOther)
}

// === Helpers ===

func (d *AuditDeps) render(w http.ResponseWriter, name string, data auditPageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, name, data); err != nil {
		log.Printf("audit_render(%s): %v", name, err)
	}
}

// parseFilterFromQuery reads filter fields from URL.Values (works for
// both r.URL.Query() and r.PostForm). Returns the filter, page, and
// page size with defensive bounds.
func (d *AuditDeps) parseFilterFromQuery(q url.Values) (store.AuditFilter, int, int) {
	f := store.AuditFilter{}
	f.EventTypes = csvList(q.Get("event_type"))
	f.SourceServices = csvList(q.Get("source_service"))
	f.Actors = csvList(q.Get("actor"))
	f.RequestID = strings.TrimSpace(q.Get("request_id"))
	if v := strings.TrimSpace(q.Get("payload_contains")); v != "" {
		// Cap at 256 chars defensively; longer payloads are likely
		// pasted noise that would slow the LIKE query.
		if len(v) > 256 {
			v = v[:256]
		}
		f.PayloadContains = v
	}
	if ts := strings.TrimSpace(q.Get("from")); ts != "" {
		if t, err := parseFilterTimestamp(ts); err == nil {
			f.TimestampFrom = &t
		}
	}
	if ts := strings.TrimSpace(q.Get("to")); ts != "" {
		if t, err := parseFilterTimestamp(ts); err == nil {
			f.TimestampTo = &t
		}
	}
	page := 1
	if v := strings.TrimSpace(q.Get("page")); v != "" {
		if p, err := strconv.Atoi(v); err == nil && p > 0 {
			page = p
		}
	}
	pageSize := 50
	if v := strings.TrimSpace(q.Get("page_size")); v != "" {
		if p, err := strconv.Atoi(v); err == nil && p > 0 {
			pageSize = p
		}
	}
	// Safety cap on page; the store also caps the ListEvents page_size.
	if d.MaxPagesAllowed > 0 && page > d.MaxPagesAllowed {
		page = d.MaxPagesAllowed
	}
	f.Page = page
	f.PageSize = pageSize
	return f, page, pageSize
}

func (d *AuditDeps) populatePagination(data *auditPageData) {
	if data.PageSize <= 0 {
		data.PageSize = 50
	}
	if data.Total <= 0 || data.PageSize <= 0 {
		data.TotalPages = 1
	} else {
		data.TotalPages = (data.Total + data.PageSize - 1) / data.PageSize
	}
	if data.Page < 1 {
		data.Page = 1
	}
	if data.Page > data.TotalPages {
		data.Page = data.TotalPages
	}
	if data.Page > 1 {
		data.HasPrev = true
		data.PrevPage = data.Page - 1
	}
	if data.Page < data.TotalPages {
		data.HasNext = true
		data.NextPage = data.Page + 1
	}
	start := (data.Page-1)*data.PageSize + 1
	end := data.Page * data.PageSize
	if end > data.Total {
		end = data.Total
	}
	if data.Total == 0 {
		start = 0
		end = 0
	}
	data.StartIndex = start
	data.EndIndex = end
	// Window of page numbers around the current page (max 7).
	data.PageList = pageWindow(data.Page, data.TotalPages, 7)
}

func (d *AuditDeps) populateRedactedRows(data *auditPageData) {
	data.RowsRedacted = make([]renderedRow, 0, len(data.Events))
	for _, ev := range data.Events {
		// Slice 6 fix-up r1 H1: the flat piiguard.Redact treats every
		// 5-digit number as a German postal code, every 13-19 digit
		// number as a PAN, and HH:MM:SS timestamps as IPv6. Audit
		// payloads carry numeric leaves (id, latency_ms, port,
		// response_size, BIGSERIAL ids) that MUST NOT be redacted —
		// they're the operator's primary triage signal. RedactJSON
		// walks the structure and only Redact()s string leaves,
		// preserving every number / boolean / null as-is. Falls back
		// to flat Redact on non-JSON / malformed input via its
		// internal contract.
		var preview string
		if redacted, err := piiguard.RedactJSON(ev.Payload); err == nil && len(redacted) > 0 {
			preview = string(redacted)
		} else {
			// Defence-in-depth: the JSON walker should never error
			// because its malformed-input branch already falls back
			// to flat Redact; if we somehow land here, render the
			// sentinel rather than the raw bytes.
			preview = "[REDACTED — render error]"
		}
		if len(preview) > 80 {
			preview = preview[:80] + "…"
		}
		data.RowsRedacted = append(data.RowsRedacted, renderedRow{
			ID:             ev.ID,
			EventID:        ev.EventID,
			EventType:      ev.EventType,
			SourceService:  ev.SourceService,
			Actor:          piiguard.Redact(ev.Actor),
			Timestamp:      ev.Timestamp,
			RequestID:      ev.RequestID,
			PayloadPreview: preview,
		})
	}
}

func pageWindow(current, total, width int) []int {
	if total <= 0 {
		return nil
	}
	if width <= 0 {
		width = 5
	}
	if total <= width {
		out := make([]int, total)
		for i := range out {
			out[i] = i + 1
		}
		return out
	}
	half := width / 2
	start := current - half
	if start < 1 {
		start = 1
	}
	end := start + width - 1
	if end > total {
		end = total
		start = end - width + 1
		if start < 1 {
			start = 1
		}
	}
	out := make([]int, 0, end-start+1)
	for i := start; i <= end; i++ {
		out = append(out, i)
	}
	return out
}

func csvList(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	raw := strings.Split(s, ",")
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		out = append(out, v)
	}
	if len(out) == 0 {
		return nil
	}
	sort.Strings(out)
	return out
}

// parseFilterTimestamp accepts RFC 3339 (browser <input type=datetime-local>
// "YYYY-MM-DDTHH:MM" form too) and date-only.
func parseFilterTimestamp(s string) (time.Time, error) {
	layouts := []string{
		time.RFC3339,
		"2006-01-02T15:04",
		"2006-01-02",
	}
	for _, l := range layouts {
		if t, err := time.Parse(l, s); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("parse timestamp %q", s)
}

// redactPayloadJSON applies the JSON-aware redactor to a payload blob.
// On any error path, returns a fixed sentinel rather than the raw
// bytes (fail-closed).
func redactPayloadJSON(payload []byte) string {
	if len(payload) == 0 {
		return ""
	}
	out, err := piiguard.RedactJSON(payload)
	if err != nil || len(out) == 0 {
		return "[REDACTED — render error]"
	}
	return string(out)
}

// redactPayloadCSV mirrors redactPayloadJSON for the CSV export
// stream. Same fail-closed sentinel on error.
func redactPayloadCSV(payload []byte) []byte {
	if len(payload) == 0 {
		return payload
	}
	out, err := piiguard.RedactJSON(payload)
	if err != nil || len(out) == 0 {
		return []byte("[REDACTED — render error]")
	}
	return out
}

// extractEventIDFromPath parses /audit/{event_id} or
// /audit/{event_id}/reveal-raw, returning event_id (no suffix).
func extractEventIDFromPath(path string) string {
	const prefix = "/audit/"
	if !strings.HasPrefix(path, prefix) {
		return ""
	}
	rest := strings.TrimPrefix(path, prefix)
	rest = strings.TrimSuffix(rest, "/")
	// Strip trailing suffix our router pins to event_id (TrimSuffix
	// is a no-op when the suffix is absent).
	rest = strings.TrimSuffix(rest, "/reveal-raw")
	// Discard any nested path component we don't recognise.
	if strings.Contains(rest, "/") {
		return ""
	}
	// Defensive: reject suspicious shapes.
	if rest == "" || rest == "export.csv" || strings.HasPrefix(rest, "saved-filters") {
		return ""
	}
	return rest
}

// extractSavedFilterNameFromPath parses /audit/saved-filters/{name}.
func extractSavedFilterNameFromPath(path string) string {
	const prefix = "/audit/saved-filters/"
	if !strings.HasPrefix(path, prefix) {
		return ""
	}
	rest := strings.TrimPrefix(path, prefix)
	rest = strings.TrimSuffix(rest, "/")
	if strings.Contains(rest, "/") {
		return ""
	}
	return rest
}

// filterToQuery rebuilds a URL query string from the in-memory filter
// so SavedFiltersPost can hand the user back a /audit URL with the
// saved filter applied. Pagination is intentionally omitted.
func filterToQuery(f store.AuditFilter) string {
	v := url.Values{}
	if len(f.EventTypes) > 0 {
		v.Set("event_type", strings.Join(f.EventTypes, ","))
	}
	if len(f.SourceServices) > 0 {
		v.Set("source_service", strings.Join(f.SourceServices, ","))
	}
	if len(f.Actors) > 0 {
		v.Set("actor", strings.Join(f.Actors, ","))
	}
	if f.RequestID != "" {
		v.Set("request_id", f.RequestID)
	}
	if f.PayloadContains != "" {
		v.Set("payload_contains", f.PayloadContains)
	}
	if f.TimestampFrom != nil && !f.TimestampFrom.IsZero() {
		v.Set("from", f.TimestampFrom.UTC().Format(time.RFC3339))
	}
	if f.TimestampTo != nil && !f.TimestampTo.IsZero() {
		v.Set("to", f.TimestampTo.UTC().Format(time.RFC3339))
	}
	return v.Encode()
}

// redactQueryForAudit strips obvious PII from a query string before
// emitting it into the audit log. The query may carry an actor email
// the operator filtered on; we apply the same render-time redactor
// so the audit event itself does not become a PII leak vector.
func redactQueryForAudit(raw string) string {
	if raw == "" {
		return ""
	}
	if len(raw) > 1024 {
		raw = raw[:1024]
	}
	return piiguard.Redact(raw)
}
