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
