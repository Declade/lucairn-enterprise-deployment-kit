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
// Two implementations ship:
//
//   - LogEmitter — the default. Writes one structured log line per emit
//     via the standard log package. Matches Slice 3's
//     `log.Printf("cert.verify_requested ...")` convention so operators
//     parsing pod logs see all audit-worthy events in the same place.
//
//   - MemoryEmitter — capture buffer for tests. Each Emit appends a copy
//     of the event to an in-memory slice protected by a mutex. Tests
//     assert against Events() to verify a handler emitted the right
//     event names with the right payloads.
//
// NEVER include secret material (raw key bytes, admin token, password
// values) in event payloads. The MintHandler / RevokeHandler MUST log
// metadata (customer_id, key_id, key_prefix, redactedSensitive(...))
// only — never raw_key.
package audit

import (
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
// string representation.
type Event struct {
	EventType string
	Actor     string
	Timestamp time.Time
	Payload   map[string]string
}

// Emitter is the contract handlers consume. Implementations MUST be
// concurrency-safe — handlers run inside concurrent HTTP goroutines.
type Emitter interface {
	Emit(eventType, actor string, payload map[string]string)
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
func (e *LogEmitter) Emit(eventType, actor string, payload map[string]string) {
	if e == nil {
		return
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
		b.WriteString(sanitizeAuditField(payload[k]))
	}
	log.Println(b.String())
}

// MemoryEmitter captures Emit calls for tests. Events() returns a copy
// of the captured slice so callers can iterate without holding the
// mutex.
type MemoryEmitter struct {
	mu     sync.Mutex
	events []Event
	now    func() time.Time
}

// NewMemoryEmitter returns a fresh in-memory emitter. now=nil falls
// back to time.Now.
func NewMemoryEmitter() *MemoryEmitter {
	return &MemoryEmitter{now: time.Now}
}

// Emit appends a deep-copied Event to the in-memory buffer.
func (m *MemoryEmitter) Emit(eventType, actor string, payload map[string]string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	cpy := make(map[string]string, len(payload))
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

func sortedKeys(m map[string]string) []string {
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
