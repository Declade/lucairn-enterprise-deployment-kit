// This file extends package store with audit-log access. Slice 6 ship.
//
// # Audit DB vs cert DB
//
// The Slice 3 env var `LUCAIRN_DASHBOARD_AUDIT_DB_URL` is a legacy misnomer:
// it points at postgres-bridge (which holds veil_certificates). The audit
// EVENT log lives in a separate Postgres instance (`postgres-audit`) with
// its own role + schema (per
// dual-sandbox-architecture/services/audit/migrations/000001_create_events.up.sql).
// Slice 6 introduces a NEW env var `LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL` to
// keep the two connections independent; downstream code never reaches a
// place where the cert DB and the audit DB would get conflated.
//
// # Schema reference
//
// audit_events table (from the upstream service's migrations):
//
//	id                  BIGSERIAL PRIMARY KEY
//	event_id            TEXT NOT NULL UNIQUE
//	event_type          TEXT NOT NULL
//	source_service      TEXT NOT NULL
//	actor               TEXT NOT NULL
//	timestamp           TIMESTAMPTZ NOT NULL DEFAULT NOW()
//	previous_event_hash TEXT NOT NULL DEFAULT ''
//	event_hash          TEXT NOT NULL
//	payload             BYTEA
//	created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
//	-- migration 000005 additions:
//	request_id          TEXT
//	payload_type        TEXT NOT NULL DEFAULT 'FLAT_JSON'
//	payload_bytes       BYTEA
//
// The dashboard reads + writes the `audit_app` role on audit_events:
// SELECT for the /audit browsing surface and INSERT for the paired
// reveal-raw + csv_export_with_reveal audit events emitted by the
// dashboard's DBEmitter (Slice 6 fix-up r1 H3 / DRIFT-006). Without
// INSERT, those flows fail-close with 500 and never return raw PII.
// Saved-filters require an additional table; see saved_filters.go for
// the dedicated table + the privilege expansion note in OPS.md.
//
// # Defence in depth
//
// All filter values reach SQL through positional parameters
// (`$N`). pq's array helpers handle IN-clause arrays safely; the test
// suite verifies the generated SQL never contains user-input substrings
// (TestAuditFilter_SQLBuilder_NoInterpolation).
package store

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/sync/singleflight"
)

// AuditEvent is one row in the browser / detail surface. Payload is
// stored as the raw bytes from `audit_events.payload` (BYTEA — the
// upstream emit writes JSON bytes here; older rows may contain other
// shapes which the render-time guard handles via the malformed-JSON
// fallback).
//
// PayloadBytes carries the migration-000005 `payload_bytes` column
// (typed binary payloads emitted by services that use the upstream
// audit-service's typed-events API). When PayloadType == "FLAT_JSON"
// the column is NULL + ignored; the JSON lives in Payload as usual.
// For any other PayloadType the dashboard renders an explainer banner
// + the raw bytes hex-encoded so operators see the row exists without
// the dashboard pretending to decode a binary encoding it doesn't
// know. Slice 6 fix-up r1 DRIFT-002.
type AuditEvent struct {
	ID                int64
	EventID           string
	EventType         string
	SourceService     string
	Actor             string
	Timestamp         time.Time
	PreviousEventHash string
	EventHash         string
	Payload           []byte
	PayloadBytes      []byte
	RequestID         string
	PayloadType       string
}

// AuditFilter constrains the audit-browser query.
//
// All slice fields use a "non-empty = filter" convention (empty =
// "no constraint"). Page defaults applied in ListEvents:
// PageSize=50 when ≤0, max 200. Page=1 maps to offset 0.
type AuditFilter struct {
	EventTypes      []string
	SourceServices  []string
	Actors          []string
	RequestID       string
	TimestampFrom   *time.Time
	TimestampTo     *time.Time
	PayloadContains string
	Page            int
	PageSize        int
}

// AuditFilterShape implements the views.FilterReader contract so the
// template helper `filterURL` can serialise an AuditFilter into a URL
// query string. Returning a tuple of scalar / slice / pointer values
// (no shared struct type) sidesteps the circular import between
// views ← store.
func (f AuditFilter) AuditFilterShape() (eventTypes, sourceServices, actors []string, requestID, payloadContains string, from, to *time.Time) {
	return f.EventTypes, f.SourceServices, f.Actors, f.RequestID, f.PayloadContains, f.TimestampFrom, f.TimestampTo
}

// AuditConfig carries store-level knobs. distinctTTL governs the
// in-memory cache for filter-dropdown values; lower values mean
// fresher dropdowns but more DB pressure. Default 5 minutes.
type AuditConfig struct {
	DistinctTTL time.Duration
	MaxPageSize int
}

// AuditStore is the audit-log data layer.
//
// dbURL is RETAINED in the struct for diagnostic logging only and is
// the redacted form (no user:pass). The pool's connection string lives
// inside pgxpool itself; the dashboard never reads it back.
type AuditStore struct {
	db          Querier
	cfg         AuditConfig
	mu          sync.Mutex
	cachedTypes []string
	typesCached time.Time
	cachedSvcs  []string
	svcsCached  time.Time
	flight      singleflight.Group
	clock       func() time.Time // injectable for tests
}

// ErrPlaceholderURL is returned by NewAuditStore when the operator's
// connection string still contains a CHANGE_ME-style placeholder.
// Fail-closed at boot per Slice 3 pattern #25.
var ErrPlaceholderURL = errors.New("store: audit log DB URL is a placeholder; replace before enabling the surface")

// NewAuditStore builds an AuditStore from a libpq URL. Returns the
// store, the underlying pool (for graceful Close on shutdown), and an
// error. Pool sizing mirrors CertStore (8 max conns, 1 min, idle/
// lifetime budgets).
func NewAuditStore(ctx context.Context, connStr string) (*AuditStore, *pgxpool.Pool, error) {
	if strings.TrimSpace(connStr) == "" {
		return nil, nil, errors.New("store: audit log DB connection string is required")
	}
	if isPlaceholderURL(connStr) {
		return nil, nil, ErrPlaceholderURL
	}
	parsed, err := url.Parse(connStr)
	if err != nil {
		return nil, nil, fmt.Errorf("store: parse audit log DB URL: %w", err)
	}
	switch parsed.Scheme {
	case "postgres", "postgresql":
		// ok
	default:
		return nil, nil, fmt.Errorf("store: audit log DB URL scheme must be postgres:// or postgresql://, got %q", parsed.Scheme)
	}
	cfg, err := pgxpool.ParseConfig(connStr)
	if err != nil {
		return nil, nil, fmt.Errorf("store: parse audit log connection string: %w", err)
	}
	cfg.MaxConns = 8
	cfg.MinConns = 1
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.MaxConnLifetime = 30 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("store: build audit log pool: %w", err)
	}
	s := &AuditStore{
		db:    pool,
		cfg:   AuditConfig{DistinctTTL: 5 * time.Minute, MaxPageSize: 200},
		clock: time.Now,
	}
	return s, pool, nil
}

// NewAuditStoreWithDB wraps an existing Querier for tests.
func NewAuditStoreWithDB(db Querier) *AuditStore {
	return &AuditStore{
		db:    db,
		cfg:   AuditConfig{DistinctTTL: 5 * time.Minute, MaxPageSize: 200},
		clock: time.Now,
	}
}

// ListEvents returns one page of matching rows plus the total filtered
// count.
func (s *AuditStore) ListEvents(ctx context.Context, filter AuditFilter) ([]AuditEvent, int, error) {
	if filter.PageSize <= 0 {
		filter.PageSize = 50
	}
	maxPage := s.cfg.MaxPageSize
	if maxPage <= 0 {
		maxPage = 200
	}
	if filter.PageSize > maxPage {
		filter.PageSize = maxPage
	}
	if filter.Page < 1 {
		filter.Page = 1
	}
	offset := (filter.Page - 1) * filter.PageSize

	where, args := buildAuditWhere(filter, 1)
	listSQL := strings.Builder{}
	// Slice 6 fix-up r1 DRIFT-002: read payload_bytes column too so
	// typed-event payloads (where payload_type != 'FLAT_JSON') don't
	// silently render as empty.
	listSQL.WriteString(`SELECT
			id,
			event_id,
			event_type,
			source_service,
			actor,
			timestamp,
			COALESCE(previous_event_hash, ''),
			COALESCE(event_hash, ''),
			COALESCE(payload, ''::bytea),
			COALESCE(request_id, ''),
			COALESCE(payload_type, 'FLAT_JSON'),
			COALESCE(payload_bytes, ''::bytea)
		FROM audit_events
		WHERE 1=1`)
	listSQL.WriteString(where)
	fmt.Fprintf(&listSQL, " ORDER BY timestamp DESC, id DESC LIMIT $%d OFFSET $%d", len(args)+1, len(args)+2)
	args = append(args, filter.PageSize, offset)

	rows, err := s.db.Query(ctx, listSQL.String(), args...)
	if err != nil {
		return nil, 0, fmt.Errorf("store: list audit events: %w", err)
	}
	defer rows.Close()
	out := make([]AuditEvent, 0, filter.PageSize)
	for rows.Next() {
		var e AuditEvent
		if err := rows.Scan(
			&e.ID,
			&e.EventID,
			&e.EventType,
			&e.SourceService,
			&e.Actor,
			&e.Timestamp,
			&e.PreviousEventHash,
			&e.EventHash,
			&e.Payload,
			&e.RequestID,
			&e.PayloadType,
			&e.PayloadBytes,
		); err != nil {
			return nil, 0, fmt.Errorf("store: scan audit event: %w", err)
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("store: iterate audit events: %w", err)
	}

	// Re-build args for the count query so positional placeholders
	// stay aligned (no pagination params on the COUNT path).
	countWhere, countArgs := buildAuditWhere(filter, 1)
	countSQL := "SELECT COUNT(*) FROM audit_events WHERE 1=1" + countWhere
	var total int
	if err := s.db.QueryRow(ctx, countSQL, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("store: count audit events: %w", err)
	}
	return out, total, nil
}

// GetEvent loads a single event by its public event_id (text identifier
// the audit emitter mints — uuidv4 in production). Returns
// pgx.ErrNoRows when the row is absent so callers can render a 404.
func (s *AuditStore) GetEvent(ctx context.Context, eventID string) (*AuditEvent, error) {
	if strings.TrimSpace(eventID) == "" {
		return nil, errors.New("store: event_id required")
	}
	// Slice 6 fix-up r1 DRIFT-002: also load payload_bytes (migration
	// 000005) so typed-event detail pages render the binary blob
	// hex-encoded rather than silently empty.
	//
	// Slice 6 fix-up r1 DRIFT-001 (documentation): the payload_contains
	// LIKE filter compares against payload::text — Postgres renders
	// BYTEA values as `\x<hex>` strings, so the operator searches the
	// hex form, not the JSON form. Operators searching for an actor
	// email won't match because the comparison is against hex bytes.
	// A real fix would require either (a) storing payload as JSONB
	// (migration + upstream-coordination), or (b) `convert_from(payload,
	// 'UTF8')` which crashes on non-UTF-8 bytes. Both are out of scope
	// for this fix-up; document the limitation and let operators use
	// event_type + source_service + actor as the primary filters.
	const sql = `SELECT
			id,
			event_id,
			event_type,
			source_service,
			actor,
			timestamp,
			COALESCE(previous_event_hash, ''),
			COALESCE(event_hash, ''),
			COALESCE(payload, ''::bytea),
			COALESCE(request_id, ''),
			COALESCE(payload_type, 'FLAT_JSON'),
			COALESCE(payload_bytes, ''::bytea)
		FROM audit_events
		WHERE event_id = $1`
	var e AuditEvent
	row := s.db.QueryRow(ctx, sql, eventID)
	if err := row.Scan(
		&e.ID,
		&e.EventID,
		&e.EventType,
		&e.SourceService,
		&e.Actor,
		&e.Timestamp,
		&e.PreviousEventHash,
		&e.EventHash,
		&e.Payload,
		&e.RequestID,
		&e.PayloadType,
		&e.PayloadBytes,
	); err != nil {
		return nil, err
	}
	return &e, nil
}

// DistinctEventTypes returns the alphabetically-sorted set of distinct
// event_type values currently in the audit table. Cached for
// cfg.DistinctTTL so dropdown rendering is cheap; singleflight guards
// against the cache-stampede pattern on a cold boot with concurrent
// /audit hits.
func (s *AuditStore) DistinctEventTypes(ctx context.Context) ([]string, error) {
	s.mu.Lock()
	now := s.clock()
	if !s.typesCached.IsZero() && now.Sub(s.typesCached) < s.cfg.DistinctTTL {
		out := append([]string(nil), s.cachedTypes...)
		s.mu.Unlock()
		return out, nil
	}
	s.mu.Unlock()
	v, err, _ := s.flight.Do("event_types", func() (interface{}, error) {
		// Detach the inner ctx from the first caller's so a cancel
		// from caller A doesn't poison coalesced caller B.
		// (Slice 5 pattern #39.)
		innerCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return s.fetchDistinct(innerCtx, "event_type")
	})
	if err != nil {
		return nil, err
	}
	values := v.([]string)
	s.mu.Lock()
	s.cachedTypes = append([]string(nil), values...)
	s.typesCached = s.clock()
	s.mu.Unlock()
	return values, nil
}

// DistinctSourceServices mirrors DistinctEventTypes for source_service.
func (s *AuditStore) DistinctSourceServices(ctx context.Context) ([]string, error) {
	s.mu.Lock()
	now := s.clock()
	if !s.svcsCached.IsZero() && now.Sub(s.svcsCached) < s.cfg.DistinctTTL {
		out := append([]string(nil), s.cachedSvcs...)
		s.mu.Unlock()
		return out, nil
	}
	s.mu.Unlock()
	v, err, _ := s.flight.Do("source_services", func() (interface{}, error) {
		innerCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return s.fetchDistinct(innerCtx, "source_service")
	})
	if err != nil {
		return nil, err
	}
	values := v.([]string)
	s.mu.Lock()
	s.cachedSvcs = append([]string(nil), values...)
	s.svcsCached = s.clock()
	s.mu.Unlock()
	return values, nil
}

// fetchDistinct issues the SELECT DISTINCT query. column is one of an
// internally-controlled allowlist — never sourced from user input — so
// concatenation is safe.
func (s *AuditStore) fetchDistinct(ctx context.Context, column string) ([]string, error) {
	allowed := map[string]struct{}{"event_type": {}, "source_service": {}}
	if _, ok := allowed[column]; !ok {
		return nil, fmt.Errorf("store: distinct column %q not allowlisted", column)
	}
	q := fmt.Sprintf("SELECT DISTINCT %s FROM audit_events WHERE %s IS NOT NULL AND %s <> '' ORDER BY %s ASC", column, column, column, column)
	rows, err := s.db.Query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("store: distinct %s: %w", column, err)
	}
	defer rows.Close()
	out := make([]string, 0, 16)
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, fmt.Errorf("store: scan distinct %s: %w", column, err)
		}
		out = append(out, v)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate distinct %s: %w", column, err)
	}
	return out, nil
}

// buildAuditWhere produces a parameterized WHERE-suffix + args slice.
// startIdx is the first $N to assign; the LIMIT/OFFSET tail adds two
// more on top of whatever this function returns.
//
// Defense-in-depth posture identical to buildWhere for certs:
//   - all user input goes through positional placeholders
//   - IN-clause arrays use pgx's []string driver-friendly form
//   - LIKE for payload search escapes the `%` / `_` / `\` operators on
//     the caller's input so the user cannot inject glob-style probes.
func buildAuditWhere(filter AuditFilter, startIdx int) (string, []any) {
	var b strings.Builder
	args := make([]any, 0, 8)
	idx := startIdx

	if filter.TimestampFrom != nil && !filter.TimestampFrom.IsZero() {
		fmt.Fprintf(&b, " AND timestamp >= $%d", idx)
		args = append(args, *filter.TimestampFrom)
		idx++
	}
	if filter.TimestampTo != nil && !filter.TimestampTo.IsZero() {
		fmt.Fprintf(&b, " AND timestamp < $%d", idx)
		args = append(args, *filter.TimestampTo)
		idx++
	}
	if len(filter.EventTypes) > 0 {
		// IN clause via pgx's slice expansion. pgx encodes []string
		// as TEXT[] which Postgres consumes with `= ANY($N::text[])`.
		fmt.Fprintf(&b, " AND event_type = ANY($%d::text[])", idx)
		args = append(args, filter.EventTypes)
		idx++
	}
	if len(filter.SourceServices) > 0 {
		fmt.Fprintf(&b, " AND source_service = ANY($%d::text[])", idx)
		args = append(args, filter.SourceServices)
		idx++
	}
	if len(filter.Actors) > 0 {
		fmt.Fprintf(&b, " AND actor = ANY($%d::text[])", idx)
		args = append(args, filter.Actors)
		idx++
	}
	if strings.TrimSpace(filter.RequestID) != "" {
		fmt.Fprintf(&b, " AND request_id = $%d", idx)
		args = append(args, strings.TrimSpace(filter.RequestID))
		idx++
	}
	if strings.TrimSpace(filter.PayloadContains) != "" {
		// LIKE with explicit escape so user-provided '%' / '_' /
		// '\' are treated as literals. The trailing `escape '\'`
		// pins backslash as the escape character.
		fmt.Fprintf(&b, " AND payload::text LIKE $%d ESCAPE '\\'", idx)
		args = append(args, "%"+escapeLikePattern(filter.PayloadContains)+"%")
	}
	return b.String(), args
}

// escapeLikePattern escapes the three SQL-LIKE special characters so a
// crafted payload-contains filter cannot perform glob-style probes
// (e.g. "%admin%" matching every payload containing the substring
// "admin"). Backslash escape character pinned in the SQL.
func escapeLikePattern(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(s)
}

// isPlaceholderURL recognises the common CHANGE_ME stencils so a
// freshly-cloned env file does not silently boot the dashboard
// against a half-configured backend.
func isPlaceholderURL(s string) bool {
	if s == "" {
		return false
	}
	stripped := strings.ToLower(strings.Join(strings.Fields(s), ""))
	indicators := []string{
		"change_me",
		"changeme",
		"your-",
		"placeholder",
		"replace_me",
		"replaceme",
		"todo:set",
	}
	for _, ind := range indicators {
		if strings.Contains(stripped, ind) {
			return true
		}
	}
	return false
}

