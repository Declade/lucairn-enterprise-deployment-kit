package server

import (
	"encoding/json"
	"net/http"
	"strings"
)

// healthzHandler returns 200 with a small JSON body describing readiness.
// /healthz is whitelisted by the session middleware so liveness probes do
// not need credentials.
func healthzHandler(version string) http.HandlerFunc {
	if strings.TrimSpace(version) == "" {
		version = "dev"
	}
	type healthzBody struct {
		Status  string `json:"status"`
		Version string `json:"version"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(healthzBody{Status: "ok", Version: version})
	}
}
