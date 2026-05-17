package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// queryCall records one Query/QueryRow invocation against the fake DB so
// tests can assert the SQL + bind variables match the expected shape.
type queryCall struct {
	sql  string
	args []any
}

// fakeDB is a deterministic in-process implementation of Querier. It
// matches the rows-typed contract pgx.Rows imposes without depending on
// a docker-postgres fixture; that lift is reserved for the
// internal/integration test which actually exercises a real Postgres.
type fakeDB struct {
	calls    []queryCall
	listRows []CertSummary
	listErr  error
	count    int
	countErr error
	getRow   *CertSummary
	getErr   error
}

func (f *fakeDB) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	f.calls = append(f.calls, queryCall{sql: sql, args: args})
	if f.listErr != nil {
		return nil, f.listErr
	}
	return &fakeRows{data: f.listRows}, nil
}

func (f *fakeDB) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	f.calls = append(f.calls, queryCall{sql: sql, args: args})
	// Two callers reach QueryRow in the cert store:
	//   - List() -> COUNT(*)
	//   - Get(id) -> single-row SELECT
	if strings.Contains(strings.ToUpper(sql), "COUNT(") {
		return &fakeRow{countVal: f.count, err: f.countErr}
	}
	return &fakeRow{getVal: f.getRow, err: f.getErr}
}

type fakeRows struct {
	data []CertSummary
	idx  int
	err  error
}

func (r *fakeRows) Next() bool {
	if r.err != nil || r.idx >= len(r.data) {
		return false
	}
	return true
}
func (r *fakeRows) Scan(dest ...any) error {
	if r.idx >= len(r.data) {
		return errors.New("scan past end")
	}
	row := r.data[r.idx]
	r.idx++
	// CertSummary scan order matches the SELECT projection in store.go
	if id, ok := dest[0].(*string); ok {
		*id = row.ID
	}
	if cid, ok := dest[1].(*string); ok {
		*cid = row.CustomerID
	}
	if ts, ok := dest[2].(*time.Time); ok {
		*ts = row.CreatedAt
	}
	if v, ok := dest[3].(*string); ok {
		*v = row.Verdict
	}
	if rc, ok := dest[4].(*int); ok {
		*rc = row.RedactionCount
	}
	if cc, ok := dest[5].(*int); ok {
		*cc = row.ClaimCount
	}
	return nil
}
func (r *fakeRows) Err() error                                  { return r.err }
func (r *fakeRows) Close()                                      {}
func (r *fakeRows) CommandTag() pgconn.CommandTag               { return pgconn.CommandTag{} }
func (r *fakeRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *fakeRows) Values() ([]any, error)                      { return nil, nil }
func (r *fakeRows) RawValues() [][]byte                         { return nil }
func (r *fakeRows) Conn() *pgx.Conn                             { return nil }

type fakeRow struct {
	countVal int
	getVal   *CertSummary
	err      error
}

func (r *fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if r.getVal != nil {
		// Get-row variant: scan all 6 columns.
		if id, ok := dest[0].(*string); ok {
			*id = r.getVal.ID
		}
		if cid, ok := dest[1].(*string); ok {
			*cid = r.getVal.CustomerID
		}
		if ts, ok := dest[2].(*time.Time); ok {
			*ts = r.getVal.CreatedAt
		}
		if v, ok := dest[3].(*string); ok {
			*v = r.getVal.Verdict
		}
		if rc, ok := dest[4].(*int); ok {
			*rc = r.getVal.RedactionCount
		}
		if cc, ok := dest[5].(*int); ok {
			*cc = r.getVal.ClaimCount
		}
		return nil
	}
	// Count-row variant.
	if c, ok := dest[0].(*int); ok {
		*c = r.countVal
	}
	return nil
}

func TestList_NoFilter_PaginatesWithLimitOffset(t *testing.T) {
	t.Parallel()
	db := &fakeDB{
		listRows: []CertSummary{
			{ID: "a", CustomerID: "cust-1", CreatedAt: time.Now(), Verdict: "verified"},
			{ID: "b", CustomerID: "cust-1", CreatedAt: time.Now(), Verdict: "partial"},
		},
		count: 2,
	}
	s := NewCertStoreWithDB(db)
	rows, total, err := s.List(context.Background(), CertFilter{}, Page{Limit: 50, Offset: 0})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if total != 2 {
		t.Errorf("total: got %d want 2", total)
	}
	if len(rows) != 2 {
		t.Errorf("rows: got %d want 2", len(rows))
	}
	// Validate the SQL contains LIMIT + OFFSET bound positionally.
	if len(db.calls) < 1 {
		t.Fatalf("expected at least 1 db call")
	}
	if !strings.Contains(db.calls[0].sql, "LIMIT $1 OFFSET $2") {
		t.Errorf("expected positional LIMIT/OFFSET, got: %s", db.calls[0].sql)
	}
	if db.calls[0].args[0] != 50 {
		t.Errorf("limit arg: got %v want 50", db.calls[0].args[0])
	}
	if db.calls[0].args[1] != 0 {
		t.Errorf("offset arg: got %v want 0", db.calls[0].args[1])
	}
}

func TestList_FilterBuildsPositionalWhereClause(t *testing.T) {
	t.Parallel()
	db := &fakeDB{count: 0}
	s := NewCertStoreWithDB(db)
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 18, 0, 0, 0, 0, time.UTC)
	filter := CertFilter{
		From:         from,
		To:           to,
		Verdicts:     []string{"verified", "partial"},
		CustomerID:   "cust-7",
		RedactionMin: 3,
	}
	_, _, err := s.List(context.Background(), filter, Page{Limit: 50, Offset: 0})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	got := db.calls[0].sql
	// Every filter clause MUST appear with positional bindings.
	for _, want := range []string{
		"AND created_at >= $1",
		"AND created_at < $2",
		"AND verdict IN ($3,$4)",
		"AND customer_id = $5",
		"AND COALESCE(redaction_count,0) >= $6",
		"LIMIT $7 OFFSET $8",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing clause %q in SQL: %s", want, got)
		}
	}
	// Args ordering: from, to, verdict[0], verdict[1], customer, min, limit, offset
	wantArgs := []any{from, to, "verified", "partial", "cust-7", 3, 50, 0}
	if len(db.calls[0].args) != len(wantArgs) {
		t.Fatalf("arg count: got %d want %d", len(db.calls[0].args), len(wantArgs))
	}
	for i, w := range wantArgs {
		if db.calls[0].args[i] != w {
			t.Errorf("arg[%d]: got %v want %v", i, db.calls[0].args[i], w)
		}
	}
}

func TestList_LimitCappedAt200(t *testing.T) {
	t.Parallel()
	db := &fakeDB{count: 0}
	s := NewCertStoreWithDB(db)
	_, _, err := s.List(context.Background(), CertFilter{}, Page{Limit: 9999, Offset: 0})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if db.calls[0].args[0] != 200 {
		t.Errorf("limit cap: got %v want 200", db.calls[0].args[0])
	}
}

func TestList_NegativeOffsetClamped(t *testing.T) {
	t.Parallel()
	db := &fakeDB{count: 0}
	s := NewCertStoreWithDB(db)
	_, _, err := s.List(context.Background(), CertFilter{}, Page{Limit: 50, Offset: -1000})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if db.calls[0].args[1] != 0 {
		t.Errorf("offset clamp: got %v want 0", db.calls[0].args[1])
	}
}

func TestGet_NotFoundReturnsPgxErrNoRows(t *testing.T) {
	t.Parallel()
	db := &fakeDB{getErr: pgx.ErrNoRows}
	s := NewCertStoreWithDB(db)
	_, err := s.Get(context.Background(), "missing")
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows, got %v", err)
	}
}

func TestGet_ReturnsRow(t *testing.T) {
	t.Parallel()
	want := CertSummary{
		ID:             "abc",
		CustomerID:     "cust-1",
		CreatedAt:      time.Date(2026, 5, 18, 0, 0, 0, 0, time.UTC),
		Verdict:        "verified",
		RedactionCount: 5,
		ClaimCount:     6,
	}
	db := &fakeDB{getRow: &want}
	s := NewCertStoreWithDB(db)
	got, err := s.Get(context.Background(), "abc")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got != want {
		t.Errorf("get: got %#v want %#v", got, want)
	}
}

func TestStream_BuildsSelectWithoutLimit(t *testing.T) {
	t.Parallel()
	db := &fakeDB{listRows: []CertSummary{{ID: "a"}}}
	s := NewCertStoreWithDB(db)
	rows, err := s.Stream(context.Background(), CertFilter{Verdicts: []string{"verified"}})
	if err != nil {
		t.Fatalf("stream: %v", err)
	}
	defer rows.Close()
	if strings.Contains(db.calls[0].sql, "LIMIT") {
		t.Errorf("Stream MUST NOT add a LIMIT (CSV export emits all rows): %s", db.calls[0].sql)
	}
	if !strings.Contains(db.calls[0].sql, "AND verdict IN ($1)") {
		t.Errorf("Stream missing verdict filter binding: %s", db.calls[0].sql)
	}
}

// TestVerdictAllowed locks the closed set of verdicts the UI may filter
// on. A regression that adds a new verdict to the surface MUST update
// this map, the renderer, and any banned-literal scans simultaneously.
func TestVerdictAllowed(t *testing.T) {
	t.Parallel()
	want := []string{"verified", "partial", "failed"}
	for _, v := range want {
		if _, ok := VerdictAllowed[v]; !ok {
			t.Errorf("VerdictAllowed missing %q", v)
		}
	}
	if len(VerdictAllowed) != len(want) {
		t.Errorf("VerdictAllowed size: got %d want %d", len(VerdictAllowed), len(want))
	}
}
