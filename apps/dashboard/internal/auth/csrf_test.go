package auth

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestCSRF_IssueAndVerify(t *testing.T) {
	rr := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/login", nil)
	tok, err := IssueToken(rr, r)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if tok == "" {
		t.Fatalf("expected non-empty token")
	}
	cookies := rr.Result().Cookies()
	var csrfCookie *http.Cookie
	for _, c := range cookies {
		if c.Name == CSRFCookieName {
			csrfCookie = c
		}
	}
	if csrfCookie == nil {
		t.Fatalf("CSRF cookie not set")
	}

	body := url.Values{CSRFFormField: {tok}}
	post := httptest.NewRequest("POST", "/login", strings.NewReader(body.Encode()))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	post.AddCookie(csrfCookie)
	if err := VerifyToken(post); err != nil {
		t.Errorf("verify: %v", err)
	}
}

func TestCSRF_RejectsMismatch(t *testing.T) {
	rr := httptest.NewRecorder()
	r := httptest.NewRequest("GET", "/login", nil)
	_, err := IssueToken(rr, r)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	csrfCookie := rr.Result().Cookies()[0]

	body := url.Values{CSRFFormField: {"not-the-same-token-value-xxxx"}}
	post := httptest.NewRequest("POST", "/login", strings.NewReader(body.Encode()))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	post.AddCookie(csrfCookie)
	if err := VerifyToken(post); err == nil {
		t.Errorf("expected mismatch error")
	}
}

func TestCSRF_RejectsMissingCookie(t *testing.T) {
	body := url.Values{CSRFFormField: {"some-value"}}
	post := httptest.NewRequest("POST", "/login", strings.NewReader(body.Encode()))
	post.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if err := VerifyToken(post); err == nil {
		t.Errorf("expected error when cookie missing")
	}
}
