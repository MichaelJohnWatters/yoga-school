package store

import (
	"context"
	"testing"
	"time"
)

func TestEligibleEntitlements_ExcludesZeroCreditPasses(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	full := f.insertEntitlement(t, s, "credit", 3)
	empty := f.insertEntitlement(t, s, "credit", 0)

	rows, err := s.EligibleEntitlements(ctx, f.studioID, f.studentID, class)
	if err != nil {
		t.Fatalf("EligibleEntitlements: %v", err)
	}
	ids := entIdsOf(rows)
	if !contains(ids, full) {
		t.Errorf("missing eligible credit pass: got=%v want includes %s", ids, full)
	}
	if contains(ids, empty) {
		t.Errorf("zero-credit pass leaked into eligible set: got=%v includes %s", ids, empty)
	}
}

func TestEligibleEntitlements_ExcludesExpiredPasses(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	// Backdate expiry to yesterday.
	yesterday := time.Now().UTC().Add(-24 * time.Hour).Format(time.RFC3339)
	if _, err := s.db.ExecContext(ctx,
		`UPDATE entitlements SET expires_at = ? WHERE id = ?`, yesterday, ent,
	); err != nil {
		t.Fatalf("backdate: %v", err)
	}

	rows, err := s.EligibleEntitlements(ctx, f.studioID, f.studentID, class)
	if err != nil {
		t.Fatalf("EligibleEntitlements: %v", err)
	}
	if contains(entIdsOf(rows), ent) {
		t.Errorf("expired pass returned as eligible: %v", entIdsOf(rows))
	}
}

func TestEligibleEntitlements_UnlimitedPassRanksAboveCredit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	credit := f.insertEntitlement(t, s, "credit", 5)
	unlimited := f.insertEntitlement(t, s, "unlimited", 0)

	rows, err := s.EligibleEntitlements(ctx, f.studioID, f.studentID, class)
	if err != nil {
		t.Fatalf("EligibleEntitlements: %v", err)
	}
	if len(rows) < 2 {
		t.Fatalf("want 2 rows got %d", len(rows))
	}
	if rows[0].ID != unlimited {
		t.Errorf("ordering: first row %s want unlimited %s (credit=%s)",
			rows[0].ID, unlimited, credit)
	}
}

func TestCancelBooking_FreeRefundsCredit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Class 48h out, snapshot cutoff is 12h (fixture default) → cancel is
	// well outside the cutoff → cancelled_free, credit returned.
	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	// After booking, credit drops 5 → 4.
	var creditsAfterBook int
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, ent,
	).Scan(&creditsAfterBook); err != nil {
		t.Fatalf("read credits: %v", err)
	}
	if creditsAfterBook != 4 {
		t.Fatalf("after book: got %d want 4", creditsAfterBook)
	}

	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	var outcome string
	var creditsAfterCancel int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(outcome,''), (SELECT credits_remaining FROM entitlements WHERE id = ?)
		   FROM bookings WHERE id = ?`, ent, bookingID,
	).Scan(&outcome, &creditsAfterCancel); err != nil {
		t.Fatalf("read: %v", err)
	}
	if outcome != "cancelled_free" {
		t.Errorf("outcome: got %q want cancelled_free", outcome)
	}
	if creditsAfterCancel != 5 {
		t.Errorf("credit refunded: got %d want 5", creditsAfterCancel)
	}
}

func TestCancelBooking_LateBurnsCredit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Class 2h out, snapshot cutoff is 12h → cancel is INSIDE the cutoff →
	// cancelled_late_burned, credit stays consumed.
	class := f.insertClass(t, s, time.Now().UTC().Add(2*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	var outcome string
	var credits int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(outcome,''), (SELECT credits_remaining FROM entitlements WHERE id = ?)
		   FROM bookings WHERE id = ?`, ent, bookingID,
	).Scan(&outcome, &credits); err != nil {
		t.Fatalf("read: %v", err)
	}
	if outcome != "cancelled_late_burned" {
		t.Errorf("outcome: got %q want cancelled_late_burned", outcome)
	}
	if credits != 4 {
		t.Errorf("credit must stay burned: got %d want 4", credits)
	}
}

func TestMarkAttendance_NoShowSetsOutcome(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(-2*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID := f.insertBookedSeat(t, s, class, ent)
	if err := s.MarkAttendance(ctx, "actor-test", bookingID, "no_show", "manual"); err != nil {
		t.Fatalf("mark: %v", err)
	}
	var outcome string
	if err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(outcome,'') FROM bookings WHERE id = ?`, bookingID,
	).Scan(&outcome); err != nil {
		t.Fatalf("read: %v", err)
	}
	if outcome != "no_show_burned" {
		t.Errorf("outcome: got %q want no_show_burned", outcome)
	}

	// Undo back to booked clears the outcome.
	if err := s.MarkAttendance(ctx, "actor-test", bookingID, "booked", ""); err != nil {
		t.Fatalf("undo: %v", err)
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(outcome,'') FROM bookings WHERE id = ?`, bookingID,
	).Scan(&outcome); err != nil {
		t.Fatalf("read after undo: %v", err)
	}
	if outcome != "" {
		t.Errorf("undo did not clear outcome: got %q", outcome)
	}
}

func TestCancelBooking_NotFoundWhenAlreadyCancelled(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")

	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("first cancel: %v", err)
	}
	err := s.CancelBooking(ctx, f.studentID, bookingID)
	if err != ErrNotFound {
		t.Errorf("re-cancel: got %v want ErrNotFound", err)
	}
}

func entIdsOf(rows []EligibleEntitlement) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.ID
	}
	return out
}
