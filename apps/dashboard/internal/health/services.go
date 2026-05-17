// Package health implements the dashboard's server-health overview surface.
//
// Slice 4 ships:
//   - A list of expected kit services (parseable from a comma-separated
//     env-var; sensible defaults bundled).
//   - A concurrent poller that probes each service on a 10s cadence and
//     maintains a per-service rolling status snapshot.
//   - A side-drawer render path that embeds short-lived JWT-authenticated
//     Grafana panels for the four standard kit metrics.
//
// Design note: the poller runs one goroutine PER service. Each goroutine
// owns its service's failure-mode handling end-to-end (network error,
// non-200 status, body shape mismatch). A single global sweeper would
// have to multiplex error states across services, which makes the per-
// service back-off + per-service jitter awkward; per-service goroutines
// stay small (~30 lines) and are trivially testable.
package health

import (
	"fmt"
	"strings"
)

// Scheme enumerates the supported probe schemes. HTTP / HTTPS probe a
// service's `/healthz`-style endpoint and treat any 2xx response as ok.
// TCP performs a bare TCP connect (no HTTP); good for postgres / redis
// / ollama-on-bare-port services that don't expose a JSON healthz body.
type Scheme string

const (
	SchemeHTTP  Scheme = "http"
	SchemeHTTPS Scheme = "https"
	SchemeTCP   Scheme = "tcp"
)

// Service is a single probe target.
//
// Name is the human-facing label rendered on the overview card. URL is the
// probe target (full URL for http/https, host:port for tcp). Scheme is
// derived from URL prefix at parse-time so the poller doesn't have to
// re-split the URL on every tick.
type Service struct {
	Name   string
	URL    string
	Scheme Scheme
	// Target is the host:port string passed to net.Dial for TCP probes.
	// Empty for http/https probes.
	Target string
}

// DefaultServicesSpec is the bundled service list, used when
// LUCAIRN_DASHBOARD_HEALTH_SERVICES is empty. Reflects the canonical kit
// service topology: 7 HTTP `/healthz` endpoints + 3 postgres ports + 1 redis
// + 1 ollama bare HTTP endpoint = 12 services.
//
// Service DNS names + ports match charts/lucairn/charts/*/values.yaml +
// docker-compose service definitions; the Compose path's container DNS
// labels resolve identically to the Helm path's Service DNS.
//
// Lines are SERVICE_NAME=URL ; the URL is parsed by ParseServicesSpec. The
// spec is stored as a single string (not a Go slice) so the env-var
// override path is a verbatim drop-in.
const DefaultServicesSpec = "gateway=http://gateway:8080/healthz," +
	"sanitizer=http://sanitizer:8086/healthz," +
	"witness=http://veil-witness:8081/healthz," +
	"bridge=http://id-bridge:8082/healthz," +
	"sandbox-a=http://sandbox-a:8083/healthz," +
	"sandbox-b=http://sandbox-b:8084/healthz," +
	"audit=http://audit:8085/healthz," +
	"postgres-audit=tcp://postgres-audit:5432," +
	"postgres-bridge=tcp://postgres-bridge:5432," +
	"postgres-sandbox-a=tcp://postgres-sandbox-a:5432," +
	"redis=tcp://redis:6379," +
	"ollama=http://ollama:11434/"

// ParseServicesSpec parses a comma-separated list of `name=url` pairs
// into a slice of Service values. Empty input returns the DefaultServicesSpec
// parse result.
//
// Validation rules:
//   - Each non-empty token MUST contain exactly one '=' separator.
//   - The URL part MUST start with http://, https://, or tcp://.
//   - tcp:// URLs MUST contain a host:port (one colon after the host).
//   - http(s):// URLs are accepted as-is (the probe sends a GET and
//     treats any 2xx as ok).
//
// Returns an error on any malformed token so misconfiguration fails the
// dashboard at boot rather than producing a confused overview with some
// services silently missing.
func ParseServicesSpec(spec string) ([]Service, error) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		spec = DefaultServicesSpec
	}
	parts := strings.Split(spec, ",")
	services := make([]Service, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, raw := range parts {
		tok := strings.TrimSpace(raw)
		if tok == "" {
			continue
		}
		eq := strings.IndexByte(tok, '=')
		if eq < 0 || eq == len(tok)-1 {
			return nil, fmt.Errorf("health: bad services token %q: expected name=url", tok)
		}
		name := strings.TrimSpace(tok[:eq])
		raw := strings.TrimSpace(tok[eq+1:])
		if name == "" {
			return nil, fmt.Errorf("health: bad services token %q: empty name", tok)
		}
		if _, dupe := seen[name]; dupe {
			return nil, fmt.Errorf("health: duplicate service name %q", name)
		}
		svc, err := parseServiceURL(name, raw)
		if err != nil {
			return nil, err
		}
		seen[name] = struct{}{}
		services = append(services, svc)
	}
	if len(services) == 0 {
		return nil, fmt.Errorf("health: empty services spec")
	}
	return services, nil
}

// parseServiceURL splits the URL into a Scheme + Target / full URL pair.
//
// For tcp:// it extracts the host:port substring (the net.Dial argument).
// For http(s):// it keeps the full URL as Service.URL and leaves Target
// empty.
func parseServiceURL(name, raw string) (Service, error) {
	switch {
	case strings.HasPrefix(raw, "https://"):
		return Service{Name: name, URL: raw, Scheme: SchemeHTTPS}, nil
	case strings.HasPrefix(raw, "http://"):
		return Service{Name: name, URL: raw, Scheme: SchemeHTTP}, nil
	case strings.HasPrefix(raw, "tcp://"):
		hostPort := strings.TrimPrefix(raw, "tcp://")
		// Trim an optional trailing slash so "tcp://postgres-audit:5432/"
		// is treated identically to "tcp://postgres-audit:5432".
		hostPort = strings.TrimSuffix(hostPort, "/")
		if !strings.Contains(hostPort, ":") {
			return Service{}, fmt.Errorf("health: tcp service %q url %q missing :port", name, raw)
		}
		return Service{Name: name, URL: raw, Scheme: SchemeTCP, Target: hostPort}, nil
	default:
		return Service{}, fmt.Errorf("health: service %q url %q must start with http://, https://, or tcp://", name, raw)
	}
}
