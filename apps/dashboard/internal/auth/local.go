// Package auth provides local-admin authentication, server-side session
// storage, role-based access middleware, and CSRF protection for the
// Lucairn Enterprise Dashboard.
package auth

import (
	"crypto/sha256"
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

// Authenticate verifies an email + password pair without leaking which half
// failed and without leaking input lengths.
//
// Timing-side-channel hygiene:
//   - bcrypt.CompareHashAndPassword is itself constant-time over the configured
//     cost — it always hashes the supplied password before comparing, so it
//     runs unconditionally on every call (including unknown-email paths) to
//     prevent username enumeration via response-time correlation.
//   - subtle.ConstantTimeCompare short-circuits on a length mismatch, which
//     would otherwise leak the configured email's length. We defeat that by
//     compressing both sides through SHA-256 to fixed-length 32-byte digests
//     before the compare. Any difference in input length is absorbed by the
//     hash, so the equality compare always operates on equal-length inputs.
//
// The previous implementation wrapped the boolean outcome in another
// subtle.ConstantTimeCompare — this provided no defense against a
// realistic attacker (the `if x != 1` branch leaks the same one bit), so it
// has been removed in favor of an honest, documented, fail-shut path.
func (a *LocalAuthenticator) Authenticate(email, password string) (User, error) {
	suppliedEmailHash := sha256.Sum256([]byte(strings.TrimSpace(strings.ToLower(email))))
	configuredEmailHash := sha256.Sum256([]byte(a.email))
	emailMatch := subtle.ConstantTimeCompare(suppliedEmailHash[:], configuredEmailHash[:]) == 1

	// Run bcrypt unconditionally so unknown-email and wrong-password paths
	// have identical wall-clock cost.
	bcryptErr := bcrypt.CompareHashAndPassword(a.hashedPass, []byte(password))
	passwordMatch := bcryptErr == nil

	if !emailMatch || !passwordMatch {
		return User{}, ErrInvalidCredentials
	}
	return User{Email: a.email, Role: RoleAdmin}, nil
}
