package grafana

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// fixedNow returns a stable time.Time so iat/exp claims are byte-stable
// across test runs.
func fixedNow(t *testing.T) func() time.Time {
	t.Helper()
	frozen, err := time.Parse(time.RFC3339, "2026-05-18T12:00:00Z")
	if err != nil {
		t.Fatalf("frozen parse: %v", err)
	}
	return func() time.Time { return frozen }
}

func TestNewSigner_RejectsShortSecret(t *testing.T) {
	t.Parallel()
	cases := []string{"", "short", strings.Repeat("a", MinSecretBytes-1)}
	for _, sec := range cases {
		sec := sec
		t.Run("len_"+itoa(len(sec)), func(t *testing.T) {
			t.Parallel()
			if _, err := NewSigner(sec, 0, nil); err == nil {
				t.Fatalf("expected error for secret len=%d", len(sec))
			}
		})
	}
}

func TestSigner_SignFor_RoundTrip(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	now := fixedNow(t)
	s, err := NewSigner(secret, DefaultTTL, now)
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	token, err := s.SignFor("op@example.com", "Operator One", "Admin")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	got, err := s.Parse(token)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got.Email != "op@example.com" {
		t.Errorf("email: %q", got.Email)
	}
	if got.Name != "Operator One" {
		t.Errorf("name: %q", got.Name)
	}
	if got.Role != "Admin" {
		t.Errorf("role: %q", got.Role)
	}
	if got.Issuer != Issuer {
		t.Errorf("iss: %q want %q", got.Issuer, Issuer)
	}
	if len(got.Audience) != 1 || got.Audience[0] != Audience {
		t.Errorf("aud: %v want [%q]", got.Audience, Audience)
	}
	if got.ID == "" {
		t.Errorf("jti empty — replay-defense weakened")
	}

	// exp = iat + ttl (DefaultTTL == 60s) — pin the field so a future
	// regression that flips the TTL surfaces immediately.
	frozen := now()
	if !got.IssuedAt.Equal(frozen) {
		t.Errorf("iat: %v want %v", got.IssuedAt.Time, frozen)
	}
	if !got.ExpiresAt.Equal(frozen.Add(DefaultTTL)) {
		t.Errorf("exp: %v want %v", got.ExpiresAt.Time, frozen.Add(DefaultTTL))
	}
}

func TestSigner_SignFor_DefaultsRoleViewer(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	s, err := NewSigner(secret, 0, fixedNow(t))
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	token, err := s.SignFor("v@example.com", "", "")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	c, err := s.Parse(token)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if c.Role != "Viewer" {
		t.Errorf("role default: got %q want Viewer", c.Role)
	}
}

func TestSigner_SignFor_RejectsEmptyEmail(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	s, _ := NewSigner(secret, 0, fixedNow(t))
	if _, err := s.SignFor("", "x", "Admin"); err == nil {
		t.Fatalf("expected error on empty email")
	}
}

func TestSigner_Parse_RejectsExpiredToken(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	t0, _ := time.Parse(time.RFC3339, "2026-05-18T12:00:00Z")
	clk := &mutableClock{now: t0}
	s, err := NewSigner(secret, 30*time.Second, clk.Now)
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	token, err := s.SignFor("op@example.com", "Op", "Admin")
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	// Advance the clock past exp.
	clk.advance(2 * time.Minute)
	if _, err := s.Parse(token); err == nil {
		t.Fatalf("expected expired-token rejection")
	}
}

func TestSigner_Parse_RejectsTamperedSignature(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	s, _ := NewSigner(secret, 0, fixedNow(t))
	token, _ := s.SignFor("op@example.com", "Op", "Admin")
	// Flip a byte in the signature segment.
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token has %d segments; want 3", len(parts))
	}
	tampered := parts[0] + "." + parts[1] + ".AAAA" + parts[2][4:]
	if _, err := s.Parse(tampered); err == nil {
		t.Fatalf("tampered signature accepted — HMAC verification weak")
	}
}

func TestSigner_Parse_RejectsWrongSecret(t *testing.T) {
	t.Parallel()
	secretA := strings.Repeat("a", MinSecretBytes)
	secretB := strings.Repeat("b", MinSecretBytes)
	sigA, _ := NewSigner(secretA, 0, fixedNow(t))
	sigB, _ := NewSigner(secretB, 0, fixedNow(t))
	token, _ := sigA.SignFor("op@example.com", "Op", "Admin")
	if _, err := sigB.Parse(token); err == nil {
		t.Fatalf("foreign signer accepted A's token — secrets crossed")
	}
}

func TestSigner_Parse_RejectsAlgNone(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	s, _ := NewSigner(secret, 0, fixedNow(t))

	// Hand-craft an alg=none token with valid claims body but no sig.
	header := map[string]any{"alg": "none", "typ": "JWT"}
	hdrB64 := base64Url(jsonMust(t, header))
	claims := map[string]any{
		"iss":   Issuer,
		"aud":   Audience,
		"sub":   "op@example.com",
		"email": "op@example.com",
		"exp":   fixedNow(t)().Add(30 * time.Second).Unix(),
		"iat":   fixedNow(t)().Unix(),
		"role":  "Admin",
	}
	clmB64 := base64Url(jsonMust(t, claims))
	noneTok := hdrB64 + "." + clmB64 + "."
	if _, err := s.Parse(noneTok); err == nil {
		t.Fatalf("alg=none accepted — classic JWT confusion attack reachable")
	}
}

func TestSigner_Parse_RejectsRS256AttemptOnHS256Signer(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	s, _ := NewSigner(secret, 0, fixedNow(t))

	// Synthesise a token whose header advertises RS256. jwt.NewWithClaims
	// would require a real RSA key; we only need the parser to reject the
	// alg before getting that far.
	header := map[string]any{"alg": "RS256", "typ": "JWT"}
	hdrB64 := base64Url(jsonMust(t, header))
	claims := map[string]any{
		"iss":   Issuer,
		"aud":   Audience,
		"sub":   "op@example.com",
		"email": "op@example.com",
		"exp":   fixedNow(t)().Add(30 * time.Second).Unix(),
		"iat":   fixedNow(t)().Unix(),
	}
	clmB64 := base64Url(jsonMust(t, claims))
	tok := hdrB64 + "." + clmB64 + ".AAAA"
	if _, err := s.Parse(tok); err == nil {
		t.Fatalf("RS256-header token accepted on HS256 signer")
	}
}

func TestSigner_HeaderAdvertisesHS256(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", MinSecretBytes)
	s, _ := NewSigner(secret, 0, fixedNow(t))
	token, _ := s.SignFor("op@example.com", "Op", "Admin")
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token has %d segments; want 3", len(parts))
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("decode header: %v", err)
	}
	var hdr struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}
	if err := json.Unmarshal(raw, &hdr); err != nil {
		t.Fatalf("unmarshal header: %v", err)
	}
	if hdr.Alg != "HS256" {
		t.Errorf("alg in header: %q want HS256", hdr.Alg)
	}
}

// helpers.

type mutableClock struct{ now time.Time }

func (m *mutableClock) Now() time.Time          { return m.now }
func (m *mutableClock) advance(d time.Duration) { m.now = m.now.Add(d) }
func jsonMust(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("json marshal: %v", err)
	}
	return b
}
func base64Url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
func itoa(i int) string {
	// avoid pulling strconv into the test header for a single helper
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	out := ""
	for i > 0 {
		out = string(rune('0'+i%10)) + out
		i /= 10
	}
	if neg {
		out = "-" + out
	}
	return out
}

// Ensure jwt/v5 package is imported even if SigningMethodHS256 reference
// would otherwise be unused after rewrites.
var _ = jwt.SigningMethodHS256
