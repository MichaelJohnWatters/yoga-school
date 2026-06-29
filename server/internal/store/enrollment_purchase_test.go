package store

import (
	"context"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

func seedTestSeries(t *testing.T, s *Store, f fixture, capacity int) *NewSeriesResult {
	t.Helper()
	start := time.Now().AddDate(0, 0, 7) // a week out so all sessions are future
	res, err := s.CreateSeries(context.Background(), f.studioID, f.instructorID, NewSeriesInput{
		Title:        "Beginners Course",
		PriceMinor:   6000,
		InstructorID: f.instructorID,
		RoomID:       f.roomID,
		Weekday:      int((start.Weekday() + 6) % 7), // Mon=0
		StartHour:    18,
		StartMinute:  0,
		DurationMins: 60,
		Capacity:     capacity,
		SessionCount: 3,
		StartsOn:     start.Format("2006-01-02"),
	})
	if err != nil {
		t.Fatalf("CreateSeries: %v", err)
	}
	return res
}

// A paid series purchase, on fulfilment, enrolls the student: mints the
// entitlement, books every session, and completes the purchase.
func TestEnrollmentPurchase_FulfilEnrolls(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	series := seedTestSeries(t, s, f, 2)

	pending, err := s.CreatePendingPurchase(
		ctx, f.studioID, f.studentID, series.ProductID, "card", "", series.EnrollmentID)
	if err != nil {
		t.Fatalf("CreatePendingPurchase: %v", err)
	}
	g.intents[pending.StripePaymentID] = payments.StatusSucceeded

	entID, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatalf("ConfirmPurchase: %v", err)
	}
	if entID == "" {
		t.Fatal("expected an entitlement")
	}

	var eb, bk int
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM enrollment_bookings WHERE enrollment_id=? AND user_id=? AND status='active'`,
		series.EnrollmentID, f.studentID).Scan(&eb)
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM bookings WHERE user_id=? AND entitlement_id=?`,
		f.studentID, entID).Scan(&bk)
	if eb != 1 {
		t.Errorf("enrollment_bookings = %d, want 1", eb)
	}
	if bk != 3 {
		t.Errorf("session bookings = %d, want 3", bk)
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "completed")
}

// If the series fills before payment lands, fulfilment refunds + marks the
// purchase refunded + notifies, and does not enroll.
func TestEnrollmentPurchase_RefundWhenFull(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	withStripeCreds(t, s, f.studioID, f.studentID)
	refunded := false
	g := &fakeGateway{
		intents:  map[string]string{},
		refundFn: func(string, int64) (string, error) { refunded = true; return "re_1", nil },
	}
	s.SetPaymentGateway(g)
	series := seedTestSeries(t, s, f, 1) // single seat

	// Fill the seat with another student (sync dev path).
	other := insertOtherStudent(t, s, f.studioID)
	if _, err := s.JoinEnrollment(ctx, f.studioID, other, series.EnrollmentID, "dev_stub", ""); err != nil {
		t.Fatalf("fill seat: %v", err)
	}

	// Our student pays — pending purchase tagged with the (now full) series.
	pending, err := s.CreatePendingPurchase(
		ctx, f.studioID, f.studentID, series.ProductID, "card", "", series.EnrollmentID)
	if err != nil {
		t.Fatalf("CreatePendingPurchase: %v", err)
	}

	// payment_intent.succeeded webhook → series full → refund + notify.
	g.verifyFn = func([]byte, string, string) (payments.Event, error) {
		return payments.Event{
			ID: "evt_pi_full", Type: "payment_intent.succeeded",
			IntentID: pending.StripePaymentID, Status: "succeeded",
		}, nil
	}
	if err := s.HandleStripeEvent(ctx, f.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("webhook: %v", err)
	}

	if !refunded {
		t.Error("expected a Stripe refund")
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "refunded")
	var eb int
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM enrollment_bookings WHERE enrollment_id=? AND user_id=?`,
		series.EnrollmentID, f.studentID).Scan(&eb)
	if eb != 0 {
		t.Errorf("should not be enrolled when full, got eb=%d", eb)
	}
	if n := auditCount(t, s, f.studioID, "series_full_refund"); n != 1 {
		t.Errorf("series_full_refund audit = %d, want 1", n)
	}
}
