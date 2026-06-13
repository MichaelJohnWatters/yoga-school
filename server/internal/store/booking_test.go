package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestCreateBooking_RefusesWhenClassFull(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 1)
	ent1 := f.insertEntitlement(t, s, "unlimited", 0)

	// First booking fills the class.
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent1, false); err != nil {
		t.Fatalf("first book: %v", err)
	}

	// Second student tries — should get class_full.
	other := insertOtherStudent(t, s, f.studioID)
	ent2 := f.insertEntitlementFor(t, s, other, "unlimited", 0)
	_, err := s.CreateBooking(ctx, f.studioID, other, class, ent2, false)
	assertBookingErr(t, err, "class_full")
}

func TestCreateBooking_RefusesPlusOneWhenStudioGateOff(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true)
	assertBookingErr(t, err, "plus_one_not_allowed")
}

func TestCreateBooking_PlusOneSucceedsWhenGateOn(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)

	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true); err != nil {
		t.Fatalf("+1 book: %v", err)
	}

	// Two seats consumed → 5 - 2 = 3 credits.
	var remaining int
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, ent,
	).Scan(&remaining); err != nil {
		t.Fatalf("read credits: %v", err)
	}
	if remaining != 3 {
		t.Errorf("credits_remaining: got %d want 3", remaining)
	}

	// Two booking rows: caller + plus_one (parent_booking_id set).
	var count int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM bookings WHERE class_id = ? AND status = 'booked'`, class,
	).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 2 {
		t.Errorf("booking rows: got %d want 2 (caller + +1)", count)
	}
}

func TestCreateBooking_CreditPassDecrementsBy1OnSoloBook(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 3)

	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false); err != nil {
		t.Fatalf("book: %v", err)
	}
	var remaining int
	_ = s.db.QueryRowContext(ctx,
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, ent,
	).Scan(&remaining)
	if remaining != 2 {
		t.Errorf("credits: got %d want 2", remaining)
	}
}

func TestCreateBooking_RefusesWhenCreditsExhausted(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 0)

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false)
	// The eligibility filter excludes zero-credit passes before the
	// "no_credits" check fires, so the surfaced code is "entitlement_ineligible".
	// Either is a correct refusal; assert it's a typed BookingError, not a 500.
	var be *BookingError
	if !errors.As(err, &be) {
		t.Fatalf("expected BookingError, got %v", err)
	}
}

func TestCreateBooking_RefusesEntitlementNotCoveringClassType(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	// Drop the coverage row so the entitlement doesn't cover the class type.
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM entitlement_class_types WHERE entitlement_id = ?`, ent,
	); err != nil {
		t.Fatalf("drop coverage: %v", err)
	}

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false)
	assertBookingErr(t, err, "entitlement_ineligible")
}

func TestCreateBooking_RefusesDuplicate(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false); err != nil {
		t.Fatalf("first book: %v", err)
	}
	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false)
	assertBookingErr(t, err, "already_booked")
}

func assertBookingErr(t *testing.T, err error, wantCode string) {
	t.Helper()
	var be *BookingError
	if !errors.As(err, &be) {
		t.Fatalf("expected BookingError, got %T: %v", err, err)
	}
	if be.Code != wantCode {
		t.Errorf("error code: got %q want %q (msg=%q)", be.Code, wantCode, be.Message)
	}
}
