package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/grafana"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/health"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// HealthDeps groups the runtime collaborators for the /health surface.
//
// Configured tells the handler whether real probes are active. When false
// the page still renders, but every service shows as "unknown" with a
// guidance banner pointing at customer.env / Helm values; the embed-
// Grafana drawer also short-circuits with a "not configured" pill.
//
// GrafanaConfigured is independent from health-Configured: a kit may
// have the health poller running but no Grafana, in which case the cards
// still flip to ok/warn/fail but the side drawer renders the placeholder
// panel block.
type HealthDeps struct {
	Renderer          *views.Renderer
	Poller            HealthPoller
	GrafanaSigner     *grafana.Signer
	GrafanaConfig     GrafanaPanelConfig
	HealthConfigured  bool
	GrafanaConfigured bool
}

// HealthPoller is the dashboard-internal contract for the health
// poller — same shape as *health.Poller but kept as an interface so
// tests can drive deterministic snapshots.
type HealthPoller interface {
	Services() []health.Service
	Snapshots() []health.Snapshot
	Snapshot(name string) (health.Snapshot, bool)
}

// GrafanaPanelConfig pins the four default-embedded panels + the Grafana
// base URL. Customers override the panel UIDs via Helm or compose env.
//
// PanelURL formats a Grafana panel iframe URL with an HS256 JWT carried as
// `auth_token` query param (the documented Grafana JWT URL-login
// mechanism — see internal/grafana/jwt.go header).
type GrafanaPanelConfig struct {
	BaseURL              string
	GatewayThroughputUID string
	SanitizerHitRatesUID string
	WitnessVerifyRateUID string
	AuditLogVolumeUID    string
}

// Panel is a single embed target rendered in the side drawer when a
// status card is clicked.
type Panel struct {
	Slug     string
	Title    string
	PanelUID string
	URL      string
	Height   int
}

// HealthOverviewPageData wraps PageData with the per-card render state.
type HealthOverviewPageData struct {
	views.PageData
	Configured     bool
	GrafanaWired   bool
	Cards          []HealthCard
	GrafanaBaseURL string
	Panels         []Panel
	GuidanceBanner string
}

// HealthCard is the renderable shape of one service in the overview grid.
type HealthCard struct {
	Name     string
	Status   string // "ok"|"warn"|"fail"|"unknown" (statusdot dot color class)
	Label    string // human-facing label rendered next to the dot
	Detail   string // short reason on non-ok states
	LastPoll string // formatted "<n>s ago" string; empty when unknown
}

// HealthOverviewHandler is GET /health. Auth-gated (middleware) so only
// authenticated users (any role) see the kit's service health.
func (d *HealthDeps) HealthOverviewHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}
	tok, err := auth.IssueToken(w, r)
	if err != nil {
		log.Printf("health_overview: csrf issue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	data := HealthOverviewPageData{
		PageData: views.PageData{
			Title:      "Health",
			User:       user,
			CSRFToken:  tok,
			ActivePage: "health",
		},
		Configured:     d.HealthConfigured,
		GrafanaWired:   d.GrafanaConfigured,
		GrafanaBaseURL: d.GrafanaConfig.BaseURL,
		Panels:         d.buildPanelDescriptors(),
	}
	if d.HealthConfigured && d.Poller != nil {
		now := time.Now()
		snaps := d.Poller.Snapshots()
		cards := make([]HealthCard, 0, len(snaps))
		for _, s := range snaps {
			cards = append(cards, toCard(s, now))
		}
		data.Cards = cards
	} else {
		// Render the static service list with status=unknown so the
		// overview surface communicates what would be probed once the
		// operator wires LUCAIRN_DASHBOARD_HEALTH_SERVICES.
		stub, _ := health.ParseServicesSpec("")
		cards := make([]HealthCard, 0, len(stub))
		for _, s := range stub {
			cards = append(cards, HealthCard{
				Name:   s.Name,
				Status: "unknown",
				Label:  "Probe disabled",
			})
		}
		data.Cards = cards
		data.GuidanceBanner = "Health probing is OFF. Set LUCAIRN_DASHBOARD_HEALTH_SERVICES (compose) or dashboard.healthServices (Helm) to enable per-service health probes."
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.Renderer.Render(w, "health/overview.html.tmpl", data); err != nil {
		log.Printf("health_overview: render: %v", err)
	}
}

// HealthGrafanaJWTHandler is POST /health/grafana-jwt. Mints a fresh JWT
// for the authenticated user and returns it as JSON. Used by the drawer
// front-end before rendering the iframe so the JWT never sits in the
// initial HTML response (closes the "JWT leaks via View Source" vector).
//
// Auth: any authenticated user. Role gating is enforced at the Grafana
// side via the JWT's `role` claim (Admin vs Viewer).
func (d *HealthDeps) HealthGrafanaJWTHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user, ok := auth.CurrentUser(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if err := auth.VerifyToken(r); err != nil {
		http.Error(w, "csrf failure", http.StatusForbidden)
		return
	}
	if !d.GrafanaConfigured || d.GrafanaSigner == nil {
		http.Error(w, "grafana embed not configured", http.StatusServiceUnavailable)
		return
	}
	role := "Viewer"
	if user.Role == auth.RoleAdmin {
		role = "Admin"
	}
	signed, err := d.GrafanaSigner.SignFor(user.Email, user.Email, role)
	if err != nil {
		log.Printf("health_grafana_jwt: sign: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	panelSlug := strings.TrimSpace(r.PostFormValue("panel"))
	urlOut := d.panelURL(panelSlug, signed)
	if urlOut == "" {
		// Unknown panel slug; return the JWT alone so the drawer can
		// surface a "panel not configured" message without 500'ing.
		log.Printf("health_grafana_jwt: unknown panel slug %q", panelSlug)
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	resp := struct {
		Token string `json:"token"`
		URL   string `json:"url"`
		TTL   int    `json:"ttl_seconds"`
	}{
		Token: signed,
		URL:   urlOut,
		TTL:   int(grafana.DefaultTTL / time.Second),
	}
	_ = json.NewEncoder(w).Encode(resp)
}

// panelURL builds a panel iframe URL with the supplied token applied as
// `auth_token` query param. Empty base URL or unknown slug return "" so
// the front-end can render the "not configured" placeholder.
func (d *HealthDeps) panelURL(slug, token string) string {
	base := strings.TrimSpace(d.GrafanaConfig.BaseURL)
	if base == "" {
		return ""
	}
	uid := d.panelUIDFor(slug)
	if uid == "" {
		return ""
	}
	u, err := url.Parse(strings.TrimRight(base, "/") + "/d/" + uid)
	if err != nil {
		return ""
	}
	q := u.Query()
	q.Set("orgId", "1")
	q.Set("kiosk", "tv")
	q.Set("auth_token", token)
	u.RawQuery = q.Encode()
	return u.String()
}

func (d *HealthDeps) panelUIDFor(slug string) string {
	switch slug {
	case "gateway-throughput":
		return d.GrafanaConfig.GatewayThroughputUID
	case "sanitizer-hit-rates":
		return d.GrafanaConfig.SanitizerHitRatesUID
	case "witness-verify-rate":
		return d.GrafanaConfig.WitnessVerifyRateUID
	case "audit-log-volume":
		return d.GrafanaConfig.AuditLogVolumeUID
	default:
		return ""
	}
}

// buildPanelDescriptors returns the four canonical drawer panels with
// the operator-overridable UID + height defaults. URL is left empty here
// — front-end fetches /health/grafana-jwt to mint a fresh token per
// drawer-open.
func (d *HealthDeps) buildPanelDescriptors() []Panel {
	return []Panel{
		{
			Slug:     "gateway-throughput",
			Title:    "Gateway throughput (5m / 1h / 24h)",
			PanelUID: d.GrafanaConfig.GatewayThroughputUID,
			Height:   320,
		},
		{
			Slug:     "sanitizer-hit-rates",
			Title:    "Sanitizer L1/L2/L3 hit rates",
			PanelUID: d.GrafanaConfig.SanitizerHitRatesUID,
			Height:   320,
		},
		{
			Slug:     "witness-verify-rate",
			Title:    "Witness verify rate",
			PanelUID: d.GrafanaConfig.WitnessVerifyRateUID,
			Height:   320,
		},
		{
			Slug:     "audit-log-volume",
			Title:    "Audit log volume",
			PanelUID: d.GrafanaConfig.AuditLogVolumeUID,
			Height:   320,
		},
	}
}

// toCard projects a Snapshot onto the renderable HealthCard. Status maps
// directly to the existing statusdot CSS variants (ok / warn / fail /
// unknown).
func toCard(s health.Snapshot, now time.Time) HealthCard {
	var statusClass, label string
	switch s.Status {
	case health.StatusOK:
		statusClass, label = "ok", "Healthy"
	case health.StatusWarn:
		statusClass, label = "warn", "Degraded"
	case health.StatusFail:
		statusClass, label = "fail", "Down"
	default:
		statusClass, label = "unknown", "Polling…"
	}
	lastPoll := ""
	if !s.LastPoll.IsZero() {
		lastPoll = humanizeAgo(now.Sub(s.LastPoll))
	}
	return HealthCard{
		Name:     s.Service.Name,
		Status:   statusClass,
		Label:    label,
		Detail:   s.Detail,
		LastPoll: lastPoll,
	}
}

// humanizeAgo renders a duration as "Ns ago" / "Nm ago" / "Nh ago". Caps
// at hours; older delta = "stale" (the poller writes LastPoll every
// interval so >1h means the goroutine isn't running).
func humanizeAgo(d time.Duration) string {
	if d < 0 {
		return "just now"
	}
	if d < time.Minute {
		s := int(d.Seconds())
		if s < 1 {
			return "just now"
		}
		return formatAgo(s, "s")
	}
	if d < time.Hour {
		return formatAgo(int(d.Minutes()), "m")
	}
	if d < 24*time.Hour {
		return formatAgo(int(d.Hours()), "h")
	}
	return "stale"
}

func formatAgo(n int, unit string) string {
	return itoaPositive(n) + unit + " ago"
}

// itoaPositive is a strconv-free int-to-string helper kept local so this
// file's import list stays minimal (handlers/ does not otherwise import
// strconv). Drops sign because the caller filters d<0 already.
func itoaPositive(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
