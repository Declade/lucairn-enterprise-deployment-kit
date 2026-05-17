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
		// /healthz is hit by liveness probes every few seconds; intermediate
		// caches MUST NOT serve stale 200 bodies or the readiness signal lies
		// silently. Cache-Control: no-store also keeps it out of access-log
		// CDN aggregations on operators who front the dashboard with a CDN.
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(healthzBody{Status: "ok", Version: version})
	}
}
