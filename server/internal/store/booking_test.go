package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestCreateBooking_RefusesBeyondBookingWindow(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	// Default window is 14 days — a class 20 days out is refused.
	far := f.insertClass(t, s, time.Now().UTC().Add(20*24*time.Hour), 10)
	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, far, ent, false, "")
	assertBookingErr(t, err, "outside_booking_window")

	// A class inside the window books fine.
	near := f.insertClass(t, s, time.Now().UTC().Add(3*24*time.Hour), 10)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, near, ent, false, ""); err != nil {
		t.Fatalf("near booking should succeed: %v", err)
	}

	// window = 0 disables the limit — the far class books.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE studios SET booking_window_days = 0 WHERE id = ?`, f.studioID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, far, ent, false, ""); err != nil {
		t.Fatalf("far booking should succeed with no window: %v", err)
	}
}

func TestCreateBooking_RefusesPassExpiringBeforeClass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	// Pass is active but expires in 2 days; the class is 5 days out (still
	// inside the booking window). The pass won't be valid when the class runs.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE entitlements SET expires_at = ? WHERE id = ?`,
		time.Now().UTC().Add(48*time.Hour).Format(time.RFC3339), ent); err != nil {
		t.Fatal(err)
	}
	class := f.insertClass(t, s, time.Now().UTC().Add(5*24*time.Hour), 10)
	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	assertBookingErr(t, err, "entitlement_ineligible")

	// The picker must hide it too.
	elig, err := s.EligibleEntitlements(ctx, f.studioID, f.studentID, class)
	if err != nil {
		t.Fatalf("eligible: %v", err)
	}
	if len(elig) != 0 {
		t.Fatalf("expected no eligible passes (expires before class), got %d", len(elig))
	}
}

func TestCreateBooking_RefusesWhenClassFull(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 1)
	ent1 := f.insertEntitlement(t, s, "unlimited", 0)

	// First booking fills the class.
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent1, false, ""); err != nil {
		t.Fatalf("first book: %v", err)
	}

	// Second student tries — should get class_full.
	other := insertOtherStudent(t, s, f.studioID)
	ent2 := f.insertEntitlementFor(t, s, other, "unlimited", 0)
	_, err := s.CreateBooking(ctx, f.studioID, other, class, ent2, false, "")
	assertBookingErr(t, err, "class_full")
}

func TestCreateBooking_RefusesPlusOneWhenStudioGateOff(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Test Friend")
	assertBookingErr(t, err, "plus_one_not_allowed")
}

// Even with the studio gate on, +1 is restricted to credit passes.
// Unlimited subscriptions don't decrement on booking, so allowing +1
// would let a single subscription bring unlimited free guests.
func TestCreateBooking_RefusesPlusOneOnUnlimitedPass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Test Friend")
	assertBookingErr(t, err, "plus_one_unlimited_not_allowed")
}

func TestCreateBooking_PlusOneSucceedsWhenGateOn(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)

	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Test Friend"); err != nil {
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

	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
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

// TestCreateBooking_RefusesWhenCreditsExhausted asserts the specific
// "no_credits" code on the booking path. The entitlement is still status =
// active + covers the class type, so the upstream eligibility check passes;
// the inner credit-count check is what rejects.
//
// (Contrast: EligibleEntitlements — used for the buy-vs-book UI listing —
// does pre-filter zero-credit passes. The booking path validates the
// supplied entitlement_id directly and reports the more specific reason.)
func TestCreateBooking_RefusesWhenCreditsExhausted(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 0)

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	assertBookingErr(t, err, "no_credits")
}

// TestCreateBooking_RefusesPlusOneOnLastCredit catches the +1 corner case:
// a credit pass with 1 credit left can book solo but must refuse the +1
// request (which needs 2 seats). The same "no_credits" code surfaces, but
// the situation is different — a regression that allowed the second seat to
// go through would over-decrement the pass into negative territory.
func TestCreateBooking_RefusesPlusOneOnLastCredit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 1)

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true /* +1 */, "Test Friend")
	assertBookingErr(t, err, "no_credits")

	// Credit untouched (1, not 0 or -1).
	var remaining int
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, ent,
	).Scan(&remaining); err != nil {
		t.Fatal(err)
	}
	if remaining != 1 {
		t.Errorf("credits after refusal: got %d want 1 (untouched)", remaining)
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

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	assertBookingErr(t, err, "entitlement_ineligible")
}

func TestCreateBooking_RefusesDuplicate(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatalf("first book: %v", err)
	}
	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	assertBookingErr(t, err, "already_booked")
}

// TestCreateBooking_WritesBookingConfirmedNotification proves the spec's
// "booking_confirmed" feed entry actually fires on a real booking — the
// student should see "You're booked into …" in their notifications feed.
func TestCreateBooking_WritesBookingConfirmedNotification(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	var n int
	var title, payload string
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM notifications
		 WHERE user_id = ? AND type = 'booking_confirmed'`, f.studentID,
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("notif count: got %d want 1", n)
	}
	if err := s.db.QueryRowContext(ctx, `
		SELECT title, payload FROM notifications
		 WHERE user_id = ? AND type = 'booking_confirmed'`, f.studentID,
	).Scan(&title, &payload); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(title, "You're booked into ") {
		t.Errorf("title: got %q want 'You're booked into …'", title)
	}
	if !strings.Contains(payload, bookingID) {
		t.Errorf("payload missing booking_id: %s", payload)
	}
}

func readCredits(t *testing.T, s *Store, entitlementID string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, entitlementID,
	).Scan(&n); err != nil {
		t.Fatalf("read credits: %v", err)
	}
	return n
}

func readBookingStatus(t *testing.T, s *Store, bookingID string) (status, outcome string) {
	t.Helper()
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT status, COALESCE(outcome,'') FROM bookings WHERE id = ?`, bookingID,
	).Scan(&status, &outcome); err != nil {
		t.Fatalf("read booking %s: %v", bookingID, err)
	}
	return
}

func readChildBookingID(t *testing.T, s *Store, parentID string) string {
	t.Helper()
	var id string
	err := s.db.QueryRowContext(context.Background(),
		`SELECT id FROM bookings WHERE parent_booking_id = ?`, parentID,
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return ""
	}
	if err != nil {
		t.Fatalf("read child: %v", err)
	}
	return id
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

// You can't book a class that has already started — the doors-closed gate
// is independent of the (earlier) cancellation cutoff window. This is the
// security fix for "UI lets you book classes in the past, API allows it".
func TestCreateBooking_RefusesPastClass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(-1*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	_, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	assertBookingErr(t, err, "class_already_started")
}

func TestBookingPreview_RefusesPastClass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(-1*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	p, err := s.BookingPreview(ctx, f.studioID, f.studentID, class, ent)
	if err != nil {
		t.Fatalf("preview: %v", err)
	}
	if p.CanBook {
		t.Errorf("CanBook = true; want false for a past class")
	}
	if p.BlockReason != "class_already_started" {
		t.Errorf("BlockReason = %q; want class_already_started", p.BlockReason)
	}
}

// Once the class has begun, cancellation is refused outright — we don't
// retroactively rewrite history into a late-cancel.
func TestCancelBooking_RefusesPastClass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(-2*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID := f.insertBookedSeat(t, s, class, ent)

	err := s.CancelBooking(ctx, f.studentID, bookingID)
	if !errors.Is(err, ErrClassStarted) {
		t.Fatalf("CancelBooking err = %v; want ErrClassStarted", err)
	}
}

// Cancelling a booking with a +1 has to take the friend with it — otherwise
// the friend's row stays 'booked', holds a seat against capacity, and keeps
// a live checkin_token. Free cancel returns both credits (the original
// booking consumed two).
func TestCancelBooking_CascadesToPlusOneOnFreeCancel(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	// Class far enough out to be free-cancel (default cutoff is 12h).
	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)

	parentID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Sam Jones")
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	// CreateBooking should have burned 2 credits.
	creditsAfterBook := readCredits(t, s, ent)
	if creditsAfterBook != 3 {
		t.Fatalf("credits after book: got %d want 3", creditsAfterBook)
	}

	if err := s.CancelBooking(ctx, f.studentID, parentID); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	// Both rows should be cancelled.
	parentStatus, parentOutcome := readBookingStatus(t, s, parentID)
	if parentStatus != "cancelled" || parentOutcome != "cancelled_free" {
		t.Errorf("parent: got status=%q outcome=%q; want cancelled / cancelled_free",
			parentStatus, parentOutcome)
	}
	childID := readChildBookingID(t, s, parentID)
	if childID == "" {
		t.Fatal("no +1 child row found — fixture didn't seed properly")
	}
	childStatus, childOutcome := readBookingStatus(t, s, childID)
	if childStatus != "cancelled" || childOutcome != "cancelled_free" {
		t.Errorf("child: got status=%q outcome=%q; want cancelled / cancelled_free",
			childStatus, childOutcome)
	}

	// Both credits should have returned.
	creditsAfterCancel := readCredits(t, s, ent)
	if creditsAfterCancel != 5 {
		t.Errorf("credits after cancel: got %d want 5 (both refunded)", creditsAfterCancel)
	}

}

// On a late cancel the pass stays consumed for both rows (the +1 ticket is
// not magically restored). The seats both free up so the studio can refill
// from the waitlist; credits do not refund.
func TestCancelBooking_CascadesToPlusOneOnLateCancel(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	// Cutoff is 12h by default — class in 6h is inside the late window.
	class := f.insertClass(t, s, time.Now().UTC().Add(6*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)

	parentID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Sam Jones")
	if err != nil {
		t.Fatalf("book: %v", err)
	}
	creditsAfterBook := readCredits(t, s, ent)

	if err := s.CancelBooking(ctx, f.studentID, parentID); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	_, parentOutcome := readBookingStatus(t, s, parentID)
	if parentOutcome != "cancelled_late_burned" {
		t.Errorf("parent outcome: got %q want cancelled_late_burned", parentOutcome)
	}
	childID := readChildBookingID(t, s, parentID)
	_, childOutcome := readBookingStatus(t, s, childID)
	if childOutcome != "cancelled_late_burned" {
		t.Errorf("child outcome: got %q want cancelled_late_burned", childOutcome)
	}

	// No credits should refund on late.
	if got := readCredits(t, s, ent); got != creditsAfterBook {
		t.Errorf("credits after late cancel: got %d want %d (no refund)", got, creditsAfterBook)
	}
}

// When a seat opens up via student cancel, the next waitlister should get
// an offer automatically. Today the manager has to manually promote — this
// pins down the auto-promote behaviour.
func TestCancelBooking_PromotesWaitlistAsync(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Capacity = 1 so the second student goes straight to the waitlist.
	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 1)
	entSelf := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, entSelf, false, "")
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	other := insertOtherStudent(t, s, f.studioID)
	f.insertEntitlementFor(t, s, other, "unlimited", 0)
	if _, err := s.JoinWaitlist(ctx, other, class); err != nil {
		t.Fatalf("join waitlist: %v", err)
	}

	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	// The promote runs in a goroutine; poll briefly for the offer row.
	waitForAutoBook(t, s, class, other)
}

// Cascade cancel frees two seats — two waitlisters should each get an offer.
func TestCancelBooking_PromotesTwoWaitersAfterPlusOneCascade(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 2)
	ent := f.insertEntitlement(t, s, "credit", 5)
	parentID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Sam")
	if err != nil {
		t.Fatalf("book +1: %v", err)
	}

	w1 := insertOtherStudent(t, s, f.studioID)
	w2 := insertOtherStudent(t, s, f.studioID)
	f.insertEntitlementFor(t, s, w1, "unlimited", 0)
	f.insertEntitlementFor(t, s, w2, "unlimited", 0)
	for _, u := range []string{w1, w2} {
		if _, err := s.JoinWaitlist(ctx, u, class); err != nil {
			t.Fatalf("join %s: %v", u, err)
		}
	}

	if err := s.CancelBooking(ctx, f.studentID, parentID); err != nil {
		t.Fatalf("cancel: %v", err)
	}

	waitForAutoBook(t, s, class, w1)
	waitForAutoBook(t, s, class, w2)
}

// Empty-waitlist case must not blow up the cancel — the cancel succeeded
// and the no-waiters case is benign.
func TestCancelBooking_SucceedsWhenWaitlistEmpty(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(24*time.Hour), 5)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, "")
	if err != nil {
		t.Fatalf("book: %v", err)
	}

	if err := s.CancelBooking(ctx, f.studentID, bookingID); err != nil {
		t.Fatalf("cancel: %v", err)
	}
}

// waitForAutoBook polls for up to 2s for a booked row matching (class,
// user). The promote loop runs in a goroutine off CancelBooking, so the
// assertion has to be eventually-consistent. Under the auto-book promote
// semantics a successful promote inserts a real booking — no offer
// intermediate.
func waitForAutoBook(t *testing.T, s *Store, classID, userID string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		var n int
		if err := s.db.QueryRowContext(context.Background(), `
			SELECT COUNT(*) FROM bookings
			 WHERE class_id = ? AND user_id = ? AND status = 'booked'`,
			classID, userID,
		).Scan(&n); err != nil {
			t.Fatalf("poll booking: %v", err)
		}
		if n > 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no auto-promoted booking for user=%s class=%s after 2s", userID, classID)
}

func TestCancelPreview_RefusesPastClass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(-30*time.Minute), 10)
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	bookingID := f.insertBookedSeat(t, s, class, ent)

	p, err := s.CancelPreview(ctx, f.studentID, bookingID)
	if err != nil {
		t.Fatalf("CancelPreview: %v", err)
	}
	if p.CanCancel {
		t.Errorf("CanCancel = true; want false for a past class")
	}
	if p.BlockReason != "class_already_started" {
		t.Errorf("BlockReason = %q; want class_already_started", p.BlockReason)
	}
}

// TestAddPlusOne_SucceedsAfterSoloBook is the happy path for "add a friend
// after the fact": a student books solo on a credit pass, then later adds a
// +1 charged to that same pass (one more credit), creating a child booking
// row that points at the parent.
func TestAddPlusOne_SucceedsAfterSoloBook(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatalf("solo book: %v", err)
	}

	if _, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, ent, "Test Friend"); err != nil {
		t.Fatalf("add +1: %v", err)
	}

	// 5 - 1 (solo) - 1 (+1) = 3 credits.
	var remaining int
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, ent,
	).Scan(&remaining); err != nil {
		t.Fatalf("read credits: %v", err)
	}
	if remaining != 3 {
		t.Errorf("credits_remaining: got %d want 3", remaining)
	}

	// Two booked rows; the +1 carries the friend's name and a parent link.
	var plusOnes int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM bookings
		 WHERE class_id = ? AND status = 'booked'
		   AND is_plus_one = 1 AND plus_one_name = 'Test Friend'
		   AND parent_booking_id IS NOT NULL`, class,
	).Scan(&plusOnes); err != nil {
		t.Fatalf("count +1: %v", err)
	}
	if plusOnes != 1 {
		t.Errorf("plus_one rows: got %d want 1", plusOnes)
	}
}

// TestAddPlusOne_UnlimitedParentPaysWithCreditPass is the case that drove the
// "student can choose the pass" design: a student books solo on an UNLIMITED
// pass (which can't fund a +1), then brings a friend by picking a separate
// CREDIT pass. The +1 succeeds and only the credit pass is decremented.
func TestAddPlusOne_UnlimitedParentPaysWithCreditPass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	unlimited := f.insertEntitlement(t, s, "unlimited", 0)
	credit := f.insertEntitlement(t, s, "credit", 4)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, unlimited, false, ""); err != nil {
		t.Fatalf("solo book on unlimited: %v", err)
	}

	if _, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, credit, "Test Friend"); err != nil {
		t.Fatalf("add +1 on credit pass: %v", err)
	}

	// Only the chosen credit pass is charged: 4 - 1 = 3.
	var remaining int
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, credit,
	).Scan(&remaining); err != nil {
		t.Fatalf("read credits: %v", err)
	}
	if remaining != 3 {
		t.Errorf("credit pass: got %d want 3", remaining)
	}
}

// TestCancelBooking_RefundsPlusOneToItsOwnPass verifies the per-seat refund:
// a free cancel of an unlimited-parent booking with a credit-pass +1 returns
// the credit to the +1's pass (and nothing to the unlimited).
func TestCancelBooking_RefundsPlusOneToItsOwnPass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	unlimited := f.insertEntitlement(t, s, "unlimited", 0)
	credit := f.insertEntitlement(t, s, "credit", 4)
	parentID, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, unlimited, false, "")
	if err != nil {
		t.Fatalf("solo book: %v", err)
	}
	if _, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, credit, "Test Friend"); err != nil {
		t.Fatalf("add +1: %v", err)
	}
	// credit now 3. Free-cancel the parent → cascade cancels the +1 and
	// refunds 1 credit to the credit pass (back to 4).
	if err := s.CancelBooking(ctx, f.studentID, parentID); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	var remaining int
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_remaining FROM entitlements WHERE id = ?`, credit,
	).Scan(&remaining); err != nil {
		t.Fatalf("read credits: %v", err)
	}
	if remaining != 4 {
		t.Errorf("credit pass after free cancel: got %d want 4 (refunded)", remaining)
	}
}

// Adding a +1 without an existing seat on the class is refused — there's
// nothing to hang the guest off.
func TestAddPlusOne_RequiresExistingBooking(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	_, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, ent, "Test Friend")
	assertBookingErr(t, err, "not_booked")
}

// A second +1 on the same class is refused (one guest per booking).
func TestAddPlusOne_RefusesSecondPlusOne(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, true, "Friend One"); err != nil {
		t.Fatalf("book with +1: %v", err)
	}
	_, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, ent, "Friend Two")
	assertBookingErr(t, err, "plus_one_exists")
}

// Picking an unlimited pass to fund the +1 is refused — guests need a credit
// pass (an unlimited would let one subscription bring free guests).
func TestAddPlusOne_RefusesUnlimitedChosenPass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	credit := f.insertEntitlement(t, s, "credit", 5)
	unlimited := f.insertEntitlement(t, s, "unlimited", 0)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, credit, false, ""); err != nil {
		t.Fatalf("solo book: %v", err)
	}
	_, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, unlimited, "Test Friend")
	assertBookingErr(t, err, "plus_one_unlimited_not_allowed")
}

// No spare credit on the chosen pass → refused.
func TestAddPlusOne_RefusesWithoutSpareCredit(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 1)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatalf("solo book: %v", err)
	}
	// The solo book spent the last credit, so the chosen pass now has none.
	_, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, ent, "Test Friend")
	assertBookingErr(t, err, "no_credits")
}

// The +1 path enforces the same class-type coverage as a normal booking: a
// credit pass that doesn't cover this class's type (e.g. a Reformer pass on a
// Yoga class) can't fund a guest. Guards the ect.class_type_id join in
// AddPlusOneToBooking.
func TestAddPlusOne_RefusesPassNotCoveringClassType(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	f.setPlusOneAllowed(t, s, true)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	parentPass := f.insertEntitlement(t, s, "credit", 5)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, parentPass, false, ""); err != nil {
		t.Fatalf("solo book: %v", err)
	}

	// A second credit pass with its coverage stripped — it no longer covers
	// this class's type, so it can't pay for the +1.
	otherPass := f.insertEntitlement(t, s, "credit", 5)
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM entitlement_class_types WHERE entitlement_id = ?`, otherPass,
	); err != nil {
		t.Fatalf("drop coverage: %v", err)
	}

	_, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, otherPass, "Test Friend")
	assertBookingErr(t, err, "entitlement_ineligible")
}

// Gate off at the studio level → refused even with a valid booking + credits.
func TestAddPlusOne_RefusesWhenGateOff(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	class := f.insertClass(t, s, time.Now().UTC().Add(48*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	if _, err := s.CreateBooking(ctx, f.studioID, f.studentID, class, ent, false, ""); err != nil {
		t.Fatalf("solo book: %v", err)
	}
	_, err := s.AddPlusOneToBooking(ctx, f.studioID, f.studentID, class, ent, "Test Friend")
	assertBookingErr(t, err, "plus_one_not_allowed")
}
