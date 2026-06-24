package store

import (
	"context"
	"fmt"
	"testing"
)

// insertAuditAt inserts an audit row with an explicit created_at so ordering
// is deterministic (the live path stamps "now", which collides at ms scale).
func (f fixture) insertAuditAt(t *testing.T, s *Store, action, detail, createdAt string) {
	t.Helper()
	if _, err := s.db.ExecContext(context.Background(), `
		INSERT INTO audit_log (id, studio_id, actor_id, action, target_type, detail, created_at)
		VALUES (?, ?, ?, ?, 'test', ?, ?)`,
		NewID(), f.studioID, f.instructorID, action, detail, createdAt,
	); err != nil {
		t.Fatalf("insert audit: %v", err)
	}
}

// TestListAudit_KeysetPaginatesWithoutGapsOrDupes walks every page and checks
// the union is the full set, newest-first, with nothing repeated or skipped.
func TestListAudit_KeysetPaginatesWithoutGapsOrDupes(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	// 7 rows, created_at increasing so T07 is newest.
	for i := 1; i <= 7; i++ {
		f.insertAuditAt(t, s, "class_create", fmt.Sprintf(`{"n":%d}`, i),
			fmt.Sprintf("2026-06-01T00:00:0%d.000Z", i))
	}

	var got []string // created_at values, in page order
	cursor := ""
	pages := 0
	for {
		page, err := s.ListAudit(ctx, f.studioID, AuditQuery{Cursor: cursor, Limit: 3})
		if err != nil {
			t.Fatalf("ListAudit: %v", err)
		}
		pages++
		for _, e := range page.Entries {
			got = append(got, e.CreatedAt)
		}
		if page.NextCursor == "" {
			break
		}
		cursor = page.NextCursor
		if pages > 10 {
			t.Fatal("pagination did not terminate")
		}
	}

	// 3 + 3 + 1 across three pages, newest-first, no repeats.
	want := []string{
		"2026-06-01T00:00:07.000Z", "2026-06-01T00:00:06.000Z",
		"2026-06-01T00:00:05.000Z", "2026-06-01T00:00:04.000Z",
		"2026-06-01T00:00:03.000Z", "2026-06-01T00:00:02.000Z",
		"2026-06-01T00:00:01.000Z",
	}
	if pages != 3 {
		t.Errorf("pages: got %d want 3", pages)
	}
	if len(got) != len(want) {
		t.Fatalf("rows: got %d want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("row %d: got %s want %s", i, got[i], want[i])
		}
	}
}

// TestListAudit_FilterAndSearch confirms the action filter + free-text search
// run server-side (over the whole table, not a single page).
func TestListAudit_FilterAndSearch(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	f.insertAuditAt(t, s, "cash_grant", `{"student_name":"Maya Rowe"}`, "2026-06-01T00:00:01.000Z")
	f.insertAuditAt(t, s, "booking_create", `{"class_title":"Vinyasa Flow"}`, "2026-06-01T00:00:02.000Z")
	f.insertAuditAt(t, s, "cash_grant", `{"student_name":"Ben Carter"}`, "2026-06-01T00:00:03.000Z")

	// Action filter.
	page, err := s.ListAudit(ctx, f.studioID, AuditQuery{Action: "cash_grant", Limit: 50})
	if err != nil {
		t.Fatalf("filter: %v", err)
	}
	if len(page.Entries) != 2 {
		t.Errorf("action filter: got %d want 2", len(page.Entries))
	}
	for _, e := range page.Entries {
		if e.Action != "cash_grant" {
			t.Errorf("filter leaked action %q", e.Action)
		}
	}

	// Free-text search over the detail blob.
	page, err = s.ListAudit(ctx, f.studioID, AuditQuery{Search: "Vinyasa", Limit: 50})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(page.Entries) != 1 || page.Entries[0].Action != "booking_create" {
		t.Errorf("search: got %+v, want the one Vinyasa booking row", page.Entries)
	}
}
