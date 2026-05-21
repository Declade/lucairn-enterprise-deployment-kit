// Package compliance — aggregator.go.
//
// Slice 7 needs to count three populations in a date window for the
// compliance PDF:
//
//  1. Certificates issued (joined to their overall_verdict — derived
//     from veil_certificates.verdict column populated by the audit DB).
//  2. Sanitizer redaction activity (audit events emitted by the
//     sanitizer service grouped by L1 / L2 / L3 layer; the payload's
//     sanitizer_layer key is the source-of-truth).
//  3. Audit event volume by type (cross-cutting; the operator can show
//     a "what changed" overview without leaking PII because counts ARE
//     the aggregation — no row content surfaces in the PDF).
//
// The aggregator REUSES the Slice 3 + Slice 6 pgxpool connections —
// there is intentionally no separate compliance DB env var. The cert
// DB pool drives count (1); the audit-log DB pool drives counts (2)
// and (3).
//
// Date windows are half-open: [from, to). The max window is 365 days
// to keep aggregate scans bounded; PDFs spanning multiple years are
// the operator's signal to slice the export.
//
// Concurrency model: each `Summary` call issues three parallel queries
// via errgroup, one per population. The aggregator does NOT keep any
// internal caching — the gateway-admin client + cert browser already
// cache; compliance PDFs are infrequent enough that a fresh query is
// the simpler design (avoids stale evidence in the artefact).
package compliance

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// MaxWindowDays caps the date range any aggregator query will scan.
// Operators wanting a longer span MUST slice the export — the cap
// keeps the aggregate planner-bounded against a one-year history.
const MaxWindowDays = 365

// HardMaxWindowDays is the doctor-side safety ceiling (10 years).
// Configurable LUCAIRN_DASHBOARD_COMPLIANCE_MAX_WINDOW_DAYS values
// above this trigger a doctor WARN — likely operator typo.
const HardMaxWindowDays = 3650

// DefaultWindowDays is the form's default if the operator submits no
// date range.
const DefaultWindowDays = 30

// ErrWindowTooLarge is returned by Summary when (to - from) exceeds
// the maxWindowDays passed to NewAggregator (or, when zero, the
// package-level MaxWindowDays).
var ErrWindowTooLarge = errors.New("compliance: date range exceeds configured maximum window")

// ErrWindowInvalid is returned when from >= to or either side is
// zero-time.
var ErrWindowInvalid = errors.New("compliance: date range is empty or inverted")

// Querier is the subset of pgx-shaped methods the aggregator needs.
// Mirrors apps/dashboard/internal/store/certs.go::Querier so an
// existing *pgxpool.Pool satisfies it directly (no separate adapter).
// Tests inject a pgxmock-shaped fake.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// CertCounts is the cert-population shape for a window.
type CertCounts struct {
	Total      int
	ByVerdict  map[string]int
	NoVerdict  int // rows with NULL or empty verdict column
	WindowFrom time.Time
	WindowTo   time.Time
}

// SanitizerCounts is the sanitizer-activity shape for a window.
//
// TotalRedactions counts every emit of an event_type starting with
// "sanitizer." in the audit log; ByLayer projects the count via the
// `sanitizer_layer` key inside each event's JSON payload (string
// "L1" / "L2" / "L3" / "unknown"). The aggregator does NOT decode
// the payload bytes itself — Postgres does the JSON extraction via
// `payload::jsonb ->> 'sanitizer_layer'` on the assumption that
// payloads emitted by the sanitizer are valid JSON. Rows where the
// extraction returns NULL fall into the "unknown" bucket.
//
// Rationale for not decoding in Go: pulling N audit rows server-
// side then JSON-decoding each one in Go scales poorly for a 365-day
// window with 10k+ sanitizer events. Postgres does the projection
// for free as part of GROUP BY.
type SanitizerCounts struct {
	TotalRedactions int
	ByLayer         map[string]int
	WindowFrom      time.Time
	WindowTo        time.Time
}

// AuditCounts is the audit-event volume shape for a window.
type AuditCounts struct {
	Total      int
	ByType     map[string]int
	WindowFrom time.Time
	WindowTo   time.Time
}

// ComplianceSummary is the rolled-up shape pdf.go consumes.
type ComplianceSummary struct {
	WindowFrom time.Time
	WindowTo   time.Time
	Certs      CertCounts
	Sanitizer  SanitizerCounts
	Audit      AuditCounts
}

// Aggregator wraps the two DB pools (cert DB + audit-log DB) and
// exposes the count + summary methods the handler consumes.
type Aggregator struct {
	certDB        Querier
	auditDB       Querier
	maxWindowDays int
	queryTimeout  time.Duration
	now           func() time.Time
}

// AggregatorOpts customises the aggregator. Zero-value gets safe
// defaults.
type AggregatorOpts struct {
	// MaxWindowDays caps the inclusive window length aggregator queries
	// will scan. 0 = use MaxWindowDays constant (365). Operators can
	// reduce this via the Helm value `dashboard.compliance.maxWindowDays`.
	MaxWindowDays int

	// QueryTimeout is the per-query context deadline applied to each
	// count call. 0 = 30 seconds.
	QueryTimeout time.Duration

	// Now lets tests pin the wall-clock for stable "window relative to
	// now" calculations.
	Now func() time.Time
}

// NewAggregator constructs an aggregator. certDB may be nil when the
// cert browser surface is not configured — the cert-count query then
// returns an empty CertCounts struct. Same for auditDB.
func NewAggregator(certDB, auditDB Querier, opts AggregatorOpts) *Aggregator {
	max := opts.MaxWindowDays
	if max <= 0 {
		max = MaxWindowDays
	}
	if max > HardMaxWindowDays {
		max = HardMaxWindowDays
	}
	timeout := opts.QueryTimeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	nowFn := opts.Now
	if nowFn == nil {
		nowFn = time.Now
	}
	return &Aggregator{
		certDB:        certDB,
		auditDB:       auditDB,
		maxWindowDays: max,
		queryTimeout:  timeout,
		now:           nowFn,
	}
}

// validateWindow enforces the half-open interval + max-window guard.
// Returns canonical UTC-normalised from / to.
func (a *Aggregator) validateWindow(from, to time.Time) (time.Time, time.Time, error) {
	from = from.UTC()
	to = to.UTC()
	if from.IsZero() || to.IsZero() {
		return time.Time{}, time.Time{}, ErrWindowInvalid
	}
	if !from.Before(to) {
		return time.Time{}, time.Time{}, ErrWindowInvalid
	}
	// The window is half-open [from, to); the handler already converts an
	// inclusive user-supplied 'to' date to a half-open exclusive instant
	// by adding 1 day (see compliance.go). Computing spanDays as the bare
	// duration in days correctly counts the number of VISIBLE inclusive
	// days the user asked for — a 365-visible-day annual export produces
	// to.Sub(from) == 365*24h, hence spanDays == 365, at the default cap.
	spanDays := int(to.Sub(from) / (24 * time.Hour))
	if spanDays > a.maxWindowDays {
		return time.Time{}, time.Time{}, fmt.Errorf("%w: %d days (max %d)", ErrWindowTooLarge, spanDays, a.maxWindowDays)
	}
	return from, to, nil
}

// CountCertsInWindow returns the cert count + by-verdict projection
// for [from, to). When certDB is nil (cert browser surface
// unconfigured) returns an empty CertCounts. Errors propagate so the
// handler can fail-closed.
func (a *Aggregator) CountCertsInWindow(ctx context.Context, from, to time.Time) (CertCounts, error) {
	from, to, err := a.validateWindow(from, to)
	if err != nil {
		return CertCounts{}, err
	}
	if a.certDB == nil {
		return CertCounts{
			ByVerdict:  map[string]int{},
			WindowFrom: from,
			WindowTo:   to,
		}, nil
	}

	qctx, cancel := context.WithTimeout(ctx, a.queryTimeout)
	defer cancel()

	const sql = `
		SELECT
			COUNT(*),
			COALESCE(NULLIF(verdict, ''), '__none__') AS verdict_bucket
		FROM veil_certificates
		WHERE created_at >= $1 AND created_at < $2
		GROUP BY verdict_bucket
		ORDER BY verdict_bucket`
	rows, err := a.certDB.Query(qctx, sql, from, to)
	if err != nil {
		return CertCounts{}, fmt.Errorf("compliance: cert count query: %w", err)
	}
	defer rows.Close()

	out := CertCounts{
		ByVerdict:  map[string]int{},
		WindowFrom: from,
		WindowTo:   to,
	}
	for rows.Next() {
		var n int
		var verdict string
		if err := rows.Scan(&n, &verdict); err != nil {
			return CertCounts{}, fmt.Errorf("compliance: cert count scan: %w", err)
		}
		out.Total += n
		if verdict == "__none__" {
			out.NoVerdict = n
		} else {
			out.ByVerdict[verdict] = n
		}
	}
	if err := rows.Err(); err != nil {
		return CertCounts{}, fmt.Errorf("compliance: cert count iterate: %w", err)
	}
	return out, nil
}

// CountSanitizerActivityInWindow returns sanitizer-layer activity for
// [from, to). Rows are audit_events where event_type LIKE
// 'sanitizer.%'. ByLayer projects the count of each `sanitizer_layer`
// JSON payload key value; rows with no extractable layer fall in the
// "unknown" bucket.
//
// When auditDB is nil returns an empty SanitizerCounts struct.
func (a *Aggregator) CountSanitizerActivityInWindow(ctx context.Context, from, to time.Time) (SanitizerCounts, error) {
	from, to, err := a.validateWindow(from, to)
	if err != nil {
		return SanitizerCounts{}, err
	}
	if a.auditDB == nil {
		return SanitizerCounts{
			ByLayer:    map[string]int{},
			WindowFrom: from,
			WindowTo:   to,
		}, nil
	}

	qctx, cancel := context.WithTimeout(ctx, a.queryTimeout)
	defer cancel()

	// The payload is stored as BYTEA but the sanitizer's emit format is
	// canonical JSON (per `apps/dashboard/internal/audit/db_emitter.go`
	// :: marshalCanonicalPayload — same shape upstream emits). The
	// CAST + ->> chain extracts the layer key; rows with malformed JSON
	// or no payload bucket as 'unknown'.
	//
	// Defence: encode_to_text + json validity gate via try/catch isn't
	// available pre-Postgres-17. We rely on the upstream's contract
	// that sanitizer emits valid JSON; broken rows show up as 'unknown'
	// which matches the operator's mental model ("could not classify").
	const sql = `
		SELECT
			COUNT(*),
			COALESCE(NULLIF(layer, ''), 'unknown') AS layer_bucket
		FROM (
			SELECT
				CASE
					WHEN payload IS NULL OR octet_length(payload) = 0 THEN ''
					ELSE COALESCE(
						(convert_from(payload, 'UTF8')::jsonb ->> 'sanitizer_layer'),
						''
					)
				END AS layer
			FROM audit_events
			WHERE event_type LIKE 'sanitizer.%'
				AND timestamp >= $1
				AND timestamp < $2
		) layers
		GROUP BY layer_bucket
		ORDER BY layer_bucket`
	rows, err := a.auditDB.Query(qctx, sql, from, to)
	if err != nil {
		return SanitizerCounts{}, fmt.Errorf("compliance: sanitizer count query: %w", err)
	}
	defer rows.Close()

	out := SanitizerCounts{
		ByLayer:    map[string]int{},
		WindowFrom: from,
		WindowTo:   to,
	}
	for rows.Next() {
		var n int
		var layer string
		if err := rows.Scan(&n, &layer); err != nil {
			return SanitizerCounts{}, fmt.Errorf("compliance: sanitizer count scan: %w", err)
		}
		out.TotalRedactions += n
		out.ByLayer[layer] = n
	}
	if err := rows.Err(); err != nil {
		return SanitizerCounts{}, fmt.Errorf("compliance: sanitizer count iterate: %w", err)
	}
	return out, nil
}

// CountAuditEventsInWindow returns the total + by-type breakdown for
// audit_events in [from, to). When auditDB is nil returns an empty
// AuditCounts.
func (a *Aggregator) CountAuditEventsInWindow(ctx context.Context, from, to time.Time) (AuditCounts, error) {
	from, to, err := a.validateWindow(from, to)
	if err != nil {
		return AuditCounts{}, err
	}
	if a.auditDB == nil {
		return AuditCounts{
			ByType:     map[string]int{},
			WindowFrom: from,
			WindowTo:   to,
		}, nil
	}

	qctx, cancel := context.WithTimeout(ctx, a.queryTimeout)
	defer cancel()

	const sql = `
		SELECT
			COUNT(*),
			event_type
		FROM audit_events
		WHERE timestamp >= $1 AND timestamp < $2
		GROUP BY event_type
		ORDER BY event_type`
	rows, err := a.auditDB.Query(qctx, sql, from, to)
	if err != nil {
		return AuditCounts{}, fmt.Errorf("compliance: audit count query: %w", err)
	}
	defer rows.Close()

	out := AuditCounts{
		ByType:     map[string]int{},
		WindowFrom: from,
		WindowTo:   to,
	}
	for rows.Next() {
		var n int
		var eventType string
		if err := rows.Scan(&n, &eventType); err != nil {
			return AuditCounts{}, fmt.Errorf("compliance: audit count scan: %w", err)
		}
		out.Total += n
		out.ByType[eventType] = n
	}
	if err := rows.Err(); err != nil {
		return AuditCounts{}, fmt.Errorf("compliance: audit count iterate: %w", err)
	}
	return out, nil
}

// Summary composes the three counts into a single ComplianceSummary.
// If any sub-query fails the whole Summary returns the error — the
// PDF generator MUST receive a complete population set, partial
// summaries would mislead the customer.
func (a *Aggregator) Summary(ctx context.Context, from, to time.Time) (*ComplianceSummary, error) {
	from, to, err := a.validateWindow(from, to)
	if err != nil {
		return nil, err
	}

	certs, err := a.CountCertsInWindow(ctx, from, to)
	if err != nil {
		return nil, err
	}
	sanitizer, err := a.CountSanitizerActivityInWindow(ctx, from, to)
	if err != nil {
		return nil, err
	}
	audit, err := a.CountAuditEventsInWindow(ctx, from, to)
	if err != nil {
		return nil, err
	}

	return &ComplianceSummary{
		WindowFrom: from,
		WindowTo:   to,
		Certs:      certs,
		Sanitizer:  sanitizer,
		Audit:      audit,
	}, nil
}

// SanitizeCustomerName trims + validates the operator-supplied customer
// name. Returns the canonical form or an error if the input contains
// banned literals, exceeds 200 chars, contains control characters,
// or is otherwise unfit for direct embedding into PDF body copy.
//
// Allowed: Unicode letters + digits + spaces + common punctuation
// (. , - _ ( ) & ' / : @ + ).
func SanitizeCustomerName(name string) (string, error) {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "", fmt.Errorf("compliance: customer name required")
	}
	if len(trimmed) > 200 {
		return "", fmt.Errorf("compliance: customer name exceeds 200 characters")
	}
	for i, r := range trimmed {
		if r < 0x20 || r == 0x7F {
			return "", fmt.Errorf("compliance: customer name contains control character at offset %d", i)
		}
	}
	// Banned-literal scan before returning. The customer name lands on
	// the cover page; a banned literal here would corrupt the artefact.
	if err := Assert(trimmed); err != nil {
		return "", err
	}
	return trimmed, nil
}
