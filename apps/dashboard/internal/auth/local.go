// Package auth provides local-admin authentication, server-side session
// storage, role-based access middleware, and CSRF protection for the
// Lucairn Enterprise Dashboard.
package auth

import (
	"crypto/subtle"
	"errors"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

// Role enumerates the two dashboard roles. Slice 1 ships admin only via the
// bootstrap secret; viewer is enforced in middleware so future slices can mint
// viewer accounts without touching the gate.
type Role string

const (
	RoleAdmin  Role = "admin"
	RoleViewer Role = "viewer"

	// bcryptCost = 12 per PRD § Slice 1 auth tests. Higher costs add latency
	// without measurable security gain at this size.
	bcryptCost = 12
)

// User represents an authenticated identity.
type User struct {
	Email string
	Role  Role
}

// Authenticator verifies a user's credentials. Implementations MUST treat the
// match decision in constant time.
type Authenticator interface {
	Authenticate(email, password string) (User, error)
}

// ErrInvalidCredentials is returned for ALL credential-rejection paths. Never
// leak whether the failure was "unknown email" vs "wrong password".
var ErrInvalidCredentials = errors.New("invalid credentials")

// LocalAuthenticator holds a single bootstrap-admin record. Future slices add
// OIDC + DB-backed users behind the Authenticator interface — this skeleton
// stays untouched.
type LocalAuthenticator struct {
	email      string
	hashedPass []byte
}

// NewLocalAuthenticator builds a LocalAuthenticator with a bcrypt-hashed copy
// of the bootstrap admin password. The plaintext password is never retained.
func NewLocalAuthenticator(email, password string) (*LocalAuthenticator, error) {
	email = strings.TrimSpace(strings.ToLower(email))
	if email == "" {
		return nil, errors.New("bootstrap admin email must not be empty")
	}
	if len(password) < 12 {
		return nil, errors.New("bootstrap admin password must be at least 12 characters")
	}
	hashed, err := bcrypt.GenerateFromPassword([]byte(password), bcryptCost)
	if err != nil {
		return nil, err
	}
	return &LocalAuthenticator{email: email, hashedPass: hashed}, nil
}

// Authenticate verifies an email + password pair in constant time. The match
// boolean is funnelled through subtle.ConstantTimeCompare AFTER bcrypt has
// returned its own constant-time verdict so any subsequent boolean equality
// check is non-leaking. Documented per PRD § Slice 1 brief: bcrypt itself is
// constant-time but the wrapping logic still uses subtle for the 1==1 path.
func (a *LocalAuthenticator) Authenticate(email, password string) (User, error) {
	emailMatch := subtle.ConstantTimeCompare(
		[]byte(strings.TrimSpace(strings.ToLower(email))),
		[]byte(a.email),
	) == 1

	bcryptErr := bcrypt.CompareHashAndPassword(a.hashedPass, []byte(password))
	passwordMatch := bcryptErr == nil

	matched := emailMatch && passwordMatch
	// Constant-time wrap on the boolean outcome. Reduces side-channel surface
	// in callers that subsequently use `match == true`.
	if subtle.ConstantTimeCompare([]byte{boolByte(matched)}, []byte{1}) != 1 {
		return User{}, ErrInvalidCredentials
	}
	return User{Email: a.email, Role: RoleAdmin}, nil
}

func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}
