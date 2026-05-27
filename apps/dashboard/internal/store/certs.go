// Package store wraps the dashboard's read-only Postgres access to the
// customer's audit/cert database.
//
// Slice 3 reads `veil_certificates` for the cert browser + cert inspector
// surfaces. The customer pre-creates a read-only role with SELECT only on
// veil_certificates (and any future view tables we expose). The dashboard
// never writes, never escalates, and surfaces a "DB unreachable" badge
// rather than crashing if the connection fails.
//
// pgxpool is the connection model — short-lived connections are bad UX
// (Postgres connect cost is non-trivial on every page load); a small
// long-lived pool is the standard pattern. The pool is built once at
// startup; the Querier interface keeps the store testable against a
// pgxmock-driven fake.
package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	witnesspb "github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/witness/pb"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/proto"
)

// CertSummary is one row in the cert-browser list view. Fields are the
// minimum the list page renders; the cert inspector reads the full
// witness verify response via the witness gRPC client and combines
// CertSummary + VerifyResult for the per-cert page.
//
// ID is the operator-facing certificate_id (e.g. "veil_<uuid>"). It is
// the canonical display ID + URL slug. RequestID is the witness's
// lookup key — the dashboard uses it to drive the GetCertificate RPC
// because the upstream witness CertServer at
// dual-sandbox-architecture/services/veil-witness/internal/server/
// cert_server.go:44-53 looks up by request_id (the upstream DB index is
// on request_id, per store.go:88-93). The two columns hold distinct
// values: the assembler at assembler.go:89-92 mints certificate_id
// independently from each claim's request_id.
type CertSummary struct {
	ID             string
	RequestID      string
	CustomerID     string
	CreatedAt      time.Time
	Verdict        string
	RedactionCount int
	ClaimCount     int
}

// CertFilter constrains the cert-browser query. Empty fields = no filter.
// Date range is half-open: rows with created_at >= From and created_at <
// To. RedactionMin is the minimum redaction_count (>=). Verdicts is the
// allowlist; an empty slice = no verdict filter.
type CertFilter struct {
	From         time.Time
	To           time.Time
	Verdicts     []string
	CustomerID   string
	RedactionMin int
}

// Page constrains pagination. Limit defaults to 50; Offset is the row
// offset from the start of the filtered set.
type Page struct {
	Limit  int
	Offset int
}

// Querier is the subset of pgx-shaped methods the cert store needs. The
// production pool implements this directly (via *pgxpool.Pool); tests
// drive a pgxmock-friendly stub.
//
// Exec is REQUIRED for non-returning statements (INSERT / DELETE / UPDATE).
// Using Query for INSERT/DELETE leaks a pgx.Rows that must be Close()d;
// per Slice 6 reviewer-chain B1 the saved-filters Save + Delete paths
// previously discarded the Rows and starved the connection pool after
// ~4 saves. Exec returns a pgconn.CommandTag and never opens a Rows.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// CertStore is the cert browser's data layer.
type CertStore struct {
	db Querier
}

// NewCertStore builds a CertStore backed by a real pgx pool. The pool is
// constructed once at startup; Close on dashboard shutdown.
func NewCertStore(ctx context.Context, connStr string) (*CertStore, *pgxpool.Pool, error) {
	if connStr == "" {
		return nil, nil, errors.New("store: connection string is required")
	}
	cfg, err := pgxpool.ParseConfig(connStr)
	if err != nil {
		return nil, nil, fmt.Errorf("store: parse connection string: %w", err)
	}
	// Bound the pool. The dashboard is single-pod, low-RPS; even on a
	// busy cert-browser session we expect <5 concurrent queries.
	cfg.MaxConns = 8
	cfg.MinConns = 1
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.MaxConnLifetime = 30 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("store: build pool: %w", err)
	}
	return &CertStore{db: pool}, pool, nil
}

// NewCertStoreWithDB wraps a pre-built Querier for tests.
func NewCertStoreWithDB(db Querier) *CertStore {
	return &CertStore{db: db}
}

// List returns the visible page + total count for filter. Caller renders
// pagination using total / page.Limit. Pagination errors surface as
// errors; empty result (no rows match) returns (nil, 0, nil).
//
// SCHEMA NOTE (PR #38 follow-up — 2026-05-27):
// The upstream `veil_certificates` table (per
// migrations/veil-witness/000001_create_veil_certificates.up.sql) exposes:
//
//   certificate_id TEXT PRIMARY KEY
//   request_id     TEXT NOT NULL UNIQUE
//   customer_id    TEXT NOT NULL DEFAULT ''
//   issued_at      TIMESTAMPTZ
//   verdict        TEXT  (proto enum String() form, e.g. "VERDICT_VERIFIED")
//   protocol_version INTEGER
//   certificate_raw  BYTEA  (proto.Marshal of dsa.veil.v1.VeilCertificate)
//   attestation_raw  BYTEA
//   created_at       TIMESTAMPTZ
//   anchor_status    TEXT
//   anchor_attempts  INTEGER
//   anchor_last_error TEXT
//   anchor_human_note TEXT
//
// There is NO `cert_id`, `redaction_count`, or `claim_count` column. The
// earlier dashboard SQL targeted a phantom schema. We now:
//   - SELECT certificate_id (the correct column)
//   - parse certificate_raw with proto.Unmarshal(witnesspb.VeilCertificate)
//     to derive RedactionCount (sum of SanitizerClaim.pii_entities_found
//     across all sanitizer claims) + ClaimCount (len(VeilCertificate.claims))
//   - normalise verdict from "VERDICT_VERIFIED" → "verified" before render
//
// RedactionMin filter is applied POST-parse in Go, after the SQL fetch.
// The COUNT(*) reflects the full filter (including RedactionMin) by
// fetching one wider page when RedactionMin is set; the case-without-
// RedactionMin keeps SQL-side LIMIT/OFFSET for honest pagination.
func (s *CertStore) List(ctx context.Context, filter CertFilter, page Page) ([]CertSummary, int, error) {
	if page.Limit <= 0 {
		page.Limit = 50
	}
	if page.Limit > 200 {
		// Defensive cap; the UI binds limit to 50 but the export path
		// would otherwise be free to OOM on a 1M-row scan via crafted
		// query params.
		page.Limit = 200
	}
	if page.Offset < 0 {
		page.Offset = 0
	}
	// Verdict filter values arrive in UI form ("verified" / "partial" /
	// "failed"). The DB stores the proto enum String() ("VERDICT_VERIFIED"
	// / "VERDICT_PARTIAL" / "VERDICT_FAILED") because veil-witness
	// cmd/server/main.go:272 persists OverallVerdict.String() verbatim.
	// Map UI → DB before the SELECT so the IN-clause matches anything.
	dbFilter := filter
	dbFilter.Verdicts = dbVerdictsFromUI(filter.Verdicts)
	// RedactionMin lives in the proto payload, not as a column, so we
	// strip it from the SQL filter and apply it post-parse.
	hasRedactionFilter := dbFilter.RedactionMin > 0
	dbFilter.RedactionMin = 0
	where, args, _ := buildWhere(dbFilter, 1)

	listSQL := strings.Builder{}
	listSQL.WriteString(`
		SELECT
			certificate_id::text,
			COALESCE(request_id::text, '') AS request_id,
			customer_id::text,
			created_at,
			COALESCE(verdict, '') AS verdict,
			certificate_raw
		FROM veil_certificates
		WHERE 1=1`)
	listSQL.WriteString(where)
	listSQL.WriteString(`
		ORDER BY created_at DESC`)

	// When no RedactionMin filter is active, push LIMIT/OFFSET to SQL —
	// honest pagination + minimal rows hauled across the wire.
	// When RedactionMin IS active, fetch a wider window (capped) and
	// filter+paginate in Go. The COUNT(*) below reflects only the
	// SQL-level WHERE; the Go-side filter then narrows the actual rows
	// list, which (combined with the offset) is the best honest
	// pagination we can offer without a derived column.
	if !hasRedactionFilter {
		fmt.Fprintf(&listSQL, `
		LIMIT $%d OFFSET $%d`, len(args)+1, len(args)+2)
		args = append(args, page.Limit, page.Offset)
	} else {
		// Cap at 2000 rows so a crafted RedactionMin filter cannot OOM
		// the dashboard. In practice customer audit DBs have <1k certs
		// per pilot window; this is purely defensive.
		listSQL.WriteString(`
		LIMIT 2000`)
	}

	rows, err := s.db.Query(ctx, listSQL.String(), args...)
	if err != nil {
		return nil, 0, fmt.Errorf("store: list certs: %w", err)
	}
	defer rows.Close()
	out := make([]CertSummary, 0, page.Limit)
	for rows.Next() {
		cs, scanErr := scanCertRow(rows)
		if scanErr != nil {
			return nil, 0, scanErr
		}
		out = append(out, cs)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("store: iterate certs: %w", err)
	}

	// Total count uses the SAME WHERE clause as the list query so
	// pagination is honest. Re-build args from the start so $N indices
	// don't drift.
	countWhere, countArgs, _ := buildWhere(dbFilter, 1)
	countSQL := "SELECT COUNT(*) FROM veil_certificates WHERE 1=1" + countWhere
	var total int
	if err := s.db.QueryRow(ctx, countSQL, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("store: count certs: %w", err)
	}

	// Apply RedactionMin filter + Go-side pagination when a redaction
	// filter is active. The total count narrows to the post-filter set.
	if hasRedactionFilter {
		filtered := make([]CertSummary, 0, len(out))
		for _, cs := range out {
			if cs.RedactionCount >= filter.RedactionMin {
				filtered = append(filtered, cs)
			}
		}
		total = len(filtered)
		start := page.Offset
		if start > len(filtered) {
			start = len(filtered)
		}
		end := start + page.Limit
		if end > len(filtered) {
			end = len(filtered)
		}
		out = filtered[start:end]
	}
	return out, total, nil
}

// scanCertRow scans a single 6-column SELECT (certificate_id, request_id,
// customer_id, created_at, verdict, certificate_raw) into a CertSummary,
// parsing the proto payload to populate RedactionCount + ClaimCount and
// normalising the verdict from proto-enum form to UI form. Used by both
// List and Stream so the two paths can't drift.
func scanCertRow(rows pgx.Rows) (CertSummary, error) {
	var cs CertSummary
	var rawCert []byte
	if err := rows.Scan(
		&cs.ID,
		&cs.RequestID,
		&cs.CustomerID,
		&cs.CreatedAt,
		&cs.Verdict,
		&rawCert,
	); err != nil {
		return CertSummary{}, fmt.Errorf("store: scan cert: %w", err)
	}
	cs.Verdict = NormaliseVerdict(cs.Verdict)
	if rc, cc, ok := parseClaimCounts(rawCert); ok {
		cs.RedactionCount = rc
		cs.ClaimCount = cc
	}
	return cs, nil
}

// parseClaimCounts unmarshals the protobuf-encoded VeilCertificate payload
// stored in veil_certificates.certificate_raw and returns
// (redaction_count, claim_count, ok).
//
// redaction_count = sum of SanitizerClaim.pii_entities_found across every
// CLAIM_TYPE_PII_SANITIZED claim. claim_count = len(cert.claims).
//
// A malformed or empty payload returns (0, 0, false); callers render
// zero counts rather than failing the row — the cert is still listable
// even if a future protocol bump introduces an unrecognised payload.
func parseClaimCounts(raw []byte) (int, int, bool) {
	if len(raw) == 0 {
		return 0, 0, false
	}
	var cert witnesspb.VeilCertificate
	if err := proto.Unmarshal(raw, &cert); err != nil {
		return 0, 0, false
	}
	claimCount := len(cert.GetClaims())
	redactions := 0
	for _, claim := range cert.GetClaims() {
		if san := claim.GetSanitizer(); san != nil {
			redactions += int(san.GetPiiEntitiesFound())
		}
	}
	return redactions, claimCount, true
}

// NormaliseVerdict converts the proto-enum String() form persisted in
// veil_certificates.verdict ("VERDICT_VERIFIED" / "VERDICT_PARTIAL" /
// "VERDICT_FAILED" / "VERDICT_UNSPECIFIED") to the lowercase UI form
// the renderer + filter checkboxes match on ("verified" / "partial" /
// "failed"). Anything outside the closed set is returned lowercased
// + prefix-stripped so the operator sees the raw verdict instead of
// the dashboard silently dropping it.
func NormaliseVerdict(raw string) string {
	switch raw {
	case "VERDICT_VERIFIED":
		return "verified"
	case "VERDICT_PARTIAL":
		return "partial"
	case "VERDICT_FAILED":
		return "failed"
	case "", "VERDICT_UNSPECIFIED":
		return ""
	}
	// Defensive: strip VERDICT_ prefix + lowercase so any future enum
	// value (e.g. VERDICT_PENDING) renders as "pending" instead of
	// disappearing. Not in the closed UI allowlist; the template's
	// fallback branch will render it as muted text.
	out := strings.TrimPrefix(raw, "VERDICT_")
	return strings.ToLower(out)
}

// dbVerdictsFromUI converts the UI verdict allowlist ("verified" /
// "partial" / "failed") to the proto-enum String() form persisted in
// veil_certificates.verdict ("VERDICT_VERIFIED" / "VERDICT_PARTIAL" /
// "VERDICT_FAILED"). Unknown values are dropped — defence-in-depth
// against a future regression that adds a verdict to the UI without
// updating this mapping (the SQL filter would simply match zero rows).
func dbVerdictsFromUI(uiVerdicts []string) []string {
	if len(uiVerdicts) == 0 {
		return nil
	}
	out := make([]string, 0, len(uiVerdicts))
	for _, v := range uiVerdicts {
		switch v {
		case "verified":
			out = append(out, "VERDICT_VERIFIED")
		case "partial":
			out = append(out, "VERDICT_PARTIAL")
		case "failed":
			out = append(out, "VERDICT_FAILED")
		}
	}
	return out
}

// Stream yields the matching rows for CSV export without paging. The
// caller MUST close the returned rows iterator.
//
// Schema-rewrite note (PR #38 follow-up — 2026-05-27): the historical
// 6-column projection was (cert_id, customer_id, created_at, verdict,
// redaction_count, claim_count) — none of redaction_count / claim_count
// exists. Stream now projects (certificate_id, customer_id, created_at,
// verdict, certificate_raw). The handler scans 5 fields and parses the
// proto payload to derive the redaction_count + claim_count columns the
// CSV emits.
func (s *CertStore) Stream(ctx context.Context, filter CertFilter) (pgx.Rows, error) {
	// Same UI→DB verdict translation + post-parse RedactionMin handling
	// as List(). RedactionMin in CSV mode is honoured but enforced on
	// the streaming consumer side (handlers/certs.go) via the same
	// parseClaimCounts helper — there is no way to push it into SQL.
	dbFilter := filter
	dbFilter.Verdicts = dbVerdictsFromUI(filter.Verdicts)
	dbFilter.RedactionMin = 0 // never push to SQL — no column
	where, args, _ := buildWhere(dbFilter, 1)
	sql := strings.Builder{}
	sql.WriteString(`
		SELECT
			certificate_id::text,
			customer_id::text,
			created_at,
			COALESCE(verdict, '') AS verdict,
			certificate_raw
		FROM veil_certificates
		WHERE 1=1`)
	sql.WriteString(where)
	sql.WriteString(`
		ORDER BY created_at DESC`)
	rows, err := s.db.Query(ctx, sql.String(), args...)
	if err != nil {
		return nil, fmt.Errorf("store: stream certs: %w", err)
	}
	return rows, nil
}

// StreamRow holds the parsed CSV row emitted by the cert export. The
// CSV handler in handlers/certs.go uses this struct to consume the
// Stream rows uniformly (post-parse so redaction_count / claim_count
// reflect the proto payload, not phantom DB columns).
type StreamRow struct {
	CertID         string
	CustomerID     string
	CreatedAt      time.Time
	Verdict        string
	RedactionCount int
	ClaimCount     int
}

// ScanStreamRow consumes one pgx.Rows row produced by Stream() and
// returns a parsed StreamRow with the proto payload turned into derived
// columns. Apply RedactionMin filtering on the returned struct in the
// caller — Stream cannot push it into SQL because the column does not
// exist.
func ScanStreamRow(rows pgx.Rows) (StreamRow, error) {
	var (
		row     StreamRow
		rawCert []byte
		verdict string
	)
	if err := rows.Scan(
		&row.CertID,
		&row.CustomerID,
		&row.CreatedAt,
		&verdict,
		&rawCert,
	); err != nil {
		return StreamRow{}, fmt.Errorf("store: scan stream row: %w", err)
	}
	row.Verdict = NormaliseVerdict(verdict)
	if rc, cc, ok := parseClaimCounts(rawCert); ok {
		row.RedactionCount = rc
		row.ClaimCount = cc
	}
	return row, nil
}

// Get returns the single CertSummary for id, or pgx.ErrNoRows when the id
// is not present. The cert inspector calls this before invoking the
// witness — when the row is absent the inspector renders a 404. The
// returned CertSummary.RequestID is the witness's lookup key the
// inspector / validator / reverify handlers pass to Verifier.Verify.
//
// Schema rewrite (PR #38 follow-up — 2026-05-27): id is the
// veil_certificates.certificate_id text column (NOT a phantom `cert_id`).
// RedactionCount + ClaimCount are derived from parsing
// certificate_raw — see parseClaimCounts.
func (s *CertStore) Get(ctx context.Context, id string) (CertSummary, error) {
	const sql = `
		SELECT
			certificate_id::text,
			COALESCE(request_id::text, '') AS request_id,
			customer_id::text,
			created_at,
			COALESCE(verdict, '') AS verdict,
			certificate_raw
		FROM veil_certificates
		WHERE certificate_id = $1`
	var (
		cs      CertSummary
		rawCert []byte
		verdict string
	)
	row := s.db.QueryRow(ctx, sql, id)
	if err := row.Scan(
		&cs.ID,
		&cs.RequestID,
		&cs.CustomerID,
		&cs.CreatedAt,
		&verdict,
		&rawCert,
	); err != nil {
		return CertSummary{}, err
	}
	cs.Verdict = NormaliseVerdict(verdict)
	if rc, cc, ok := parseClaimCounts(rawCert); ok {
		cs.RedactionCount = rc
		cs.ClaimCount = cc
	}
	return cs, nil
}

// GetRequestIDsByCertIDs returns a cert_id → request_id map for the given
// cert IDs. Used by the bulk re-verify worker so a 100-cert batch resolves
// every operator-facing cert_id to its witness-lookup request_id in ONE
// query (vs N+1 round trips).
//
// IDs not present in the audit DB are simply omitted from the result map;
// callers handle the missing key by recording a per-cert "not found"
// outcome rather than blowing up the whole job.
//
// The pgx ANY($1::text[]) form is the postgres-friendly batch primitive;
// the value goes in as a Go []string and pgx encodes the array literal
// safely.
func (s *CertStore) GetRequestIDsByCertIDs(ctx context.Context, certIDs []string) (map[string]string, error) {
	out := make(map[string]string, len(certIDs))
	if len(certIDs) == 0 {
		return out, nil
	}
	// Defensive cap. The bulk handler already caps at 100; this stops a
	// crafted call deeper in the stack from issuing an unbounded array.
	if len(certIDs) > 1000 {
		certIDs = certIDs[:1000]
	}
	const sql = `
		SELECT
			certificate_id::text,
			COALESCE(request_id::text, '') AS request_id
		FROM veil_certificates
		WHERE certificate_id = ANY($1::text[])`
	rows, err := s.db.Query(ctx, sql, certIDs)
	if err != nil {
		return nil, fmt.Errorf("store: batch request_id lookup: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var certID, requestID string
		if err := rows.Scan(&certID, &requestID); err != nil {
			return nil, fmt.Errorf("store: scan request_id row: %w", err)
		}
		out[certID] = requestID
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate request_id rows: %w", err)
	}
	return out, nil
}

// buildWhere produces a parameterized WHERE-suffix + the slice of args
// already added. startIdx is the first $N to assign; callers append
// pagination params after.
//
// Defense-in-depth: verdicts and customer_id are bound to placeholders
// (no string interpolation); dates are bound likewise. The query is
// read-only by virtue of the read-only Postgres role the customer
// creates per INSTALL.md.
//
// RedactionMin is intentionally NOT pushed into SQL — the underlying
// veil_certificates table has no redaction_count column. The List path
// strips RedactionMin from the CertFilter before calling buildWhere and
// re-applies the filter in Go after parsing the proto payload (see
// CertStore.List + parseClaimCounts).
func buildWhere(filter CertFilter, startIdx int) (string, []any, int) {
	var b strings.Builder
	args := make([]any, 0, 6)
	idx := startIdx
	if !filter.From.IsZero() {
		fmt.Fprintf(&b, " AND created_at >= $%d", idx)
		args = append(args, filter.From)
		idx++
	}
	if !filter.To.IsZero() {
		fmt.Fprintf(&b, " AND created_at < $%d", idx)
		args = append(args, filter.To)
		idx++
	}
	if len(filter.Verdicts) > 0 {
		// Build a positional IN clause: AND verdict IN ($3,$4,...)
		placeholders := make([]string, 0, len(filter.Verdicts))
		for _, v := range filter.Verdicts {
			placeholders = append(placeholders, fmt.Sprintf("$%d", idx))
			args = append(args, v)
			idx++
		}
		b.WriteString(" AND verdict IN (" + strings.Join(placeholders, ",") + ")")
	}
	if filter.CustomerID != "" {
		fmt.Fprintf(&b, " AND customer_id = $%d", idx)
		args = append(args, filter.CustomerID)
		idx++
	}
	// Intentionally no RedactionMin clause — column does not exist on
	// veil_certificates. Caller filters post-parse in Go.
	return b.String(), args, idx
}

// VerdictAllowed is the closed allowlist of verdicts the UI exposes as
// filters. Anything else is dropped before the SQL runs so a crafted
// query param cannot force-load a verdict that never existed.
var VerdictAllowed = map[string]struct{}{
	"verified": {},
	"partial":  {},
	"failed":   {},
}
