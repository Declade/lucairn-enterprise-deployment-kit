package demodata

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
	"github.com/jackc/pgx/v5"
)

// DemoCertStore is an in-memory CertStorer + BulkCertResolver.
// Satisfies both interfaces declared in apps/dashboard/internal/handlers/
// (CertStorer at certs.go:39, BulkCertResolver at bulk_reverify.go:25).
//
// Holds ~50 synthetic certs generated at construction time.
type DemoCertStore struct {
	certs []store.CertSummary
	// reqByCert maps cert_id → request_id for the bulk re-verify resolver.
	reqByCert map[string]string
}

// NewCertStore builds a fresh demo cert store. Generates 50 certs
// distributed across the 30 days ending at SeedTime(), with verdict
// distribution roughly matching the cover-page sampleInput counts (80%
// passed, 17% partial, 2% failed, 1% no-verdict).
func NewCertStore() *DemoCertStore {
	now := SeedTime()
	verdicts := []string{"passed", "partial", "failed", ""}
	verdictWeights := []int{40, 8, 1, 1} // 80/16/2/2 split across 50

	const total = 50
	certs := make([]store.CertSummary, 0, total)
	reqByCert := make(map[string]string, total)

	pickVerdict := func(i int) string {
		acc := 0
		for j, w := range verdictWeights {
			acc += w
			if i < acc {
				return verdicts[j]
			}
		}
		return verdicts[0]
	}

	for i := 0; i < total; i++ {
		certID := formatCertID(i)
		reqID := formatRequestID(i)
		// Spread 50 certs across the last 30 days; newest first when
		// sorted by CreatedAt desc.
		createdAt := now.Add(-time.Duration(i) * 14 * time.Hour)
		certs = append(certs, store.CertSummary{
			ID:             certID,
			RequestID:      reqID,
			CustomerID:     demoCustomerID,
			CreatedAt:      createdAt,
			Verdict:        pickVerdict(i % total),
			RedactionCount: (i * 7) % 23,    // 0..22 pseudo-random spread
			ClaimCount:     3 + (i % 2),     // 3 or 4 claims per cert
		})
		reqByCert[certID] = reqID
	}

	// Sort newest first (the cert browser default).
	sort.SliceStable(certs, func(a, b int) bool {
		return certs[a].CreatedAt.After(certs[b].CreatedAt)
	})

	return &DemoCertStore{certs: certs, reqByCert: reqByCert}
}

// List implements handlers.CertStorer.
func (s *DemoCertStore) List(ctx context.Context, filter store.CertFilter, page store.Page) ([]store.CertSummary, int, error) {
	filtered := s.applyFilter(filter)
	total := len(filtered)

	limit := page.Limit
	if limit <= 0 {
		limit = 50
	}
	offset := page.Offset
	if offset < 0 {
		offset = 0
	}
	if offset >= total {
		return []store.CertSummary{}, total, nil
	}
	end := offset + limit
	if end > total {
		end = total
	}
	return filtered[offset:end], total, nil
}

// Get implements handlers.CertStorer.
func (s *DemoCertStore) Get(ctx context.Context, id string) (store.CertSummary, error) {
	for _, c := range s.certs {
		if c.ID == id {
			return c, nil
		}
	}
	return store.CertSummary{}, errors.New("cert not found (demo store)")
}

// Stream implements handlers.CertStorer. Demo mode does NOT support
// the streaming CSV export path — pgx.Rows is a deep interface and the
// dashboard browser surface (which uses List, not Stream) covers the
// demo use case. CSV export will return 503 in demo mode.
func (s *DemoCertStore) Stream(ctx context.Context, filter store.CertFilter) (pgx.Rows, error) {
	return nil, errors.New("demo mode: CSV export of certs not supported (use the browser surface)")
}

// GetRequestIDsByCertIDs implements handlers.BulkCertResolver. Bulk
// re-verify still works in demo mode for the cert-id → request-id
// lookup; the witness Verify call will degrade gracefully on real RPC
// (witness client wired to a non-functional endpoint in demo mode →
// per-cert reverify returns a friendly error and the bulk job tags
// each row "verifier_unavailable").
func (s *DemoCertStore) GetRequestIDsByCertIDs(ctx context.Context, certIDs []string) (map[string]string, error) {
	out := make(map[string]string, len(certIDs))
	for _, cid := range certIDs {
		if rid, ok := s.reqByCert[cid]; ok {
			out[cid] = rid
		}
	}
	return out, nil
}

// applyFilter walks the in-memory cert slice and returns rows that
// pass the user's filter. Mirrors the SQL WHERE clauses of the real
// store as closely as a memory scan can.
func (s *DemoCertStore) applyFilter(f store.CertFilter) []store.CertSummary {
	out := make([]store.CertSummary, 0, len(s.certs))
	for _, c := range s.certs {
		if !f.From.IsZero() && c.CreatedAt.Before(f.From) {
			continue
		}
		if !f.To.IsZero() && !c.CreatedAt.Before(f.To) {
			continue
		}
		if f.CustomerID != "" && c.CustomerID != f.CustomerID {
			continue
		}
		if f.RedactionMin > 0 && c.RedactionCount < f.RedactionMin {
			continue
		}
		if len(f.Verdicts) > 0 {
			matched := false
			for _, v := range f.Verdicts {
				if c.Verdict == v {
					matched = true
					break
				}
			}
			if !matched {
				continue
			}
		}
		out = append(out, c)
	}
	return out
}
