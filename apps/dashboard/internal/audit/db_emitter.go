// db_emitter.go — Slice 6 fix-up r1 H3 / DRIFT-006 closure.
//
// LogEmitter writes only to log.Println. That makes the PRD's
// load-bearing security guarantee ("admin reveal emits a paired
// audit.reveal_raw event into the audit DB; auditors can see who
// unmasked what") FALSE in production: pod logs are transient and the
// dashboard's own /audit surface — the one auditors actually use —
// queries audit_events, not pod logs.
//
// DBEmitter closes that gap by INSERTing into audit_events directly,
// reusing the audit_app role's existing INSERT grant
// (migrations/audit/000003_least_privilege_role.up.sql:35). The wire
// shape matches audit_events' NOT-NULL columns:
//
//	event_id        TEXT NOT NULL UNIQUE        — UUIDv4 per emit
//	event_type      TEXT NOT NULL               — from the call site
//	source_service  TEXT NOT NULL               — "dsa-dashboard"
//	actor           TEXT NOT NULL               — caller's email
//	timestamp                                   — NOW()
//	event_hash      TEXT NOT NULL               — SHA-256 of canonical
//	                                              JSON (defensive — the
//	                                              upstream audit service
//	                                              chains hashes; the
//	                                              dashboard's emits do
//	                                              NOT participate in the
//	                                              hash chain, they're
//	                                              standalone events)
//	payload         BYTEA                       — JSON-encoded
//	payload_type    TEXT NOT NULL DEFAULT       — 'FLAT_JSON'
//
// The dashboard's emits live alongside (NOT inside) the upstream
// service's hash chain. previous_event_hash defaults to '' per
// migration 000001 line 8. Operators who need a verified chain across
// dashboard + upstream emits should reconstruct via SQL — same row
// ordering is preserved by id BIGSERIAL.

package audit

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// DBEmitter INSERTs each Emit() call into audit_events.
//
// service is the source_service column value (always "dsa-dashboard"
// in production; injectable for tests). pool is the audit-log DB pool;
// the audit_app role this connects as already holds INSERT on
// audit_events per migration 000003. now lets tests pin the timestamp;
// nil falls back to time.Now.
type DBEmitter struct {
	pool    *pgxpool.Pool
	service string
	now     func() time.Time
}

// NewDBEmitter returns a DBEmitter against the supplied pool. The
// caller is responsible for the pool's lifecycle — close on shutdown.
func NewDBEmitter(pool *pgxpool.Pool, sourceService string) *DBEmitter {
	svc := strings.TrimSpace(sourceService)
	if svc == "" {
		svc = "dsa-dashboard"
	}
	return &DBEmitter{
		pool:    pool,
		service: svc,
		now:     time.Now,
	}
}

// Emit INSERTs one row into audit_events.
//
// Returns a wrapped error on failure so the handler's reveal-raw +
// csv_export_with_reveal paths can fail-closed BEFORE returning
// sensitive data. The handler MUST check the error and 500 — losing
// the audit trail BEFORE surfacing raw PII would diverge the
// on-screen reveal from the queryable audit log.
//
// Concurrency: pgxpool handles serial-access semantics per connection;
// concurrent Emit calls fan out to different pool connections.
func (e *DBEmitter) Emit(ctx context.Context, eventType, actor string, payload map[string]any) error {
	if e == nil || e.pool == nil {
		return fmt.Errorf("audit: DBEmitter not configured")
	}
	if strings.TrimSpace(eventType) == "" {
		return fmt.Errorf("audit: event_type required")
	}
	if strings.TrimSpace(actor) == "" {
		return fmt.Errorf("audit: actor required")
	}

	// Payload → canonical JSON. Sort keys so the hash is deterministic
	// against goroutine timing + Go map iteration order.
	payloadJSON, err := marshalCanonicalPayload(payload)
	if err != nil {
		return fmt.Errorf("audit: marshal payload: %w", err)
	}

	eventID, err := newEventID()
	if err != nil {
		return fmt.Errorf("audit: mint event_id: %w", err)
	}

	ts := e.now().UTC()
	eventHash := hashEvent(eventID, eventType, e.service, actor, ts, payloadJSON)

	const insertSQL = `
		INSERT INTO audit_events (
			event_id, event_type, source_service, actor,
			timestamp, previous_event_hash, event_hash,
			payload, payload_type
		)
		VALUES ($1, $2, $3, $4, $5, '', $6, $7, 'FLAT_JSON')`
	if _, err := e.pool.Exec(ctx, insertSQL,
		eventID, eventType, e.service, actor,
		ts, eventHash,
		payloadJSON,
	); err != nil {
		return fmt.Errorf("audit: insert audit_events: %w", err)
	}
	return nil
}

// marshalCanonicalPayload renders a payload as a canonical JSON
// object: keys sorted lexicographically, no extra whitespace. This is
// what the event_hash is computed over; a deterministic encoding lets
// auditors recompute the hash from row contents.
func marshalCanonicalPayload(payload map[string]any) ([]byte, error) {
	if len(payload) == 0 {
		return []byte("{}"), nil
	}
	keys := make([]string, 0, len(payload))
	for k := range payload {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString("{")
	for i, k := range keys {
		if i > 0 {
			b.WriteString(",")
		}
		keyJSON, err := json.Marshal(k)
		if err != nil {
			return nil, err
		}
		b.Write(keyJSON)
		b.WriteString(":")
		valJSON, err := json.Marshal(payload[k])
		if err != nil {
			return nil, err
		}
		b.Write(valJSON)
	}
	b.WriteString("}")
	return []byte(b.String()), nil
}

// newEventID returns a UUIDv4-shaped string sourced from crypto/rand.
// Matches the upstream audit service's mint shape so cross-stream
// joins on event_id stay portable.
func newEventID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	// RFC 4122 variant + version bits.
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%s-%s-%s-%s-%s",
		hex.EncodeToString(b[0:4]),
		hex.EncodeToString(b[4:6]),
		hex.EncodeToString(b[6:8]),
		hex.EncodeToString(b[8:10]),
		hex.EncodeToString(b[10:16]),
	), nil
}

// hashEvent computes a stable SHA-256 over the row's canonical inputs.
// The dashboard's emits are standalone events (previous_event_hash is
// always '' per migration 000001:8) — the upstream audit service's
// hash chain runs independently. Operators who need to chain across
// streams must reconstruct via SQL.
func hashEvent(eventID, eventType, sourceService, actor string, ts time.Time, payloadJSON []byte) string {
	h := sha256.New()
	h.Write([]byte(eventID))
	h.Write([]byte("\x1f"))
	h.Write([]byte(eventType))
	h.Write([]byte("\x1f"))
	h.Write([]byte(sourceService))
	h.Write([]byte("\x1f"))
	h.Write([]byte(actor))
	h.Write([]byte("\x1f"))
	h.Write([]byte(ts.UTC().Format(time.RFC3339Nano)))
	h.Write([]byte("\x1f"))
	h.Write(payloadJSON)
	return hex.EncodeToString(h.Sum(nil))
}
