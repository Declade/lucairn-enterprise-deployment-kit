// Package grafana mints short-lived JWTs the dashboard hands to embedded
// Grafana panels via the standard `auth_token` URL-query parameter.
//
// Architecture (locked in PR #24 / Slice 4):
//
//   - Algorithm HS256 with shared secret. The same Secret is mounted in
//     BOTH the dashboard (read at startup) AND the Grafana pod (set as
//     [auth.jwt].key_file). Helm template generates the Secret once via
//     the `lookup` pattern so `helm upgrade` does not rotate it
//     accidentally (Slice 1 pattern, see secret-bootstrap-admin.yaml).
//
//   - TTL: 60 seconds. The dashboard signs a fresh JWT per iframe-render
//     request; tokens are not cached between requests. The iframe in
//     the side drawer carries a single-use token; if the operator
//     leaves the drawer open for >60s, a hard refresh of the page mints
//     a new one.
//
//   - Delivery: `auth_token` URL query parameter on the Grafana panel URL.
//     The pre-Slice-4 spec discussed URL-fragment delivery — empirically
//     Grafana 11+ does NOT support fragment-based JWT lookup; the
//     documented mechanism is `[auth.jwt].url_login = true` + the
//     `auth_token` query param (see Grafana docs:
//     https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/jwt/).
//
//   - Leak surface (documented design choices, not security gaps):
//     1) The iframe element carries `referrerpolicy="no-referrer"` so
//     the dashboard → Grafana first-request URL (which contains the
//     token in the query string) does NOT leak to Grafana via the
//     `Referer` header. This closes the FIRST request's leak vector.
//     2) Subresources loaded INSIDE the Grafana iframe (panel data
//     fetches, dashboards, plugins) use Grafana's own
//     Referrer-Policy header — typically `strict-origin-when-cross-origin`.
//     Customer Grafana installs that override this header to a more
//     permissive value can leak the token to third-party origins
//     referenced inside the panel. Audit your Grafana's
//     Referrer-Policy if your panels embed third-party content.
//     3) Browser DevTools (Network tab) WILL show the JWT in the iframe
//     `src=`. This is unavoidable for any URL-bearing auth scheme.
//     Users with the DevTools open already have role-based access to
//     the same panel via the dashboard's own auth; we are not
//     creating a new exposure beyond what they could already see.
//     4) The 60-second TTL is the DOMINANT defense. Any token captured
//     from the query string or DevTools expires before it can be
//     replayed in a meaningful attack window. Rotation cadence on
//     the shared HMAC secret (see OPS.md) closes the long-tail
//     window for compromised secrets.
//     5) The dashboard itself never logs the token, never appends it
//     to outbound links, and clears it from the DOM when the drawer
//     closes (Alpine.js `iframeSrc = ”` reset).
//
//   - Claims: standard registered claims (iss, sub, aud, exp, iat, jti) +
//     `email` + `name` + `role`. Grafana is configured with
//     [auth.jwt].email_claim = email so each dashboard user shows up in
//     Grafana's audit log under their dashboard email (no shared
//     anonymous identity).
//
//   - Algorithm pinning: the verifier rejects any token whose header alg
//     is NOT HS256 (defense against the classic `alg: none` confusion
//     attack). The signer never emits any other alg.
package grafana

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	// DefaultTTL is the per-render JWT lifetime. Tuned in PRD § Slice 4.
	DefaultTTL = 60 * time.Second

	// Issuer is locked across releases; Grafana's [auth.jwt].expect_claims
	// is configured to enforce this value, so changing it requires a
	// coordinated update of both sides.
	Issuer = "lucairn-dashboard"

	// Audience is the value Grafana's expect_claims should pin. Grafana's
	// JWT validator does not pre-validate `aud` natively, but the
	// expect_claims map can enforce it.
	Audience = "grafana"
)

// MinSecretBytes is the floor on shared-secret length. 32 bytes = 256
// bits HMAC key strength. The Helm template generates 48 alphanumeric
// chars (~36 bytes of entropy) which satisfies this.
const MinSecretBytes = 32

// Claims is the dashboard's Grafana JWT shape. Mirrors the registered
// JWT claims + the small set of name/email/role fields Grafana reads.
type Claims struct {
	jwt.RegisteredClaims
	Email string `json:"email"`
	Name  string `json:"name"`
	Role  string `json:"role"`
}

// Signer produces short-lived HS256 tokens against a fixed shared secret.
//
// The signer keeps a single secret in memory; rotation requires a
// dashboard restart (the same Secret is mounted via valueFrom.secretKeyRef
// so a `kubectl rollout restart` is the standard rotation step). Bouncing
// the dashboard alone is sufficient because tokens are 60s lifetime —
// any token in flight at rotation time expires before the new secret
// activates on the Grafana side, even if the operator restarts the two
// pods in the wrong order.
type Signer struct {
	secret []byte
	now    func() time.Time
	ttl    time.Duration
}

// NewSigner constructs a Signer over the supplied shared secret.
//
// secret MUST be >= MinSecretBytes after trimming. Empty / short secrets
// return an error so the dashboard fails-closed at boot rather than
// silently signing tokens nobody can verify.
//
// `now` is injected for tests so iat/exp claims are deterministic.
// `ttl` defaults to DefaultTTL when zero.
func NewSigner(secret string, ttl time.Duration, now func() time.Time) (*Signer, error) {
	s := strings.TrimSpace(secret)
	if len(s) < MinSecretBytes {
		return nil, fmt.Errorf("grafana: shared secret too short (got %d bytes, need >= %d)", len(s), MinSecretBytes)
	}
	if now == nil {
		now = time.Now
	}
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	return &Signer{secret: []byte(s), now: now, ttl: ttl}, nil
}

// SignFor builds a fresh JWT for the supplied user identity. The JWT
// carries iss/aud/iat/exp + email + name + role; nbf is set equal to iat
// so the token is valid immediately.
//
// jti is a fresh random 16-byte hex string per call to defeat JTI replay
// across the 60s window — if Grafana enables nbf/jti tracking in a
// future config the dashboard already supplies unique values.
func (s *Signer) SignFor(email, name, role string) (string, error) {
	email = strings.TrimSpace(email)
	if email == "" {
		return "", errors.New("grafana: email is required")
	}
	if role == "" {
		role = "Viewer"
	}
	now := s.now()
	jti, err := randomHex(16)
	if err != nil {
		return "", fmt.Errorf("grafana: jti gen: %w", err)
	}
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    Issuer,
			Audience:  jwt.ClaimStrings{Audience},
			Subject:   email,
			ID:        jti,
			IssuedAt:  jwt.NewNumericDate(now),
			NotBefore: jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(s.ttl)),
		},
		Email: email,
		Name:  name,
		Role:  role,
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString(s.secret)
	if err != nil {
		return "", fmt.Errorf("grafana: sign: %w", err)
	}
	return signed, nil
}

// Parse verifies a token string against this signer's secret. Used by
// tests + (potentially in future) by an introspection endpoint. Algorithm
// is pinned to HS256 — any token whose header alg differs (incl. alg=none)
// is rejected.
//
// Parse uses the signer's `now` clock for nbf/iat/exp validation. In
// production `now` is time.Now so behavior matches the reference clock.
// In tests, a frozen clock keeps sign + parse byte-stable; a mutable
// clock lets expiration tests advance past exp deterministically.
func (s *Signer) Parse(tokenStr string) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (any, error) {
		if t.Method.Alg() != jwt.SigningMethodHS256.Alg() {
			return nil, fmt.Errorf("grafana: unexpected alg %q", t.Method.Alg())
		}
		return s.secret, nil
	},
		// jwt/v5 default-validates exp/nbf/iat when present; expose the
		// validation knobs explicitly so any future opts (audience pin,
		// issuer pin) are straightforward to wire in here.
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithTimeFunc(s.now),
	)
	if err != nil {
		return nil, err
	}
	if !token.Valid {
		return nil, errors.New("grafana: token marked invalid by parser")
	}
	return claims, nil
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
