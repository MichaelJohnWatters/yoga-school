package store

import (
	"context"
	"testing"
	"time"
)

// TestVoidEntitlement_CancelsFutureBookingsOnThatPass locks the behaviour a
// manager expects when voiding a pass: the student's *future* (not-yet-
// happened) bookings paid for WITH THAT PASS are cancelled, while
//   - bookings on the same pass for classes that already happened are left
//     alone (you can't un-attend the past), and
//   - bookings paid for with a DIFFERENT pass are untouched (voiding one pass
//     isn't voiding the whole account).
func TestVoidEntitlement_CancelsFutureBookingsOnThatPass(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	voided := f.insertEntitlement(t, s, "credit", 5) // the pass being voided
	otherPass := f.insertEntitlement(t, s, "credit", 5)

	futureClass := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	pastClass := f.insertClass(t, s, time.Now().UTC().Add(-48*time.Hour), 10)
	otherClass := f.insertClass(t, s, time.Now().UTC().Add(72*time.Hour), 10)

	futureBk := f.insertBookedSeat(t, s, futureClass, voided)  // → cancelled
	pastBk := f.insertBookedSeat(t, s, pastClass, voided)      // → survives (past)
	otherBk := f.insertBookedSeat(t, s, otherClass, otherPass) // → survives (other pass)

	// actorID just needs to be a real user for the audit FK — use the
	// fixture's instructor as the acting manager.
	if _, err := s.VoidEntitlement(ctx, f.studioID, f.instructorID, voided, VoidInput{
		Refund: "none",
		Reason: "Test void",
	}); err != nil {
		t.Fatalf("VoidEntitlement: %v", err)
	}

	status := func(bookingID string) string {
		var st string
		if err := s.db.QueryRowContext(ctx,
			`SELECT status FROM bookings WHERE id = ?`, bookingID,
		).Scan(&st); err != nil {
			t.Fatalf("read booking %s: %v", bookingID, err)
		}
		return st
	}

	if got := status(futureBk); got != "cancelled" {
		t.Errorf("future booking on the voided pass: got %q, want cancelled", got)
	}
	if got := status(pastBk); got != "booked" {
		t.Errorf("past booking on the voided pass: got %q, want still booked "+
			"(the class already happened)", got)
	}
	if got := status(otherBk); got != "booked" {
		t.Errorf("booking paid by a different pass: got %q, want still booked", got)
	}

	// The pass itself is now voided.
	var entStatus string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status FROM entitlements WHERE id = ?`, voided,
	).Scan(&entStatus); err != nil {
		t.Fatalf("read entitlement: %v", err)
	}
	if entStatus != "voided" {
		t.Errorf("entitlement status: got %q, want voided", entStatus)
	}
}
