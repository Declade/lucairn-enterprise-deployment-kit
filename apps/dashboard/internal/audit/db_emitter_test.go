// Slice 6 fix-up r1 H3 / DRIFT-006 DBEmitter unit tests.
//
// These verify the canonical-payload + hash + UUID minting paths
// without dialing a real Postgres. The real-Postgres INSERT path is
// reserved for the integration smoke harness (when DOCTOR_OFFLINE=0
// and a live audit DB is reachable).

package audit

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestMarshalCanonicalPayload_Empty(t *testing.T) {
	t.Parallel()
	got, err := marshalCanonicalPayload(nil)
	if err != nil {
		t.Fatalf("marshal nil: %v", err)
	}
	if string(got) != "{}" {
		t.Errorf("nil payload: got %q want {}", got)
	}
	got, err = marshalCanonicalPayload(map[string]any{})
	if err != nil {
		t.Fatalf("marshal empty map: %v", err)
	}
	if string(got) != "{}" {
		t.Errorf("empty map: got %q want {}", got)
	}
}

func TestMarshalCanonicalPayload_SortsKeys(t *testing.T) {
	t.Parallel()
	// Same payload, different map iteration orders MUST produce
	// byte-identical JSON. We can't force iteration order so we just
	// check the result starts with the alphabetically-first key.
	payload := map[string]any{
		"zeta":    "z",
		"alpha":   "a",
		"middle":  "m",
		"numeric": 42,
	}
	got, err := marshalCanonicalPayload(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	gotStr := string(got)
	if !strings.HasPrefix(gotStr, `{"alpha":"a"`) {
		t.Errorf("canonical payload should start with alphabetically-first key alpha; got %s", gotStr)
	}
	if !strings.HasSuffix(gotStr, `"zeta":"z"}`) {
		t.Errorf("canonical payload should end with alphabetically-last key zeta; got %s", gotStr)
	}
	// Round-trip back to a map to verify all values survived.
	var rt map[string]any
	if err := json.Unmarshal(got, &rt); err != nil {
		t.Fatalf("round-trip: %v", err)
	}
	if rt["numeric"].(float64) != 42 {
		t.Errorf("numeric value lost: got %v", rt["numeric"])
	}
}

func TestNewEventID_ShapeIsUUIDv4(t *testing.T) {
	t.Parallel()
	id, err := newEventID()
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	// 8-4-4-4-12 hex shape.
	parts := strings.Split(id, "-")
	if len(parts) != 5 {
		t.Fatalf("UUID parts: got %d want 5 in %s", len(parts), id)
	}
	if len(parts[0]) != 8 || len(parts[1]) != 4 || len(parts[2]) != 4 || len(parts[3]) != 4 || len(parts[4]) != 12 {
		t.Errorf("UUID part lengths: %v", parts)
	}
	// Version nibble (3rd group, 1st hex digit) is 4 for v4.
	if parts[2][0] != '4' {
		t.Errorf("UUID version nibble: got %c want 4 (id=%s)", parts[2][0], id)
	}
	// Variant bits (4th group, 1st hex digit) is 8/9/a/b.
	switch parts[3][0] {
	case '8', '9', 'a', 'b':
		// ok
	default:
		t.Errorf("UUID variant nibble: got %c (id=%s)", parts[3][0], id)
	}
}

func TestNewEventID_Uniqueness(t *testing.T) {
	t.Parallel()
	seen := make(map[string]struct{}, 1000)
	for i := 0; i < 1000; i++ {
		id, err := newEventID()
		if err != nil {
			t.Fatalf("mint %d: %v", i, err)
		}
		if _, dup := seen[id]; dup {
			t.Fatalf("UUID collision at i=%d: %s", i, id)
		}
		seen[id] = struct{}{}
	}
}

func TestHashEvent_DeterministicForSameInputs(t *testing.T) {
	t.Parallel()
	ts := time.Date(2026, 5, 21, 12, 30, 0, 0, time.UTC)
	payload := []byte(`{"k":"v"}`)
	h1 := hashEvent("eid", "et", "svc", "actor", ts, payload)
	h2 := hashEvent("eid", "et", "svc", "actor", ts, payload)
	if h1 != h2 {
		t.Errorf("hash non-deterministic: %s != %s", h1, h2)
	}
	// SHA-256 hex is 64 chars.
	if len(h1) != 64 {
		t.Errorf("hash length: got %d want 64", len(h1))
	}
}

func TestHashEvent_ChangesOnAnyFieldChange(t *testing.T) {
	t.Parallel()
	ts := time.Date(2026, 5, 21, 12, 30, 0, 0, time.UTC)
	base := hashEvent("eid", "et", "svc", "actor", ts, []byte(`{"k":"v"}`))
	cases := []struct {
		name string
		h    string
	}{
		{"event_id", hashEvent("eid-2", "et", "svc", "actor", ts, []byte(`{"k":"v"}`))},
		{"event_type", hashEvent("eid", "et-2", "svc", "actor", ts, []byte(`{"k":"v"}`))},
		{"source", hashEvent("eid", "et", "svc-2", "actor", ts, []byte(`{"k":"v"}`))},
		{"actor", hashEvent("eid", "et", "svc", "actor-2", ts, []byte(`{"k":"v"}`))},
		{"timestamp", hashEvent("eid", "et", "svc", "actor", ts.Add(time.Second), []byte(`{"k":"v"}`))},
		{"payload", hashEvent("eid", "et", "svc", "actor", ts, []byte(`{"k":"v-2"}`))},
	}
	for _, c := range cases {
		if c.h == base {
			t.Errorf("hash collision when %s changed: %s == %s", c.name, c.h, base)
		}
	}
}

func TestNewDBEmitter_DefaultsServiceWhenEmpty(t *testing.T) {
	t.Parallel()
	em := NewDBEmitter(nil, "")
	if em.service != "lucairn-dashboard" {
		t.Errorf("default service: got %q want lucairn-dashboard", em.service)
	}
}

func TestDBEmitter_RejectsNilPool(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	var em *DBEmitter // nil
	err := em.Emit(ctx, "et", "actor", nil)
	if err == nil {
		t.Errorf("nil DBEmitter should error")
	}
	em2 := NewDBEmitter(nil, "svc")
	err = em2.Emit(ctx, "et", "actor", nil)
	if err == nil || !strings.Contains(err.Error(), "DBEmitter not configured") {
		t.Errorf("nil pool: got err=%v", err)
	}
}
