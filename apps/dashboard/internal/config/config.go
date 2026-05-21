// Package config loads dashboard configuration from environment variables.
//
// Slice 1 surface: listen address + bootstrap admin email/password + session
// signing secret.
//
// Slice 2 adds optional OIDC SSO. Default OFF. When OIDC is enabled, the
// loader validates the full quartet of required fields and fails-closed
// if any are missing — there is no half-configured OIDC mode.
//
// LUCAIRN_DASHBOARD_SESSION_SECRET is intentionally OPTIONAL in Slice 1.
// The in-memory session store uses opaque random IDs and does NOT consume
// the secret. The value is reserved for a future flip to signed-cookie
// sessions; once that lands, the default in compose/values.yaml and the
// enforcement in this loader will both flip together. Keeping the field
// surface-shaped today lets operators stage rotation tooling early without
// dragging an enforcement gate into a release that does not need it.
package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"regexp"
	"strings"
)

// grafanaPanelUIDPattern locks the legal shape of operator-supplied
// Grafana panel UIDs (Slice 4 fix-up r1, closes bug-hunter M4).
//
// Grafana's own UID alphabet is alphanumeric plus `-` / `_`, capped at
// 40 characters. We allow up to 64 to leave headroom and reject
// anything else at config-load time so the URL builder in
// handlers/health.go never accepts characters that would let an
// operator inject a path segment or query parameter (e.g. `?evil=1` or
// `/../admin`). Fail-closed-at-boot per Slice 3 pattern #25.
var grafanaPanelUIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

const (
	envListenAddr        = "LUCAIRN_DASHBOARD_LISTEN_ADDR"
	envBootstrapEmail    = "LUCAIRN_DASHBOARD_BOOTSTRAP_EMAIL"
	envBootstrapPassword = "LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD"
	envSessionSecret     = "LUCAIRN_DASHBOARD_SESSION_SECRET"

	envOIDCEnabled      = "LUCAIRN_DASHBOARD_OIDC_ENABLED"
	envOIDCIssuerURL    = "LUCAIRN_DASHBOARD_OIDC_ISSUER_URL"
	envOIDCClientID     = "LUCAIRN_DASHBOARD_OIDC_CLIENT_ID"
	envOIDCClientSecret = "LUCAIRN_DASHBOARD_OIDC_CLIENT_SECRET"
	envOIDCAdminGroup   = "LUCAIRN_DASHBOARD_OIDC_ADMIN_GROUP"
	envOIDCViewerGroup  = "LUCAIRN_DASHBOARD_OIDC_VIEWER_GROUP"
	envOIDCGroupsClaim  = "LUCAIRN_DASHBOARD_OIDC_GROUPS_CLAIM"
	envOIDCCallbackURL  = "LUCAIRN_DASHBOARD_OIDC_CALLBACK_URL"
	envOIDCPublicURL    = "LUCAIRN_DASHBOARD_OIDC_PUBLIC_URL"

	// Slice 3: cert browser + inspector + audit-grade validator.
	envAuditDBURL        = "LUCAIRN_DASHBOARD_AUDIT_DB_URL"
	envWitnessEndpoint   = "LUCAIRN_DASHBOARD_WITNESS_ENDPOINT"
	envWitnessTLSEnabled = "LUCAIRN_DASHBOARD_WITNESS_TLS_ENABLED"

	// Slice 4: server health overview + Grafana embedding plumbing.
	envHealthServices            = "LUCAIRN_DASHBOARD_HEALTH_SERVICES"
	envHealthPollIntervalSeconds = "LUCAIRN_DASHBOARD_HEALTH_POLL_INTERVAL_SECONDS"
	envGrafanaURL                = "LUCAIRN_DASHBOARD_GRAFANA_URL"
	envGrafanaJWTSecret          = "LUCAIRN_DASHBOARD_GRAFANA_JWT_SECRET"
	envGrafanaPanelGatewayUID    = "LUCAIRN_DASHBOARD_GRAFANA_PANEL_GATEWAY_THROUGHPUT_UID"
	envGrafanaPanelSanitizerUID  = "LUCAIRN_DASHBOARD_GRAFANA_PANEL_SANITIZER_HIT_RATES_UID"
	envGrafanaPanelWitnessUID    = "LUCAIRN_DASHBOARD_GRAFANA_PANEL_WITNESS_VERIFY_RATE_UID"
	envGrafanaPanelAuditUID      = "LUCAIRN_DASHBOARD_GRAFANA_PANEL_AUDIT_LOG_VOLUME_UID"

	// Slice 5: API key management against the gateway admin HTTP surface.
	envGatewayAdminURL   = "LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL"
	envGatewayAdminToken = "LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN"

	// Slice 6: audit log browser. Note the env var name is
	// LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL — distinct from the Slice 3
	// LUCAIRN_DASHBOARD_AUDIT_DB_URL (which points at the cert DB).
	envAuditLogDBURL    = "LUCAIRN_DASHBOARD_AUDIT_LOG_DB_URL"
	envSavedFiltersDBURL = "LUCAIRN_DASHBOARD_AUDIT_LOG_SAVED_FILTERS_DB_URL"

	defaultListenAddr       = "0.0.0.0:8443"
	defaultBootstrapEmail   = "admin@lucairn.local"
	defaultOIDCGroupsClaim  = "groups"
	defaultOIDCCallbackPath = "/auth/oidc/callback"

	defaultHealthPollInterval = 10
)

// Config holds runtime configuration for the dashboard.
type Config struct {
	ListenAddr        string
	BootstrapEmail    string
	BootstrapPassword string
	// SessionSecret is read into the Config but NOT enforced in Slice 1.
	// A future slice will flip the enforcement when signed-cookie sessions
	// land.
	SessionSecret string

	// OIDCEnabled is the master switch for SSO. When false the rest of
	// the OIDC fields are unread and the login surface renders only the
	// local form.
	OIDCEnabled      bool
	OIDCIssuerURL    string
	OIDCClientID     string
	OIDCClientSecret string
	OIDCAdminGroup   string
	OIDCViewerGroup  string
	OIDCGroupsClaim  string
	OIDCCallbackURL  string

	// Slice 3 cert surface configuration. Both fields are optional —
	// when AuditDBURL OR WitnessEndpoint is empty, cert pages render
	// the "not configured" explainer and never dial either backend.
	AuditDBURL        string
	WitnessEndpoint   string
	WitnessTLSEnabled bool

	// Slice 4 server-health overview + Grafana embedding plumbing.
	//
	// HealthServices is the comma-separated `name=url` spec. Empty →
	// the bundled default 12-service kit list is used. The Go side
	// holds the raw string + lets health.ParseServicesSpec do the
	// parsing (separation of concerns: config validates SHAPE here,
	// the health package validates SEMANTICS).
	HealthServices            string
	HealthPollIntervalSeconds int
	// Grafana embedding is opt-in. Both URL + JWTSecret MUST be set
	// together when GrafanaURL is non-empty; the loader fails-closed if
	// only one half is populated (the Slice 3 pattern #25 — don't mask
	// half-wired config with Go defaults).
	GrafanaURL               string
	GrafanaJWTSecret         string
	GrafanaPanelGatewayUID   string
	GrafanaPanelSanitizerUID string
	GrafanaPanelWitnessUID   string
	GrafanaPanelAuditUID     string

	// Slice 5: API key management. Both fields are OPTIONAL — when
	// either is empty, the /keys surface still registers but renders
	// the "not configured" explainer. Setting one without the other is
	// a configuration error caught at boot.
	GatewayAdminURL   string
	GatewayAdminToken string

	// Slice 6: audit log browser. Both fields are OPTIONAL.
	// AuditLogDBURL drives the /audit surface; empty = "not
	// configured" explainer. SavedFiltersDBURL is an optional
	// hardening override — operators uncomfortable widening the
	// audit_app role's privileges can point this at a separate role
	// with INSERT/SELECT/UPDATE/DELETE on dashboard_saved_filters.
	// Empty = fall back to AuditLogDBURL.
	AuditLogDBURL     string
	SavedFiltersDBURL string
}

// Load reads configuration from the environment and applies safe defaults.
// Returns an error if any required value is missing or malformed.
func Load() (*Config, error) {
	cfg := &Config{
		ListenAddr:        firstNonEmpty(os.Getenv(envListenAddr), defaultListenAddr),
		BootstrapEmail:    firstNonEmpty(os.Getenv(envBootstrapEmail), defaultBootstrapEmail),
		BootstrapPassword: strings.TrimSpace(os.Getenv(envBootstrapPassword)),
		SessionSecret:     strings.TrimSpace(os.Getenv(envSessionSecret)),
	}
	if cfg.BootstrapPassword == "" {
		return nil, errors.New("LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD must be set")
	}

	if err := applyOIDCConfig(cfg); err != nil {
		return nil, err
	}

	if err := applyCertSurfaceConfig(cfg); err != nil {
		return nil, err
	}

	if err := applyHealthSurfaceConfig(cfg); err != nil {
		return nil, err
	}

	if err := applyKeysSurfaceConfig(cfg); err != nil {
		return nil, err
	}

	if err := applyAuditLogSurfaceConfig(cfg); err != nil {
		return nil, err
	}

	return cfg, nil
}

// applyAuditLogSurfaceConfig reads + validates the Slice 6 audit-log
// browser env vars.
//
// AuditLogDBURL is OPTIONAL — empty disables the /audit surface.
// When set, the URL must parse and use the postgres:// scheme.
// SavedFiltersDBURL is optional hardening: if set, must also be a
// postgres:// URL.
func applyAuditLogSurfaceConfig(cfg *Config) error {
	cfg.AuditLogDBURL = strings.TrimSpace(os.Getenv(envAuditLogDBURL))
	cfg.SavedFiltersDBURL = strings.TrimSpace(os.Getenv(envSavedFiltersDBURL))
	if cfg.AuditLogDBURL == "" {
		// Surface disabled. Discard the saved-filters URL so main.go's
		// audit wiring also short-circuits cleanly even if the
		// operator set saved-filters without audit.
		cfg.SavedFiltersDBURL = ""
		return nil
	}
	u, err := url.Parse(cfg.AuditLogDBURL)
	if err != nil {
		return fmt.Errorf("%s: parse: %w", envAuditLogDBURL, err)
	}
	switch u.Scheme {
	case "postgres", "postgresql":
		// ok
	default:
		return fmt.Errorf("%s scheme must be postgres:// or postgresql://, got %q", envAuditLogDBURL, u.Scheme)
	}
	if cfg.SavedFiltersDBURL != "" {
		uSF, err := url.Parse(cfg.SavedFiltersDBURL)
		if err != nil {
			return fmt.Errorf("%s: parse: %w", envSavedFiltersDBURL, err)
		}
		switch uSF.Scheme {
		case "postgres", "postgresql":
			// ok
		default:
			return fmt.Errorf("%s scheme must be postgres:// or postgresql://, got %q", envSavedFiltersDBURL, uSF.Scheme)
		}
	}
	return nil
}

// applyKeysSurfaceConfig reads + validates the Slice 5 API-key
// management env vars.
//
// The /keys surface is OPT-IN. The driver is the pair
// LUCAIRN_DASHBOARD_GATEWAY_ADMIN_URL + LUCAIRN_DASHBOARD_GATEWAY_ADMIN_TOKEN.
// Both must be set together; setting only one is a half-wired config
// caught here (Slice 3 pattern #25 — fail-closed at boot, not silently
// at first /keys request).
func applyKeysSurfaceConfig(cfg *Config) error {
	cfg.GatewayAdminURL = strings.TrimSpace(os.Getenv(envGatewayAdminURL))
	cfg.GatewayAdminToken = strings.TrimSpace(os.Getenv(envGatewayAdminToken))
	if cfg.GatewayAdminURL == "" && cfg.GatewayAdminToken == "" {
		return nil
	}
	if cfg.GatewayAdminURL == "" {
		return fmt.Errorf("%s must be set when %s is set", envGatewayAdminURL, envGatewayAdminToken)
	}
	if cfg.GatewayAdminToken == "" {
		return fmt.Errorf("%s must be set when %s is set", envGatewayAdminToken, envGatewayAdminURL)
	}
	u, err := url.Parse(cfg.GatewayAdminURL)
	if err != nil {
		return fmt.Errorf("%s parse %q: %w", envGatewayAdminURL, cfg.GatewayAdminURL, err)
	}
	switch u.Scheme {
	case "http", "https":
		// ok
	default:
		return fmt.Errorf("%s scheme must be http:// or https://, got %q", envGatewayAdminURL, u.Scheme)
	}
	return nil
}

// applyHealthSurfaceConfig reads + validates the Slice 4 server-health +
// Grafana embedding env vars.
//
// The HEALTH side is always-on at the Go binary level — the poller starts
// regardless. Operators who want to disable it set HealthServices to an
// empty value and the binary skips poller boot.
//
// The GRAFANA side is opt-in and follows the W2A-pattern-#25 fail-closed
// rule: when GrafanaURL is non-empty, GrafanaJWTSecret MUST also be set
// (and at the minimum-length floor enforced by grafana.NewSigner).
//
// Panel UIDs are individually optional — when a UID is empty, the side
// drawer for that panel renders the "panel not configured" placeholder
// and the handler does NOT mint a JWT (panelURL returns "").
func applyHealthSurfaceConfig(cfg *Config) error {
	cfg.HealthServices = strings.TrimSpace(os.Getenv(envHealthServices))
	cfg.HealthPollIntervalSeconds = defaultHealthPollInterval
	if v := strings.TrimSpace(os.Getenv(envHealthPollIntervalSeconds)); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err != nil || n <= 0 {
			return fmt.Errorf("%s must be a positive integer (seconds), got %q", envHealthPollIntervalSeconds, v)
		}
		if n > 3600 {
			return fmt.Errorf("%s must be <= 3600 (one hour), got %d", envHealthPollIntervalSeconds, n)
		}
		cfg.HealthPollIntervalSeconds = n
	}

	cfg.GrafanaURL = strings.TrimSpace(os.Getenv(envGrafanaURL))
	cfg.GrafanaJWTSecret = strings.TrimSpace(os.Getenv(envGrafanaJWTSecret))
	cfg.GrafanaPanelGatewayUID = strings.TrimSpace(os.Getenv(envGrafanaPanelGatewayUID))
	cfg.GrafanaPanelSanitizerUID = strings.TrimSpace(os.Getenv(envGrafanaPanelSanitizerUID))
	cfg.GrafanaPanelWitnessUID = strings.TrimSpace(os.Getenv(envGrafanaPanelWitnessUID))
	cfg.GrafanaPanelAuditUID = strings.TrimSpace(os.Getenv(envGrafanaPanelAuditUID))

	// Slice 4 fix-up r1: allowlist the panel UID shape at boot so
	// path/query injection via the env var cannot reach the URL builder
	// in handlers/health.go. Empty string is fine (= "panel not configured").
	for envName, val := range map[string]string{
		envGrafanaPanelGatewayUID:   cfg.GrafanaPanelGatewayUID,
		envGrafanaPanelSanitizerUID: cfg.GrafanaPanelSanitizerUID,
		envGrafanaPanelWitnessUID:   cfg.GrafanaPanelWitnessUID,
		envGrafanaPanelAuditUID:     cfg.GrafanaPanelAuditUID,
	} {
		if val == "" {
			continue
		}
		if !grafanaPanelUIDPattern.MatchString(val) {
			return fmt.Errorf("%s must match [A-Za-z0-9_-]{1,64}, got %q", envName, val)
		}
	}

	if cfg.GrafanaURL != "" {
		// URL must parse + use http/https scheme.
		u, err := url.Parse(cfg.GrafanaURL)
		if err != nil {
			return fmt.Errorf("%s: parse %q: %w", envGrafanaURL, cfg.GrafanaURL, err)
		}
		switch u.Scheme {
		case "http", "https":
			// ok
		default:
			return fmt.Errorf("%s scheme must be http:// or https://, got %q", envGrafanaURL, u.Scheme)
		}
		if cfg.GrafanaJWTSecret == "" {
			return fmt.Errorf("%s must be set when %s is set", envGrafanaJWTSecret, envGrafanaURL)
		}
		// Length validation is delegated to grafana.NewSigner so the
		// floor (MinSecretBytes) lives next to the JWT signer code.
	} else if cfg.GrafanaJWTSecret != "" {
		// Half-wired case: secret without URL. Fail-closed.
		return fmt.Errorf("%s must be set when %s is set", envGrafanaURL, envGrafanaJWTSecret)
	}

	return nil
}

// applyCertSurfaceConfig reads the cert browser / inspector config and
// validates the shape when populated. The fields are OPTIONAL — leaving
// both unset is the supported "cert surface off" mode. When at least
// one is set we validate the pair so the operator never ends up with
// a half-configured surface that crashes on the first cert click.
//
// Required (jointly) when either is set:
//   - LUCAIRN_DASHBOARD_AUDIT_DB_URL    libpq URL (postgres://...)
//   - LUCAIRN_DASHBOARD_WITNESS_ENDPOINT host:port
//
// Optional:
//   - LUCAIRN_DASHBOARD_WITNESS_TLS_ENABLED  reserved for the future
//     mTLS slice (defaults false).
func applyCertSurfaceConfig(cfg *Config) error {
	cfg.AuditDBURL = strings.TrimSpace(os.Getenv(envAuditDBURL))
	cfg.WitnessEndpoint = strings.TrimSpace(os.Getenv(envWitnessEndpoint))
	cfg.WitnessTLSEnabled = parseBoolOIDC(strings.ToLower(strings.TrimSpace(os.Getenv(envWitnessTLSEnabled))))

	// The cert surface is OPT-IN. The driver is LUCAIRN_DASHBOARD_AUDIT_DB_URL:
	//   - empty AUDIT_DB_URL = cert surface OFF (regardless of WITNESS_ENDPOINT).
	//     Operators who set a compose-level WITNESS_ENDPOINT default but never
	//     opt into the cert surface get the friendly "not configured" pages
	//     instead of a fail-closed boot.
	//   - non-empty AUDIT_DB_URL = cert surface ON; WITNESS_ENDPOINT MUST also
	//     be populated (the cert inspector cannot validate anything without
	//     the witness). This is the "half-wired" guard.
	if cfg.AuditDBURL == "" {
		// Surface deliberately disabled. Discard the witness endpoint so
		// main.go's cert wiring also short-circuits cleanly.
		cfg.WitnessEndpoint = ""
		return nil
	}
	if cfg.WitnessEndpoint == "" {
		return fmt.Errorf("%s must be set when %s is set", envWitnessEndpoint, envAuditDBURL)
	}
	// Validate the DB URL parses + uses postgres scheme.
	u, err := url.Parse(cfg.AuditDBURL)
	if err != nil {
		return fmt.Errorf("%s: parse: %w", envAuditDBURL, err)
	}
	switch u.Scheme {
	case "postgres", "postgresql":
		// ok
	default:
		return fmt.Errorf("%s scheme must be postgres:// or postgresql://, got %q", envAuditDBURL, u.Scheme)
	}
	// Validate the witness endpoint has a colon (host:port).
	if !strings.Contains(cfg.WitnessEndpoint, ":") {
		return fmt.Errorf("%s must be host:port, got %q", envWitnessEndpoint, cfg.WitnessEndpoint)
	}
	return nil
}

// applyOIDCConfig reads + validates the OIDC env vars in one pass. Kept
// separate so the Load() top-level reads cleanly and so unit tests can
// fuzz the OIDC half without rebuilding the whole Config.
//
// Required when OIDCEnabled=true:
//   - LUCAIRN_DASHBOARD_OIDC_ISSUER_URL  (must parse as URL)
//   - LUCAIRN_DASHBOARD_OIDC_CLIENT_ID
//   - LUCAIRN_DASHBOARD_OIDC_CLIENT_SECRET
//   - LUCAIRN_DASHBOARD_OIDC_ADMIN_GROUP
//   - LUCAIRN_DASHBOARD_OIDC_VIEWER_GROUP
//   - One of LUCAIRN_DASHBOARD_OIDC_CALLBACK_URL or
//     LUCAIRN_DASHBOARD_OIDC_PUBLIC_URL (callback URL derived from public
//     URL by appending /auth/oidc/callback).
//
// Optional:
//   - LUCAIRN_DASHBOARD_OIDC_GROUPS_CLAIM (defaults to "groups")
func applyOIDCConfig(cfg *Config) error {
	enabledRaw := strings.TrimSpace(strings.ToLower(os.Getenv(envOIDCEnabled)))
	cfg.OIDCEnabled = parseBoolOIDC(enabledRaw)
	if !cfg.OIDCEnabled {
		return nil
	}

	cfg.OIDCIssuerURL = strings.TrimRight(strings.TrimSpace(os.Getenv(envOIDCIssuerURL)), "/")
	cfg.OIDCClientID = strings.TrimSpace(os.Getenv(envOIDCClientID))
	cfg.OIDCClientSecret = strings.TrimSpace(os.Getenv(envOIDCClientSecret))
	cfg.OIDCAdminGroup = strings.TrimSpace(os.Getenv(envOIDCAdminGroup))
	cfg.OIDCViewerGroup = strings.TrimSpace(os.Getenv(envOIDCViewerGroup))
	cfg.OIDCGroupsClaim = firstNonEmpty(strings.TrimSpace(os.Getenv(envOIDCGroupsClaim)), defaultOIDCGroupsClaim)

	if cfg.OIDCIssuerURL == "" {
		return fmt.Errorf("%s must be set when %s=true", envOIDCIssuerURL, envOIDCEnabled)
	}
	if _, err := url.Parse(cfg.OIDCIssuerURL); err != nil {
		return fmt.Errorf("%s: parse %q: %w", envOIDCIssuerURL, cfg.OIDCIssuerURL, err)
	}
	if cfg.OIDCClientID == "" {
		return fmt.Errorf("%s must be set when %s=true", envOIDCClientID, envOIDCEnabled)
	}
	if cfg.OIDCClientSecret == "" {
		return fmt.Errorf("%s must be set when %s=true", envOIDCClientSecret, envOIDCEnabled)
	}
	if cfg.OIDCAdminGroup == "" {
		return fmt.Errorf("%s must be set when %s=true", envOIDCAdminGroup, envOIDCEnabled)
	}
	if cfg.OIDCViewerGroup == "" {
		return fmt.Errorf("%s must be set when %s=true", envOIDCViewerGroup, envOIDCEnabled)
	}

	callbackURL := strings.TrimSpace(os.Getenv(envOIDCCallbackURL))
	if callbackURL == "" {
		publicURL := strings.TrimSpace(os.Getenv(envOIDCPublicURL))
		if publicURL == "" {
			return fmt.Errorf(
				"%s or %s must be set when %s=true (callback URL is derived from public URL when absent)",
				envOIDCCallbackURL, envOIDCPublicURL, envOIDCEnabled,
			)
		}
		callbackURL = strings.TrimRight(publicURL, "/") + defaultOIDCCallbackPath
	}
	if _, err := url.Parse(callbackURL); err != nil {
		return fmt.Errorf("oidc callback url %q parse: %w", callbackURL, err)
	}
	cfg.OIDCCallbackURL = callbackURL

	return nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// parseBoolOIDC accepts the canonical true tokens. Lower-cased before
// the lookup. Anything unrecognized → false (default-OFF). Operators
// who fat-finger "yes" silently end up with OIDC disabled — by design
// (default-OFF is the safe failure mode).
func parseBoolOIDC(v string) bool {
	switch v {
	case "true", "1", "yes", "on":
		return true
	default:
		return false
	}
}
