package store

import (
	"context"
	"testing"
	"time"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// Refunding a membership refunds the latest payment AND cancels now — revoking
// access and releasing the student's future booked seats.
func TestAdminRefundMembership(t *testing.T) {
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
	productID := seedRecurringProduct(t, s, f)

	out, err := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID, "a", "b")
	if err != nil {
		t.Fatalf("checkout: %v", err)
	}
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_sess", Type: "checkout.session.completed", SessionMode: "subscription",
		SessionID: "cs_" + out.SubscriptionID, SubscriptionID: "sub_1", CustomerID: "cus_x",
	})
	// invoice.paid carrying the PaymentIntent → captured onto the subscription.
	fireEvent(t, s, g, f.studioID, payments.Event{
		ID: "evt_inv1", Type: "invoice.paid", SubscriptionID: "sub_1", CustomerID: "cus_x",
		InvoiceBillingReason: "subscription_create",
		CurrentPeriodEnd:     time.Now().UTC().AddDate(0, 0, 30).Unix(),
		IntentID:             "pi_live_x",
	})

	_, _, entID := subStatus(t, s, out.SubscriptionID)
	if entID == "" {
		t.Fatal("expected entitlement")
	}

	// A future class booked on this membership pass.
	classID := NewID()
	mustExec(t, s, `
		INSERT INTO classes (id, studio_id, class_type_id, instructor_id, room_id, starts_at, ends_at, status, capacity)
		VALUES (?, ?, ?, ?, ?, ?, ?, 'scheduled', 10)`,
		classID, f.studioID, f.classTypeID, f.instructorID, f.roomID,
		time.Now().UTC().AddDate(0, 0, 3).Format(time.RFC3339),
		time.Now().UTC().AddDate(0, 0, 3).Add(time.Hour).Format(time.RFC3339))
	bookingID := NewID()
	mustExec(t, s, `
		INSERT INTO bookings (id, studio_id, class_id, user_id, entitlement_id, is_plus_one, booked_by_role, cancel_cutoff_hours, status)
		VALUES (?, ?, ?, ?, ?, 0, 'student', 0, 'booked')`,
		bookingID, f.studioID, classID, f.studentID, entID)

	if err := s.AdminRefundMembership(ctx, f.studioID, f.instructorID, out.SubscriptionID); err != nil {
		t.Fatalf("AdminRefundMembership: %v", err)
	}

	if !refunded {
		t.Error("expected a Stripe refund")
	}
	if st, _, _ := subStatus(t, s, out.SubscriptionID); st != "canceled" {
		t.Errorf("subscription status = %q, want canceled", st)
	}
	if st := entitlementStatus(t, s, entID); st != "expired" {
		t.Errorf("entitlement status = %q, want expired", st)
	}
	var bookingStatus string
	s.db.QueryRowContext(ctx, `SELECT status FROM bookings WHERE id = ?`, bookingID).Scan(&bookingStatus)
	if bookingStatus != "cancelled" {
		t.Errorf("future booking status = %q, want cancelled (seat released)", bookingStatus)
	}
	if n := auditCount(t, s, f.studioID, "subscription_refund"); n != 1 {
		t.Errorf("subscription_refund audit = %d, want 1", n)
	}
}

// With no captured payment intent, refund is refused (manager uses the Dashboard).
func TestAdminRefundMembership_NoPayment(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)
	productID := seedRecurringProduct(t, s, f)
	subID := NewID()
	mustExec(t, s, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id, status, currency, amount_minor)
		VALUES (?, ?, ?, ?, 'cus_x', 'active', 'GBP', 8800)`,
		subID, f.studioID, f.studentID, productID)

	if err := s.AdminRefundMembership(ctx, f.studioID, f.instructorID, subID); err != ErrNoRefundablePayment {
		t.Errorf("err = %v, want ErrNoRefundablePayment", err)
	}
}
