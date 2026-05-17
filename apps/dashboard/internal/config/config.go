// Package config loads dashboard configuration from environment variables.
//
// Slice 1 surface: listen address + bootstrap admin email/password + session
// signing secret.
//
// LUCAIRN_DASHBOARD_SESSION_SECRET is intentionally OPTIONAL in Slice 1.
// The in-memory session store uses opaque random IDs and does NOT consume
// the secret. The value is reserved for Slice 2's flip to signed-cookie
// sessions; once Slice 2 lands, the default in compose/values.yaml and the
// enforcement in this loader will both flip together. Keeping the field
// surface-shaped today lets operators stage rotation tooling early without
// dragging an enforcement gate into a release that does not need it.
package config

import (
	"errors"
	"os"
	"strings"
)

const (
	envListenAddr        = "LUCAIRN_DASHBOARD_LISTEN_ADDR"
	envBootstrapEmail    = "LUCAIRN_DASHBOARD_BOOTSTRAP_EMAIL"
	envBootstrapPassword = "LUCAIRN_DASHBOARD_BOOTSTRAP_PASSWORD"
	envSessionSecret     = "LUCAIRN_DASHBOARD_SESSION_SECRET"

	defaultListenAddr     = "0.0.0.0:8443"
	defaultBootstrapEmail = "admin@lucairn.local"
)

// Config holds runtime configuration for the dashboard.
type Config struct {
	ListenAddr        string
	BootstrapEmail    string
	BootstrapPassword string
	// SessionSecret is read into the Config but NOT enforced in Slice 1.
	// Slice 2 will flip the enforcement when signed-cookie sessions land.
	SessionSecret string
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
	return cfg, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
