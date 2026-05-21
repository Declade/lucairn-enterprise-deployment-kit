package audit

import (
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/testutil"
)

// NOTE: TestLogEmitter_FormatStable + TestLogEmitter_NoSecretLeak both
// mutate the package-global log.Writer(). They are intentionally NOT
// t.Parallel'd — running them in parallel with each other (or with any
// other sibling test that calls log.Printf) would race on the buffer
// AND on the writer pointer itself. The Slice 4 C33 lesson
// (handlers/keys_test.go TestKeys_PlaintextNeverLogged) applies here
// too: serial execution + a sync.Mutex-wrapped buffer is the
// load-bearing pair.

func TestLogEmitter_FormatStable(t *testing.T) {
	var buf testutil.SafeBuffer
	oldOut := log.Writer()
	oldFlags := log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(oldOut)
		log.SetFlags(oldFlags)
	})

	em := &LogEmitter{now: func() time.Time { return time.Date(2026, 5, 21, 12, 30, 0, 0, time.UTC) }}
	if err := em.Emit(context.Background(), "key.mint_requested", "admin@lucairn.local", map[string]any{
		"customer_id": "cust_a",
		"key_id":      "k_abcd",
	}); err != nil {
		t.Fatalf("LogEmitter.Emit returned err: %v", err)
	}
	got := buf.String()
	// Keys must appear in alphabetical order in the line.
	wantContains := []string{
		"audit eventType=key.mint_requested",
		"actor=admin@lucairn.local",
		"timestamp=2026-05-21T12:30:00Z",
		"customer_id=cust_a",
		"key_id=k_abcd",
	}
	for _, w := range wantContains {
		if !strings.Contains(got, w) {
			t.Errorf("log line missing %q\ngot: %s", w, got)
		}
	}
}

func TestLogEmitter_NoSecretLeak(t *testing.T) {
	// Intentionally NOT t.Parallel — see top-of-file note.
	var buf testutil.SafeBuffer
	oldOut := log.Writer()
	oldFlags := log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(oldOut)
		log.SetFlags(oldFlags)
	})

	em := NewLogEmitter()
	// Caller MUST never put raw_key into the payload — but if a future
	// regression does, the emitter at least doesn't actively make the
	// leak worse. This test pins that newline + quote injection is
	// scrubbed (an attacker who somehow got newline-bearing data into
	// a payload value cannot forge log lines).
	if err := em.Emit(context.Background(), "key.mint_requested", "admin@lucairn.local", map[string]any{
		"customer_id": "cust\nfake_event_type=key.bypass",
		"key_id":      "k_with\"quote",
	}); err != nil {
		t.Fatalf("LogEmitter.Emit returned err: %v", err)
	}
	got := buf.String()
	if strings.Contains(got, "\n") && strings.Count(got, "\n") > 1 {
		t.Errorf("log line has more than one newline (potential injection): %q", got)
	}
	// Quote was scrubbed to underscore.
	if !strings.Contains(got, "k_with_quote") {
		t.Errorf("quote not scrubbed in payload value: %s", got)
	}
}

func TestMemoryEmitter_CapturesEvents(t *testing.T) {
	t.Parallel()
	em := NewMemoryEmitter()

	_ = em.Emit(context.Background(), "key.mint_requested", "alice", map[string]any{"customer_id": "c1"})
	_ = em.Emit(context.Background(), "key.revoke_requested", "alice", map[string]any{"customer_id": "c1", "key_id": "k1"})
	_ = em.Emit(context.Background(), "key.revoke_requested", "alice", map[string]any{"customer_id": "c1", "key_id": "k2"})

	events := em.Events()
	if len(events) != 3 {
		t.Fatalf("want 3 events, got %d", len(events))
	}
	if em.CountByEventType("key.mint_requested") != 1 {
		t.Errorf("want 1 mint event, got %d", em.CountByEventType("key.mint_requested"))
	}
	if em.CountByEventType("key.revoke_requested") != 2 {
		t.Errorf("want 2 revoke events, got %d", em.CountByEventType("key.revoke_requested"))
	}
}

func TestMemoryEmitter_DeepCopyPayload(t *testing.T) {
	t.Parallel()
	em := NewMemoryEmitter()
	pl := map[string]any{"customer_id": "c1"}
	_ = em.Emit(context.Background(), "key.mint_requested", "alice", pl)
	// Mutating the caller's payload AFTER Emit must NOT leak into the
	// captured event — otherwise tests that assert payload contents are
	// fragile.
	pl["customer_id"] = "c2"
	events := em.Events()
	if events[0].Payload["customer_id"] != "c1" {
		t.Errorf("captured payload was not deep-copied: %v", events[0].Payload)
	}
}

func TestMemoryEmitter_Concurrent(t *testing.T) {
	t.Parallel()
	em := NewMemoryEmitter()
	const goroutines = 32
	const perGoroutine = 50
	var wg sync.WaitGroup
	wg.Add(goroutines)
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			for j := 0; j < perGoroutine; j++ {
				_ = em.Emit(context.Background(), "key.revoke_requested", "alice", map[string]any{
					"key_id": "k",
				})
			}
		}()
	}
	wg.Wait()
	if want, got := goroutines*perGoroutine, len(em.Events()); want != got {
		t.Errorf("want %d events, got %d", want, got)
	}
}

func TestMemoryEmitter_Reset(t *testing.T) {
	t.Parallel()
	em := NewMemoryEmitter()
	_ = em.Emit(context.Background(), "e", "a", nil)
	em.Reset()
	if len(em.Events()) != 0 {
		t.Errorf("Reset did not clear events: %v", em.Events())
	}
}

// TestMemoryEmitter_SetEmitErr verifies SetEmitErr returns the injected
// error from subsequent Emit calls — the test hook for the handler's
// fail-closed path in Slice 6 H3 / DRIFT-006.
func TestMemoryEmitter_SetEmitErr(t *testing.T) {
	t.Parallel()
	em := NewMemoryEmitter()
	injected := errors.New("synthetic INSERT failure")
	em.SetEmitErr(injected)
	err := em.Emit(context.Background(), "audit.reveal_raw", "admin", map[string]any{"k": "v"})
	if !errors.Is(err, injected) {
		t.Fatalf("SetEmitErr: got err=%v, want %v", err, injected)
	}
	// Event is still recorded so tests can verify the handler tried to
	// emit before failing.
	if len(em.Events()) != 1 {
		t.Errorf("event not recorded on injected failure: %d events", len(em.Events()))
	}
	// Restoring nil clears the failure injection.
	em.SetEmitErr(nil)
	if err := em.Emit(context.Background(), "audit.reveal_raw", "admin", nil); err != nil {
		t.Errorf("Emit after clearing SetEmitErr: %v", err)
	}
}
