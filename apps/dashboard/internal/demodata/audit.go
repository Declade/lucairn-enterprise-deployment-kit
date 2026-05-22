package demodata

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/Declade/lucairn-enterprise-deployment-kit/apps/dashboard/internal/store"
)

// DemoAuditStore implements handlers.AuditReadStore + handlers.SavedFiltersReadWriteStore.
//
// Holds ~300 synthetic audit events spread across the last 30 days, with
// the event-type / source-service mix matching the cover-page PDF's
// Category 3 inventory (audit.cert_issued dominates).
type DemoAuditStore struct {
	events       []store.AuditEvent
	savedFilters map[string][]store.SavedFilter // user_email → filters
}

// NewAuditStore builds a fresh in-memory audit store.
func NewAuditStore() *DemoAuditStore {
	now := SeedTime()

	type seed struct {
		eventType     string
		sourceService string
		count         int
	}
	// Roughly proportional to Cat 3 inventory on the customer-handed PDF
	// (8500 cert_issued + 50 key.mint + ... scaled down to ~300 total).
	seeds := []seed{
		{"audit.cert_issued", "dsa-gateway", 200},
		{"sanitizer.l1_redaction", "dsa-sanitizer", 40},
		{"sanitizer.l2_redaction", "dsa-sanitizer", 15},
		{"sanitizer.l3_redaction", "dsa-sanitizer", 3},
		{"key.mint_requested", "lucairn-dashboard", 18},
		{"key.revoke_requested", "lucairn-dashboard", 8},
		{"audit.csv_export_with_reveal", "lucairn-dashboard", 4},
		{"audit.reveal_raw", "lucairn-dashboard", 6},
		{"audit.compliance_pdf_generated", "lucairn-dashboard", 12},
	}
	actors := []string{
		"admin@acme.local",
		"compliance@acme.local",
		"sre@acme.local",
		"reviewer@acme.local",
	}

	events := make([]store.AuditEvent, 0, 320)
	id := int64(1000)
	for _, s := range seeds {
		for i := 0; i < s.count; i++ {
			// Spread across the 30-day window with a stable hash so
			// re-renders show the same timeline.
			minuteOffset := int(int64(s.eventType[0]+s.eventType[len(s.eventType)-1])+int64(i)*37) % (30 * 24 * 60)
			ts := now.Add(-time.Duration(minuteOffset) * time.Minute)
			actor := actors[(int(id)+i)%len(actors)]
			reqID := formatRequestID((i * 13) % 50)
			payload := buildPayload(s.eventType, actor, reqID)
			payloadJSON, _ := json.Marshal(payload)
			events = append(events, store.AuditEvent{
				ID:            id,
				EventID:       fmt.Sprintf("ev_%010d", id),
				EventType:     s.eventType,
				SourceService: s.sourceService,
				Actor:         actor,
				Timestamp:     ts,
				EventHash:     fmt.Sprintf("sha256:%x", id*0x1f1f1f),
				Payload:       payloadJSON,
				RequestID:     reqID,
				PayloadType:   "FLAT_JSON",
			})
			id++
		}
	}

	// Sort newest first (matches the production browser default).
	sort.SliceStable(events, func(a, b int) bool {
		return events[a].Timestamp.After(events[b].Timestamp)
	})

	// Backfill PreviousEventHash chain (oldest-to-newest, then sort
	// re-applies so the chain links by row order). Cosmetic for the
	// demo — production chain-of-custody verification is not exercised.
	for i := range events {
		if i+1 < len(events) {
			events[i].PreviousEventHash = events[i+1].EventHash
		}
	}

	return &DemoAuditStore{
		events:       events,
		savedFilters: make(map[string][]store.SavedFilter),
	}
}

func buildPayload(eventType, actor, requestID string) map[string]any {
	base := map[string]any{
		"actor":      actor,
		"request_id": requestID,
		"customer":   "Acme Corp GmbH",
	}
	switch {
	case strings.HasPrefix(eventType, "audit.cert_issued"):
		base["verdict"] = "passed"
		base["redaction_count"] = 4
	case strings.HasPrefix(eventType, "sanitizer."):
		base["entity_type"] = "PERSON"
	case strings.HasPrefix(eventType, "key.mint"):
		base["key_prefix"] = "lcr_live_demo"
	case strings.HasPrefix(eventType, "key.revoke"):
		base["key_id"] = "k_demo_42"
	case strings.HasPrefix(eventType, "audit.compliance_pdf_generated"):
		base["page_count"] = 4
		base["byte_size"] = 5779
	}
	return base
}

// ListEvents implements handlers.AuditReadStore.
func (s *DemoAuditStore) ListEvents(ctx context.Context, filter store.AuditFilter) ([]store.AuditEvent, int, error) {
	filtered := s.applyFilter(filter)
	total := len(filtered)

	pageSize := filter.PageSize
	if pageSize <= 0 {
		pageSize = 50
	}
	page := filter.Page
	if page <= 0 {
		page = 1
	}
	offset := (page - 1) * pageSize
	if offset >= total {
		return []store.AuditEvent{}, total, nil
	}
	end := offset + pageSize
	if end > total {
		end = total
	}
	return filtered[offset:end], total, nil
}

// GetEvent implements handlers.AuditReadStore.
func (s *DemoAuditStore) GetEvent(ctx context.Context, eventID string) (*store.AuditEvent, error) {
	for i := range s.events {
		if s.events[i].EventID == eventID {
			ev := s.events[i]
			return &ev, nil
		}
	}
	return nil, nil
}

// DistinctEventTypes implements handlers.AuditReadStore.
func (s *DemoAuditStore) DistinctEventTypes(ctx context.Context) ([]string, error) {
	set := make(map[string]struct{}, 16)
	for _, e := range s.events {
		set[e.EventType] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out, nil
}

// DistinctSourceServices implements handlers.AuditReadStore.
func (s *DemoAuditStore) DistinctSourceServices(ctx context.Context) ([]string, error) {
	set := make(map[string]struct{}, 4)
	for _, e := range s.events {
		set[e.SourceService] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out, nil
}

// Save implements handlers.SavedFiltersReadWriteStore.
func (s *DemoAuditStore) Save(ctx context.Context, user, name string, filter store.AuditFilter) error {
	now := SeedTime()
	existing := s.savedFilters[user]
	for i, sf := range existing {
		if sf.Name == name {
			existing[i].Filter = filter
			existing[i].UpdatedAt = now
			s.savedFilters[user] = existing
			return nil
		}
	}
	existing = append(existing, store.SavedFilter{
		ID:        int64(len(existing) + 1),
		UserEmail: user,
		Name:      name,
		Filter:    filter,
		CreatedAt: now,
		UpdatedAt: now,
	})
	s.savedFilters[user] = existing
	return nil
}

// List implements handlers.SavedFiltersReadWriteStore.
func (s *DemoAuditStore) List(ctx context.Context, user string) ([]store.SavedFilter, error) {
	src := s.savedFilters[user]
	out := make([]store.SavedFilter, len(src))
	copy(out, src)
	sort.SliceStable(out, func(a, b int) bool {
		return out[a].Name < out[b].Name
	})
	return out, nil
}

// Delete implements handlers.SavedFiltersReadWriteStore.
func (s *DemoAuditStore) Delete(ctx context.Context, user, name string) error {
	existing := s.savedFilters[user]
	for i, sf := range existing {
		if sf.Name == name {
			s.savedFilters[user] = append(existing[:i], existing[i+1:]...)
			return nil
		}
	}
	return nil
}

func (s *DemoAuditStore) applyFilter(f store.AuditFilter) []store.AuditEvent {
	out := make([]store.AuditEvent, 0, len(s.events))
	for _, e := range s.events {
		if f.TimestampFrom != nil && e.Timestamp.Before(*f.TimestampFrom) {
			continue
		}
		if f.TimestampTo != nil && !e.Timestamp.Before(*f.TimestampTo) {
			continue
		}
		if f.RequestID != "" && e.RequestID != f.RequestID {
			continue
		}
		if f.PayloadContains != "" && !strings.Contains(string(e.Payload), f.PayloadContains) {
			continue
		}
		if len(f.EventTypes) > 0 && !containsString(f.EventTypes, e.EventType) {
			continue
		}
		if len(f.SourceServices) > 0 && !containsString(f.SourceServices, e.SourceService) {
			continue
		}
		if len(f.Actors) > 0 && !containsString(f.Actors, e.Actor) {
			continue
		}
		out = append(out, e)
	}
	return out
}

func containsString(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}
