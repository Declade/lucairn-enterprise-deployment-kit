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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
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
	From          time.Time
	To            time.Time
	Verdicts      []string
	CustomerID    string
	RedactionMin  int
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
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
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
	where, args, _ := buildWhere(filter, 1)

	listSQL := strings.Builder{}
	listSQL.WriteString(`
		SELECT
			cert_id::text,
			COALESCE(request_id::text, '') AS request_id,
			customer_id::text,
			created_at,
			COALESCE(verdict, '') AS verdict,
			COALESCE(redaction_count, 0) AS redaction_count,
			COALESCE(claim_count, 0) AS claim_count
		FROM veil_certificates
		WHERE 1=1`)
	listSQL.WriteString(where)
	fmt.Fprintf(&listSQL, `
		ORDER BY created_at DESC
		LIMIT $%d OFFSET $%d`, len(args)+1, len(args)+2)
	args = append(args, page.Limit, page.Offset)

	rows, err := s.db.Query(ctx, listSQL.String(), args...)
	if err != nil {
		return nil, 0, fmt.Errorf("store: list certs: %w", err)
	}
	defer rows.Close()
	out := make([]CertSummary, 0, page.Limit)
	for rows.Next() {
		var cs CertSummary
		if err := rows.Scan(
			&cs.ID,
			&cs.RequestID,
			&cs.CustomerID,
			&cs.CreatedAt,
			&cs.Verdict,
			&cs.RedactionCount,
			&cs.ClaimCount,
		); err != nil {
			return nil, 0, fmt.Errorf("store: scan cert: %w", err)
		}
		out = append(out, cs)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("store: iterate certs: %w", err)
	}

	// Total count uses the SAME WHERE clause as the list query so
	// pagination is honest. Re-build args from the start so $N indices
	// don't drift.
	countWhere, countArgs, _ := buildWhere(filter, 1)
	countSQL := "SELECT COUNT(*) FROM veil_certificates WHERE 1=1" + countWhere
	var total int
	if err := s.db.QueryRow(ctx, countSQL, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("store: count certs: %w", err)
	}
	return out, total, nil
}

// Stream is identical to List except it does not cap rows and yields a
// rows.Rows-shaped iterator the CSV writer drains directly. Pagination
// is ignored — Stream is used by the CSV export only, which honours the
// same filter as the browser but emits every matching row. The caller
// MUST close the returned rows iterator.
func (s *CertStore) Stream(ctx context.Context, filter CertFilter) (pgx.Rows, error) {
	where, args, _ := buildWhere(filter, 1)
	sql := strings.Builder{}
	// NOTE: column order intentionally omits request_id — the CSV export
	// surface is operator-facing only (the certificate_id is what auditors
	// quote in tickets). The Stream caller in handlers/certs.go scans 6
	// fields in the same order as the historical SELECT projection; adding
	// request_id to Stream would force a scan-order change in the CSV
	// writer for a column nobody consumes off the export.
	sql.WriteString(`
		SELECT
			cert_id::text,
			customer_id::text,
			created_at,
			COALESCE(verdict, '') AS verdict,
			COALESCE(redaction_count, 0) AS redaction_count,
			COALESCE(claim_count, 0) AS claim_count
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

// Get returns the single CertSummary for id, or pgx.ErrNoRows when the id
// is not present. The cert inspector calls this before invoking the
// witness — when the row is absent the inspector renders a 404. The
// returned CertSummary.RequestID is the witness's lookup key the
// inspector / validator / reverify handlers pass to Verifier.Verify.
func (s *CertStore) Get(ctx context.Context, id string) (CertSummary, error) {
	const sql = `
		SELECT
			cert_id::text,
			COALESCE(request_id::text, '') AS request_id,
			customer_id::text,
			created_at,
			COALESCE(verdict, '') AS verdict,
			COALESCE(redaction_count, 0) AS redaction_count,
			COALESCE(claim_count, 0) AS claim_count
		FROM veil_certificates
		WHERE cert_id = $1`
	var cs CertSummary
	row := s.db.QueryRow(ctx, sql, id)
	if err := row.Scan(
		&cs.ID,
		&cs.RequestID,
		&cs.CustomerID,
		&cs.CreatedAt,
		&cs.Verdict,
		&cs.RedactionCount,
		&cs.ClaimCount,
	); err != nil {
		return CertSummary{}, err
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
			cert_id::text,
			COALESCE(request_id::text, '') AS request_id
		FROM veil_certificates
		WHERE cert_id = ANY($1::text[])`
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
// (no string interpolation); redaction_min / dates are bound likewise.
// The query is read-only by virtue of the read-only Postgres role the
// customer creates per INSTALL.md.
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
	if filter.RedactionMin > 0 {
		fmt.Fprintf(&b, " AND COALESCE(redaction_count,0) >= $%d", idx)
		args = append(args, filter.RedactionMin)
		idx++
	}
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
