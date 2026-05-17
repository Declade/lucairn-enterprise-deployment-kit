package handlers

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/auth"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/grafana"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/health"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/views"
)

// withSession injects an authenticated session onto the request via the
// auth-package test hook so handlers can call auth.CurrentUser without
// running the full LoadSession middleware.
func withSession(r *http.Request, sess *auth.Session) *http.Request {
	return auth.WithSessionForTest(r, sess)
}

// fakePoller drives deterministic snapshots into HealthOverviewHandler so
// the renderer test doesn't depend on goroutine timing.
type fakePoller struct {
	svcs  []health.Service
	snaps []health.Snapshot
}

func (f *fakePoller) Services() []health.Service { return f.svcs }
func (f *fakePoller) Snapshots() []health.Snapshot {
	out := make([]health.Snapshot, len(f.snaps))
	copy(out, f.snaps)
	return out
}
func (f *fakePoller) Snapshot(name string) (health.Snapshot, bool) {
	for _, s := range f.snaps {
		if s.Service.Name == name {
			return s, true
		}
	}
	return health.Snapshot{}, false
}

func mustRenderer(t *testing.T) *views.Renderer {
	t.Helper()
	r, err := views.New()
	if err != nil {
		t.Fatalf("views: %v", err)
	}
	return r
}

func newAdminSession() *auth.Session {
	return &auth.Session{ID: "sess-test", User: auth.User{Email: "admin@lucairn.local", Role: auth.RoleAdmin}}
}

func newViewerSession() *auth.Session {
	return &auth.Session{ID: "sess-viewer", User: auth.User{Email: "viewer@lucairn.local", Role: auth.RoleViewer}}
}

func TestHealthOverview_Configured_RendersCards(t *testing.T) {
	t.Parallel()
	now := time.Now()
	deps := &HealthDeps{
		Renderer:         mustRenderer(t),
		HealthConfigured: true,
		Poller: &fakePoller{
			snaps: []health.Snapshot{
				{Service: health.Service{Name: "gateway"}, Status: health.StatusOK, LastPoll: now.Add(-3 * time.Second)},
				{Service: health.Service{Name: "sanitizer"}, Status: health.StatusFail, LastPoll: now.Add(-1 * time.Second), Detail: "non-2xx: 503"},
				{Service: health.Service{Name: "redis"}, Status: health.StatusUnknown},
			},
		},
	}

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req = withSession(req, newAdminSession())
	rr := httptest.NewRecorder()
	deps.HealthOverviewHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	// Status pills should render the canonical statusdot classes.
	for _, want := range []string{"lc-statusdot--ok", "lc-statusdot--fail", "lc-statusdot--unknown"} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q in body", want)
		}
	}
	// Detail line for the failed service is honored.
	if !strings.Contains(body, "non-2xx: 503") {
		t.Errorf("expected fail detail rendered")
	}
	// Sidebar active item.
	if !strings.Contains(body, "aria-current=\"page\"") {
		t.Errorf("missing aria-current on sidebar")
	}
}

func TestHealthOverview_NotConfigured_RendersUnknownAndBanner(t *testing.T) {
	t.Parallel()
	deps := &HealthDeps{
		Renderer:         mustRenderer(t),
		HealthConfigured: false,
	}
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req = withSession(req, newAdminSession())
	rr := httptest.NewRecorder()
	deps.HealthOverviewHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d", rr.Code)
	}
	body := rr.Body.String()
	if !strings.Contains(body, "Health probing is OFF") {
		t.Errorf("missing guidance banner")
	}
	if !strings.Contains(body, "lc-statusdot--unknown") {
		t.Errorf("expected at least one unknown status pill")
	}
}

func TestHealthOverview_Unauthenticated_RedirectsToLogin(t *testing.T) {
	t.Parallel()
	deps := &HealthDeps{Renderer: mustRenderer(t)}
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	deps.HealthOverviewHandler(rr, req)
	if rr.Code != http.StatusFound {
		t.Fatalf("status: %d want 302", rr.Code)
	}
	if loc := rr.Header().Get("Location"); !strings.HasPrefix(loc, "/login") {
		t.Errorf("location: %q", loc)
	}
}

func TestHealthGrafanaJWT_Admin_MintsAdminRole(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", grafana.MinSecretBytes)
	signer, err := grafana.NewSigner(secret, 0, nil)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	deps := &HealthDeps{
		Renderer:          mustRenderer(t),
		GrafanaSigner:     signer,
		GrafanaConfigured: true,
		GrafanaConfig: GrafanaPanelConfig{
			BaseURL:              "https://grafana.lucairn.local",
			GatewayThroughputUID: "abc-123",
		},
	}
	form := url.Values{}
	form.Set("panel", "gateway-throughput")
	req := httptest.NewRequest(http.MethodPost, "/health/grafana-jwt", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// CSRF: issue token then echo it back.
	rec := httptest.NewRecorder()
	getReq := httptest.NewRequest(http.MethodGet, "/health", nil)
	getReq = withSession(getReq, newAdminSession())
	tok, err := auth.IssueToken(rec, getReq)
	if err != nil {
		t.Fatalf("csrf issue: %v", err)
	}
	form.Set("csrf", tok)
	req = httptest.NewRequest(http.MethodPost, "/health/grafana-jwt", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// Re-attach the CSRF cookie via the GET's Set-Cookie header.
	for _, c := range rec.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withSession(req, newAdminSession())

	rr := httptest.NewRecorder()
	deps.HealthGrafanaJWTHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	var body struct {
		Token string `json:"token"`
		URL   string `json:"url"`
		TTL   int    `json:"ttl_seconds"`
	}
	if err := json.NewDecoder(rr.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Token == "" {
		t.Fatalf("token empty")
	}
	if !strings.Contains(body.URL, "auth_token=") {
		t.Errorf("url missing auth_token: %s", body.URL)
	}
	if !strings.Contains(body.URL, "/d/abc-123") {
		t.Errorf("url missing panel UID: %s", body.URL)
	}
	if body.TTL != 60 {
		t.Errorf("ttl_seconds: %d want 60", body.TTL)
	}
	// Parse the token and assert role=Admin.
	claims, err := signer.Parse(body.Token)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if claims.Role != "Admin" {
		t.Errorf("role=%q want Admin", claims.Role)
	}

	// Referrer-Policy header is the leak-defense.
	if got := rr.Header().Get("Referrer-Policy"); got != "no-referrer" {
		t.Errorf("Referrer-Policy: %q want no-referrer", got)
	}
}

func TestHealthGrafanaJWT_Viewer_MintsViewerRole(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", grafana.MinSecretBytes)
	signer, _ := grafana.NewSigner(secret, 0, nil)
	deps := &HealthDeps{
		Renderer:          mustRenderer(t),
		GrafanaSigner:     signer,
		GrafanaConfigured: true,
		GrafanaConfig: GrafanaPanelConfig{
			BaseURL:              "https://grafana.lucairn.local",
			GatewayThroughputUID: "abc-123",
		},
	}
	getRec := httptest.NewRecorder()
	getReq := httptest.NewRequest(http.MethodGet, "/health", nil)
	getReq = withSession(getReq, newViewerSession())
	tok, _ := auth.IssueToken(getRec, getReq)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("panel", "gateway-throughput")
	req := httptest.NewRequest(http.MethodPost, "/health/grafana-jwt", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range getRec.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withSession(req, newViewerSession())
	rr := httptest.NewRecorder()
	deps.HealthGrafanaJWTHandler(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	var body struct {
		Token string `json:"token"`
	}
	_ = json.NewDecoder(rr.Body).Decode(&body)
	claims, err := signer.Parse(body.Token)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if claims.Role != "Viewer" {
		t.Errorf("role=%q want Viewer", claims.Role)
	}
}

func TestHealthGrafanaJWT_Unauthenticated_401(t *testing.T) {
	t.Parallel()
	signer, _ := grafana.NewSigner(strings.Repeat("k", grafana.MinSecretBytes), 0, nil)
	deps := &HealthDeps{
		Renderer:          mustRenderer(t),
		GrafanaSigner:     signer,
		GrafanaConfigured: true,
	}
	req := httptest.NewRequest(http.MethodPost, "/health/grafana-jwt", strings.NewReader(""))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	deps.HealthGrafanaJWTHandler(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status: %d want 401", rr.Code)
	}
}

func TestHealthGrafanaJWT_NoCSRF_403(t *testing.T) {
	t.Parallel()
	signer, _ := grafana.NewSigner(strings.Repeat("k", grafana.MinSecretBytes), 0, nil)
	deps := &HealthDeps{
		Renderer:          mustRenderer(t),
		GrafanaSigner:     signer,
		GrafanaConfigured: true,
	}
	form := url.Values{}
	form.Set("panel", "gateway-throughput")
	req := httptest.NewRequest(http.MethodPost, "/health/grafana-jwt", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req = withSession(req, newAdminSession())
	rr := httptest.NewRecorder()
	deps.HealthGrafanaJWTHandler(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("status: %d want 403", rr.Code)
	}
}

func TestHealthGrafanaJWT_NotConfigured_503(t *testing.T) {
	t.Parallel()
	deps := &HealthDeps{
		Renderer:          mustRenderer(t),
		GrafanaConfigured: false,
	}
	getRec := httptest.NewRecorder()
	getReq := httptest.NewRequest(http.MethodGet, "/health", nil)
	getReq = withSession(getReq, newAdminSession())
	tok, _ := auth.IssueToken(getRec, getReq)
	form := url.Values{}
	form.Set("csrf", tok)
	req := httptest.NewRequest(http.MethodPost, "/health/grafana-jwt", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range getRec.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withSession(req, newAdminSession())
	rr := httptest.NewRecorder()
	deps.HealthGrafanaJWTHandler(rr, req)
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status: %d want 503", rr.Code)
	}
}

func TestHealthGrafanaJWT_UnknownPanelSlug_ReturnsEmptyURL(t *testing.T) {
	t.Parallel()
	secret := strings.Repeat("k", grafana.MinSecretBytes)
	signer, _ := grafana.NewSigner(secret, 0, nil)
	deps := &HealthDeps{
		Renderer:          mustRenderer(t),
		GrafanaSigner:     signer,
		GrafanaConfigured: true,
		GrafanaConfig:     GrafanaPanelConfig{BaseURL: "https://grafana.lucairn.local", GatewayThroughputUID: "abc"},
	}
	getRec := httptest.NewRecorder()
	getReq := httptest.NewRequest(http.MethodGet, "/health", nil)
	getReq = withSession(getReq, newAdminSession())
	tok, _ := auth.IssueToken(getRec, getReq)
	form := url.Values{}
	form.Set("csrf", tok)
	form.Set("panel", "not-a-real-panel")
	req := httptest.NewRequest(http.MethodPost, "/health/grafana-jwt", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for _, c := range getRec.Result().Cookies() {
		req.AddCookie(c)
	}
	req = withSession(req, newAdminSession())
	rr := httptest.NewRecorder()
	deps.HealthGrafanaJWTHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status: %d body=%s", rr.Code, rr.Body.String())
	}
	body, _ := io.ReadAll(rr.Body)
	if !strings.Contains(string(body), "\"url\":\"\"") {
		t.Errorf("expected empty url for unknown slug, body=%s", body)
	}
}

func TestHumanizeAgo_Buckets(t *testing.T) {
	t.Parallel()
	cases := []struct {
		d    time.Duration
		want string
	}{
		{500 * time.Millisecond, "just now"},
		{2 * time.Second, "2s ago"},
		{59 * time.Second, "59s ago"},
		{61 * time.Second, "1m ago"},
		{2 * time.Hour, "2h ago"},
		{36 * time.Hour, "stale"},
	}
	for _, tc := range cases {
		if got := humanizeAgo(tc.d); got != tc.want {
			t.Errorf("humanizeAgo(%v)=%q want %q", tc.d, got, tc.want)
		}
	}
}
