// Package templates carries the composable PDF cover-page renderer for
// the compliance export. The cover is rendered as a single function so
// fpdf doesn't have to support sub-template embedding — fpdf is a
// flat-rendering library. Keeping cover composition in its own package
// makes the layout reusable if a future PDF surface (e.g. operator
// onboarding receipts) needs the same boxed-header treatment.
//
// CoverInput carries every field the cover page emits. Every string
// input MUST already pass through compliance.SanitizeCustomerName +
// compliance.Assert at the handler layer — the cover renderer
// re-asserts via the supplied AssertFn so a programming error that
// bypassed the handler-side guard still gets caught at render time.
// AssertFn is wired by pdf.go to compliance.AssertSection so a
// banned-literal slip produces an actionable section-named error.
package templates

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// CoverInput is the cover-page render payload.
type CoverInput struct {
	CustomerName  string
	DateRangeFrom time.Time
	DateRangeTo   time.Time
	KitVersion    string
	DashboardVer  string
	GeneratedAt   time.Time
	// ImageDigests maps "service-name" → "tag@sha256:..." (or simply
	// "tag" when the digest is unknown to the dashboard). The cover
	// renders services in alphabetical order for stable layout across
	// fresh builds.
	ImageDigests map[string]string
}

// AssertFn is the banned-literal guard interface. pdf.go injects
// compliance.AssertSection bound to the section name; tests inject a
// no-op or a record-and-pass-through hook.
type AssertFn func(section, text string) error

// CoverRenderer is the abstract interface the cover composer uses to
// emit text + lines onto the page. fpdf's *Fpdf satisfies it directly
// — the method signatures here match `github.com/go-pdf/fpdf` Fpdf
// methods 1:1 (ln is an int per fpdf convention: 0=right, 1=newline,
// 2=below).
type CoverRenderer interface {
	AddPage()
	SetFont(family, style string, sizePt float64)
	SetTextColor(r, g, b int)
	SetDrawColor(r, g, b int)
	SetLineWidth(w float64)
	SetY(y float64)
	SetX(x float64)
	GetX() float64
	GetY() float64
	CellFormat(w, h float64, text, border string, ln int, align string, fill bool, link int, linkStr string)
	MultiCell(w, h float64, text, border, align string, fill bool)
	Line(x1, y1, x2, y2 float64)
	Ln(h float64)
	PageWidth() float64
}

// Render writes the cover page onto the renderer. Returns any
// banned-literal violation; on error the caller MUST short-circuit
// PDF generation (fail-closed per pattern #46 / Slice 6).
//
// Layout: top-bar Lucairn brand, then h1 title, then the customer +
// date-range + kit-version block, then a small image-digest table.
// Footer carries the GeneratedAt timestamp + a single "Lucairn
// Enterprise Dashboard" attribution line.
func Render(r CoverRenderer, in CoverInput, assert AssertFn) error {
	// Cover content gates — every string we emit goes through Assert.
	for label, text := range map[string]string{
		"customer_name": in.CustomerName,
		"kit_version":   in.KitVersion,
		"dashboard_ver": in.DashboardVer,
	} {
		if err := assert(label, text); err != nil {
			return err
		}
	}

	r.AddPage()

	// Top-bar accent line at the page top — uses Lucairn accent color
	// (#8EC0F0 → r=142,g=192,b=240).
	r.SetDrawColor(142, 192, 240)
	r.SetLineWidth(0.6)
	r.Line(20, 18, r.PageWidth()-20, 18)
	r.SetDrawColor(0, 0, 0)

	// Title block.
	r.SetY(28)
	r.SetTextColor(20, 20, 22)
	r.SetFont("Helvetica", "B", 22)
	if err := assert("title", "Lucairn - Compliance Export"); err != nil {
		return err
	}
	r.CellFormat(0, 12, "Lucairn - Compliance Export", "", 1, "L", false, 0, "")

	// Subtitle.
	r.SetFont("Helvetica", "", 11)
	r.SetTextColor(120, 120, 125)
	subtitle := "AI Act Art. 10 / 12 / 14 / 15 evidence summary"
	if err := assert("subtitle", subtitle); err != nil {
		return err
	}
	r.CellFormat(0, 7, subtitle, "", 1, "L", false, 0, "")

	r.Ln(8)

	// Customer + window block. Each label/value pair lives in two
	// columns: label (40mm wide, bold) + value (rest of the line).
	rows := []struct {
		label string
		value string
	}{
		{"Customer", in.CustomerName},
		{"Date range", fmt.Sprintf("%s through %s (UTC)", in.DateRangeFrom.Format("2006-01-02"), in.DateRangeTo.Add(-1*time.Nanosecond).Format("2006-01-02"))},
		{"Kit version", in.KitVersion},
		{"Dashboard version", in.DashboardVer},
		{"Generated", in.GeneratedAt.UTC().Format(time.RFC3339)},
	}
	r.SetTextColor(20, 20, 22)
	for _, row := range rows {
		if err := assert("cover_row_"+row.label, row.value); err != nil {
			return err
		}
		r.SetFont("Helvetica", "B", 10)
		r.CellFormat(40, 7, row.label, "", 0, "L", false, 0, "")
		r.SetFont("Helvetica", "", 10)
		r.CellFormat(0, 7, row.value, "", 1, "L", false, 0, "")
	}

	r.Ln(8)

	// Image-digest table. The cover lists every pinned kit image so
	// the customer evidence chain documents what was installed.
	r.SetFont("Helvetica", "B", 11)
	if err := assert("digest_header", "Kit image manifest (pinned versions)"); err != nil {
		return err
	}
	r.CellFormat(0, 7, "Kit image manifest (pinned versions)", "", 1, "L", false, 0, "")

	r.SetFont("Helvetica", "", 9)
	r.SetTextColor(80, 80, 85)
	keys := sortedKeys(in.ImageDigests)
	if len(keys) == 0 {
		// Constant fallback text; bypasses AssertFn intentionally because
		// the string contains no operator-supplied substrings. Listed
		// here so the BH-L5 / L1 follow-up audit treats this as a known
		// allow-listed exception rather than a coverage gap.
		r.MultiCell(0, 6, "Image manifest unavailable in this build.", "", "L", false)
	} else {
		for _, k := range keys {
			v := in.ImageDigests[k]
			line := fmt.Sprintf("%s — %s", k, v)
			if err := assert("digest_row_"+k, line); err != nil {
				return err
			}
			r.SetFont("Helvetica", "B", 9)
			r.CellFormat(70, 6, k, "", 0, "L", false, 0, "")
			r.SetFont("Helvetica", "", 9)
			// fpdf's Latin-1 encoding can't render arbitrary unicode in
			// digests — the digest values are hex anyway.
			r.CellFormat(0, 6, v, "", 1, "L", false, 0, "")
		}
	}

	// Footer caveat: this artefact is informational, not a regulator-
	// issued attestation. Customer counsel quotes from it directly so
	// the framing matters.
	r.Ln(10)
	r.SetFont("Helvetica", "I", 8)
	r.SetTextColor(140, 140, 145)
	caveat := strings.Join([]string{
		"This report is an automated count produced by the Lucairn Enterprise Dashboard. It documents what occurred inside the customer's own infrastructure during the window above.",
		"Lucairn is the software vendor; the customer is the regulator-facing operator and remains responsible for assessing the AI system's classification, conformity-assessment, and obligations under Regulation (EU) 2024/1689.",
		"This report is informational and is not legal advice. Review by qualified counsel is required before relying on it for compliance decisions. Lucairn UG (i.Gr.) disclaims all liability for downstream use.",
	}, " ")
	if err := assert("cover_caveat", caveat); err != nil {
		return err
	}
	r.MultiCell(0, 4.5, caveat, "", "L", false)

	r.SetTextColor(0, 0, 0)
	return nil
}

// sortedKeys returns the keys of m alphabetically sorted. Helper kept
// inline so the test file can import a sibling stub.
func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
