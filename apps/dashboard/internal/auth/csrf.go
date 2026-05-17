package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net/http"
)

// CSRFCookieName carries the double-submit token. It is NOT HttpOnly because
// Slice 1 has no client-side JS that needs to read it; the cookie is rendered
// into form fields server-side. Future slices with client JS may need to read
// it via document.cookie.
const CSRFCookieName = "lucairn_dash_csrf"

// CSRFFormField is the hidden form input name that mirrors the cookie value.
const CSRFFormField = "csrf"

// ErrCSRFMismatch is the cause when the double-submit values disagree.
var ErrCSRFMismatch = errors.New("csrf token mismatch")

// IssueToken writes a fresh CSRF token to a cookie and returns the value.
// Idempotent on a single request — if a token cookie already exists and looks
// well-formed, it is reused.
func IssueToken(w http.ResponseWriter, r *http.Request) (string, error) {
	if c, err := r.Cookie(CSRFCookieName); err == nil && len(c.Value) >= 24 {
		return c.Value, nil
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	tok := base64.RawURLEncoding.EncodeToString(buf)
	// CSRF cookie lifetime is intentionally aligned with the SESSION
	// lifetime, not pinned to a wall-clock 8h expiry. Setting MaxAge: 0
	// (and omitting Expires) makes this a session cookie — it lives as
	// long as the browser session, matching the sliding-expiry session
	// cookie. Previously the CSRF cookie's absolute 8h Expires could
	// outlive the (sliding) session cookie, leaving a window where a
	// stale CSRF token was accepted against a freshly-rotated session.
	http.SetCookie(w, &http.Cookie{
		Name:     CSRFCookieName,
		Value:    tok,
		Path:     "/",
		HttpOnly: false,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   0,
	})
	return tok, nil
}

// VerifyToken compares the cookie + form values in constant time. Returns nil
// on success, ErrCSRFMismatch on any disagreement.
func VerifyToken(r *http.Request) error {
	c, err := r.Cookie(CSRFCookieName)
	if err != nil || c.Value == "" {
		return ErrCSRFMismatch
	}
	supplied := r.FormValue(CSRFFormField)
	if supplied == "" {
		return ErrCSRFMismatch
	}
	if subtle.ConstantTimeCompare([]byte(c.Value), []byte(supplied)) != 1 {
		return ErrCSRFMismatch
	}
	return nil
}
