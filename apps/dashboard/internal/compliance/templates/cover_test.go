package templates

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// recordingRenderer is a minimal CoverRenderer that captures every
// emitted text + cell so the test can grep the output.
type recordingRenderer struct {
	calls []string
}

func (r *recordingRenderer) AddPage()                                       { r.calls = append(r.calls, "addpage") }
func (r *recordingRenderer) SetFont(family, style string, sizePt float64)   {}
func (r *recordingRenderer) SetTextColor(rr, g, b int)                      {}
func (r *recordingRenderer) SetDrawColor(rr, g, b int)                      {}
func (r *recordingRenderer) SetLineWidth(w float64)                         {}
func (r *recordingRenderer) SetY(y float64)                                 {}
func (r *recordingRenderer) SetX(x float64)                                 {}
func (r *recordingRenderer) GetX() float64                                  { return 0 }
func (r *recordingRenderer) GetY() float64                                  { return 0 }
func (r *recordingRenderer) Line(x1, y1, x2, y2 float64)                    {}
func (r *recordingRenderer) Ln(h float64)                                   {}
func (r *recordingRenderer) PageWidth() float64                             { return 210 }
func (r *recordingRenderer) CellFormat(w, h float64, text, border string, ln int, align string, fill bool, link int, linkStr string) {
	r.calls = append(r.calls, "cell:"+text)
}
func (r *recordingRenderer) MultiCell(w, h float64, text, border, align string, fill bool) {
	r.calls = append(r.calls, "mcell:"+text)
}

func (r *recordingRenderer) joined() string {
	return strings.Join(r.calls, "\n")
}

func TestRender_EmitsRequiredSections(t *testing.T) {
	rec := &recordingRenderer{}
	asserts := []string{}
	in := CoverInput{
		CustomerName:  "Acme Corp GmbH",
		DateRangeFrom: time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
		DateRangeTo:   time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		KitVersion:    "1.4.0-dashboard",
		DashboardVer:  "0.7.0",
		GeneratedAt:   time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC),
		ImageDigests: map[string]string{
			"lucairn-dashboard": "0.7.0",
			"dsa-gateway":       "0.4.0",
		},
	}
	err := Render(rec, in, func(section, text string) error {
		asserts = append(asserts, section)
		return nil
	})
	if err != nil {
		t.Fatalf("Render = %v, want nil", err)
	}
	out := rec.joined()
	for _, must := range []string{
		"Lucairn - Compliance Export",
		"AI Act Art. 10 / 12 / 14 / 15 evidence summary",
		"Customer",
		"Acme Corp GmbH",
		"Date range",
		"2026-04-01",
		"2026-04-30", // (to - 1ns).Format("2006-01-02")
		"1.4.0-dashboard",
		"0.7.0",
		"lucairn-dashboard",
		"dsa-gateway",
		"This report is an automated count",
		// Release-gate polish (2026-05-21) — regulator-validator FAIL [6/7]
		// closure: the cover caveat MUST frame the 3-category obligation
		// overlay as Lucairn's opinion, never as the AI Act's own
		// categorization. This assertion locks the fix against silent
		// regression (tautological-test bug class — Slice 4 C33 / Slice 5
		// BH-H2 / Slice 6 H2 / Slice 7 BH-M1 pattern).
		"Lucairn's opinionated obligation overlay",
		"Regulation (EU) 2024/1689 does not itself define these three categories",
	} {
		if !strings.Contains(out, must) {
			t.Errorf("output missing %q\nfull:\n%s", must, out)
		}
	}
	if len(asserts) < 5 {
		t.Errorf("expected ≥5 assert callbacks, got %d", len(asserts))
	}
}

func TestRender_FailsClosedOnBannedLiteralInCustomerName(t *testing.T) {
	rec := &recordingRenderer{}
	in := CoverInput{
		CustomerName:  "Acme Holdings",
		DateRangeFrom: time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
		DateRangeTo:   time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		KitVersion:    "1.4.0-dashboard",
		DashboardVer:  "0.7.0",
		GeneratedAt:   time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC),
	}
	// The assert hook returns an error on a specific section to simulate
	// a banned-literal detection at the cover-row level.
	err := Render(rec, in, func(section, text string) error {
		if section == "cover_row_Customer" {
			return fmt.Errorf("banned literal at offset 0: HIPAA")
		}
		return nil
	})
	if err == nil {
		t.Fatal("Render = nil err, want non-nil")
	}
}

func TestRender_StableImageDigestOrdering(t *testing.T) {
	in := CoverInput{
		CustomerName:  "Acme",
		DateRangeFrom: time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
		DateRangeTo:   time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		KitVersion:    "1.4.0",
		DashboardVer:  "0.7.0",
		GeneratedAt:   time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC),
		ImageDigests: map[string]string{
			"z-service":         "0.1.0",
			"a-service":         "0.2.0",
			"m-service":         "0.3.0",
			"lucairn-dashboard": "0.7.0",
		},
	}
	for i := 0; i < 5; i++ {
		rec := &recordingRenderer{}
		if err := Render(rec, in, func(_, _ string) error { return nil }); err != nil {
			t.Fatalf("Render iter %d: %v", i, err)
		}
		// Iterate calls looking for the 4 digest rows; assert they appear
		// in alphabetical order.
		var rows []string
		for _, c := range rec.calls {
			if strings.HasPrefix(c, "cell:") {
				body := strings.TrimPrefix(c, "cell:")
				if body == "a-service" || body == "lucairn-dashboard" || body == "m-service" || body == "z-service" {
					rows = append(rows, body)
				}
			}
		}
		want := []string{"a-service", "lucairn-dashboard", "m-service", "z-service"}
		if strings.Join(rows, "|") != strings.Join(want, "|") {
			t.Errorf("iter %d image order = %v, want %v", i, rows, want)
		}
	}
}

func TestRender_EmptyImageDigestsRendersFallback(t *testing.T) {
	rec := &recordingRenderer{}
	in := CoverInput{
		CustomerName:  "Acme",
		DateRangeFrom: time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
		DateRangeTo:   time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		KitVersion:    "1.4.0",
		DashboardVer:  "0.7.0",
		GeneratedAt:   time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC),
		ImageDigests:  nil,
	}
	if err := Render(rec, in, func(_, _ string) error { return nil }); err != nil {
		t.Fatalf("Render = %v", err)
	}
	if !strings.Contains(rec.joined(), "Image manifest unavailable") {
		t.Errorf("empty-digest fallback line missing\nfull:\n%s", rec.joined())
	}
}
