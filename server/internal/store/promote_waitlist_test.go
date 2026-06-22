package store

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"
)

// TestPromoteWaitlist_AutoBooksHeadAndBurnsCredit walks the happy path under
// the auto-book semantics. A class with one open seat, three waitlisters,
// the first has a credit pass. After promote: the head waitlister is now
// booked, their credit is decremented, their waitlist row is gone, the
// other two stay queued, and a waitlist_promoted notification was sent.
func TestPromoteWaitlist_AutoBooksHeadAndBurnsCredit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)

	a := insertOtherStudent(t, s, f.studioID)
	b := insertOtherStudent(t, s, f.studioID)
	c := insertOtherStudent(t, s, f.studioID)
	entA := f.insertEntitlementFor(t, s, a, "credit", 5)
	f.insertEntitlementFor(t, s, b, "unlimited", 0)
	f.insertEntitlementFor(t, s, c, "unlimited", 0)
	for _, u := range []string{a, b, c} {
		if _, err := s.JoinWaitlist(ctx, u, class); err != nil {
			t.Fatalf("waitlist %s: %v", u, err)
		}
	}

	out, err := s.PromoteWaitlist(ctx, f.studioID, "", class)
	if err != nil {
		t.Fatalf("PromoteWaitlist: %v", err)
	}

	if out.PromotedUserID != a {
		t.Errorf("promoted user: got %s want %s (head of waitlist)", out.PromotedUserID, a)
	}
	if out.BookingID == "" {
		t.Error("expected BookingID, got empty")
	}
	if out.NextWaitlistN != 2 {
		t.Errorf("next_waitlist_size: got %d want 2", out.NextWaitlistN)
	}

	// Booking exists and is in 'booked' state.
	var status string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status FROM bookings WHERE id = ?`, out.BookingID,
	).Scan(&status); err != nil {
		t.Fatalf("read booking: %v", err)
	}
	if status != "booked" {
		t.Errorf("booking status: got %q want booked", status)
	}

	// Credit burned 5 → 4.
	assertCreditsRemaining(t, s, entA, 4)

	// Head waiter's row is kept for audit but flipped to status='promoted'
	// with a promoted_at timestamp — the visible queue no longer contains
	// them but the history does.
	var (
		headStatus      string
		headPromotedAt  sql.NullString
		headActiveCount int
	)
	if err := s.db.QueryRowContext(ctx, `
		SELECT status, promoted_at FROM waitlist_entries
		 WHERE class_id = ? AND user_id = ?`,
		class, a,
	).Scan(&headStatus, &headPromotedAt); err != nil {
		t.Fatal(err)
	}
	if headStatus != "promoted" {
		t.Errorf("head waiter row status: got %q want promoted", headStatus)
	}
	if !headPromotedAt.Valid {
		t.Error("head waiter row should have promoted_at set")
	}
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM waitlist_entries
		 WHERE class_id = ? AND user_id = ? AND status = 'waiting'`,
		class, a,
	).Scan(&headActiveCount); err != nil {
		t.Fatal(err)
	}
	if headActiveCount != 0 {
		t.Errorf("head waiter shouldn't be in the active queue anymore: got %d", headActiveCount)
	}

	// Other two waitlisters re-numbered to positions 1 and 2 in the
	// active queue.
	type entry struct {
		userID string
		pos    int
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT user_id, position FROM waitlist_entries
		 WHERE class_id = ? AND status = 'waiting'
		 ORDER BY position`,
		class)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var remaining []entry
	for rows.Next() {
		var e entry
		if err := rows.Scan(&e.userID, &e.pos); err != nil {
			t.Fatal(err)
		}
		remaining = append(remaining, e)
	}
	if len(remaining) != 2 || remaining[0].userID != b || remaining[0].pos != 1 ||
		remaining[1].userID != c || remaining[1].pos != 2 {
		t.Errorf("waitlist after promote: got %+v want [{b,1},{c,2}]", remaining)
	}

	// waitlist_promoted notification fired.
	var notifCount int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM notifications
		 WHERE user_id = ? AND type = 'waitlist_promoted'`, a,
	).Scan(&notifCount); err != nil {
		t.Fatal(err)
	}
	if notifCount != 1 {
		t.Errorf("waitlist_promoted notifs: got %d want 1", notifCount)
	}
}

// TestPromoteWaitlist_SkipsHeadWhenNoEligiblePass models: the first
// waitlister joined when they had credits, has since run out. Promote
// should skip them and book the next person who can take the seat. The
// skipped student's waitlist row is dropped (rejoin to get back in).
func TestPromoteWaitlist_SkipsHeadWhenNoEligiblePass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	a := insertOtherStudent(t, s, f.studioID)
	b := insertOtherStudent(t, s, f.studioID)
	// A has a depleted credit pass — joined when it had credits, doesn't
	// now. Forcibly insert with credits_remaining=0 to model that.
	f.insertEntitlementFor(t, s, a, "credit", 0)
	entB := f.insertEntitlementFor(t, s, b, "credit", 3)
	if _, err := s.JoinWaitlist(ctx, a, class); err != nil {
		t.Fatal(err)
	}
	if _, err := s.JoinWaitlist(ctx, b, class); err != nil {
		t.Fatal(err)
	}

	out, err := s.PromoteWaitlist(ctx, f.studioID, "", class)
	if err != nil {
		t.Fatalf("PromoteWaitlist: %v", err)
	}
	if out.PromotedUserID != b {
		t.Errorf("promoted user: got %s want %s (head A had no credits)", out.PromotedUserID, b)
	}
	assertCreditsRemaining(t, s, entB, 2)
}

// TestPromoteWaitlist_NoOneEligible exercises the "everyone's pass
// lapsed" case. Promote returns a typed BookingError with code
// "no_eligible_entitlement" so the caller can log + stop trying.
func TestPromoteWaitlist_NoOneEligible(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	a := insertOtherStudent(t, s, f.studioID)
	b := insertOtherStudent(t, s, f.studioID)
	f.insertEntitlementFor(t, s, a, "credit", 0)
	f.insertEntitlementFor(t, s, b, "credit", 0)
	if _, err := s.JoinWaitlist(ctx, a, class); err != nil {
		t.Fatal(err)
	}
	if _, err := s.JoinWaitlist(ctx, b, class); err != nil {
		t.Fatal(err)
	}

	_, err := s.PromoteWaitlist(ctx, f.studioID, "", class)
	var be *BookingError
	if !errors.As(err, &be) || be.Code != "no_eligible_entitlement" {
		t.Errorf("expected BookingError no_eligible_entitlement, got %T %v", err, err)
	}
}

func TestPromoteWaitlist_RefusesWhenClassFull(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 1)

	// Fill the one seat with student A.
	a := insertOtherStudent(t, s, f.studioID)
	entA := f.insertEntitlementFor(t, s, a, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, a, class, entA, false, ""); err != nil {
		t.Fatalf("seed full: %v", err)
	}
	// Add B to the waitlist.
	b := insertOtherStudent(t, s, f.studioID)
	f.insertEntitlementFor(t, s, b, "unlimited", 0)
	if _, err := s.JoinWaitlist(ctx, b, class); err != nil {
		t.Fatalf("waitlist B: %v", err)
	}

	if _, err := s.PromoteWaitlist(ctx, f.studioID, "", class); err == nil {
		t.Error("expected refusal for full class, got nil")
	}
}

func TestPromoteWaitlist_RefusesWhenWaitlistEmpty(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	if _, err := s.PromoteWaitlist(ctx, f.studioID, "", class); err == nil {
		t.Error("expected refusal for empty waitlist, got nil")
	}
}
