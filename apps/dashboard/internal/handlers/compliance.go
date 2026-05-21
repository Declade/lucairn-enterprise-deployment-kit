package handlers

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/audit"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/compliance"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// ComplianceDeps wires the /compliance surface. The PDF export is the
// terminal surface of the v1.0-dashboard arc.
//
// Aggregator may be nil when neither the cert DB (Slice 3) nor the
// audit DB (Slice 6) is configured — the surface still registers but
// renders the "not configured" explainer with zero queries.
//
// Configured is the honesty bit: when false, the GET surface renders
// the explainer and POST returns 404 (admin-only + opt-in surface).
//
// AuditEmitter is REQUIRED in production — every PDF generation
// emits an `audit.compliance_pdf_generated` event with the row count,
// page count, byte size, and operator email. Fail-closed pattern (the
// emit MUST land BEFORE PDF bytes go on the wire; mirrors Slice 6's
// reveal-raw pattern at handlers/audit.go:327).
//
// KitVersion + DashboardVersion + ImageDigests are the static
// metadata the cover page renders. ImageDigests is the manifest the
// kit shipped with; the orchestrator wires it from image-manifest.yaml
// at startup. Empty map = "Image manifest unavailable in this build"
// fallback on the cover page.
type ComplianceDeps struct {
	Renderer        *views.Renderer
	Aggregator      *compliance.Aggregator
	AuditEmitter    audit.Emitter
	Configured      bool
	KitVersion      string
	DashboardVersion string
	ImageDigests    map[string]string
	MaxWindowDays   int
	DefaultCustomer string
	Clock           func() time.Time
}

// NewComplianceDeps constructs a configured ComplianceDeps. When
// aggregator is nil, configured=false is forced — the surface renders
// the explainer regardless of the caller's intent. emitter=nil falls
// back to LogEmitter (matches Slice 5 + Slice 6 pattern).
func NewComplianceDeps(
	renderer *views.Renderer,
	aggregator *compliance.Aggregator,
	emitter audit.Emitter,
	kitVersion string,
	dashboardVersion string,
	imageDigests map[string]string,
	maxWindowDays int,
	defaultCustomer string,
	configured bool,
) *ComplianceDeps {
	if emitter == nil {
		emitter = audit.NewLogEmitter()
	}
	if maxWindowDays <= 0 {
		maxWindowDays = compliance.MaxWindowDays
	}
	if maxWindowDays > compliance.HardMaxWindowDays {
		maxWindowDays = compliance.HardMaxWindowDays
	}
	if aggregator == nil {
		configured = false
	}
	return &ComplianceDeps{
		Renderer:         renderer,
		Aggregator:       aggregator,
		AuditEmitter:     emitter,
		Configured:       configured,
		KitVersion:       kitVersion,
		DashboardVersion: dashboardVersion,
		ImageDigests:     imageDigests,
		MaxWindowDays:    maxWindowDays,
		DefaultCustomer:  defaultCustomer,
		Clock:            time.Now,
	}
}

// compliancePageData is the render payload for /compliance.
type compliancePageData struct {
	views.PageData
	Configured       bool
	NotConfigured    string
	DefaultCustomer  string
	DefaultFrom      string // YYYY-MM-DD
	DefaultTo        string // YYYY-MM-DD
	MaxWindowDays    int
	FlashError       string
	KitVersion       string
	DashboardVersion string
}

// ExportPage is GET /compliance. Admin-only (RequireRole handles the
// 404-for-viewers gate at the server layer). Renders the date range
// picker + customer name input + Generate PDF CTA.
func (d *ComplianceDeps) ExportPage(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("compliance_export_page: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	now := d.Clock().UTC()
	defaultTo := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, 1) // end-of-today exclusive
	defaultFrom := defaultTo.AddDate(0, 0, -compliance.DefaultWindowDays)

	data := compliancePageData{
		PageData: views.PageData{
			Title:      "Compliance export",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "compliance",
		},
		Configured:       d.Configured,
		DefaultCustomer:  d.DefaultCustomer,
		DefaultFrom:      defaultFrom.Format("2006-01-02"),
		DefaultTo:        defaultTo.AddDate(0, 0, -1).Format("2006-01-02"),
		MaxWindowDays:    d.MaxWindowDays,
		KitVersion:       d.KitVersion,
		DashboardVersion: d.DashboardVersion,
	}
	if !d.Configured {
		data.NotConfigured = "Compliance export is not configured on this install. Set LUCAIRN_DASHBOARD_AUDIT_DB_URL (Slice 3) and LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL (Slice 6) to populate the certificate and audit-event counts. See INSTALL.md § \"Compliance PDF export\"."
	}
	d.render(w, "compliance/export.html.tmpl", data)
}

// ExportPDF is POST /compliance/export. Admin-only. CSRF-required.
// Reads form fields (customer_name + from + to), validates the date
// range, calls aggregator + PDF generator, emits the audit event,
// then returns the PDF bytes with a Content-Disposition attachment
// filename.
//
// Fail-closed pattern: the audit emit MUST succeed BEFORE the PDF
// bytes are written to the response writer. If emit fails the
// handler returns 500 + zero PDF bytes.
//
// Sequence:
//
//  1. CSRF verify
//  2. Form parse + validate (customer_name + from + to)
//  3. Sanitize customer_name (banned-literal-check, length, ctrl chars)
//  4. Aggregator.Summary() — fails closed if any sub-query errors
//  5. GeneratePDF — fails closed on banned-literal during render
//  6. AuditEmitter.Emit — fails closed if DB emit errors
//  7. Write PDF bytes with attachment headers
func (d *ComplianceDeps) ExportPDF(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	if !d.Configured || d.Aggregator == nil {
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

	// (a) Customer name.
	rawName := r.PostFormValue("customer_name")
	if rawName == "" {
		rawName = d.DefaultCustomer
	}
	customerName, err := compliance.SanitizeCustomerName(rawName)
	if err != nil {
		log.Printf("compliance_export: customer name rejected: %v", err)
		http.Error(w, "customer name invalid: "+err.Error(), http.StatusBadRequest)
		return
	}

	// (b) Date range.
	from, to, err := parseComplianceDateRange(
		r.PostFormValue("from"),
		r.PostFormValue("to"),
		d.MaxWindowDays,
	)
	if err != nil {
		log.Printf("compliance_export: date range rejected: %v", err)
		http.Error(w, "date range invalid: "+err.Error(), http.StatusBadRequest)
		return
	}

	// (c) Aggregate.
	summary, err := d.Aggregator.Summary(r.Context(), from, to)
	if err != nil {
		if errors.Is(err, compliance.ErrWindowTooLarge) {
			http.Error(w, "date range exceeds maximum window of "+strconv.Itoa(d.MaxWindowDays)+" days", http.StatusBadRequest)
			return
		}
		if errors.Is(err, compliance.ErrWindowInvalid) {
			http.Error(w, "date range is empty or inverted", http.StatusBadRequest)
			return
		}
		log.Printf("compliance_export: aggregator: %v", err)
		http.Error(w, "compliance summary unavailable", http.StatusBadGateway)
		return
	}

	// (d) Render.
	pdfBytes, pageCount, err := compliance.GeneratePDF(compliance.PDFInput{
		CustomerName: customerName,
		KitVersion:   d.KitVersion,
		DashboardVer: d.DashboardVersion,
		GeneratedAt:  d.Clock().UTC(),
		ImageDigests: d.ImageDigests,
		Summary:      summary,
	})
	if err != nil {
		log.Printf("compliance_export: PDF render: %v", err)
		// Fail-closed banned-literal detection from pdf.go OR any
		// fpdf internal error — neither path produces partial PDF bytes
		// on the wire because the writer hasn't been touched yet.
		http.Error(w, "PDF generation failed", http.StatusInternalServerError)
		return
	}

	// (e) Audit emit BEFORE writing PDF bytes. Slice 6 fail-closed
	// pattern — if the audit trail can't capture WHO generated the PDF
	// (and over WHICH window) the dashboard refuses to ship the bytes.
	// The trail-vs-leak invariance is the same as reveal-raw: never
	// surface evidence content without a matching audit row.
	emitPayload := map[string]any{
		"customer_name": customerName,
		"window_from":   from.UTC().Format(time.RFC3339),
		"window_to":     to.UTC().Format(time.RFC3339),
		"page_count":    pageCount,
		"byte_size":     len(pdfBytes),
		"cert_count":    summary.Certs.Total,
		"sanitizer_events": summary.Sanitizer.TotalRedactions,
		"audit_events":  summary.Audit.Total,
	}
	if err := d.AuditEmitter.Emit(r.Context(), "audit.compliance_pdf_generated", user.Email, emitPayload); err != nil {
		log.Printf("compliance_export: audit emit failed (fail-closed; PDF NOT returned): %v", err)
		http.Error(w, "audit emit failed", http.StatusInternalServerError)
		return
	}

	// (f) Write bytes.
	filename := compliance.SanitizeFilename(customerName, from, to)
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", `attachment; filename="`+filename+`"`)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.Itoa(len(pdfBytes)))
	if _, err := w.Write(pdfBytes); err != nil {
		log.Printf("compliance_export: write body: %v", err)
	}
}

// parseComplianceDateRange parses the form's `from` + `to` fields into
// canonical UTC half-open [from, to). Format is `YYYY-MM-DD`; `to` is
// inclusive as displayed (the field labelled "To" means "up to and
// including this day") but converted to exclusive half-open for the
// query (add 1 day).
//
// Returns ErrWindowInvalid on parse errors or inverted ranges.
// Returns ErrWindowTooLarge if (to - from) > maxWindowDays.
func parseComplianceDateRange(fromStr, toStr string, maxWindowDays int) (time.Time, time.Time, error) {
	const layout = "2006-01-02"
	from, err := time.Parse(layout, fromStr)
	if err != nil {
		return time.Time{}, time.Time{}, errors.New("'from' must be in YYYY-MM-DD format")
	}
	to, err := time.Parse(layout, toStr)
	if err != nil {
		return time.Time{}, time.Time{}, errors.New("'to' must be in YYYY-MM-DD format")
	}
	// Half-open: form's "to" is inclusive of the day; add 1 day so the
	// SQL comparison `< $2` excludes the next day.
	from = time.Date(from.Year(), from.Month(), from.Day(), 0, 0, 0, 0, time.UTC)
	to = time.Date(to.Year(), to.Month(), to.Day(), 0, 0, 0, 0, time.UTC).AddDate(0, 0, 1)
	if !from.Before(to) {
		return time.Time{}, time.Time{}, compliance.ErrWindowInvalid
	}
	spanDays := int(to.Sub(from)/(24*time.Hour)) + 1
	if maxWindowDays > 0 && spanDays > maxWindowDays {
		return time.Time{}, time.Time{}, compliance.ErrWindowTooLarge
	}
	return from, to, nil
}

func (d *ComplianceDeps) render(w http.ResponseWriter, name string, data compliancePageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, name, data); err != nil {
		log.Printf("compliance_render(%s): %v", name, err)
	}
}
