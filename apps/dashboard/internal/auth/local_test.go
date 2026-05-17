package auth

import (
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestLocalAuthenticator_RoundTrip(t *testing.T) {
	a, err := NewLocalAuthenticator("Admin@Example.com", "correct-horse-battery")
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	user, err := a.Authenticate("admin@example.com", "correct-horse-battery")
	if err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	if user.Role != RoleAdmin {
		t.Errorf("expected role admin, got %q", user.Role)
	}
	if user.Email != "admin@example.com" {
		t.Errorf("expected email admin@example.com, got %q", user.Email)
	}
}

func TestLocalAuthenticator_RejectsWrongPassword(t *testing.T) {
	a, err := NewLocalAuthenticator("admin@example.com", "correct-horse-battery")
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	if _, err := a.Authenticate("admin@example.com", "incorrect-horse-battery"); err == nil {
		t.Fatalf("expected error for wrong password")
	}
}

func TestLocalAuthenticator_RejectsWrongEmail(t *testing.T) {
	a, err := NewLocalAuthenticator("admin@example.com", "correct-horse-battery")
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	if _, err := a.Authenticate("other@example.com", "correct-horse-battery"); err == nil {
		t.Fatalf("expected error for wrong email")
	}
}

func TestLocalAuthenticator_RejectsBlankConfig(t *testing.T) {
	if _, err := NewLocalAuthenticator("", "correct-horse-battery"); err == nil {
		t.Errorf("expected error for empty email")
	}
	if _, err := NewLocalAuthenticator("admin@example.com", "short"); err == nil {
		t.Errorf("expected error for short password")
	}
}

// TestLocalAuthenticator_BcryptCost asserts the cost embedded in the
// resulting hash is exactly 12. Lower costs would silently weaken the gate.
func TestLocalAuthenticator_BcryptCost(t *testing.T) {
	a, err := NewLocalAuthenticator("admin@example.com", "correct-horse-battery")
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	got, err := bcrypt.Cost(a.hashedPass)
	if err != nil {
		t.Fatalf("cost: %v", err)
	}
	if got != bcryptCost {
		t.Errorf("expected bcrypt cost %d, got %d", bcryptCost, got)
	}
}

// TestLocalAuthenticator_NoPlaintextRetention is a documentation-shaped
// assertion: nothing in the LocalAuthenticator struct should contain the
// plaintext password after construction. Today only hashedPass exists, and
// it is a bcrypt blob.
func TestLocalAuthenticator_NoPlaintextRetention(t *testing.T) {
	password := "uniqueliteral-12345"
	a, err := NewLocalAuthenticator("admin@example.com", password)
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	if strings.Contains(string(a.hashedPass), password) {
		t.Errorf("plaintext password leaked into stored hash")
	}
}
