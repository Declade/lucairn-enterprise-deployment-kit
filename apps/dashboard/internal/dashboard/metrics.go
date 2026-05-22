// Package dashboard aggregates KPI + chart data for the enterprise
// home-page overview. Consumers: handlers/dashboard_home.go renders
// the result; the package does NOT touch HTTP or templates.
//
// The aggregator runs on every home-page request (cheap — counts +
// 30-day buckets over the in-memory or pgx-backed stores). For
// production installs with very large audit volumes the aggregator
// caps the windows it scans (CertWindowDays / AuditRecentLimit
// constants below); for the MVP these are conservative defaults.
package dashboard

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/gateway"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/health"
	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
)

// Narrowed source interfaces. Defined here (NOT imported from handlers/)
// to avoid an import cycle: handlers/dashboard_home.go imports
// dashboard, so dashboard can NOT import handlers. Go's structural
// typing means the production *store.CertStore + demodata.* impls
// satisfy both these interfaces AND the handlers.* aliases without
// any conversion ceremony.

// CertStorer mirrors handlers.CertStorer's read-path surface (no Stream
// — the aggregator only needs counts).
type CertStorer interface {
	List(ctx context.Context, filter store.CertFilter, page store.Page) ([]store.CertSummary, int, error)
	Get(ctx context.Context, id string) (store.CertSummary, error)
}

// AuditReadStore mirrors handlers.AuditReadStore.
type AuditReadStore interface {
	ListEvents(ctx context.Context, filter store.AuditFilter) ([]store.AuditEvent, int, error)
	GetEvent(ctx context.Context, eventID string) (*store.AuditEvent, error)
	DistinctEventTypes(ctx context.Context) ([]string, error)
	DistinctSourceServices(ctx context.Context) ([]string, error)
}

// AdminClient mirrors handlers.AdminClient.
type AdminClient interface {
	ListCustomers(ctx context.Context) ([]gateway.CustomerEntry, error)
	ListKeys(ctx context.Context, customerID string, reveal bool) (*gateway.ListKeysResult, error)
}

// HealthPoller mirrors handlers.HealthPoller.
type HealthPoller interface {
	Services() []health.Service
	Snapshots() []health.Snapshot
	Snapshot(name string) (health.Snapshot, bool)
}

const (
	CertWindowDays    = 30
	AuditRecentLimit  = 10
	HealthDownIsAlert = true
)

// Metrics is the full render payload for the dashboard home page.
type Metrics struct {
	// Hero KPI tiles.
	CertsTotal         int
	CertsLast24h       int
	CertsLast24hDelta  float64 // percent change vs the prior 24h window
	AuditEventsTotal   int
	AuditLast24h       int
	RedactionsTotal    int
	RedactionsLast24h  int
	ServicesUp         int
	ServicesTotal      int
	ServicesAllGreen   bool
	KeysActive         int
	CustomersWithKeys  int

	// Trend chart: cert volume per day across the last CertWindowDays.
	CertVolumeByDay []TimeSeriesPoint

	// Distribution chart: cert verdict counts.
	VerdictBuckets []NamedCount

	// Distribution chart: sanitizer redaction counts by detection layer.
	RedactionLayers []NamedCount

	// Recent activity table: last AuditRecentLimit audit events
	// (newest-first).
	RecentActivity []ActivityRow

	// Snapshot timestamp + window endpoints (UTC).
	GeneratedAt time.Time
	WindowFrom  time.Time
	WindowTo    time.Time
}

// TimeSeriesPoint is one bucket on a time-series chart.
type TimeSeriesPoint struct {
	Date  time.Time
	Count int
}

// NamedCount is a label/value pair for distribution charts.
type NamedCount struct {
	Label string
	Count int
}

// ActivityRow renders one line in the recent-activity table.
type ActivityRow struct {
	When      time.Time
	EventType string
	Source    string
	Actor     string
	RequestID string
}

// ComputeInput names the four data sources the aggregator reads.
// All fields are optional: when a source is nil the matching tiles +
// charts render as zero/empty (the template degrades the empty state
// to a dashed placeholder).
type ComputeInput struct {
	Certs        CertStorer
	Audits       AuditReadStore
	Admin        AdminClient
	HealthPoller HealthPoller
}

// Compute aggregates the four data sources into a renderable
// Metrics snapshot. Cap-bounded: the cert scan walks at most
// CertWindowDays of recent certs; the audit scan walks at most
// 1000 recent events. Returns a zero-value Metrics on context
// cancellation (no error — the page renders "no data" rather than
// surfacing a 500).
func Compute(ctx context.Context, in ComputeInput) Metrics {
	now := time.Now().UTC()
	windowFrom := now.Add(-time.Duration(CertWindowDays) * 24 * time.Hour)

	m := Metrics{
		GeneratedAt: now,
		WindowFrom:  windowFrom,
		WindowTo:    now,
	}

	// Cert metrics: list the last CertWindowDays of certs (capped at
	// 500 rows so a large production install doesn't pull the whole
	// table; the verdict-mix chart is accurate within that window).
	if in.Certs != nil {
		filter := store.CertFilter{From: windowFrom, To: now}
		certs, total, err := in.Certs.List(ctx, filter, store.Page{Limit: 500, Offset: 0})
		if err == nil {
			m.CertsTotal = total
			m.CertVolumeByDay, m.VerdictBuckets, m.CertsLast24h, m.CertsLast24hDelta = aggregateCerts(certs, now)
		}
	}

	// Audit metrics: pull the most recent 1000 events for the layer
	// distribution + recent-activity table.
	if in.Audits != nil {
		af := store.AuditFilter{Page: 1, PageSize: 1000}
		events, total, err := in.Audits.ListEvents(ctx, af)
		if err == nil {
			m.AuditEventsTotal = total
			m.AuditLast24h, m.RedactionsTotal, m.RedactionsLast24h, m.RedactionLayers = aggregateAudit(events, now)
			m.RecentActivity = recentActivity(events, AuditRecentLimit)
		}
	}

	// Service health: rolling readiness from the bundled poller.
	if in.HealthPoller != nil {
		snaps := in.HealthPoller.Snapshots()
		m.ServicesTotal = len(snaps)
		for _, s := range snaps {
			if s.Status == health.StatusOK {
				m.ServicesUp++
			}
		}
		m.ServicesAllGreen = m.ServicesTotal > 0 && m.ServicesUp == m.ServicesTotal
	}

	// Key counts: walk every customer + sum their active keys.
	if in.Admin != nil {
		customers, err := in.Admin.ListCustomers(ctx)
		if err == nil {
			for _, cust := range customers {
				keys, err := in.Admin.ListKeys(ctx, cust.CustomerID, false)
				if err != nil || keys == nil {
					continue
				}
				if len(keys.Keys) > 0 {
					m.CustomersWithKeys++
					m.KeysActive += len(keys.Keys)
				}
			}
		}
	}

	return m
}

// aggregateCerts walks the cert slice + produces:
//   - per-day buckets across the CertWindowDays
//   - verdict distribution counts
//   - last-24h count + delta vs the prior 24h window
func aggregateCerts(certs []store.CertSummary, now time.Time) ([]TimeSeriesPoint, []NamedCount, int, float64) {
	// Per-day buckets, oldest-first.
	buckets := make([]TimeSeriesPoint, CertWindowDays)
	for i := range buckets {
		buckets[i].Date = now.AddDate(0, 0, -(CertWindowDays - 1 - i)).Truncate(24 * time.Hour)
	}

	verdictCounts := map[string]int{}
	last24Cutoff := now.Add(-24 * time.Hour)
	prev24Cutoff := now.Add(-48 * time.Hour)
	last24, prev24 := 0, 0
	for _, c := range certs {
		age := now.Sub(c.CreatedAt) / (24 * time.Hour)
		dayIdx := int(CertWindowDays - 1 - int(age))
		if dayIdx >= 0 && dayIdx < CertWindowDays {
			buckets[dayIdx].Count++
		}

		v := c.Verdict
		if v == "" {
			v = "no-verdict"
		}
		verdictCounts[v]++

		if c.CreatedAt.After(last24Cutoff) {
			last24++
		} else if c.CreatedAt.After(prev24Cutoff) {
			prev24++
		}
	}

	// Stable verdict ordering for chart consistency across renders.
	verdictOrder := []string{"passed", "partial", "failed", "no-verdict"}
	verdictBuckets := make([]NamedCount, 0, len(verdictOrder))
	for _, v := range verdictOrder {
		if c, ok := verdictCounts[v]; ok && c > 0 {
			verdictBuckets = append(verdictBuckets, NamedCount{Label: v, Count: c})
		}
	}

	var delta float64
	if prev24 > 0 {
		delta = (float64(last24) - float64(prev24)) / float64(prev24) * 100.0
	}

	return buckets, verdictBuckets, last24, delta
}

// aggregateAudit walks the audit-event slice + produces:
//   - last-24h count
//   - total redactions (count of sanitizer.l*_redaction events)
//   - redaction count by layer (L1/L2/L3)
func aggregateAudit(events []store.AuditEvent, now time.Time) (last24 int, redTotal int, redLast24 int, redLayers []NamedCount) {
	last24Cutoff := now.Add(-24 * time.Hour)
	layerCounts := map[string]int{}
	for _, e := range events {
		if e.Timestamp.After(last24Cutoff) {
			last24++
		}
		var layer string
		switch e.EventType {
		case "sanitizer.l1_redaction":
			layer = "L1"
		case "sanitizer.l2_redaction":
			layer = "L2"
		case "sanitizer.l3_redaction":
			layer = "L3"
		default:
			continue
		}
		redTotal++
		if e.Timestamp.After(last24Cutoff) {
			redLast24++
		}
		layerCounts[layer]++
	}
	order := []string{"L1", "L2", "L3"}
	for _, l := range order {
		if c, ok := layerCounts[l]; ok && c > 0 {
			redLayers = append(redLayers, NamedCount{Label: l, Count: c})
		}
	}
	return last24, redTotal, redLast24, redLayers
}

// recentActivity returns the first `limit` events from the slice
// (the slice is already newest-first by store contract). RequestID
// is propagated so the template can link out to the cert browser.
func recentActivity(events []store.AuditEvent, limit int) []ActivityRow {
	if len(events) > limit {
		events = events[:limit]
	}
	out := make([]ActivityRow, len(events))
	for i, e := range events {
		out[i] = ActivityRow{
			When:      e.Timestamp,
			EventType: e.EventType,
			Source:    e.SourceService,
			Actor:     e.Actor,
			RequestID: e.RequestID,
		}
	}
	return out
}

// ZeroMetrics is what the handler renders when the home page is
// reached but no stores are wired (production install with default
// LUCAIRN_DASHBOARD_* env left empty). The template degrades each
// tile / chart to a dashed-placeholder render.
func ZeroMetrics() Metrics {
	now := time.Now().UTC()
	return Metrics{
		GeneratedAt: now,
		WindowFrom:  now.Add(-time.Duration(CertWindowDays) * 24 * time.Hour),
		WindowTo:    now,
	}
}

// CertVolumeValues projects Metrics.CertVolumeByDay onto a []int
// suitable for the sparkline FuncMap helper (which takes primitives so
// views package doesn't have to import dashboard).
func (m Metrics) CertVolumeValues() []int {
	out := make([]int, len(m.CertVolumeByDay))
	for i, p := range m.CertVolumeByDay {
		out[i] = p.Count
	}
	return out
}

// VerdictLabels + VerdictValues are parallel slices for donutSVG.
func (m Metrics) VerdictLabels() []string {
	out := make([]string, len(m.VerdictBuckets))
	for i, v := range m.VerdictBuckets {
		out[i] = v.Label
	}
	return out
}
func (m Metrics) VerdictValues() []int {
	out := make([]int, len(m.VerdictBuckets))
	for i, v := range m.VerdictBuckets {
		out[i] = v.Count
	}
	return out
}

// RedactionMax returns the max bar value across RedactionLayers so the
// bar chart row can render each bar in proportion. 0 when empty.
func (m Metrics) RedactionMax() int {
	maxV := 0
	for _, r := range m.RedactionLayers {
		if r.Count > maxV {
			maxV = r.Count
		}
	}
	return maxV
}

// HasAnyData returns true when any of the four data sources produced a
// non-zero count. Template uses this to render an empty-state hint
// when none of the surfaces are wired AND demo mode is off.
func (m Metrics) HasAnyData() bool {
	return m.CertsTotal > 0 || m.AuditEventsTotal > 0 || m.RedactionsTotal > 0 || m.ServicesTotal > 0 || m.KeysActive > 0
}

// Sort helper for deterministic chart rendering when callers feed
// pre-aggregated NamedCounts in non-canonical order.
func SortByCountDesc(items []NamedCount) []NamedCount {
	sort.SliceStable(items, func(a, b int) bool {
		return items[a].Count > items[b].Count
	})
	return items
}

// ErrNotConfigured is returned by a metrics provider when all four
// sources are nil and the operator should be nudged to wire
// LUCAIRN_DASHBOARD_DEMO_MODE=true or the real DB URLs.
var ErrNotConfigured = errors.New("dashboard: no metrics sources wired")

// Provider is the closure form of the handler.MetricsProvider
// interface: wraps a ComputeInput in a single Compute(ctx) call.
// Constructed by main.go for each backing impl (real + demo) and
// passed to handlers.Deps via the LiveMetrics / DemoMetrics fields.
type Provider struct {
	input ComputeInput
}

// NewProvider builds a Provider that runs Compute against the given
// stores on every call. Any nil store is tolerated (the matching
// tiles render with 0 values).
func NewProvider(in ComputeInput) *Provider {
	return &Provider{input: in}
}

// Compute satisfies the handlers.MetricsProvider interface.
func (p *Provider) Compute(ctx context.Context) Metrics {
	return Compute(ctx, p.input)
}

// MaxPayloadSizeForRender is the upper bound on returned recent-activity
// rows the template will render. Belt-and-braces against a future
// regression that uncaps AuditRecentLimit.
const MaxPayloadSizeForRender = 50

// _ = gateway.CustomerEntry{} keeps the gateway import live in the
// future-proof case where Compute() needs a tier breakdown KPI.
var _ = gateway.CustomerEntry{}

// _ enforces health.Snapshot is reachable from this package — the
// HealthPoller interface above relies on it.
var _ = health.Snapshot{}
