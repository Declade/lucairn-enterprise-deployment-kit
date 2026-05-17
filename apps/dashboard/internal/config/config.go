// Package config loads dashboard configuration from environment variables.
//
// Slice 1 surface: listen address + bootstrap admin email/password + session
// signing secret (reserved for future signed-cookie use; in-memory sessions
// today do not consume it but it is required so deploys that flip to signed
// cookies in a later slice fail-fast on missing config rather than silently
// degrading).
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
	SessionSecret     string
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
