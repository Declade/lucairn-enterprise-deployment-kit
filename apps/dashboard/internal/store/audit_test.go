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

// fakeAuditDB is the pgx-shaped fake for audit-store tests. It records
// every Query / QueryRow with the SQL + args so assertions on SQL
// shape + arg values are straightforward.
type fakeAuditDB struct {
	calls         []queryCall
	listRows      []AuditEvent
	listErr       error
	count         int
	countErr      error
	getRow        *AuditEvent
	getErr        error
	distinctRows  []string
	distinctErr   error
	distinctSleep time.Duration // delay singleflight callbacks in tests
}

func (f *fakeAuditDB) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	f.calls = append(f.calls, queryCall{sql: sql, args: args})
	if strings.Contains(sql, "SELECT DISTINCT") {
		if f.distinctSleep > 0 {
			select {
			case <-time.After(f.distinctSleep):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		if f.distinctErr != nil {
			return nil, f.distinctErr
		}
		return &fakeDistinctRows{data: f.distinctRows}, nil
	}
	if f.listErr != nil {
		return nil, f.listErr
	}
	return &fakeAuditRows{data: f.listRows}, nil
}

func (f *fakeAuditDB) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	f.calls = append(f.calls, queryCall{sql: sql, args: args})
	if strings.Contains(strings.ToUpper(sql), "COUNT(") {
		return &fakeAuditRow{countVal: f.count, err: f.countErr}
	}
	return &fakeAuditRow{getEv: f.getRow, err: f.getErr}
}

// fakeAuditRows iterates a slice of AuditEvent values.
type fakeAuditRows struct {
	data []AuditEvent
	idx  int
	err  error
}

func (r *fakeAuditRows) Next() bool {
	if r.err != nil || r.idx >= len(r.data) {
		return false
	}
	return true
}

func (r *fakeAuditRows) Scan(dest ...any) error {
	if r.idx >= len(r.data) {
		return errors.New("scan past end")
	}
	row := r.data[r.idx]
	r.idx++
	if len(dest) < 11 {
		return errors.New("audit rows scan expects 11 fields")
	}
	*(dest[0].(*int64)) = row.ID
	*(dest[1].(*string)) = row.EventID
	*(dest[2].(*string)) = row.EventType
	*(dest[3].(*string)) = row.SourceService
	*(dest[4].(*string)) = row.Actor
	*(dest[5].(*time.Time)) = row.Timestamp
	*(dest[6].(*string)) = row.PreviousEventHash
	*(dest[7].(*string)) = row.EventHash
	*(dest[8].(*[]byte)) = append([]byte(nil), row.Payload...)
	*(dest[9].(*string)) = row.RequestID
	*(dest[10].(*string)) = row.PayloadType
	return nil
}

func (r *fakeAuditRows) Close()                                       {}
func (r *fakeAuditRows) Err() error                                   { return r.err }
func (r *fakeAuditRows) CommandTag() pgconn.CommandTag                { return pgconn.CommandTag{} }
func (r *fakeAuditRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *fakeAuditRows) Values() ([]any, error)                       { return nil, nil }
func (r *fakeAuditRows) RawValues() [][]byte                          { return nil }
func (r *fakeAuditRows) Conn() *pgx.Conn                              { return nil }

// fakeAuditRow yields a single audit event OR a COUNT.
type fakeAuditRow struct {
	getEv    *AuditEvent
	countVal int
	err      error
}

func (r *fakeAuditRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if len(dest) == 1 {
		if p, ok := dest[0].(*int); ok {
			*p = r.countVal
			return nil
		}
	}
	if r.getEv == nil {
		return pgx.ErrNoRows
	}
	if len(dest) < 11 {
		return errors.New("audit row scan expects 11 fields")
	}
	*(dest[0].(*int64)) = r.getEv.ID
	*(dest[1].(*string)) = r.getEv.EventID
	*(dest[2].(*string)) = r.getEv.EventType
	*(dest[3].(*string)) = r.getEv.SourceService
	*(dest[4].(*string)) = r.getEv.Actor
	*(dest[5].(*time.Time)) = r.getEv.Timestamp
	*(dest[6].(*string)) = r.getEv.PreviousEventHash
	*(dest[7].(*string)) = r.getEv.EventHash
	*(dest[8].(*[]byte)) = append([]byte(nil), r.getEv.Payload...)
	*(dest[9].(*string)) = r.getEv.RequestID
	*(dest[10].(*string)) = r.getEv.PayloadType
	return nil
}

// fakeDistinctRows yields strings (event_type / source_service).
type fakeDistinctRows struct {
	data []string
	idx  int
}

func (r *fakeDistinctRows) Next() bool {
	return r.idx < len(r.data)
}
func (r *fakeDistinctRows) Scan(dest ...any) error {
	if r.idx >= len(r.data) {
		return errors.New("scan past end")
	}
	*(dest[0].(*string)) = r.data[r.idx]
	r.idx++
	return nil
}
func (r *fakeDistinctRows) Close()                                       {}
func (r *fakeDistinctRows) Err() error                                   { return nil }
func (r *fakeDistinctRows) CommandTag() pgconn.CommandTag                { return pgconn.CommandTag{} }
func (r *fakeDistinctRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *fakeDistinctRows) Values() ([]any, error)                       { return nil, nil }
func (r *fakeDistinctRows) RawValues() [][]byte                          { return nil }
func (r *fakeDistinctRows) Conn() *pgx.Conn                              { return nil }

// fixtureEvent builds an AuditEvent with deterministic field values.
func fixtureEvent(id int64, et, svc, actor string, payload string) AuditEvent {
	return AuditEvent{
		ID:                id,
		EventID:           "ev-" + et,
		EventType:         et,
		SourceService:     svc,
		Actor:             actor,
		Timestamp:         time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC),
		PreviousEventHash: "",
		EventHash:         "hash-" + et,
		Payload:           []byte(payload),
		RequestID:         "req-" + et,
		PayloadType:       "FLAT_JSON",
	}
}

// === Tests ===

func TestAuditFilter_SQLBuilder_NoInterpolation(t *testing.T) {
	// Any user-supplied string MUST be parameterized, never substituted
	// into the SQL text. The test asserts that every filter value is
	// absent from the generated SQL string and present in the args
	// slice instead.
	in := AuditFilter{
		EventTypes:      []string{"key.mint_requested", "cert.verify_requested"},
		SourceServices:  []string{"dsa-gateway"},
		Actors:          []string{"alice@example.com"},
		RequestID:       "req-special-99",
		TimestampFrom:   ptrTime(time.Now()),
		TimestampTo:     ptrTime(time.Now()),
		PayloadContains: "alice%admin",
		Page:            1,
		PageSize:        50,
	}
	where, args := buildAuditWhere(in, 1)
	if strings.Contains(where, "alice@example.com") {
		t.Fatalf("user input interpolated into SQL: %q", where)
	}
	if strings.Contains(where, "req-special-99") {
		t.Fatalf("user input interpolated into SQL: %q", where)
	}
	if strings.Contains(where, "alice%admin") {
		t.Fatalf("user input interpolated into SQL: %q", where)
	}
	// Args slice must hold the escaped form of the user's payload
	// substring. The escape function turns "alice%admin" into
	// "alice\%admin" so the LIKE wildcard is treated as a literal.
	found := false
	for _, a := range args {
		if s, ok := a.(string); ok && strings.Contains(s, `alice\%admin`) {
			found = true
		}
	}
	if !found {
		t.Fatalf("escaped payload search literal not in args slice: %#v", args)
	}
	// Generated SQL must contain $N placeholders.
	for i := 1; i <= 5; i++ {
		if !strings.Contains(where, "$"+itoaTest(i)) {
			t.Fatalf("placeholder $%d missing from SQL: %q", i, where)
		}
	}
}

func TestAuditFilter_PaginatedQuery_LimitOffset(t *testing.T) {
	// 100 events; PageSize=50; Page=1 returns first 50, Page=2 returns
	// next 50 (offset 50). The fake echoes whichever slice we hand it
	// so we assert on the LIMIT/OFFSET arg values.
	all := make([]AuditEvent, 100)
	for i := range all {
		all[i] = fixtureEvent(int64(i+1), "key.mint_requested", "dsa-gateway", "alice@example.com", `{"key":"v"}`)
	}
	fake := &fakeAuditDB{listRows: all[0:50], count: 100}
	s := NewAuditStoreWithDB(fake)

	events, total, err := s.ListEvents(context.Background(), AuditFilter{Page: 1, PageSize: 50})
	if err != nil {
		t.Fatalf("ListEvents err: %v", err)
	}
	if len(events) != 50 {
		t.Fatalf("page 1 size: got %d want 50", len(events))
	}
	if total != 100 {
		t.Fatalf("total: got %d want 100", total)
	}
	// Page 2 — offset 50.
	fake.calls = nil
	fake.listRows = all[50:100]
	events, _, err = s.ListEvents(context.Background(), AuditFilter{Page: 2, PageSize: 50})
	if err != nil {
		t.Fatalf("ListEvents err: %v", err)
	}
	if len(events) != 50 {
		t.Fatalf("page 2 size: got %d want 50", len(events))
	}
	// Verify the LIMIT 50 + OFFSET 50 args were sent.
	var limit, offset int
	for _, c := range fake.calls {
		if strings.Contains(c.sql, "LIMIT") {
			limit, _ = c.args[len(c.args)-2].(int)
			offset, _ = c.args[len(c.args)-1].(int)
		}
	}
	if limit != 50 || offset != 50 {
		t.Fatalf("page 2 LIMIT/OFFSET: limit=%d offset=%d want 50/50", limit, offset)
	}
}

func TestAuditFilter_DateRange(t *testing.T) {
	from := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 5, 21, 0, 0, 0, 0, time.UTC)
	in := AuditFilter{TimestampFrom: &from, TimestampTo: &to}
	where, args := buildAuditWhere(in, 1)
	if !strings.Contains(where, "timestamp >= $1") {
		t.Fatalf("from clause missing: %q", where)
	}
	if !strings.Contains(where, "timestamp < $2") {
		t.Fatalf("to clause missing: %q", where)
	}
	if got := args[0].(time.Time); !got.Equal(from) {
		t.Fatalf("from arg mismatch: got %v want %v", got, from)
	}
	if got := args[1].(time.Time); !got.Equal(to) {
		t.Fatalf("to arg mismatch: got %v want %v", got, to)
	}
}

func TestAuditFilter_MultiEventType(t *testing.T) {
	in := AuditFilter{EventTypes: []string{"key.mint_requested", "cert.verify_requested"}}
	where, args := buildAuditWhere(in, 1)
	if !strings.Contains(where, "event_type = ANY($1::text[])") {
		t.Fatalf("multi-eventtype clause missing: %q", where)
	}
	got, ok := args[0].([]string)
	if !ok {
		t.Fatalf("args[0] type: %T want []string", args[0])
	}
	if len(got) != 2 || got[0] != "key.mint_requested" || got[1] != "cert.verify_requested" {
		t.Fatalf("event_types arg: %v", got)
	}
}

func TestAuditFilter_PageSizeCappedAt200(t *testing.T) {
	fake := &fakeAuditDB{count: 0}
	s := NewAuditStoreWithDB(fake)
	_, _, err := s.ListEvents(context.Background(), AuditFilter{Page: 1, PageSize: 10000})
	if err != nil {
		t.Fatalf("ListEvents err: %v", err)
	}
	// Verify the LIMIT arg is 200 not 10000.
	var limit int
	for _, c := range fake.calls {
		if strings.Contains(c.sql, "LIMIT") {
			limit = c.args[len(c.args)-2].(int)
		}
	}
	if limit != 200 {
		t.Fatalf("PageSize cap: limit=%d want 200", limit)
	}
}

func TestAuditFilter_PageBelowOneNormalizesToOne(t *testing.T) {
	fake := &fakeAuditDB{count: 0}
	s := NewAuditStoreWithDB(fake)
	_, _, err := s.ListEvents(context.Background(), AuditFilter{Page: 0, PageSize: 50})
	if err != nil {
		t.Fatalf("ListEvents err: %v", err)
	}
	var offset int
	for _, c := range fake.calls {
		if strings.Contains(c.sql, "LIMIT") {
			offset = c.args[len(c.args)-1].(int)
		}
	}
	if offset != 0 {
		t.Fatalf("Page=0 normalised offset: got %d want 0", offset)
	}
}

func TestAuditFilter_PayloadContainsEscapesLikePattern(t *testing.T) {
	// '%' from the user MUST be escaped so it does not become a SQL
	// LIKE wildcard.
	in := AuditFilter{PayloadContains: "100% safe"}
	where, args := buildAuditWhere(in, 1)
	if !strings.Contains(where, "payload::text LIKE $1 ESCAPE '\\'") {
		t.Fatalf("LIKE+ESCAPE clause missing: %q", where)
	}
	got := args[0].(string)
	if !strings.Contains(got, `\%`) {
		t.Fatalf("`%%` not escaped in LIKE arg: %q", got)
	}
}

func TestAuditFilter_NoPlaceholderURLAccepted(t *testing.T) {
	cases := []string{
		"postgres://CHANGE_ME:secret@host:5432/audit",
		"postgresql://user:Change_Me@host:5432/audit",
		"postgres://YOUR-USER:pw@host:5432/audit?sslmode=disable",
		"postgres://placeholder:pw@host:5432/audit",
		"postgres://user:replace_me@host:5432/audit",
	}
	for _, c := range cases {
		_, _, err := NewAuditStore(context.Background(), c)
		if !errors.Is(err, ErrPlaceholderURL) {
			t.Fatalf("placeholder URL %q accepted; got err=%v", c, err)
		}
	}
}

func TestAuditFilter_NewAuditStoreRejectsNonPostgresScheme(t *testing.T) {
	_, _, err := NewAuditStore(context.Background(), "mysql://user:pw@host:3306/audit")
	if err == nil || !strings.Contains(err.Error(), "scheme must be postgres") {
		t.Fatalf("non-postgres scheme accepted; err=%v", err)
	}
}

func TestAuditFilter_NewAuditStoreRejectsEmpty(t *testing.T) {
	_, _, err := NewAuditStore(context.Background(), "")
	if err == nil {
		t.Fatal("empty URL accepted")
	}
}

func TestDistinctEventTypes_CachedAfterFirstCall(t *testing.T) {
	fake := &fakeAuditDB{distinctRows: []string{"cert.verify_requested", "key.mint_requested"}}
	s := NewAuditStoreWithDB(fake)
	s.cfg.DistinctTTL = 5 * time.Minute
	s.clock = func() time.Time { return time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC) }

	v1, err := s.DistinctEventTypes(context.Background())
	if err != nil {
		t.Fatalf("first call err: %v", err)
	}
	if len(v1) != 2 {
		t.Fatalf("first call returned %d types", len(v1))
	}
	calls1 := len(fake.calls)
	v2, err := s.DistinctEventTypes(context.Background())
	if err != nil {
		t.Fatalf("second call err: %v", err)
	}
	if len(v2) != 2 {
		t.Fatalf("second call returned %d types", len(v2))
	}
	calls2 := len(fake.calls)
	if calls2 != calls1 {
		t.Fatalf("cache miss on second call: calls1=%d calls2=%d", calls1, calls2)
	}
}

func TestDistinctSourceServices_BasicCachedFetch(t *testing.T) {
	fake := &fakeAuditDB{distinctRows: []string{"dsa-audit", "dsa-gateway"}}
	s := NewAuditStoreWithDB(fake)
	got, err := s.DistinctSourceServices(context.Background())
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != 2 || got[0] != "dsa-audit" || got[1] != "dsa-gateway" {
		t.Fatalf("got %v", got)
	}
}

func TestGetEvent_NotFoundReturnsPGXErrNoRows(t *testing.T) {
	fake := &fakeAuditDB{getRow: nil}
	s := NewAuditStoreWithDB(fake)
	_, err := s.GetEvent(context.Background(), "ev-missing")
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows; got %v", err)
	}
}

func TestGetEvent_RequiresNonEmptyEventID(t *testing.T) {
	s := NewAuditStoreWithDB(&fakeAuditDB{})
	_, err := s.GetEvent(context.Background(), "")
	if err == nil || !strings.Contains(err.Error(), "event_id required") {
		t.Fatalf("empty event_id error: got %v", err)
	}
}

func TestListEvents_RoundTripScansAllFields(t *testing.T) {
	src := fixtureEvent(7, "key.mint_requested", "dsa-gateway", "alice@example.com", `{"x":1}`)
	fake := &fakeAuditDB{listRows: []AuditEvent{src}, count: 1}
	s := NewAuditStoreWithDB(fake)
	events, total, err := s.ListEvents(context.Background(), AuditFilter{Page: 1, PageSize: 10})
	if err != nil {
		t.Fatalf("ListEvents err: %v", err)
	}
	if total != 1 || len(events) != 1 {
		t.Fatalf("got %d events total=%d", len(events), total)
	}
	got := events[0]
	if got.ID != src.ID || got.EventID != src.EventID || got.EventType != src.EventType {
		t.Fatalf("scan mismatch: %+v vs %+v", got, src)
	}
	if string(got.Payload) != string(src.Payload) {
		t.Fatalf("payload mismatch: %s vs %s", got.Payload, src.Payload)
	}
}

func ptrTime(t time.Time) *time.Time { return &t }
func itoaTest(n int) string {
	return strings.TrimSpace(strings.ReplaceAll(timeFmt(n), " ", ""))
}

// timeFmt converts a small int to its decimal string in test code
// without dragging strconv into the imports list (the tests file
// already pulls strings, errors, context, testing, time).
func timeFmt(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	if neg {
		return "-" + string(digits)
	}
	return string(digits)
}
