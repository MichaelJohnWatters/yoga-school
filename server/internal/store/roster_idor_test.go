package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestMarkAttendance_StudioScoped is the regression guard for the cross-tenant
// IDOR fix: a staff member may only mark bookings that belong to their own
// studio. Passing another studio's id must resolve zero rows and return
// ErrNotFound rather than silently mutating the foreign booking.
func TestMarkAttendance_StudioScoped(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	classID := f.insertClass(t, s, time.Now().Add(-48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	bookingID := f.insertBookedSeat(t, s, classID, ent)

	// Wrong studio → treated as not found, booking left untouched.
	err := s.MarkAttendance(ctx, "some-other-studio", "actor-test", bookingID, "no_show", "manual")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-tenant mark: want ErrNotFound, got %v", err)
	}
	var status string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status FROM bookings WHERE id = ?`, bookingID).Scan(&status); err != nil {
		t.Fatalf("read back status: %v", err)
	}
	if status != "booked" {
		t.Fatalf("cross-tenant mark mutated the booking: status=%q, want booked", status)
	}

	// Correct studio → succeeds.
	if err := s.MarkAttendance(ctx, f.studioID, "actor-test", bookingID, "no_show", "manual"); err != nil {
		t.Fatalf("same-studio mark: %v", err)
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT status FROM bookings WHERE id = ?`, bookingID).Scan(&status); err != nil {
		t.Fatalf("read back status: %v", err)
	}
	if status != "no_show" {
		t.Fatalf("same-studio mark: status=%q, want no_show", status)
	}
}
