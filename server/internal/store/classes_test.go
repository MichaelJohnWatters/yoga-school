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

	// Book one class for the caller.
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, booked, ent, false); err != nil {
		t.Fatalf("seed booking: %v", err)
	}
	// Fill the "full" class with another student.
	otherStudent := insertOtherStudent(t, s, f.studioID)
	otherEnt := f.insertEntitlementFor(t, s, otherStudent, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, otherStudent, full, otherEnt, false); err != nil {
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
	for _, c := range []string{pastA, pastB, future} {
		if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, c, ent, false); err != nil {
			t.Fatalf("book %s: %v", c, err)
		}
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
	cBookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, cancelled, ent, false)
	if err != nil {
		t.Fatalf("book cancelled: %v", err)
	}
	if err := s.CancelBooking(ctx, f.studentID, cBookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	aBookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, attended, ent, false)
	if err != nil {
		t.Fatalf("book attended: %v", err)
	}
	if err := s.MarkAttendance(ctx, aBookingID, "attended", "manual"); err != nil {
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
