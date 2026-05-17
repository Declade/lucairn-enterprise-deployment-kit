package auth

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
	"time"
)

// OIDCStateTTL is the maximum age of a pending OIDC authorization flow.
// The IdP redirect-back has to land within this window or the state is
// considered stale and the callback rejected. 10 minutes is the OAuth2
// recommendation and matches what most OIDC providers expect.
const OIDCStateTTL = 10 * time.Minute

// OIDCFlowState captures one in-flight authorization request. The state
// token is the map key; PKCE verifier + post-login redirect target travel
// with it so the callback handler has everything it needs in a single
// lookup.
//
// Storing the PKCE verifier server-side is critical: PKCE only defends
// against authorization-code interception if the verifier never touches
// the user agent. Cookie-based PKCE storage defeats the whole mechanism.
//
// Nonce is the OpenID Connect Core §3.1.2.1 / §3.1.3.7 ID-Token nonce.
// Like the PKCE verifier it lives server-side; the auth-code flow embeds
// it as the `nonce` query parameter on the authorize URL, and the
// callback handler asserts the returned ID token's `nonce` claim matches
// the value we minted at flow start. This closes the ID-token replay
// window an attacker would otherwise have if they intercepted a victim's
// token in a different session.
type OIDCFlowState struct {
	State        string
	Nonce        string
	CodeVerifier string
	NextPath     string
	CreatedAt    time.Time
}

// OIDCStateStore persists short-lived OIDC authorization-flow records.
// In-memory in Slice 2; the interface lets later slices swap a DB-backed
// implementation without touching callers.
type OIDCStateStore interface {
	Create(nextPath string) (*OIDCFlowState, error)
	Consume(state string) (*OIDCFlowState, bool)
}

// MemoryOIDCStateStore mirrors MemorySessionStore in structure: a single
// sync.Mutex, a GC goroutine on a configurable interval, deterministic
// expiry based on a now() func injectable from tests.
//
// Consume is one-shot — the entry is deleted on the first successful
// lookup so a leaked state token cannot be replayed against a second
// callback. Replay protection is a CSRF-class defense; rolling it into
// the lookup itself closes the obvious double-spend race.
type MemoryOIDCStateStore struct {
	mu         sync.Mutex
	entries    map[string]*OIDCFlowState
	ttl        time.Duration
	gcInterval time.Duration
	stop       chan struct{}
	stopOnce   sync.Once
	now        func() time.Time
}

// NewMemoryOIDCStateStore builds an in-memory store with the supplied TTL
// (per-entry maximum age) and GC interval. A goroutine evicts expired
// entries on the GC interval; the store is Close-safe and idempotent.
func NewMemoryOIDCStateStore(ttl, gcInterval time.Duration) *MemoryOIDCStateStore {
	s := &MemoryOIDCStateStore{
		entries:    make(map[string]*OIDCFlowState),
		ttl:        ttl,
		gcInterval: gcInterval,
		stop:       make(chan struct{}),
		now:        time.Now,
	}
	go s.gcLoop()
	return s
}

// Close stops the GC goroutine. Safe to call multiple times.
func (s *MemoryOIDCStateStore) Close() {
	s.stopOnce.Do(func() {
		close(s.stop)
	})
}

// Create mints a fresh state token + PKCE verifier and stores them with
// the post-login next= path. Returns the populated record so the handler
// can hand the state value off to the IdP redirect.
//
// The state token MUST come from crypto/rand (256 bits encoded as
// base64-url without padding). The PKCE verifier shares the same source
// — RFC 7636 mandates 43-128 chars of unreserved-character entropy, and
// 32 random bytes → 43 base64-url chars satisfies that minimum.
func (s *MemoryOIDCStateStore) Create(nextPath string) (*OIDCFlowState, error) {
	state, err := generateOIDCToken()
	if err != nil {
		return nil, err
	}
	verifier, err := generateOIDCToken()
	if err != nil {
		return nil, err
	}
	// Nonce uses the same 32-byte / 256-bit generator as state + verifier.
	// OpenID Core §15.5.2 only requires the nonce be unguessable and bound
	// to the session; reusing the helper keeps entropy uniform.
	nonce, err := generateOIDCToken()
	if err != nil {
		return nil, err
	}
	rec := &OIDCFlowState{
		State:        state,
		Nonce:        nonce,
		CodeVerifier: verifier,
		NextPath:     nextPath,
		CreatedAt:    s.now(),
	}
	s.mu.Lock()
	s.entries[state] = rec
	s.mu.Unlock()
	return rec, nil
}

// Consume looks up + atomically deletes a state record. Returns false if
// the state is unknown OR if it has aged out beyond the configured TTL.
// One-shot semantics close the replay-attack window.
func (s *MemoryOIDCStateStore) Consume(state string) (*OIDCFlowState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.entries[state]
	if !ok {
		return nil, false
	}
	delete(s.entries, state)
	if s.now().Sub(rec.CreatedAt) > s.ttl {
		return nil, false
	}
	return rec, true
}

func (s *MemoryOIDCStateStore) gcLoop() {
	ticker := time.NewTicker(s.gcInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
			s.collect()
		}
	}
}

func (s *MemoryOIDCStateStore) collect() {
	cutoff := s.now().Add(-s.ttl)
	s.mu.Lock()
	for k, rec := range s.entries {
		if rec.CreatedAt.Before(cutoff) {
			delete(s.entries, k)
		}
	}
	s.mu.Unlock()
}

// generateOIDCToken returns 32 random bytes encoded as URL-safe base64
// without padding. 256 bits of entropy.
func generateOIDCToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
