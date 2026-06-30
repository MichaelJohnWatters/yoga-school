package store

import (
	"context"
	"testing"
	"time"
)

// Voiding a pass frees the holder's future seat AND pulls the next waitlister in
// (the bulk-cancel paths now auto-promote, like a normal cancellation).
func TestVoidEntitlement_PromotesWaitlist(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	// A full class (capacity 1) booked by A on a pass; C waits with a usable pass.
	class := f.insertClass(t, s, time.Now().UTC().Add(36*time.Hour), 1)
	entA := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, entA, false, ""); err != nil {
		t.Fatalf("book A: %v", err)
	}
	studentC := insertOtherStudent(t, s, f.studioID)
	f.insertEntitlementFor(t, s, studentC, "unlimited", 0)
	if _, err := s.JoinWaitlist(ctx, studentC, class); err != nil {
		t.Fatalf("waitlist C: %v", err)
	}

	// Void A's pass → A's future seat is freed.
	if _, err := s.VoidEntitlement(ctx, f.studioID, f.instructorID, entA,
		VoidInput{Refund: "none", Reason: "test"}); err != nil {
		t.Fatalf("VoidEntitlement: %v", err)
	}

	// Promotion is async; poll for C to be booked into the freed seat.
	if !waitForBooking(t, s, class, studentC) {
		t.Fatal("waitlister C was not promoted into the freed seat")
	}
	// A's booking is cancelled.
	var aStatus string
	s.db.QueryRowContext(ctx,
		`SELECT status FROM bookings WHERE class_id=? AND user_id=?`, class, f.studentID).Scan(&aStatus)
	if aStatus != "cancelled" {
		t.Errorf("A booking = %q, want cancelled", aStatus)
	}
}

func waitForBooking(t *testing.T, s *Store, classID, userID string) bool {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		var n int
		s.db.QueryRowContext(context.Background(),
			`SELECT COUNT(*) FROM bookings WHERE class_id=? AND user_id=? AND status='booked'`,
			classID, userID).Scan(&n)
		if n > 0 {
			return true
		}
		time.Sleep(15 * time.Millisecond)
	}
	return false
}
