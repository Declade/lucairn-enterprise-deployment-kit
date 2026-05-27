package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"google.golang.org/protobuf/proto"
)

// mustMarshalCertWithCounts builds a protobuf-marshaled VeilCertificate
// payload that produces (redactionCount, claimCount) when scanned by
// parseClaimCounts. claimCount = number of claims in the chain; the
// second claim is the sanitizer carrying pii_entities_found=redactionCount.
func mustMarshalCertWithCounts(t *testing.T, redactionCount int, claimCount int) []byte {
	t.Helper()
	cert := &witnesspb.VeilCertificate{}
	for i := 0; i < claimCount; i++ {
		claim := &witnesspb.VeilClaim{}
		if i == 1 { // second claim is the sanitizer (matches assembler order)
			claim.Payload = &witnesspb.VeilClaim_Sanitizer{
				Sanitizer: &witnesspb.SanitizerClaim{
					PiiEntitiesFound: uint32(redactionCount),
				},
			}
		}
		cert.Claims = append(cert.Claims, claim)
	}
	b, err := proto.Marshal(cert)
	if err != nil {
		t.Fatalf("marshal cert fixture: %v", err)
	}
	return b
}

// queryCall records one Query/QueryRow invocation against the fake DB so
// tests can assert the SQL + bind variables match the expected shape.
type queryCall struct {
	sql  string
	args []any
}

// fakeCertRow couples a CertSummary fixture with the protobuf-marshaled
// certificate_raw bytes that the production scan path parses into
// RedactionCount + ClaimCount. Tests that don't care about counts pass
// RawCert: nil — parseClaimCounts returns (0, 0, false) and the
// resulting CertSummary has zero counts but a populated id/verdict/etc.
type fakeCertRow struct {
	Summary CertSummary
	RawCert []byte
}

// fakeDB is a deterministic in-process implementation of Querier. It
// matches the rows-typed contract pgx.Rows imposes without depending on
// a docker-postgres fixture; that lift is reserved for the
// internal/integration test which actually exercises a real Postgres.
type fakeDB struct {
	calls    []queryCall
	listRows []fakeCertRow
	listErr  error
	count    int
	countErr error
	getRow   *fakeCertRow
	getErr   error

	// batchPairs drives GetRequestIDsByCertIDs's 2-column SELECT path.
	batchPairs []certIDRequestIDPair
	batchErr   error

	// execErr lets Slice 6 saved-filter tests inject Exec failures
	// without disturbing the cert store's Query / QueryRow paths.
	execErr error
}

// certIDRequestIDPair holds one row of the batch cert_id → request_id
// resolver result.
type certIDRequestIDPair struct {
	CertID    string
	RequestID string
}

func (f *fakeDB) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	f.calls = append(f.calls, queryCall{sql: sql, args: args})
	if strings.Contains(sql, "ANY($1::text[])") {
		if f.batchErr != nil {
			return nil, f.batchErr
		}
		return &fakeBatchRows{data: f.batchPairs}, nil
	}
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

// Exec satisfies the widened Querier contract introduced in Slice 6
// fix-up r1 B1. Records the call so saved-filter tests can verify no
// rows-leak path was hit, and lets execErr inject failure scenarios.
func (f *fakeDB) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	f.calls = append(f.calls, queryCall{sql: sql, args: args})
	if f.execErr != nil {
		return pgconn.CommandTag{}, f.execErr
	}
	return pgconn.CommandTag{}, nil
}

type fakeRows struct {
	data []fakeCertRow
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
	// Scan order matches the SELECT projection in store.go's List after
	// the PR #38 schema rewrite (2026-05-27): certificate_id, request_id,
	// customer_id, created_at, verdict, certificate_raw — 6 columns.
	// RedactionCount + ClaimCount are derived in the production path by
	// parseClaimCounts(certificate_raw). Tests that want non-zero counts
	// pre-marshal a VeilCertificate fixture into row.RawCert via
	// mustMarshalCertWithCounts.
	if id, ok := dest[0].(*string); ok {
		*id = row.Summary.ID
	}
	if rid, ok := dest[1].(*string); ok {
		*rid = row.Summary.RequestID
	}
	if cid, ok := dest[2].(*string); ok {
		*cid = row.Summary.CustomerID
	}
	if ts, ok := dest[3].(*time.Time); ok {
		*ts = row.Summary.CreatedAt
	}
	if v, ok := dest[4].(*string); ok {
		// The DB stores the proto enum String() form, e.g.
		// "VERDICT_VERIFIED"; the production scan path lowercases it via
		// NormaliseVerdict. We emit raw DB form so the production
		// pipeline exercises that normalisation.
		switch row.Summary.Verdict {
		case "verified":
			*v = "VERDICT_VERIFIED"
		case "partial":
			*v = "VERDICT_PARTIAL"
		case "failed":
			*v = "VERDICT_FAILED"
		default:
			*v = row.Summary.Verdict
		}
	}
	if b, ok := dest[5].(*[]byte); ok {
		*b = row.RawCert
	}
	return nil
}
func (r *fakeRows) Err() error                                   { return r.err }
func (r *fakeRows) Close()                                       {}
func (r *fakeRows) CommandTag() pgconn.CommandTag                { return pgconn.CommandTag{} }
func (r *fakeRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *fakeRows) Values() ([]any, error)                       { return nil, nil }
func (r *fakeRows) RawValues() [][]byte                          { return nil }
func (r *fakeRows) Conn() *pgx.Conn                              { return nil }

// fakeBatchRows implements pgx.Rows for the 2-column cert_id → request_id
// batch SELECT. The shape is distinct from fakeRows because the columns
// + types differ; the batch path never returns full CertSummary rows.
type fakeBatchRows struct {
	data []certIDRequestIDPair
	idx  int
}

func (r *fakeBatchRows) Next() bool {
	return r.idx < len(r.data)
}
func (r *fakeBatchRows) Scan(dest ...any) error {
	if r.idx >= len(r.data) {
		return errors.New("scan past end")
	}
	row := r.data[r.idx]
	r.idx++
	if cid, ok := dest[0].(*string); ok {
		*cid = row.CertID
	}
	if rid, ok := dest[1].(*string); ok {
		*rid = row.RequestID
	}
	return nil
}
func (r *fakeBatchRows) Err() error                                   { return nil }
func (r *fakeBatchRows) Close()                                       {}
func (r *fakeBatchRows) CommandTag() pgconn.CommandTag                { return pgconn.CommandTag{} }
func (r *fakeBatchRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *fakeBatchRows) Values() ([]any, error)                       { return nil, nil }
func (r *fakeBatchRows) RawValues() [][]byte                          { return nil }
func (r *fakeBatchRows) Conn() *pgx.Conn                              { return nil }

type fakeRow struct {
	countVal int
	getVal   *fakeCertRow
	err      error
}

func (r *fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if r.getVal != nil {
		// Get-row variant: 6-column scan matching the PR #38 schema
		// rewrite — certificate_id, request_id, customer_id, created_at,
		// verdict (proto-enum form), certificate_raw.
		if id, ok := dest[0].(*string); ok {
			*id = r.getVal.Summary.ID
		}
		if rid, ok := dest[1].(*string); ok {
			*rid = r.getVal.Summary.RequestID
		}
		if cid, ok := dest[2].(*string); ok {
			*cid = r.getVal.Summary.CustomerID
		}
		if ts, ok := dest[3].(*time.Time); ok {
			*ts = r.getVal.Summary.CreatedAt
		}
		if v, ok := dest[4].(*string); ok {
			switch r.getVal.Summary.Verdict {
			case "verified":
				*v = "VERDICT_VERIFIED"
			case "partial":
				*v = "VERDICT_PARTIAL"
			case "failed":
				*v = "VERDICT_FAILED"
			default:
				*v = r.getVal.Summary.Verdict
			}
		}
		if b, ok := dest[5].(*[]byte); ok {
			*b = r.getVal.RawCert
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
		listRows: []fakeCertRow{
			{Summary: CertSummary{ID: "a", CustomerID: "cust-1", CreatedAt: time.Now(), Verdict: "verified"}},
			{Summary: CertSummary{ID: "b", CustomerID: "cust-1", CreatedAt: time.Now(), Verdict: "partial"}},
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
	// Schema invariant: SELECT must target certificate_id (no phantom
	// cert_id column on veil_certificates) and read certificate_raw so
	// the production scan path can derive RedactionCount + ClaimCount.
	if !strings.Contains(db.calls[0].sql, "certificate_id::text") {
		t.Errorf("List SQL must SELECT certificate_id::text, got: %s", db.calls[0].sql)
	}
	if !strings.Contains(db.calls[0].sql, "certificate_raw") {
		t.Errorf("List SQL must SELECT certificate_raw (proto payload), got: %s", db.calls[0].sql)
	}
}

func TestList_FilterBuildsPositionalWhereClause(t *testing.T) {
	t.Parallel()
	// Schema-rewrite contract (PR #38 follow-up — 2026-05-27):
	//   - Verdicts arrive in UI form ("verified" / "partial" / "failed")
	//     and are translated to the proto-enum form ("VERDICT_VERIFIED"
	//     / "VERDICT_PARTIAL" / "VERDICT_FAILED") that the DB stores
	//     before binding.
	//   - RedactionMin is NOT pushed into SQL — veil_certificates has no
	//     redaction_count column. The List path strips RedactionMin from
	//     the SQL filter and applies it post-parse in Go. When
	//     RedactionMin is set, SQL emits a defensive LIMIT 2000 (no
	//     OFFSET) and Go does the Limit/Offset slice after filtering.
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
	// SQL surface: every column-backed filter clause appears with positional
	// bindings. RedactionMin does NOT appear (no column).
	for _, want := range []string{
		"AND created_at >= $1",
		"AND created_at < $2",
		"AND verdict IN ($3,$4)",
		"AND customer_id = $5",
		"LIMIT 2000",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing clause %q in SQL: %s", want, got)
		}
	}
	if strings.Contains(got, "redaction_count") {
		t.Errorf("RedactionMin MUST NOT appear in SQL (no DB column); got: %s", got)
	}
	if strings.Contains(got, "OFFSET") {
		t.Errorf("RedactionMin filter path must skip SQL OFFSET (Go-side pagination); got: %s", got)
	}
	if strings.Contains(got, "cert_id::text") {
		t.Errorf("List SQL must use certificate_id (no phantom cert_id column); got: %s", got)
	}
	// Args ordering: from, to, verdict[0] (proto form), verdict[1], customer
	wantArgs := []any{from, to, "VERDICT_VERIFIED", "VERDICT_PARTIAL", "cust-7"}
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
	summary := CertSummary{
		ID:         "veil_0190d3a1-aaaa-bbbb-cccc-ddddeeeeffff",
		RequestID:  "req_aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000",
		CustomerID: "cust-1",
		CreatedAt:  time.Date(2026, 5, 18, 0, 0, 0, 0, time.UTC),
		Verdict:    "verified",
	}
	rawCert := mustMarshalCertWithCounts(t, 5, 6)
	// CertSummary returned from Get inherits the proto-derived counts
	// after parseClaimCounts.
	want := summary
	want.RedactionCount = 5
	want.ClaimCount = 6
	db := &fakeDB{getRow: &fakeCertRow{Summary: summary, RawCert: rawCert}}
	s := NewCertStoreWithDB(db)
	got, err := s.Get(context.Background(), summary.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got != want {
		t.Errorf("get: got %#v want %#v", got, want)
	}
	// Verify the SELECT pulls request_id so callers can drive the witness
	// RPC (whose lookup key is request_id, not certificate_id).
	if !strings.Contains(db.calls[0].sql, "request_id") {
		t.Errorf("Get SQL must SELECT request_id (witness lookup key): %s", db.calls[0].sql)
	}
	// Schema invariant: WHERE clause keys off certificate_id, not the
	// phantom cert_id column.
	if !strings.Contains(db.calls[0].sql, "WHERE certificate_id = $1") {
		t.Errorf("Get SQL must use WHERE certificate_id = $1, got: %s", db.calls[0].sql)
	}
}

func TestStream_BuildsSelectWithoutLimit(t *testing.T) {
	t.Parallel()
	db := &fakeDB{listRows: []fakeCertRow{{Summary: CertSummary{ID: "a"}}}}
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
	// UI verdict "verified" must be translated to the proto-enum form
	// before binding (DB stores VERDICT_VERIFIED).
	if len(db.calls[0].args) < 1 || db.calls[0].args[0] != "VERDICT_VERIFIED" {
		t.Errorf("Stream verdict binding: got %v want VERDICT_VERIFIED", db.calls[0].args)
	}
	// Schema invariant: Stream SELECT targets certificate_id +
	// certificate_raw (not phantom cert_id / redaction_count /
	// claim_count columns).
	if !strings.Contains(db.calls[0].sql, "certificate_id::text") {
		t.Errorf("Stream SQL must SELECT certificate_id::text, got: %s", db.calls[0].sql)
	}
	if !strings.Contains(db.calls[0].sql, "certificate_raw") {
		t.Errorf("Stream SQL must SELECT certificate_raw, got: %s", db.calls[0].sql)
	}
}

// TestGetRequestIDsByCertIDs_ReturnsMap locks the batch cert_id →
// request_id resolver used by the bulk re-verify worker. The witness
// RPC keys off request_id (upstream cert_server.go:44-53), not the
// operator-facing certificate_id, so the bulk worker MUST resolve the
// IDs server-side before driving Verify.
func TestGetRequestIDsByCertIDs_ReturnsMap(t *testing.T) {
	t.Parallel()
	db := &fakeDB{batchPairs: []certIDRequestIDPair{
		{CertID: "veil_aaaaaaaa-1111-2222-3333-444444444444", RequestID: "req_aaaa-1111"},
		{CertID: "veil_bbbbbbbb-1111-2222-3333-444444444444", RequestID: "req_bbbb-2222"},
	}}
	s := NewCertStoreWithDB(db)
	got, err := s.GetRequestIDsByCertIDs(context.Background(), []string{
		"veil_aaaaaaaa-1111-2222-3333-444444444444",
		"veil_bbbbbbbb-1111-2222-3333-444444444444",
		"veil_cccccccc-missing-row-9999-444444444444",
	})
	if err != nil {
		t.Fatalf("batch lookup: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("map size: got %d want 2 (missing row should be omitted, not error)", len(got))
	}
	if got["veil_aaaaaaaa-1111-2222-3333-444444444444"] != "req_aaaa-1111" {
		t.Errorf("aaa pair: got %q want req_aaaa-1111", got["veil_aaaaaaaa-1111-2222-3333-444444444444"])
	}
	if got["veil_bbbbbbbb-1111-2222-3333-444444444444"] != "req_bbbb-2222" {
		t.Errorf("bbb pair: got %q want req_bbbb-2222", got["veil_bbbbbbbb-1111-2222-3333-444444444444"])
	}
	// SQL surface lock: the batch path MUST bind through ANY($1::text[]),
	// the postgres-safe array form. A regression that string-joins the
	// IDs into the SQL would open a SQL-injection vector even with the
	// validCertID gate (the customer's DB role is read-only but the SQL
	// shape is still load-bearing for review hygiene).
	if !strings.Contains(db.calls[0].sql, "ANY($1::text[])") {
		t.Errorf("batch SQL must use ANY($1::text[]); got: %s", db.calls[0].sql)
	}
}

// TestGetRequestIDsByCertIDs_EmptyInputSkipsQuery is the defensive
// guard that prevents an unbounded ANY(empty array) call from hitting
// the DB.
func TestGetRequestIDsByCertIDs_EmptyInputSkipsQuery(t *testing.T) {
	t.Parallel()
	db := &fakeDB{}
	s := NewCertStoreWithDB(db)
	got, err := s.GetRequestIDsByCertIDs(context.Background(), nil)
	if err != nil {
		t.Fatalf("empty: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("empty result: got %d want 0", len(got))
	}
	if len(db.calls) != 0 {
		t.Errorf("DB must not be queried with no input; got %d call(s)", len(db.calls))
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
