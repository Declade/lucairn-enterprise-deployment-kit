// This file extends package store with per-user saved-filter persistence
// for the audit log browser. Slice 6 ship.
//
// # Backend choice
//
// Persistence lives in a new `dashboard_saved_filters` table on the
// SAME postgres-audit database the audit-events table lives on. Local
// SQLite would have required a PVC mount + would not survive pod
// rescheduling without storage migration; an extra Postgres connection
// would have doubled the audit-DB connection budget; a new table on
// the existing audit DB is the smallest moving piece.
//
// The trade-off is that `audit_app` (the role the dashboard's audit
// store already connects as) gains INSERT / SELECT / UPDATE / DELETE
// on this new table. The migration in
// apps/dashboard/migrations/000001_create_saved_filters.up.sql
// documents the privilege expansion and OPS.md surfaces it for the
// operator. Operators uncomfortable with the expansion may create a
// separate role + supply a separate connection string via
// `LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL`; the dashboard
// honours that override when set, falling back to the audit-log DB
// when not.
//
// # Cross-tenant isolation
//
// Every query scopes by user_email at the SQL layer. Handler-layer
// scoping alone is insufficient — the test
// TestAudit_SavedFiltersScope_OnlyOwnUserVisible verifies the SQL
// itself binds user_email = $1.
package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SavedFilter is one row in the saved-filters list.
type SavedFilter struct {
	ID        int64
	UserEmail string
	Name      string
	Filter    AuditFilter
	CreatedAt time.Time
	UpdatedAt time.Time
}

// SavedFilterReader implements the views.SavedFilterReader contract
// so the template helper `savedFilterURL` can serialise a stored
// filter into a URL query string. The interface is satisfied by
// returning the embedded AuditFilter as a views.FilterReader-typed
// value; AuditFilter implements that contract via its
// AuditFilterShape method.
func (s SavedFilter) SavedFilterReader() interface {
	AuditFilterShape() (eventTypes, sourceServices, actors []string, requestID, payloadContains string, from, to *time.Time)
} {
	return s.Filter
}


// SavedFiltersStore is the audit-browser per-user filter persistence.
//
// `db` defaults to the same Querier as AuditStore when the
// dashboard's wiring opts for a single shared connection; a future
// rev may split it into a dedicated pool if the operator wires
// `LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL`.
type SavedFiltersStore struct {
	db Querier
}

// NewSavedFiltersStore wraps a Querier (typically the same audit-DB
// pool the AuditStore consumes).
func NewSavedFiltersStore(db Querier) *SavedFiltersStore {
	return &SavedFiltersStore{db: db}
}

// NewSavedFiltersStoreFromURL builds a fresh pool for the saved
// filters table from a libpq URL. Returns the store, the pool, and
// an error.
func NewSavedFiltersStoreFromURL(ctx context.Context, connStr string) (*SavedFiltersStore, *pgxpool.Pool, error) {
	if strings.TrimSpace(connStr) == "" {
		return nil, nil, errors.New("store: saved filters DB connection string is required")
	}
	if isPlaceholderURL(connStr) {
		return nil, nil, ErrPlaceholderURL
	}
	parsed, err := url.Parse(connStr)
	if err != nil {
		return nil, nil, fmt.Errorf("store: parse saved filters DB URL: %w", err)
	}
	switch parsed.Scheme {
	case "postgres", "postgresql":
		// ok
	default:
		return nil, nil, fmt.Errorf("store: saved filters DB URL scheme must be postgres:// or postgresql://, got %q", parsed.Scheme)
	}
	cfg, err := pgxpool.ParseConfig(connStr)
	if err != nil {
		return nil, nil, fmt.Errorf("store: parse saved filters connection string: %w", err)
	}
	cfg.MaxConns = 4
	cfg.MinConns = 1
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.MaxConnLifetime = 30 * time.Minute
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, nil, fmt.Errorf("store: build saved filters pool: %w", err)
	}
	return &SavedFiltersStore{db: pool}, pool, nil
}

// ErrSavedFilterNameLength is returned when the operator tries to
// save a filter with a name above the 100-char ceiling.
var ErrSavedFilterNameLength = errors.New("store: saved filter name must be 1-100 characters")

// ErrSavedFilterTableMissing signals the dashboard_saved_filters
// table does not exist in the connected DB. Handlers translate to a
// friendly "saved filters require the operator to apply the
// dashboard migration" banner.
var ErrSavedFilterTableMissing = errors.New("store: dashboard_saved_filters table missing — apply apps/dashboard/migrations/000001_create_saved_filters.up.sql")

// Save inserts or updates one filter for (user, name).
func (s *SavedFiltersStore) Save(ctx context.Context, user, name string, filter AuditFilter) error {
	name = strings.TrimSpace(name)
	if len(name) == 0 || len(name) > 100 {
		return ErrSavedFilterNameLength
	}
	user = strings.TrimSpace(user)
	if user == "" {
		return errors.New("store: saved filter requires non-empty user")
	}
	payload, err := json.Marshal(sanitiseFilterForPersistence(filter))
	if err != nil {
		return fmt.Errorf("store: marshal filter: %w", err)
	}
	const sqlInsert = `
		INSERT INTO dashboard_saved_filters (user_email, name, filter_json, created_at, updated_at)
		VALUES ($1, $2, $3::jsonb, NOW(), NOW())
		ON CONFLICT (user_email, name) DO UPDATE SET
			filter_json = EXCLUDED.filter_json,
			updated_at = NOW()`
	if _, err := s.db.Query(ctx, sqlInsert, user, name, string(payload)); err != nil {
		if isMissingTableErr(err) {
			return ErrSavedFilterTableMissing
		}
		return fmt.Errorf("store: save filter: %w", err)
	}
	return nil
}

// List returns the user's saved filters, alphabetically.
func (s *SavedFiltersStore) List(ctx context.Context, user string) ([]SavedFilter, error) {
	user = strings.TrimSpace(user)
	if user == "" {
		return nil, errors.New("store: list saved filters requires non-empty user")
	}
	const sqlList = `
		SELECT id, user_email, name, filter_json::text, created_at, updated_at
		FROM dashboard_saved_filters
		WHERE user_email = $1
		ORDER BY name ASC`
	rows, err := s.db.Query(ctx, sqlList, user)
	if err != nil {
		if isMissingTableErr(err) {
			return nil, ErrSavedFilterTableMissing
		}
		return nil, fmt.Errorf("store: list saved filters: %w", err)
	}
	defer rows.Close()
	out := make([]SavedFilter, 0, 8)
	for rows.Next() {
		var f SavedFilter
		var filterJSON string
		if err := rows.Scan(&f.ID, &f.UserEmail, &f.Name, &filterJSON, &f.CreatedAt, &f.UpdatedAt); err != nil {
			return nil, fmt.Errorf("store: scan saved filter: %w", err)
		}
		if err := json.Unmarshal([]byte(filterJSON), &f.Filter); err != nil {
			// One malformed row should not blow up the dropdown.
			// Skip it and continue (the SaveAs path validates;
			// this defends only against ad-hoc DB edits).
			continue
		}
		out = append(out, f)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate saved filters: %w", err)
	}
	return out, nil
}

// Delete removes one filter for (user, name).
func (s *SavedFiltersStore) Delete(ctx context.Context, user, name string) error {
	user = strings.TrimSpace(user)
	name = strings.TrimSpace(name)
	if user == "" || name == "" {
		return errors.New("store: delete saved filter requires non-empty user + name")
	}
	const sqlDel = `DELETE FROM dashboard_saved_filters WHERE user_email = $1 AND name = $2`
	if _, err := s.db.Query(ctx, sqlDel, user, name); err != nil {
		if isMissingTableErr(err) {
			return ErrSavedFilterTableMissing
		}
		return fmt.Errorf("store: delete saved filter: %w", err)
	}
	return nil
}

// sanitiseFilterForPersistence drops the pagination fields (page +
// page_size) from the filter before persisting. Operators want
// "show me everything matching filter X"; the page number they were
// on when they saved is irrelevant.
func sanitiseFilterForPersistence(f AuditFilter) AuditFilter {
	f.Page = 0
	f.PageSize = 0
	return f
}

// isMissingTableErr matches Postgres SQLSTATE 42P01 (undefined_table)
// without dragging the pgconn dependency into a public Errors API.
// The string match is intentionally tight to avoid swallowing
// unrelated errors.
func isMissingTableErr(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "dashboard_saved_filters") &&
		(strings.Contains(msg, "does not exist") ||
			strings.Contains(msg, "no such table") ||
			strings.Contains(msg, "undefined_table"))
}

