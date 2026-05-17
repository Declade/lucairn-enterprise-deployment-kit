package auth

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"sync"
	"time"
)

// SessionCookieName is the cookie that carries the session identifier.
// HttpOnly + Secure + SameSite=Lax + Path=/.
const SessionCookieName = "lucairn_dash_sess"

// SessionStore persists session records. Slice 1 ships an in-memory
// implementation; later slices may swap to SQLite without changing callers.
type SessionStore interface {
	Create(user User) (*Session, error)
	Get(id string) (*Session, bool)
	Touch(id string) bool
	Delete(id string)
}

// Session captures an authenticated session.
type Session struct {
	ID        string
	User      User
	CreatedAt time.Time
	LastSeen  time.Time
}

// MemorySessionStore keeps sessions in a process-local map. Cleared on
// restart; that is acceptable because Slice 1 has no persistence path and
// later slices replace this with a DB-backed implementation.
type MemorySessionStore struct {
	mu          sync.RWMutex
	entries     map[string]*Session
	idleTimeout time.Duration
	gcInterval  time.Duration
	stop        chan struct{}
	stopOnce    sync.Once
	now         func() time.Time
}

// NewMemorySessionStore builds an in-memory store with the supplied idle
// timeout (sliding) and GC interval. A goroutine evicts expired sessions
// on the GC interval.
func NewMemorySessionStore(idleTimeout, gcInterval time.Duration) *MemorySessionStore {
	s := &MemorySessionStore{
		entries:     make(map[string]*Session),
		idleTimeout: idleTimeout,
		gcInterval:  gcInterval,
		stop:        make(chan struct{}),
		now:         time.Now,
	}
	go s.gcLoop()
	return s
}

// Close stops the GC goroutine. Safe to call multiple times.
func (s *MemorySessionStore) Close() {
	s.stopOnce.Do(func() {
		close(s.stop)
	})
}

// Create issues a new session identifier and stores the record.
func (s *MemorySessionStore) Create(user User) (*Session, error) {
	id, err := generateSessionID()
	if err != nil {
		return nil, err
	}
	now := s.now()
	sess := &Session{
		ID:        id,
		User:      user,
		CreatedAt: now,
		LastSeen:  now,
	}
	s.mu.Lock()
	s.entries[id] = sess
	s.mu.Unlock()
	return sess, nil
}

// Get returns the session if it exists AND has not expired.
func (s *MemorySessionStore) Get(id string) (*Session, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.entries[id]
	if !ok {
		return nil, false
	}
	if s.now().Sub(sess.LastSeen) > s.idleTimeout {
		return nil, false
	}
	return sess, true
}

// Touch refreshes the LastSeen timestamp. Returns true if the session existed
// and was refreshed.
func (s *MemorySessionStore) Touch(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.entries[id]
	if !ok {
		return false
	}
	if s.now().Sub(sess.LastSeen) > s.idleTimeout {
		delete(s.entries, id)
		return false
	}
	sess.LastSeen = s.now()
	return true
}

// Delete removes a session by id.
func (s *MemorySessionStore) Delete(id string) {
	s.mu.Lock()
	delete(s.entries, id)
	s.mu.Unlock()
}

func (s *MemorySessionStore) gcLoop() {
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

func (s *MemorySessionStore) collect() {
	cutoff := s.now().Add(-s.idleTimeout)
	s.mu.Lock()
	for id, sess := range s.entries {
		if sess.LastSeen.Before(cutoff) {
			delete(s.entries, id)
		}
	}
	s.mu.Unlock()
}

// generateSessionID returns 32 random bytes encoded as URL-safe base64 (no
// padding). 256 bits of entropy is more than sufficient.
func generateSessionID() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// SetSessionCookie writes the locked cookie attributes for a fresh session.
func SetSessionCookie(w http.ResponseWriter, id string, maxAge time.Duration) {
	http.SetCookie(w, &http.Cookie{
		Name:     SessionCookieName,
		Value:    id,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(maxAge.Seconds()),
	})
}

// ClearSessionCookie expires the session cookie on logout.
func ClearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     SessionCookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   -1,
	})
}

// CurrentSession returns the active session bound to the request, if any.
func CurrentSession(r *http.Request) (*Session, bool) {
	sess, ok := r.Context().Value(sessionContextKey{}).(*Session)
	if !ok || sess == nil {
		return nil, false
	}
	return sess, true
}

// CurrentUser returns the authenticated user, if any.
func CurrentUser(r *http.Request) (User, bool) {
	sess, ok := CurrentSession(r)
	if !ok {
		return User{}, false
	}
	return sess.User, true
}

// withSession returns a request whose context carries the supplied session.
func withSession(r *http.Request, sess *Session) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), sessionContextKey{}, sess))
}

type sessionContextKey struct{}

// ErrNoSessionCookie is returned by helpers that probe the cookie path.
var ErrNoSessionCookie = errors.New("no session cookie")
