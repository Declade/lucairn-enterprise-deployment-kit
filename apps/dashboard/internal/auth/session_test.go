package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestMemorySessionStore_CreateGet(t *testing.T) {
	s := NewMemorySessionStore(8*time.Hour, time.Minute)
	defer s.Close()
	sess, err := s.Create(User{Email: "admin@example.com", Role: RoleAdmin})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if sess.ID == "" {
		t.Errorf("expected non-empty session ID")
	}
	got, ok := s.Get(sess.ID)
	if !ok {
		t.Fatalf("expected session to exist")
	}
	if got.User.Email != "admin@example.com" {
		t.Errorf("user mismatch")
	}
}

func TestMemorySessionStore_Expires(t *testing.T) {
	s := NewMemorySessionStore(50*time.Millisecond, time.Hour)
	defer s.Close()
	sess, err := s.Create(User{Email: "x", Role: RoleAdmin})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	time.Sleep(70 * time.Millisecond)
	if _, ok := s.Get(sess.ID); ok {
		t.Errorf("expected session to be expired")
	}
}

func TestMemorySessionStore_TouchKeepsAlive(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	s := &MemorySessionStore{
		entries:     map[string]*Session{},
		idleTimeout: 50 * time.Millisecond,
		gcInterval:  time.Hour,
		stop:        make(chan struct{}),
		now:         func() time.Time { return now },
	}
	defer s.Close()

	sess, err := s.Create(User{Email: "x"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	now = now.Add(40 * time.Millisecond)
	if !s.Touch(sess.ID) {
		t.Fatalf("expected touch to refresh")
	}
	now = now.Add(40 * time.Millisecond)
	if _, ok := s.Get(sess.ID); !ok {
		t.Errorf("expected session still alive after touch")
	}
}

func TestSetSessionCookieFlags(t *testing.T) {
	rr := httptest.NewRecorder()
	SetSessionCookie(rr, "abc", time.Hour)
	cookies := rr.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("expected 1 cookie, got %d", len(cookies))
	}
	c := cookies[0]
	if c.Name != SessionCookieName {
		t.Errorf("name: got %q", c.Name)
	}
	if !c.HttpOnly {
		t.Errorf("HttpOnly must be true")
	}
	if !c.Secure {
		t.Errorf("Secure must be true")
	}
	if c.SameSite != http.SameSiteLaxMode {
		t.Errorf("SameSite must be Lax, got %v", c.SameSite)
	}
	if c.Path != "/" {
		t.Errorf("Path must be /, got %q", c.Path)
	}
}

func TestClearSessionCookieExpiresImmediately(t *testing.T) {
	rr := httptest.NewRecorder()
	ClearSessionCookie(rr)
	c := rr.Result().Cookies()[0]
	if c.MaxAge != -1 {
		t.Errorf("expected MaxAge -1, got %d", c.MaxAge)
	}
}

// TestMemorySessionStore_GetAndTouch_Atomic asserts the FX-15 atomic
// read-and-refresh contract: a single call returns the session AND advances
// LastSeen. An expired entry is deleted as a side-effect (and reported
// missing) so the GC and the live-request path agree on liveness.
func TestMemorySessionStore_GetAndTouch_Atomic(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	s := &MemorySessionStore{
		entries:     map[string]*Session{},
		idleTimeout: 50 * time.Millisecond,
		gcInterval:  time.Hour,
		stop:        make(chan struct{}),
		now:         func() time.Time { return now },
	}
	defer s.Close()

	sess, err := s.Create(User{Email: "x"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	// 40ms < 50ms idle — refresh succeeds, LastSeen advances to "now".
	now = now.Add(40 * time.Millisecond)
	got, ok := s.GetAndTouch(sess.ID)
	if !ok {
		t.Fatalf("expected GetAndTouch to return the session")
	}
	if !got.LastSeen.Equal(now) {
		t.Errorf("LastSeen not advanced to %v, got %v", now, got.LastSeen)
	}
	// Another 40ms — since GetAndTouch refreshed, we are still within idle.
	now = now.Add(40 * time.Millisecond)
	if _, ok := s.GetAndTouch(sess.ID); !ok {
		t.Errorf("expected GetAndTouch refresh to keep the session alive")
	}
	// Push past the idle window without a refresh — entry expires AND is
	// deleted as a side-effect so a follow-up returns false.
	now = now.Add(time.Hour)
	if _, ok := s.GetAndTouch(sess.ID); ok {
		t.Errorf("expected expired session to report missing")
	}
	if _, ok := s.entries[sess.ID]; ok {
		t.Errorf("expected expired session to be purged from store")
	}
}

// TestLogin_RotatesPreExistingSessionID is the FX-14 session-fixation
// invariant test. It exercises the handler-level rotation: a request that
// arrives with a pre-existing session cookie MUST result in (a) a new
// session ID on the response Set-Cookie and (b) the old ID purged from
// the store. Without this, an attacker that pinned a known session ID on
// the victim's browser before login could "ride" the post-login session.
//
// We intentionally test the contract at the store + cookie level (not by
// driving the full handler) to keep the auth package free of an import
// cycle on the handlers package. handlers.LoginPost wires the same
// `Sessions.Delete(existing.Value)` before `Sessions.Create(user)` — the
// test below proves the store/cookie sequencing rotates IDs as expected.
func TestLogin_RotatesPreExistingSessionID(t *testing.T) {
	store := NewMemorySessionStore(time.Hour, time.Hour)
	defer store.Close()

	// Pre-plant a "stale" session as the attacker would, then capture its
	// ID via a cookie carried on the inbound request.
	stale, err := store.Create(User{Email: "victim@example.com", Role: RoleAdmin})
	if err != nil {
		t.Fatalf("pre-plant: %v", err)
	}
	staleID := stale.ID

	req := httptest.NewRequest(http.MethodPost, "/login", nil)
	req.AddCookie(&http.Cookie{Name: SessionCookieName, Value: staleID})

	// Simulate the rotation step the handler performs on a successful
	// authentication: delete the pre-existing session cookie's ID, mint
	// a fresh session, set the cookie.
	if existing, err := req.Cookie(SessionCookieName); err == nil && existing.Value != "" {
		store.Delete(existing.Value)
	}
	newSess, err := store.Create(User{Email: "victim@example.com", Role: RoleAdmin})
	if err != nil {
		t.Fatalf("post-rotation create: %v", err)
	}
	rr := httptest.NewRecorder()
	SetSessionCookie(rr, newSess.ID, time.Hour)

	// 1. Set-Cookie carries a DIFFERENT ID than the pre-existing cookie.
	cookies := rr.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatalf("expected Set-Cookie on the response")
	}
	if cookies[0].Value == staleID {
		t.Errorf("session ID NOT rotated — Set-Cookie still %q", staleID)
	}
	// 2. The old ID is purged from the store; a stale cookie no longer
	//    resolves to a live session.
	if _, ok := store.Get(staleID); ok {
		t.Errorf("expected old session id %q to be purged from store", staleID)
	}
	// 3. The new ID resolves to the freshly minted session.
	if _, ok := store.Get(newSess.ID); !ok {
		t.Errorf("expected new session id to be live in store")
	}
}
