package health

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

func TestParseServicesSpec_Defaults(t *testing.T) {
	t.Parallel()
	got, err := ParseServicesSpec("")
	if err != nil {
		t.Fatalf("default parse: %v", err)
	}
	// Default spec has 12 services per PRD § Slice 4 estimate.
	if len(got) != 12 {
		t.Fatalf("default services: got %d want 12 (names=%v)", len(got), names(got))
	}
	// Spot-check a few names + schemes for drift detection.
	mustHave := map[string]Scheme{
		"gateway":            SchemeHTTP,
		"sanitizer":          SchemeHTTP,
		"postgres-audit":     SchemeTCP,
		"postgres-sandbox-a": SchemeTCP,
		"redis":              SchemeTCP,
		"ollama":             SchemeHTTP,
	}
	have := make(map[string]Scheme, len(got))
	for _, s := range got {
		have[s.Name] = s.Scheme
	}
	for name, scheme := range mustHave {
		if have[name] != scheme {
			t.Errorf("default service %q: scheme=%v want %v", name, have[name], scheme)
		}
	}
}

func TestParseServicesSpec_HTTPSAndTCP(t *testing.T) {
	t.Parallel()
	spec := "a=https://a:8443/healthz,b=http://b:9000/healthz,c=tcp://c:5432"
	got, err := ParseServicesSpec(spec)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d want 3", len(got))
	}
	if got[0].Scheme != SchemeHTTPS || got[1].Scheme != SchemeHTTP || got[2].Scheme != SchemeTCP {
		t.Fatalf("schemes: %v", []Scheme{got[0].Scheme, got[1].Scheme, got[2].Scheme})
	}
	if got[2].Target != "c:5432" {
		t.Errorf("tcp target: got %q want c:5432", got[2].Target)
	}
}

func TestParseServicesSpec_Errors(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"missing_eq", "broken", "expected name=url"},
		{"empty_name", "=http://x/healthz", "empty name"},
		{"unknown_scheme", "x=ftp://y/z", "must start with"},
		{"tcp_no_port", "x=tcp://hostonly", "missing :port"},
		{"duplicate_name", "a=tcp://x:1,a=tcp://y:2", "duplicate service name"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := ParseServicesSpec(tc.in)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err=%v want substring %q", err, tc.want)
			}
		})
	}
}

func TestPoller_HTTPProbe_ClassifiesStatuses(t *testing.T) {
	t.Parallel()
	// One responder per status class so we can read the poller's mapping
	// without racing two probes against the same target.
	okSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer okSrv.Close()
	failSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer failSrv.Close()
	warnSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 3xx without Location is unusual; the poller maps it to warn.
		w.WriteHeader(http.StatusMovedPermanently)
	}))
	defer warnSrv.Close()

	services := []Service{
		{Name: "ok", URL: okSrv.URL, Scheme: SchemeHTTP},
		{Name: "fail", URL: failSrv.URL, Scheme: SchemeHTTP},
		{Name: "warn", URL: warnSrv.URL, Scheme: SchemeHTTP},
	}
	// Use a very long interval so only the immediate first-probe fires.
	p := NewPoller(services, PollerOpts{Interval: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)
	// Wait up to 5s for all three services to leave Unknown.
	if !waitForFinalStatus(t, p, 5*time.Second) {
		t.Fatalf("timeout waiting for first probes; snapshots: %v", p.Snapshots())
	}

	cases := map[string]Status{
		"ok":   StatusOK,
		"fail": StatusFail,
		"warn": StatusWarn,
	}
	for name, want := range cases {
		snap, ok := p.Snapshot(name)
		if !ok {
			t.Fatalf("snapshot missing for %q", name)
		}
		if snap.Status != want {
			t.Errorf("%s: status=%v want %v (detail=%q)", name, snap.Status, want, snap.Detail)
		}
		if snap.LastPoll.IsZero() {
			t.Errorf("%s: LastPoll zero — poller never wrote", name)
		}
	}
}

func TestPoller_TCPProbe(t *testing.T) {
	t.Parallel()
	// listener accepting; the poller dials successfully and reports ok.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer func() { _ = ln.Close() }()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()

	services := []Service{
		{Name: "alive", URL: "tcp://" + ln.Addr().String(), Scheme: SchemeTCP, Target: ln.Addr().String()},
		{Name: "dead", URL: "tcp://127.0.0.1:1", Scheme: SchemeTCP, Target: "127.0.0.1:1"},
	}
	p := NewPoller(services, PollerOpts{Interval: time.Hour, TCPTimeout: 500 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)

	if !waitForFinalStatus(t, p, 3*time.Second) {
		t.Fatalf("timeout waiting for tcp probes; snapshots: %v", p.Snapshots())
	}
	alive, _ := p.Snapshot("alive")
	if alive.Status != StatusOK {
		t.Errorf("alive: status=%v want ok (detail=%q)", alive.Status, alive.Detail)
	}
	dead, _ := p.Snapshot("dead")
	if dead.Status != StatusFail {
		t.Errorf("dead: status=%v want fail (detail=%q)", dead.Status, dead.Detail)
	}
}

func TestPoller_ContextCancelStopsGoroutines(t *testing.T) {
	t.Parallel()
	probes := int64(0)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt64(&probes, 1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	services := []Service{
		{Name: "a", URL: srv.URL, Scheme: SchemeHTTP},
		{Name: "b", URL: srv.URL, Scheme: SchemeHTTP},
	}
	// Very short interval so we'd see steady-state probe traffic.
	p := NewPoller(services, PollerOpts{Interval: 25 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	p.Start(ctx)

	// Let the goroutines run a handful of intervals.
	time.Sleep(150 * time.Millisecond)
	preCancel := atomic.LoadInt64(&probes)
	if preCancel < 2 {
		t.Fatalf("expected at least one probe per service before cancel, got %d", preCancel)
	}
	cancel()
	// Sleep > interval to ensure any in-flight tick fires + no new probes
	// arrive after the goroutines exit.
	time.Sleep(120 * time.Millisecond)
	stable := atomic.LoadInt64(&probes)
	time.Sleep(120 * time.Millisecond)
	final := atomic.LoadInt64(&probes)
	if final != stable {
		t.Fatalf("probes continued after cancel: stable=%d final=%d", stable, final)
	}
}

func TestPoller_StartIsIdempotent(t *testing.T) {
	t.Parallel()
	probes := int64(0)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt64(&probes, 1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	services := []Service{{Name: "x", URL: srv.URL, Scheme: SchemeHTTP}}
	p := NewPoller(services, PollerOpts{Interval: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.Start(ctx)
	p.Start(ctx) // expected no-op
	p.Start(ctx)
	// Wait for the immediate probe + give time for any duplicate goroutines.
	time.Sleep(250 * time.Millisecond)
	if got := atomic.LoadInt64(&probes); got != 1 {
		t.Fatalf("idempotency: probes=%d want 1 (Start was supposed to no-op the duplicates)", got)
	}
}

func TestSnapshot_DefensiveCopy(t *testing.T) {
	t.Parallel()
	services := []Service{{Name: "a", URL: "http://a", Scheme: SchemeHTTP}}
	p := NewPoller(services, PollerOpts{Interval: time.Hour})
	// Direct in-memory store write (no real probe).
	p.mu.Lock()
	p.snapshots["a"] = Snapshot{Service: services[0], Status: StatusOK, LastPoll: time.Now()}
	p.mu.Unlock()
	got1 := p.Snapshots()
	got1[0].Status = StatusFail
	got2 := p.Snapshots()
	if got2[0].Status != StatusOK {
		t.Errorf("Snapshots() returned a shared slice — mutation leaked into the next read (got %v)", got2[0].Status)
	}
}

func TestPoller_DetailTruncated(t *testing.T) {
	t.Parallel()
	long := strings.Repeat("x", 500)
	got := truncateDetail("transport: " + long)
	if len(got) > 180 {
		t.Errorf("truncateDetail returned %d bytes; want <=180", len(got))
	}
}

// TestPoller_DetailTruncated_UTF8 regression-locks bug-hunter M2 fix:
// a 2-byte UTF-8 rune (ü = 0xC3 0xBC) must NOT be sliced in the middle,
// or the returned string will be invalid UTF-8 and render as "U+FFFD" in
// the browser. The walk-back to a rune boundary keeps the output valid.
func TestPoller_DetailTruncated_UTF8(t *testing.T) {
	t.Parallel()
	// "ü" is 2 bytes; 250 copies = 500 bytes. The cap at 180 bytes will
	// almost certainly fall mid-rune without the rune-boundary walk-back.
	in := strings.Repeat("ü", 250)
	out := truncateDetail(in)
	if !utf8.ValidString(out) {
		t.Errorf("truncateDetail produced invalid UTF-8 (bytes: %x)", []byte(out))
	}
	if len(out) > 180 {
		t.Errorf("truncateDetail returned %d bytes; want <=180", len(out))
	}
}

func waitForFinalStatus(t *testing.T, p *Poller, total time.Duration) bool {
	t.Helper()
	deadline := time.Now().Add(total)
	for time.Now().Before(deadline) {
		all := p.Snapshots()
		allKnown := true
		for _, s := range all {
			if s.Status == StatusUnknown {
				allKnown = false
				break
			}
		}
		if allKnown {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func names(svcs []Service) string {
	parts := make([]string, 0, len(svcs))
	for _, s := range svcs {
		parts = append(parts, s.Name)
	}
	return strings.Join(parts, ",")
}

// Compile-time defense: the default services spec MUST parse without error
// across releases.
var _ = func() bool {
	if _, err := ParseServicesSpec(""); err != nil {
		panic(fmt.Sprintf("DefaultServicesSpec broken at compile-init time: %v", err))
	}
	return true
}()
