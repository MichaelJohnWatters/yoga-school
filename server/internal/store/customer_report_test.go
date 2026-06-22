package store

import (
	"context"
	"testing"
	"time"
)

func TestCustomerReportFor_AggregatesSpendVisitsNoShows(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	loc := s.StudioLocation(ctx, f.studioID)

	from := time.Date(2026, 1, 1, 0, 0, 0, 0, loc)
	to := time.Date(2026, 2, 1, 0, 0, 0, 0, loc)

	// Past class in window with one attended + one no-show for the student.
	classID := f.insertClass(t, s, time.Date(2026, 1, 10, 9, 0, 0, 0, loc), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	attendedID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings (id, studio_id, class_id, user_id, entitlement_id,
		   is_plus_one, booked_by_role, cancel_cutoff_hours, status, checkin_token)
		   VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'attended', ?)`,
		attendedID, f.studioID, classID, f.studentID, ent, NewID()); err != nil {
		t.Fatalf("attended booking: %v", err)
	}
	noShowID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings (id, studio_id, class_id, user_id, entitlement_id,
		   is_plus_one, booked_by_role, cancel_cutoff_hours, status, checkin_token)
		   VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'no_show', ?)`,
		noShowID, f.studioID, classID, f.studentID, ent, NewID()); err != nil {
		t.Fatalf("no-show booking: %v", err)
	}
	// Spend in window vs out of window.
	f.insertPurchaseAt(t, s, time.Date(2026, 1, 15, 12, 0, 0, 0, loc), "card", 3000)
	f.insertPurchaseAt(t, s, time.Date(2025, 12, 1, 12, 0, 0, 0, loc), "card", 9999)

	rep, err := s.CustomerReportFor(ctx, f.studioID, from, to, "spend", "")
	if err != nil {
		t.Fatalf("CustomerReportFor: %v", err)
	}
	if len(rep.Rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rep.Rows))
	}
	r := rep.Rows[0]
	if r.Visits != 1 {
		t.Errorf("visits = %d, want 1", r.Visits)
	}
	if r.NoShows != 1 {
		t.Errorf("no_shows = %d, want 1", r.NoShows)
	}
	if r.SpendMinor != 3000 {
		t.Errorf("spend = %d, want 3000 (out-of-window purchase excluded)", r.SpendMinor)
	}
	if r.LastSeenAt == nil {
		t.Errorf("last_seen should be set from the attended class")
	}
	if r.ActivePassLabel != "5 credits" {
		t.Errorf("pass label = %q, want %q", r.ActivePassLabel, "5 credits")
	}
}

func TestCustomerReportFor_ScopedToStudioAndSearch(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// A second studio's student must never appear.
	otherStudio := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO studios (id, name, welcome_message) VALUES (?, 'Other', 'Hi')`,
		otherStudio); err != nil {
		t.Fatalf("other studio: %v", err)
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, studio_id, role, email, full_name)
		 VALUES (?, ?, 'student', 'x@o.com', 'Outsider')`,
		NewID(), otherStudio); err != nil {
		t.Fatalf("other student: %v", err)
	}

	from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 2, 1, 0, 0, 0, 0, time.UTC)
	rep, err := s.CustomerReportFor(ctx, f.studioID, from, to, "name", "")
	if err != nil {
		t.Fatalf("CustomerReportFor: %v", err)
	}
	for _, r := range rep.Rows {
		if r.FullName == "Outsider" {
			t.Fatal("cross-studio student leaked into report")
		}
	}

	// Search filters by name.
	rep, err = s.CustomerReportFor(ctx, f.studioID, from, to, "name", "zzz-no-match")
	if err != nil {
		t.Fatalf("CustomerReportFor search: %v", err)
	}
	if len(rep.Rows) != 0 {
		t.Errorf("search rows = %d, want 0", len(rep.Rows))
	}
}
