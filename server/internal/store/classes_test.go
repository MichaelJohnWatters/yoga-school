package store

import (
	"context"
	"testing"
	"time"
)

func TestClassesInRange_FiltersByDateBounds(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Anchor: midnight UTC of a known day.
	day := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)

	before := f.insertClass(t, s, day.Add(-2*time.Hour), 10) // day before, 22:00
	inside1 := f.insertClass(t, s, day.Add(9*time.Hour), 10) // 09:00 same day
	inside2 := f.insertClass(t, s, day.Add(18*time.Hour), 10)
	after := f.insertClass(t, s, day.Add(24*time.Hour), 10) // exactly at upper bound: excluded

	rows, err := s.ClassesInRange(ctx, f.studioID, f.studentID, day, day.Add(24*time.Hour))
	if err != nil {
		t.Fatalf("ClassesInRange: %v", err)
	}
	got := idsOf(rows)
	if !contains(got, inside1) || !contains(got, inside2) {
		t.Errorf("missing in-range classes: got=%v want includes %s,%s", got, inside1, inside2)
	}
	if contains(got, before) || contains(got, after) {
		t.Errorf("returned out-of-range class: got=%v before=%s after=%s", got, before, after)
	}
}

func TestClassesInRange_OrdersByStartAscending(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	day := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	late := f.insertClass(t, s, day.Add(18*time.Hour), 10)
	early := f.insertClass(t, s, day.Add(8*time.Hour), 10)
	mid := f.insertClass(t, s, day.Add(12*time.Hour), 10)

	rows, err := s.ClassesInRange(ctx, f.studioID, f.studentID, day, day.Add(24*time.Hour))
	if err != nil {
		t.Fatalf("ClassesInRange: %v", err)
	}
	want := []string{early, mid, late}
	got := idsOf(rows)
	if !sliceEq(got, want) {
		t.Errorf("order: got %v want %v", got, want)
	}
}

func TestClassesInRange_ReportsBookingState(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	day := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	available := f.insertClass(t, s, day.Add(9*time.Hour), 10)
	booked := f.insertClass(t, s, day.Add(10*time.Hour), 10)
	full := f.insertClass(t, s, day.Add(11*time.Hour), 1)

	ent := f.insertEntitlement(t, s, "unlimited", 0)

	// Seed bookings directly — the fixture's anchor day is fixed in calendar
	// time, so depending on "now" these classes may already be past, which
	// CreateBooking refuses. The booking state assertions below don't care
	// how the rows got there.
	f.insertBookedSeat(t, s, booked, ent)
	otherStudent := insertOtherStudent(t, s, f.studioID)
	otherEnt := f.insertEntitlementFor(t, s, otherStudent, "unlimited", 0)
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'booked', ?)`,
		NewID(), f.studioID, full, otherStudent, otherEnt, NewID()); err != nil {
		t.Fatalf("seed full: %v", err)
	}

	rows, err := s.ClassesInRange(ctx, f.studioID, f.studentID, day, day.Add(24*time.Hour))
	if err != nil {
		t.Fatalf("ClassesInRange: %v", err)
	}
	states := map[string]string{}
	for _, r := range rows {
		states[r.ID] = r.BookingState
	}
	if states[available] != "available" {
		t.Errorf("available class state: got %q want available", states[available])
	}
	if states[booked] != "booked" {
		t.Errorf("booked class state: got %q want booked", states[booked])
	}
	if states[full] != "full" {
		t.Errorf("full class state: got %q want full", states[full])
	}
}

func TestPastBookings_OnlyPastAndOrdersDesc(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	now := time.Now().UTC()
	pastA := f.insertClass(t, s, now.Add(-48*time.Hour), 10)
	pastB := f.insertClass(t, s, now.Add(-12*time.Hour), 10)
	future := f.insertClass(t, s, now.Add(48*time.Hour), 10)

	ent := f.insertEntitlement(t, s, "unlimited", 0)
	// Seed past bookings directly (CreateBooking refuses past classes);
	// the future one still goes through the real path.
	f.insertBookedSeat(t, s, pastA, ent)
	f.insertBookedSeat(t, s, pastB, ent)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, future, ent, false, ""); err != nil {
		t.Fatalf("book %s: %v", future, err)
	}

	rows, err := s.PastBookings(ctx, f.studentID)
	if err != nil {
		t.Fatalf("PastBookings: %v", err)
	}
	got := classIdsOf(rows)
	want := []string{pastB, pastA} // latest first
	if !sliceEq(got, want) {
		t.Errorf("past order: got %v want %v", got, want)
	}
	if contains(got, future) {
		t.Errorf("future class leaked into past: %v", got)
	}
}

func TestPastBookings_IncludesCancelledAndAttended(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	now := time.Now().UTC()
	cancelled := f.insertClass(t, s, now.Add(-72*time.Hour), 10)
	attended := f.insertClass(t, s, now.Add(-24*time.Hour), 10)

	ent := f.insertEntitlement(t, s, "unlimited", 0)
	// Seed both rows in their terminal states directly. CreateBooking and
	// CancelBooking both refuse past classes (the "doors closed" gate), so
	// for historical fixtures we mint the final state in SQL.
	cBookingID := f.insertCancelledLateSeat(t, s, cancelled, ent)
	aBookingID := f.insertBookedSeat(t, s, attended, ent)
	if err := s.MarkAttendance(ctx, "actor-test", aBookingID, "attended", "manual"); err != nil {
		t.Fatalf("mark attended: %v", err)
	}

	rows, err := s.PastBookings(ctx, f.studentID)
	if err != nil {
		t.Fatalf("PastBookings: %v", err)
	}
	statuses := map[string]string{}
	for _, r := range rows {
		statuses[r.ClassID] = r.Status
	}
	if statuses[cancelled] != "cancelled" {
		t.Errorf("cancelled status: got %q want cancelled", statuses[cancelled])
	}
	if statuses[attended] != "attended" {
		t.Errorf("attended status: got %q want attended", statuses[attended])
	}

	// Outcome column should be written for both: late_burned on the cancel
	// (cutoff already past) and NULL on the attended one (no terminal
	// outcome for a present row).
	var cancOutcome, attOutcome string
	if err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(outcome,'') FROM bookings WHERE id = ?`, cBookingID,
	).Scan(&cancOutcome); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(outcome,'') FROM bookings WHERE id = ?`, aBookingID,
	).Scan(&attOutcome); err != nil {
		t.Fatal(err)
	}
	if cancOutcome != "cancelled_late_burned" {
		t.Errorf("cancelled outcome: got %q want cancelled_late_burned", cancOutcome)
	}
	if attOutcome != "" {
		t.Errorf("attended outcome should be NULL, got %q", attOutcome)
	}
}

// ---- helpers ----

func idsOf(rows []ClassRow) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.ID
	}
	return out
}

func classIdsOf(rows []UpcomingBooking) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.ClassID
	}
	return out
}

func contains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}

func sliceEq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
