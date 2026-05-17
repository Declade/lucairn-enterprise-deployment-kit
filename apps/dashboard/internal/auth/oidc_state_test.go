package auth

import (
	"sync"
	"testing"
	"time"
)

func TestOIDCStateStore_CreateConsume(t *testing.T) {
	s := NewMemoryOIDCStateStore(time.Hour, time.Hour)
	defer s.Close()

	rec, err := s.Create("/dashboard")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if rec.State == "" {
		t.Fatalf("state token empty")
	}
	if rec.CodeVerifier == "" {
		t.Fatalf("code verifier empty")
	}
	if rec.Nonce == "" {
		t.Fatalf("nonce empty (OpenID Core §3.1.2.1 requires the flow to mint one)")
	}
	if rec.Nonce == rec.State || rec.Nonce == rec.CodeVerifier {
		t.Errorf("nonce must be independent of state/verifier; got nonce=%q state=%q verifier=%q",
			rec.Nonce, rec.State, rec.CodeVerifier)
	}
	if rec.NextPath != "/dashboard" {
		t.Errorf("next path = %q want /dashboard", rec.NextPath)
	}

	got, ok := s.Consume(rec.State)
	if !ok {
		t.Fatalf("Consume: expected hit on freshly minted state")
	}
	if got.CodeVerifier != rec.CodeVerifier {
		t.Errorf("verifier round-trip mismatch")
	}
	if got.Nonce != rec.Nonce {
		t.Errorf("nonce round-trip mismatch: got %q want %q", got.Nonce, rec.Nonce)
	}

	// Second consume MUST miss — one-shot semantics close the replay window.
	_, ok = s.Consume(rec.State)
	if ok {
		t.Errorf("Consume: expected miss on replay")
	}
}

func TestOIDCStateStore_UnknownState(t *testing.T) {
	s := NewMemoryOIDCStateStore(time.Hour, time.Hour)
	defer s.Close()
	if _, ok := s.Consume("not-a-real-state-value"); ok {
		t.Errorf("Consume: expected miss on unknown state")
	}
}

func TestOIDCStateStore_Expired(t *testing.T) {
	s := NewMemoryOIDCStateStore(time.Minute, time.Hour)
	defer s.Close()

	base := time.Now()
	s.now = func() time.Time { return base }

	rec, err := s.Create("/dashboard")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	// Fast-forward past the TTL boundary.
	s.now = func() time.Time { return base.Add(2 * time.Minute) }

	if _, ok := s.Consume(rec.State); ok {
		t.Errorf("Consume: expected miss for expired entry")
	}
}

func TestOIDCStateStore_TokensAreUnique(t *testing.T) {
	s := NewMemoryOIDCStateStore(time.Hour, time.Hour)
	defer s.Close()
	seen := make(map[string]struct{}, 200)
	for i := 0; i < 200; i++ {
		rec, err := s.Create("/x")
		if err != nil {
			t.Fatalf("Create iter %d: %v", i, err)
		}
		if _, dup := seen[rec.State]; dup {
			t.Fatalf("duplicate state token at iter %d: %q", i, rec.State)
		}
		seen[rec.State] = struct{}{}
	}
}

func TestOIDCStateStore_Concurrent(t *testing.T) {
	s := NewMemoryOIDCStateStore(time.Hour, time.Hour)
	defer s.Close()
	const N = 50
	states := make([]string, N)

	var wg sync.WaitGroup
	wg.Add(N)
	for i := 0; i < N; i++ {
		go func(idx int) {
			defer wg.Done()
			rec, err := s.Create("/x")
			if err != nil {
				t.Errorf("Create %d: %v", idx, err)
				return
			}
			states[idx] = rec.State
		}(i)
	}
	wg.Wait()

	// Now Consume in parallel — every state must yield exactly one hit
	// regardless of scheduling.
	hits := make(chan bool, N)
	for _, state := range states {
		go func(s_ string) {
			_, ok := s.Consume(s_)
			hits <- ok
		}(state)
	}
	totalHits := 0
	for i := 0; i < N; i++ {
		if <-hits {
			totalHits++
		}
	}
	if totalHits != N {
		t.Errorf("expected %d hits, got %d", N, totalHits)
	}
}

func TestOIDCStateStore_GCEvicts(t *testing.T) {
	s := NewMemoryOIDCStateStore(time.Minute, 5*time.Millisecond)
	defer s.Close()
	base := time.Now()
	s.now = func() time.Time { return base }
	if _, err := s.Create("/x"); err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return base.Add(2 * time.Minute) }
	// Trigger the GC sweep directly.
	s.collect()
	s.mu.Lock()
	got := len(s.entries)
	s.mu.Unlock()
	if got != 0 {
		t.Errorf("expected GC to evict 1 entry, got %d remaining", got)
	}
}
