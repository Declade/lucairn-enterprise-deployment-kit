package compliance

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// fakeQuerier is a minimal pgx-shaped fake. Each test case
// pre-populates rows by SQL+args key.
type fakeQuerier struct {
	queryFn func(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func (f *fakeQuerier) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	return f.queryFn(ctx, sql, args...)
}

func (f *fakeQuerier) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	panic("not used by aggregator")
}

func (f *fakeQuerier) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	panic("not used by aggregator")
}

// fakeRows is a slice-backed pgx.Rows for tests.
type fakeRows struct {
	data  [][]any
	idx   int
	err   error
	close bool
}

func newFakeRows(data [][]any) *fakeRows {
	return &fakeRows{data: data, idx: -1}
}

func (r *fakeRows) Close()              { r.close = true }
func (r *fakeRows) Err() error          { return r.err }
func (r *fakeRows) CommandTag() pgconn.CommandTag {
	return pgconn.CommandTag{}
}
func (r *fakeRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *fakeRows) Next() bool {
	r.idx++
	return r.idx < len(r.data)
}
func (r *fakeRows) Scan(dest ...any) error {
	if r.idx >= len(r.data) {
		return errors.New("scan past end")
	}
	row := r.data[r.idx]
	if len(row) != len(dest) {
		return errors.New("scan column count mismatch")
	}
	for i := range row {
		switch d := dest[i].(type) {
		case *int:
			*d = row[i].(int)
		case *string:
			*d = row[i].(string)
		case *time.Time:
			*d = row[i].(time.Time)
		default:
			return errors.New("unsupported scan destination type")
		}
	}
	return nil
}
func (r *fakeRows) Values() ([]any, error) {
	return r.data[r.idx], nil
}
func (r *fakeRows) RawValues() [][]byte { return nil }
func (r *fakeRows) Conn() *pgx.Conn     { return nil }

func TestNewAggregator_DefaultsAppliedWhenZero(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{})
	if a.maxWindowDays != MaxWindowDays {
		t.Errorf("maxWindowDays = %d, want %d", a.maxWindowDays, MaxWindowDays)
	}
	if a.queryTimeout != 30*time.Second {
		t.Errorf("queryTimeout = %v, want 30s", a.queryTimeout)
	}
}

func TestNewAggregator_CapsExcessiveMaxWindow(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{MaxWindowDays: 99999})
	if a.maxWindowDays != HardMaxWindowDays {
		t.Errorf("maxWindowDays = %d, want capped at %d", a.maxWindowDays, HardMaxWindowDays)
	}
}

func TestValidateWindow_RejectsInvertedRange(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{})
	from := time.Date(2026, 5, 10, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 5, 0, 0, 0, 0, time.UTC) // before from
	_, _, err := a.validateWindow(from, to)
	if !errors.Is(err, ErrWindowInvalid) {
		t.Errorf("validateWindow inverted = %v, want ErrWindowInvalid", err)
	}
}

func TestValidateWindow_RejectsZeroTime(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{})
	to := time.Date(2026, 5, 10, 0, 0, 0, 0, time.UTC)
	_, _, err := a.validateWindow(time.Time{}, to)
	if !errors.Is(err, ErrWindowInvalid) {
		t.Errorf("validateWindow zero from = %v, want ErrWindowInvalid", err)
	}
}

func TestValidateWindow_RejectsExcessiveSpan(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{MaxWindowDays: 30})
	from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC) // 59 days
	_, _, err := a.validateWindow(from, to)
	if !errors.Is(err, ErrWindowTooLarge) {
		t.Errorf("validateWindow excessive = %v, want ErrWindowTooLarge", err)
	}
}

func TestValidateWindow_AcceptsBoundaryWindow(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{MaxWindowDays: 30})
	from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 1, 30, 0, 0, 0, 0, time.UTC) // 29-day half-open span
	if _, _, err := a.validateWindow(from, to); err != nil {
		t.Errorf("validateWindow 29-day half-open window = %v, want nil", err)
	}
}

// TestValidateWindow_ExactMaxAccepted locks the BH-H1 boundary: a
// half-open span of EXACTLY MaxWindowDays MUST be accepted. Before
// fix-up r1 the +1 off-by-one rejected this — 365-visible-day annual
// exports failed at the default cap.
func TestValidateWindow_ExactMaxAccepted(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{MaxWindowDays: 30})
	from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 1, 31, 0, 0, 0, 0, time.UTC) // exactly 30 days half-open
	if _, _, err := a.validateWindow(from, to); err != nil {
		t.Errorf("validateWindow exact 30-day half-open window = %v, want nil (BH-H1 boundary)", err)
	}
}

// TestValidateWindow_OneOverMaxRejected anchors the upper edge: a span
// of MaxWindowDays + 1 MUST reject. Pairs with ExactMaxAccepted to lock
// the cap exactly at MaxWindowDays.
func TestValidateWindow_OneOverMaxRejected(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{MaxWindowDays: 30})
	from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC) // 31 days half-open
	_, _, err := a.validateWindow(from, to)
	if !errors.Is(err, ErrWindowTooLarge) {
		t.Errorf("validateWindow 31-day half-open window = %v, want ErrWindowTooLarge", err)
	}
}

func TestCountCertsInWindow_NilCertDBReturnsEmpty(t *testing.T) {
	a := NewAggregator(nil, nil, AggregatorOpts{})
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC)
	out, err := a.CountCertsInWindow(context.Background(), from, to)
	if err != nil {
		t.Fatalf("CountCertsInWindow nil = %v, want nil", err)
	}
	if out.Total != 0 {
		t.Errorf("Total = %d, want 0", out.Total)
	}
	if len(out.ByVerdict) != 0 {
		t.Errorf("ByVerdict = %v, want empty map", out.ByVerdict)
	}
}

func TestCountCertsInWindow_AccumulatesAndProjects(t *testing.T) {
	q := &fakeQuerier{
		queryFn: func(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
			return newFakeRows([][]any{
				{120, "passed"},
				{45, "partial"},
				{3, "failed"},
				{2, "__none__"},
			}), nil
		},
	}
	a := NewAggregator(q, nil, AggregatorOpts{})
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC)
	out, err := a.CountCertsInWindow(context.Background(), from, to)
	if err != nil {
		t.Fatalf("CountCertsInWindow = %v, want nil", err)
	}
	if out.Total != 170 {
		t.Errorf("Total = %d, want 170", out.Total)
	}
	if out.NoVerdict != 2 {
		t.Errorf("NoVerdict = %d, want 2", out.NoVerdict)
	}
	if out.ByVerdict["passed"] != 120 || out.ByVerdict["partial"] != 45 || out.ByVerdict["failed"] != 3 {
		t.Errorf("ByVerdict = %+v, want passed:120 partial:45 failed:3", out.ByVerdict)
	}
	if !out.WindowFrom.Equal(from) || !out.WindowTo.Equal(to) {
		t.Errorf("window not propagated: from=%v to=%v", out.WindowFrom, out.WindowTo)
	}
}

func TestCountSanitizerActivityInWindow_GroupsByLayer(t *testing.T) {
	q := &fakeQuerier{
		queryFn: func(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
			if !strings.Contains(sql, "sanitizer.%") {
				t.Errorf("query should filter sanitizer events, got: %s", sql)
			}
			return newFakeRows([][]any{
				{200, "L1"},
				{50, "L2"},
				{10, "L3"},
				{5, "unknown"},
			}), nil
		},
	}
	a := NewAggregator(nil, q, AggregatorOpts{})
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC)
	out, err := a.CountSanitizerActivityInWindow(context.Background(), from, to)
	if err != nil {
		t.Fatalf("CountSanitizerActivityInWindow = %v", err)
	}
	if out.TotalRedactions != 265 {
		t.Errorf("TotalRedactions = %d, want 265", out.TotalRedactions)
	}
	if out.ByLayer["L1"] != 200 || out.ByLayer["L2"] != 50 || out.ByLayer["L3"] != 10 || out.ByLayer["unknown"] != 5 {
		t.Errorf("ByLayer = %+v", out.ByLayer)
	}
}

func TestCountAuditEventsInWindow_GroupsByType(t *testing.T) {
	q := &fakeQuerier{
		queryFn: func(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
			return newFakeRows([][]any{
				{500, "audit.cert_issued"},
				{12, "audit.reveal_raw"},
				{3, "audit.csv_export_with_reveal"},
				{8, "key.mint_requested"},
			}), nil
		},
	}
	a := NewAggregator(nil, q, AggregatorOpts{})
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC)
	out, err := a.CountAuditEventsInWindow(context.Background(), from, to)
	if err != nil {
		t.Fatalf("CountAuditEventsInWindow = %v", err)
	}
	if out.Total != 523 {
		t.Errorf("Total = %d, want 523", out.Total)
	}
	if out.ByType["audit.reveal_raw"] != 12 {
		t.Errorf("reveal_raw = %d, want 12", out.ByType["audit.reveal_raw"])
	}
}

func TestSummary_ComposesAllThreePopulations(t *testing.T) {
	certCalls := 0
	auditCalls := 0
	certQ := &fakeQuerier{
		queryFn: func(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
			certCalls++
			return newFakeRows([][]any{{10, "passed"}}), nil
		},
	}
	auditQ := &fakeQuerier{
		queryFn: func(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
			auditCalls++
			if strings.Contains(sql, "sanitizer.%") {
				return newFakeRows([][]any{{5, "L1"}}), nil
			}
			return newFakeRows([][]any{{20, "audit.cert_issued"}}), nil
		},
	}
	a := NewAggregator(certQ, auditQ, AggregatorOpts{})
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC)
	out, err := a.Summary(context.Background(), from, to)
	if err != nil {
		t.Fatalf("Summary = %v", err)
	}
	if out == nil {
		t.Fatal("Summary returned nil")
	}
	if out.Certs.Total != 10 {
		t.Errorf("Certs.Total = %d, want 10", out.Certs.Total)
	}
	if out.Sanitizer.TotalRedactions != 5 {
		t.Errorf("Sanitizer.TotalRedactions = %d, want 5", out.Sanitizer.TotalRedactions)
	}
	if out.Audit.Total != 20 {
		t.Errorf("Audit.Total = %d, want 20", out.Audit.Total)
	}
	if certCalls != 1 || auditCalls != 2 {
		t.Errorf("query call counts: cert=%d audit=%d, want cert=1 audit=2", certCalls, auditCalls)
	}
}

func TestSummary_FailsClosedOnSubQueryError(t *testing.T) {
	a := NewAggregator(
		&fakeQuerier{queryFn: func(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
			return nil, errors.New("boom")
		}},
		nil,
		AggregatorOpts{},
	)
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC)
	_, err := a.Summary(context.Background(), from, to)
	if err == nil {
		t.Error("Summary on cert query error = nil; want non-nil")
	}
}

func TestSanitizeCustomerName(t *testing.T) {
	cases := []struct {
		name     string
		input    string
		want     string
		wantErr  bool
		errPiece string
	}{
		{"clean", "Acme Corp GmbH", "Acme Corp GmbH", false, ""},
		{"trims_whitespace", "  Acme Corp  ", "Acme Corp", false, ""},
		{"empty", "", "", true, "required"},
		{"only_whitespace", "    ", "", true, "required"},
		{"too_long", strings.Repeat("A", 201), "", true, "200 characters"},
		{"control_char", "Acme\x07Corp", "", true, "control character"},
		{"banned_literal_hipaa", "Acme HIPAA GmbH", "", true, "banned literal"},
		{"banned_literal_soc2", "Customer is SOC 2 audited", "", true, "banned literal"},
		{"unicode_ok", "Lucairn UG (in Gründung)", "Lucairn UG (in Gründung)", false, ""},
		{"max_length_boundary", strings.Repeat("A", 200), strings.Repeat("A", 200), false, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := SanitizeCustomerName(tc.input)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("SanitizeCustomerName(%q) = nil err; want error", tc.input)
				}
				if tc.errPiece != "" && !strings.Contains(err.Error(), tc.errPiece) {
					t.Errorf("error = %q, want substring %q", err, tc.errPiece)
				}
				return
			}
			if err != nil {
				t.Fatalf("SanitizeCustomerName(%q) = %v", tc.input, err)
			}
			if got != tc.want {
				t.Errorf("SanitizeCustomerName(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}
