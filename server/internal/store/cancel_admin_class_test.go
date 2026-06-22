package store

import (
	"context"
	"testing"
	"time"
)

// TestCancelAdminClass_RefundsCreditsAndNotifiesAndStampsOutcome covers the
// big studio-cancel path: every active booking flips to cancelled with
// outcome=class_cancelled_returned, credit passes get their credit back,
// unlimited passes are not touched, a class_cancelled notification is
// written per booker, and the waitlist is cleared. Result counts in the
// returned summary should match.
func TestCancelAdminClass_RefundsCreditsAndNotifiesAndStampsOutcome(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Class with two bookers: one credit, one unlimited. Plus a third user
	// on the waitlist so we can assert it gets cleared.
	class := f.insertClass(t, s, time.Now().UTC().Add(36*time.Hour), 2)

	studentA := f.studentID
	entA := f.insertEntitlement(t, s, "credit", 5)
	if _, err := s.CreateBooking(ctx, f.studioID, studentA, class, entA, false, ""); err != nil {
		t.Fatalf("book A: %v", err)
	}
	// After A's booking the credit pass shows 4 (one consumed).
	assertCreditsRemaining(t, s, entA, 4)

	studentB := insertOtherStudent(t, s, f.studioID)
	entB := f.insertEntitlementFor(t, s, studentB, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, studentB, class, entB, false, ""); err != nil {
		t.Fatalf("book B: %v", err)
	}

	studentC := insertOtherStudent(t, s, f.studioID)
	if _, err := s.JoinWaitlist(ctx, studentC, class); err != nil {
		t.Fatalf("waitlist C: %v", err)
	}

	out, err := s.CancelAdminClass(ctx, f.studioID, class)
	if err != nil {
		t.Fatalf("CancelAdminClass: %v", err)
	}

	// Counts.
	if out.BookingsCancelled != 2 {
		t.Errorf("bookings cancelled: got %d want 2", out.BookingsCancelled)
	}
	if out.CreditsReturned != 1 {
		t.Errorf("credits returned: got %d want 1 (only A had a credit pass)", out.CreditsReturned)
	}
	if out.NotificationsSent != 2 {
		t.Errorf("notifications: got %d want 2", out.NotificationsSent)
	}
	if out.WaitlistCleared != 1 {
		t.Errorf("waitlist cleared: got %d want 1", out.WaitlistCleared)
	}

	// Credit refunded back to 5.
	assertCreditsRemaining(t, s, entA, 5)

	// Outcome set on every cancelled booking.
	rows, err := s.db.QueryContext(ctx,
		`SELECT status, COALESCE(outcome,'') FROM bookings WHERE class_id = ?`, class,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var cancelledCount int
	for rows.Next() {
		var status, outcome string
		if err := rows.Scan(&status, &outcome); err != nil {
			t.Fatal(err)
		}
		if status != "cancelled" {
			t.Errorf("booking status: got %q want cancelled", status)
		}
		if outcome != "class_cancelled_returned" {
			t.Errorf("outcome: got %q want class_cancelled_returned", outcome)
		}
		cancelledCount++
	}
	if cancelledCount != 2 {
		t.Errorf("cancelled rows: got %d want 2", cancelledCount)
	}

	// Class itself flipped to cancelled.
	var classStatus string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status FROM classes WHERE id = ?`, class,
	).Scan(&classStatus); err != nil {
		t.Fatal(err)
	}
	if classStatus != "cancelled" {
		t.Errorf("class status: got %q want cancelled", classStatus)
	}

	// Waitlist actually gone.
	var wl int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM waitlist_entries WHERE class_id = ?`, class,
	).Scan(&wl); err != nil {
		t.Fatal(err)
	}
	if wl != 0 {
		t.Errorf("waitlist remnants: got %d want 0", wl)
	}

	// A class_cancelled notification fired to each former booker.
	var notifs int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM notifications
		 WHERE studio_id = ? AND type = 'class_cancelled'`,
		f.studioID,
	).Scan(&notifs); err != nil {
		t.Fatal(err)
	}
	if notifs != 2 {
		t.Errorf("class_cancelled notifications: got %d want 2", notifs)
	}
}

func TestCancelAdminClass_RefusesAlreadyCancelled(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	if _, err := s.CancelAdminClass(ctx, f.studioID, class); err != nil {
		t.Fatalf("first cancel: %v", err)
	}
	if _, err := s.CancelAdminClass(ctx, f.studioID, class); err == nil {
		t.Error("second cancel: expected error, got nil")
	}
}

func TestCancelAdminClass_NotFoundCrossStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	_, err := s.CancelAdminClass(ctx, "other-studio", class)
	if err == nil || err != ErrNotFound {
		t.Errorf("cross-studio cancel: got %v want ErrNotFound", err)
	}
}

func assertCreditsRemaining(t *testing.T, s *Store, entID string, want int) {
	t.Helper()
	var got int
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, entID,
	).Scan(&got); err != nil {
		t.Fatalf("read credits: %v", err)
	}
	if got != want {
		t.Errorf("credits_remaining: got %d want %d", got, want)
	}
}
