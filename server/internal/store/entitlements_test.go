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

func TestCancelBooking_SetsStatusAndTimestamp(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false)
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	var status, cancelledAt string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, COALESCE(cancelled_at,'') FROM bookings WHERE id = ?`, bookingID,
	).Scan(&status, &cancelledAt); err != nil {
		t.Fatalf("read: %v", err)
	}
	if status != "cancelled" {
		t.Errorf("status: got %q want cancelled", status)
	}
	if cancelledAt == "" {
		t.Error("cancelled_at not set")
	}
}

func TestCancelBooking_NotFoundWhenAlreadyCancelled(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, _ := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false)

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
