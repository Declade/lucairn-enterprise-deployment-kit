// Package audit provides a thin emitter abstraction the dashboard uses
// to record operator actions (mint key / revoke key / reveal raw / etc.).
//
// Slice 5 is the first surface to need a per-action audit emit. The shape
// intentionally mirrors the upstream gateway's emitAdminCustomerKeyAudit
// pattern (`services/gateway/internal/api/admin_customer_keys.go:282-302`)
// so a future cross-correlation between the gateway's persisted audit
// stream and the dashboard's local log stream can join on event_type +
// timestamp + actor.
//
// Three implementations ship:
//
//   - LogEmitter — pod-logs-only fallback used in dev / when the
//     operator hasn't wired a separate audit-log DB. Writes one
//     structured log line per emit via the standard log package.
//     Matches the cert browser's `log.Printf("cert.verify_requested ...")`
//     convention so operators parsing pod logs see all audit-worthy
//     events in the same place. Returns nil error always (best-effort).
//     Production should wire DBEmitter; LogEmitter is NOT queryable via
//     /audit and pod logs are transient.
//
//   - DBEmitter — production. INSERTs into the audit_events table on
//     the audit-log DB the dashboard already connects to (audit_app
//     role retains INSERT on audit_events per migration 000003). Returns
//     a wrapped error on failure so handlers can fail-closed BEFORE
//     surfacing raw payloads (the reveal-raw + csv_export_with_reveal
//     flows MUST emit successfully before returning sensitive data;
//     otherwise the audit trail diverges from the on-screen reveal).
//
//   - MemoryEmitter — capture buffer for tests. Each Emit appends a copy
//     of the event to an in-memory slice protected by a mutex. Tests
//     assert against Events() to verify a handler emitted the right
//     event names with the right payloads. Returns nil unless the
//     caller injects an error via SetEmitErr.
//
// Slice 6 fix-up r1 H3 / DRIFT-006: the interface widened to take a
// context.Context (for the DB path's cancellation discipline) AND
// return an error (so handlers fail-closed when the DB INSERT fails).
// Payloads carry `map[string]any` to let DBEmitter marshal mixed-type
// values into JSON without forcing every call site to pre-stringify.
//
// NEVER include secret material (raw key bytes, admin token, password
// values) in event payloads. The MintHandler / RevokeHandler MUST log
// metadata (customer_id, key_id, key_prefix, redactedSensitive(...))
// only — never raw_key.
package audit

import (
	"context"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"
)

// Event is one audit record.
//
// EventType is the canonical name (e.g. "key.mint_requested",
// "key.revoke_requested") the handler emits. Actor is the authenticated
// user email or principal id. Timestamp is captured at Emit() so the
// log line + the in-memory snapshot agree.
//
// Payload is a small set of key/value pairs. Implementations MUST sort
// keys before formatting so test assertions can match on a stable
// string representation. Slice 6 fix-up r1 widened the value type from
// `string` to `any` so DBEmitter can marshal mixed-type values (int /
// bool / nested object) without forcing every call site to
// pre-stringify.
type Event struct {
	EventType string
	Actor     string
	Timestamp time.Time
	Payload   map[string]any
}

// Emitter is the contract handlers consume. Implementations MUST be
// concurrency-safe — handlers run inside concurrent HTTP goroutines.
//
// Slice 6 fix-up r1 H3 / DRIFT-006: Emit takes a context.Context (so
// DBEmitter can honour request cancellation on long INSERTs) and
// returns an error (so handlers can fail-closed BEFORE returning raw
// payloads when the DB INSERT fails). LogEmitter always returns nil;
// DBEmitter returns the wrapped INSERT error. MemoryEmitter returns
// the test-injected error or nil.
type Emitter interface {
	Emit(ctx context.Context, eventType, actor string, payload map[string]any) error
}

// LogEmitter writes one structured log line per event. The format is
// stable + grep-friendly:
//
//	audit eventType=key.mint_requested actor=admin@lucairn.local key=value key=value
//
// Keys in the payload are sorted alphabetically so the line is stable
// across goroutine timing.
type LogEmitter struct {
	now func() time.Time // injectable for tests
}

// NewLogEmitter returns the default audit emitter for production.
func NewLogEmitter() *LogEmitter {
	return &LogEmitter{now: time.Now}
}

// Emit writes the event to the standard logger. Never panics; if a
// payload value contains characters that would break the grep-friendly
// line (newline, equals sign, quote), the value is replaced with a
// "<redacted-shape>" placeholder so the audit line stays parseable.
//
// Slice 6 fix-up r1 H3 / DRIFT-006: takes ctx + returns nil for
// interface compatibility with DBEmitter. ctx is unused (logging is
// synchronous + non-cancellable). nil error is always returned —
// callers that need fail-closed behaviour MUST wire DBEmitter.
func (e *LogEmitter) Emit(_ context.Context, eventType, actor string, payload map[string]any) error {
	if e == nil {
		return nil
	}
	ts := e.now().UTC().Format(time.RFC3339)
	keys := sortedKeys(payload)
	var b strings.Builder
	b.WriteString("audit eventType=")
	b.WriteString(sanitizeAuditField(eventType))
	b.WriteString(" actor=")
	b.WriteString(sanitizeAuditField(actor))
	b.WriteString(" timestamp=")
	b.WriteString(ts)
	for _, k := range keys {
		b.WriteString(" ")
		b.WriteString(sanitizeAuditField(k))
		b.WriteString("=")
		b.WriteString(sanitizeAuditField(stringify(payload[k])))
	}
	log.Println(b.String())
	return nil
}

// MemoryEmitter captures Emit calls for tests. Events() returns a copy
// of the captured slice so callers can iterate without holding the
// mutex.
type MemoryEmitter struct {
	mu      sync.Mutex
	events  []Event
	now     func() time.Time
	emitErr error
}

// NewMemoryEmitter returns a fresh in-memory emitter. now=nil falls
// back to time.Now.
func NewMemoryEmitter() *MemoryEmitter {
	return &MemoryEmitter{now: time.Now}
}

// SetEmitErr lets tests inject a failure so handler fail-closed paths
// are exercised. nil restores the no-error default.
func (m *MemoryEmitter) SetEmitErr(err error) {
	m.mu.Lock()
	m.emitErr = err
	m.mu.Unlock()
}

// Emit appends a deep-copied Event to the in-memory buffer.
//
// Slice 6 fix-up r1 H3 / DRIFT-006: returns the test-injected error
// (via SetEmitErr) so the handler-level fail-closed path is
// observable. On error the event is still recorded so test
// assertions can verify the handler tried to emit before failing.
func (m *MemoryEmitter) Emit(_ context.Context, eventType, actor string, payload map[string]any) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cpy := make(map[string]any, len(payload))
	for k, v := range payload {
		cpy[k] = v
	}
	now := time.Now
	if m.now != nil {
		now = m.now
	}
	m.events = append(m.events, Event{
		EventType: eventType,
		Actor:     actor,
		Timestamp: now().UTC(),
		Payload:   cpy,
	})
	return m.emitErr
}

// Events returns a copy of the captured slice. Safe to call from any
// goroutine.
func (m *MemoryEmitter) Events() []Event {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Event, len(m.events))
	copy(out, m.events)
	return out
}

// CountByEventType returns the number of events whose EventType matches
// name. Useful test helper.
func (m *MemoryEmitter) CountByEventType(name string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, e := range m.events {
		if e.EventType == name {
			n++
		}
	}
	return n
}

// Reset clears the captured event slice. Tests reuse a single emitter
// across multiple sub-cases via t.Run; Reset prevents bleed-over.
func (m *MemoryEmitter) Reset() {
	m.mu.Lock()
	m.events = nil
	m.mu.Unlock()
}

func sortedKeys(m map[string]any) []string {
	if len(m) == 0 {
		return nil
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// stringify converts a payload value to its grep-friendly string form
// for LogEmitter's k=v line. nil renders as the literal "" (so
// sanitizeAuditField's empty-input short-circuit applies).
func stringify(v any) string {
	if v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case fmt.Stringer:
		return x.String()
	default:
		return fmt.Sprintf("%v", x)
	}
}

// sanitizeAuditField scrubs characters that would break the grep-friendly
// "k=v k=v" log shape. Newlines and quotes collapse to '_'; an "=" inside
// a value would be ambiguous so we replace it too. Empty input stays
// empty.
func sanitizeAuditField(s string) string {
	if s == "" {
		return ""
	}
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch r {
		case '\n', '\r', '"', '=':
			b.WriteRune('_')
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}
