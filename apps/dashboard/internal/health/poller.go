package health

import (
	"context"
	"net"
	"net/http"
	"sync"
	"time"
	"unicode/utf8"
)

// Status enumerates the four rendered states. Unknown is the pre-poll
// initial value the snapshot starts with so the overview page can render
// immediately on Slice 4 first-load before any goroutine has reported.
type Status string

const (
	StatusUnknown Status = "unknown"
	StatusOK      Status = "ok"
	StatusWarn    Status = "warn"
	StatusFail    Status = "fail"
)

// Snapshot is the renderable status of a single service at a moment in
// time. The poller atomically swaps the per-service entry in its
// internal map after each probe; the GET-side reader grabs a defensive
// copy by holding the RLock for the duration of the read.
//
// LastPoll is set after every probe attempt — success or failure — so the
// overview page can render "last polled 4s ago" honestly even on a
// service that has been failing for hours.
//
// Detail is a short, redactable human-facing explanation of the current
// status. For OK probes it's empty (the dot + label carry the signal). For
// WARN/FAIL it's a one-line reason (e.g. "non-200: 503", "dial: connection
// refused"). Never includes request headers, response bodies, or any other
// payload — the policy is "shape only", not "content", so accidental PII
// in a probed service's healthz body never leaks into the dashboard's UI.
type Snapshot struct {
	Service  Service
	Status   Status
	LastPoll time.Time
	Detail   string
}

// Poller probes every configured service concurrently on the configured
// interval and exposes a thread-safe snapshot reader. The poller has no
// retry semantics — every tick is an independent probe with a short
// (~3s) timeout. Operators watching the overview see the truth of "is
// the probe currently passing?" without an averaging layer hiding flaps.
type Poller struct {
	services   []Service
	interval   time.Duration
	httpClient *http.Client
	tcpTimeout time.Duration

	mu        sync.RWMutex
	snapshots map[string]Snapshot

	// now is injected for tests; defaults to time.Now in NewPoller.
	now func() time.Time

	// started is set once Start is invoked so the second call is a
	// no-op rather than spawning a second set of goroutines.
	started bool
}

// PollerOpts groups the optional Poller knobs. ProbeTimeout caps a single
// HTTP probe; TCPTimeout caps a TCP dial. Both default to 3s.
type PollerOpts struct {
	Interval     time.Duration
	ProbeTimeout time.Duration
	TCPTimeout   time.Duration
	HTTPClient   *http.Client // optional override; defaults to a fresh client with ProbeTimeout
	Now          func() time.Time
}

// NewPoller constructs a Poller for the supplied service list.
//
// Interval defaults to 10s (per PRD § Slice 4). Probe + TCP timeouts
// default to 3s. The HTTP client is constructed with the configured
// ProbeTimeout so a misbehaving service can't tie up its goroutine for
// longer than one interval.
func NewPoller(services []Service, opts PollerOpts) *Poller {
	interval := opts.Interval
	if interval <= 0 {
		interval = 10 * time.Second
	}
	probeTimeout := opts.ProbeTimeout
	if probeTimeout <= 0 {
		probeTimeout = 3 * time.Second
	}
	tcpTimeout := opts.TCPTimeout
	if tcpTimeout <= 0 {
		tcpTimeout = 3 * time.Second
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	httpClient := opts.HTTPClient
	if httpClient == nil {
		httpClient = &http.Client{Timeout: probeTimeout}
	}
	snaps := make(map[string]Snapshot, len(services))
	for _, s := range services {
		snaps[s.Name] = Snapshot{Service: s, Status: StatusUnknown}
	}
	return &Poller{
		services:   services,
		interval:   interval,
		httpClient: httpClient,
		tcpTimeout: tcpTimeout,
		snapshots:  snaps,
		now:        now,
	}
}

// Services returns the configured service list in registration order. Used
// by the renderer so the cards in the overview keep a stable order across
// renders.
func (p *Poller) Services() []Service {
	out := make([]Service, len(p.services))
	copy(out, p.services)
	return out
}

// Snapshot returns the current rolling-status read for a single service,
// or false if name is unknown.
func (p *Poller) Snapshot(name string) (Snapshot, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	s, ok := p.snapshots[name]
	return s, ok
}

// Snapshots returns a defensive copy of every service's current snapshot.
// Order matches Services().
func (p *Poller) Snapshots() []Snapshot {
	p.mu.RLock()
	defer p.mu.RUnlock()
	out := make([]Snapshot, len(p.services))
	for i, s := range p.services {
		out[i] = p.snapshots[s.Name]
	}
	return out
}

// Start spawns one polling goroutine per service. Each goroutine runs
// until ctx is Done. Start is idempotent — calling it twice on the same
// Poller is a no-op.
//
// The first probe fires immediately so the overview page has fresh data
// before the first interval tick. Subsequent probes are spaced by
// `interval`.
func (p *Poller) Start(ctx context.Context) {
	p.mu.Lock()
	if p.started {
		p.mu.Unlock()
		return
	}
	p.started = true
	p.mu.Unlock()
	for _, svc := range p.services {
		svc := svc
		go p.serviceLoop(ctx, svc)
	}
}

// serviceLoop is the per-service tick loop. Each tick performs ONE probe
// (HTTP GET or TCP dial), maps the outcome to a Status, and stores the
// result in the snapshots map under the service lock.
func (p *Poller) serviceLoop(ctx context.Context, svc Service) {
	// First probe is immediate. Subsequent probes are on the ticker.
	p.probeAndStore(ctx, svc)
	t := time.NewTicker(p.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.probeAndStore(ctx, svc)
		}
	}
}

// probeAndStore runs a single probe + writes the resulting Snapshot.
//
// HTTP probes treat 2xx as ok. 5xx / 4xx / network errors map to fail.
// 3xx maps to warn (operator should investigate but the service is
// reachable). TCP probes report ok on dial success, fail on dial error.
//
// LastPoll is always written, even on failure.
func (p *Poller) probeAndStore(ctx context.Context, svc Service) {
	status, detail := p.probe(ctx, svc)
	p.mu.Lock()
	p.snapshots[svc.Name] = Snapshot{
		Service:  svc,
		Status:   status,
		LastPoll: p.now(),
		Detail:   detail,
	}
	p.mu.Unlock()
}

// probe executes the probe and returns the mapped Status + detail.
func (p *Poller) probe(ctx context.Context, svc Service) (Status, string) {
	switch svc.Scheme {
	case SchemeHTTP, SchemeHTTPS:
		return p.probeHTTP(ctx, svc)
	case SchemeTCP:
		return p.probeTCP(ctx, svc)
	default:
		return StatusFail, "unknown scheme"
	}
}

func (p *Poller) probeHTTP(ctx context.Context, svc Service) (Status, string) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, svc.URL, nil)
	if err != nil {
		return StatusFail, truncateDetail("request build: " + err.Error())
	}
	resp, err := p.httpClient.Do(req)
	if err != nil {
		// net errors (dial refused, DNS lookup fail, context cancel during shutdown).
		return StatusFail, truncateDetail("transport: " + err.Error())
	}
	defer func() {
		_ = resp.Body.Close()
	}()
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return StatusOK, ""
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return StatusWarn, truncateDetail("unexpected redirect: " + resp.Status)
	default:
		return StatusFail, truncateDetail("non-2xx: " + resp.Status)
	}
}

func (p *Poller) probeTCP(ctx context.Context, svc Service) (Status, string) {
	d := net.Dialer{Timeout: p.tcpTimeout}
	conn, err := d.DialContext(ctx, "tcp", svc.Target)
	if err != nil {
		return StatusFail, truncateDetail("dial: " + err.Error())
	}
	_ = conn.Close()
	return StatusOK, ""
}

// truncateDetail caps detail strings at 180 bytes so a long error string
// (full DNS resolution stack, certificate dump, etc.) doesn't smash the
// UI card layout. Renderers can rely on Detail being short.
//
// "…" is a 3-byte UTF-8 sequence; account for that in the slice bound so
// the returned string never exceeds the documented cap.
//
// UTF-8 safety (Slice 4 fix-up r1, closes bug-hunter M2): a naive byte
// slice can chop a multi-byte rune in half (e.g. inside a German "ü" or
// any non-ASCII PII echoed from a probe target). Walk back from the
// initial cut point until we land on a rune boundary so the returned
// string is always valid UTF-8.
func truncateDetail(s string) string {
	const max = 180
	if len(s) <= max {
		return s
	}
	const ellipsis = "…" // 3 bytes UTF-8
	cut := max - len(ellipsis)
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + ellipsis
}
