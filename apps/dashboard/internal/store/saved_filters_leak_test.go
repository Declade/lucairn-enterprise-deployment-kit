// Slice 6 fix-up r1 BLOCKER regression test.
//
// TestSavedFilters_NoConnectionLeak pins the B1 fix: Save + Delete
// MUST use Exec (which never opens a Rows) and NOT Query (which
// returns a pgx.Rows that the caller MUST Close — the previous
// implementation discarded the Rows on every Save/Delete and starved
// the MaxConns=4 saved-filters pool after ~4 ops with no error in
// logs).

package store

import (
	"context"
	"strconv"
	"strings"
	"testing"
)

func TestSavedFilters_NoConnectionLeak(t *testing.T) {
	t.Parallel()
	db := &fakeDB{}
	sf := NewSavedFiltersStore(db)
	ctx := context.Background()
	const rounds = 16
	for i := 0; i < rounds; i++ {
		if err := sf.Save(ctx, "alice@x", "f"+strconv.Itoa(i), AuditFilter{}); err != nil {
			t.Fatalf("save %d: %v", i, err)
		}
		if err := sf.Delete(ctx, "alice@x", "f"+strconv.Itoa(i)); err != nil {
			t.Fatalf("delete %d: %v", i, err)
		}
	}
	calls := db.calls
	if len(calls) != rounds*2 {
		t.Fatalf("expected %d DB calls (%d saves + %d deletes), got %d", rounds*2, rounds, rounds, len(calls))
	}
	insertCount := 0
	deleteCount := 0
	for _, c := range calls {
		if strings.Contains(c.sql, "INSERT INTO dashboard_saved_filters") {
			insertCount++
		}
		if strings.Contains(c.sql, "DELETE FROM dashboard_saved_filters") {
			deleteCount++
		}
	}
	if insertCount != rounds || deleteCount != rounds {
		t.Fatalf("call shape: inserts=%d deletes=%d (want %d + %d)", insertCount, deleteCount, rounds, rounds)
	}
}
