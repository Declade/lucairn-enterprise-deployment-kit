package auth

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

// ErrNeitherGroup is returned when an OIDC-authenticated user lacks BOTH
// the admin group and the viewer group. We do NOT auto-grant viewer to
// arbitrary authenticated users — customers must explicitly authorize an
// identity by adding them to a group, or the dashboard rejects the
// callback. This closes the "everyone in the IdP can browse certs"
// surprise that bites OIDC installs where any directory user implicitly
// inherits a default access claim.
var ErrNeitherGroup = errors.New("user is not a member of the admin or viewer group")

// ErrGroupsClaimMissing is returned when the configured groups claim is
// absent from the ID token. Distinct from ErrNeitherGroup so operators can
// tell "you misconfigured the claim name" from "this user is not in any
// group".
var ErrGroupsClaimMissing = errors.New("groups claim missing from id token")

// ErrInvalidIDToken wraps any signature / audience / issuer / expiry
// failure surfaced by the go-oidc verifier. The handler renders a generic
// flash; the underlying error is audit-logged with its OIDC error code so
// the operator can debug without leaking detail to the browser.
type ErrInvalidIDToken struct {
	Underlying error
}

func (e *ErrInvalidIDToken) Error() string {
	if e.Underlying == nil {
		return "invalid id token"
	}
	return fmt.Sprintf("invalid id token: %v", e.Underlying)
}

func (e *ErrInvalidIDToken) Unwrap() error { return e.Underlying }

// OIDCConfig groups the static configuration the OIDC authenticator
// needs at startup. ClientSecret is sensitive; callers should never log
// it. The struct keeps secret-bearing fields out of the env-var loader's
// concerns by being the only thing the loader hands to the constructor.
type OIDCConfig struct {
	IssuerURL    string
	ClientID     string
	ClientSecret string
	RedirectURL  string
	GroupsClaim  string
	AdminGroup   string
	ViewerGroup  string
	// ExtraScopes lets operators request additional scopes beyond the
	// defaults (openid, profile, email, groups). Empty is the safe default.
	ExtraScopes []string
}

// Validate returns the first OIDCConfig field problem detected, or nil if
// the config is wired correctly. The main binary calls this at startup
// and fails-fast on error so misconfiguration never becomes a runtime
// surprise mid-login.
func (c *OIDCConfig) Validate() error {
	if strings.TrimSpace(c.IssuerURL) == "" {
		return errors.New("oidc: issuer_url is required")
	}
	if _, err := url.Parse(c.IssuerURL); err != nil {
		return fmt.Errorf("oidc: issuer_url parse: %w", err)
	}
	if strings.TrimSpace(c.ClientID) == "" {
		return errors.New("oidc: client_id is required")
	}
	if strings.TrimSpace(c.ClientSecret) == "" {
		return errors.New("oidc: client_secret is required")
	}
	if strings.TrimSpace(c.RedirectURL) == "" {
		return errors.New("oidc: redirect_url is required")
	}
	if _, err := url.Parse(c.RedirectURL); err != nil {
		return fmt.Errorf("oidc: redirect_url parse: %w", err)
	}
	if strings.TrimSpace(c.AdminGroup) == "" {
		return errors.New("oidc: admin_group is required")
	}
	if strings.TrimSpace(c.ViewerGroup) == "" {
		return errors.New("oidc: viewer_group is required")
	}
	return nil
}

// OIDCAuthenticator wraps a go-oidc provider, an oauth2 config, and the
// role-mapping rules in one struct. Constructed once at startup; safe for
// concurrent use because both go-oidc and oauth2 promise it.
type OIDCAuthenticator struct {
	cfg      OIDCConfig
	provider *oidc.Provider
	verifier *oidc.IDTokenVerifier
	oauth2   *oauth2.Config
}

// NewOIDCAuthenticator performs OIDC discovery against the configured
// issuer URL and returns a ready-to-use authenticator. Discovery happens
// at startup — if the IdP is unreachable, the dashboard fails to start
// rather than silently leaving SSO broken. Operators who want
// degraded-but-available behavior should leave OIDC disabled and rely on
// the local-admin path.
func NewOIDCAuthenticator(ctx context.Context, cfg OIDCConfig) (*OIDCAuthenticator, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	provider, err := oidc.NewProvider(ctx, cfg.IssuerURL)
	if err != nil {
		return nil, fmt.Errorf("oidc: discovery against %q: %w", cfg.IssuerURL, err)
	}
	verifier := provider.Verifier(&oidc.Config{ClientID: cfg.ClientID})

	scopes := []string{oidc.ScopeOpenID, "profile", "email"}
	if cfg.GroupsClaim == "" || cfg.GroupsClaim == "groups" {
		// "groups" is the default scope most OIDC providers surface
		// alongside their groups claim. Adding the scope is a no-op for
		// IdPs that don't recognize it.
		scopes = append(scopes, "groups")
	}
	scopes = append(scopes, cfg.ExtraScopes...)

	oauth2Cfg := &oauth2.Config{
		ClientID:     cfg.ClientID,
		ClientSecret: cfg.ClientSecret,
		Endpoint:     provider.Endpoint(),
		RedirectURL:  cfg.RedirectURL,
		Scopes:       scopes,
	}

	return &OIDCAuthenticator{
		cfg:      cfg,
		provider: provider,
		verifier: verifier,
		oauth2:   oauth2Cfg,
	}, nil
}

// LoginURL returns the IdP's authorization endpoint with state + PKCE
// challenge embedded. The handler hands the user agent off via 302.
//
// PKCE is mandatory in Slice 2. RFC 7636 + the OAuth 2.1 draft both
// treat it as required for new deployments, and every OIDC provider
// accepts the S256 method.
//
// Nonce is also mandatory (OpenID Core §3.1.2.1). The minted value
// travels server-side via OIDCStateStore; the callback handler asserts
// the returned ID-token nonce claim matches.
func (a *OIDCAuthenticator) LoginURL(state, nonce, codeVerifier string) string {
	challenge := pkceS256Challenge(codeVerifier)
	return a.oauth2.AuthCodeURL(state,
		oauth2.AccessTypeOnline,
		oauth2.SetAuthURLParam("code_challenge", challenge),
		oauth2.SetAuthURLParam("code_challenge_method", "S256"),
		oauth2.SetAuthURLParam("nonce", nonce),
	)
}

// Exchange completes the authorization-code → ID-token round trip and
// validates the resulting ID token against the issuer's JWKS. On success
// the role is mapped from the configured groups claim and a User is
// returned ready for session minting.
//
// expectedNonce is the nonce minted by OIDCStateStore.Create at flow
// start. The ID-token's `nonce` claim MUST match (OpenID Core §3.1.3.7
// item 11) — if it does not, the exchange fails with ErrInvalidIDToken
// regardless of signature / audience / issuer / expiry validity.
//
// Failure paths are deliberately not differentiated to the caller beyond
// the typed errors — the handler renders a single generic flash so the
// browser cannot infer "wrong audience" vs "expired token". Operators
// get the detail via audit-logged error wrapping.
func (a *OIDCAuthenticator) Exchange(ctx context.Context, code, codeVerifier, expectedNonce string) (User, error) {
	oauth2Token, err := a.oauth2.Exchange(ctx, code,
		oauth2.SetAuthURLParam("code_verifier", codeVerifier),
	)
	if err != nil {
		return User{}, &ErrInvalidIDToken{Underlying: fmt.Errorf("token exchange: %w", err)}
	}

	rawIDToken, ok := oauth2Token.Extra("id_token").(string)
	if !ok || rawIDToken == "" {
		return User{}, &ErrInvalidIDToken{Underlying: errors.New("id_token missing from token response")}
	}

	idToken, err := a.verifier.Verify(ctx, rawIDToken)
	if err != nil {
		return User{}, &ErrInvalidIDToken{Underlying: err}
	}

	// Nonce assertion. Done AFTER verifier.Verify so signature / audience
	// / issuer / expiry have already gated; a token that survives those
	// checks but carries the wrong nonce indicates ID-token replay or a
	// misconfigured IdP that strips the nonce parameter on the authorize
	// hop. Empty expectedNonce ("") is a programmer error — the
	// state-store always mints one — so we treat it as a mismatch.
	if expectedNonce == "" || idToken.Nonce != expectedNonce {
		return User{}, &ErrInvalidIDToken{Underlying: errors.New("id_token nonce mismatch")}
	}

	var claims map[string]any
	if err := idToken.Claims(&claims); err != nil {
		return User{}, &ErrInvalidIDToken{Underlying: fmt.Errorf("claims decode: %w", err)}
	}

	role, err := a.MapGroupsToRole(claims)
	if err != nil {
		return User{}, err
	}

	email := ""
	if v, ok := claims["email"].(string); ok {
		email = strings.TrimSpace(strings.ToLower(v))
	}
	if email == "" {
		// Fall back to the OIDC subject so we always have a non-empty
		// identifier for the session record. The session's display
		// surface is keyed on User.Email so leaving it empty would render
		// a blank user in the topbar.
		email = idToken.Subject
	}

	return User{Email: email, Role: role}, nil
}

// MapGroupsToRole extracts the configured groups claim from a decoded ID
// token and resolves it to a dashboard role.
//
// Locked rules (PRD § Slice 2 / D6):
//   - Admin group wins. If a user is in BOTH the admin and viewer
//     groups, they get RoleAdmin (least-surprise: a directory operator
//     who deliberately added someone to admins shouldn't have to scrub
//     them out of viewers too).
//   - Neither group → 403, NOT auto-grant viewer. Customers must
//     explicitly authorize the identity at the IdP level.
//   - Missing claim → distinct error so misconfiguration is debuggable.
//   - String-shaped claim (single-group string instead of an array) is
//     normalized to a 1-element list. Most OIDC providers default to
//     arrays; a few emit a single string when only one group is mapped.
func (a *OIDCAuthenticator) MapGroupsToRole(claims map[string]any) (Role, error) {
	claimName := a.cfg.GroupsClaim
	if claimName == "" {
		claimName = "groups"
	}
	raw, ok := claims[claimName]
	if !ok {
		return "", ErrGroupsClaimMissing
	}
	groups, ok := normalizeGroupsClaim(raw)
	if !ok {
		return "", &ErrInvalidIDToken{Underlying: fmt.Errorf("groups claim %q has unexpected type %T", claimName, raw)}
	}

	inAdmin := false
	inViewer := false
	for _, g := range groups {
		if g == a.cfg.AdminGroup {
			inAdmin = true
		}
		if g == a.cfg.ViewerGroup {
			inViewer = true
		}
	}
	if inAdmin {
		return RoleAdmin, nil
	}
	if inViewer {
		return RoleViewer, nil
	}
	return "", ErrNeitherGroup
}

// normalizeGroupsClaim accepts either []any (strings) or a single string
// and returns []string. Returns (nil, false) for any other shape so the
// caller can surface a typed error.
func normalizeGroupsClaim(raw any) ([]string, bool) {
	switch v := raw.(type) {
	case []any:
		out := make([]string, 0, len(v))
		for _, item := range v {
			s, ok := item.(string)
			if !ok {
				return nil, false
			}
			out = append(out, s)
		}
		return out, true
	case []string:
		// JSON decoders rarely yield []string but some custom decoders do.
		out := make([]string, len(v))
		copy(out, v)
		return out, true
	case string:
		// Single-string fallback. Keep the call ergonomic for both the
		// "azure-ad-single-group" and the "we just got a malformed JSON
		// from an IdP" paths.
		return []string{v}, true
	default:
		return nil, false
	}
}

// pkceS256Challenge returns the base64-url-no-padding encoding of the
// SHA-256 of the supplied code verifier. Per RFC 7636 § 4.2.
func pkceS256Challenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}
