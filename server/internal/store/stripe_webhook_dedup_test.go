package store

import (
	"context"
	"testing"

	"github.com/studio52/yoga-school/server/internal/payments"
)

// TestHandleStripeEvent_DedupIsPerStudio guards the composite-key fix: Stripe
// event ids are only unique within an account, so the same evt_ id arriving for
// two different studios must be handled independently. A global dedup key would
// let the first studio's event silently suppress the second studio's
// fulfilment.
func TestHandleStripeEvent_DedupIsPerStudio(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	// Two independent studios (newFixture mints a fresh studio each call).
	f1 := newFixture(t, s)
	f2 := newFixture(t, s)
	withStripeCreds(t, s, f1.studioID, f1.studentID)
	withStripeCreds(t, s, f2.studioID, f2.studentID)

	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g)

	prod1 := seedTenPack(t, s, f1)
	prod2 := seedTenPack(t, s, f2)
	pending1, _ := s.CreatePendingPurchase(ctx, f1.studioID, f1.studentID, prod1, "card", "", "")
	pending2, _ := s.CreatePendingPurchase(ctx, f2.studioID, f2.studentID, prod2, "card", "", "")

	const dupEventID = "evt_shared"

	// Studio 1 receives evt_shared → fulfils.
	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) {
		return payments.Event{ID: dupEventID, Type: "payment_intent.succeeded", IntentID: pending1.StripePaymentID, Status: "succeeded"}, nil
	}
	if err := s.HandleStripeEvent(ctx, f1.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("studio1 handle: %v", err)
	}
	assertPurchaseStatus(t, s, pending1.PurchaseID, "completed")

	// Studio 2 receives an event with the SAME id. It must NOT be treated as a
	// duplicate — studio 2's purchase must still fulfil.
	g.verifyFn = func(_ []byte, _, _ string) (payments.Event, error) {
		return payments.Event{ID: dupEventID, Type: "payment_intent.succeeded", IntentID: pending2.StripePaymentID, Status: "succeeded"}, nil
	}
	if err := s.HandleStripeEvent(ctx, f2.studioID, []byte("{}"), "sig"); err != nil {
		t.Fatalf("studio2 handle: %v", err)
	}
	assertPurchaseStatus(t, s, pending2.PurchaseID, "completed")

	// Both studios should have recorded the event under their own scope.
	var n int
	s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM processed_stripe_events WHERE event_id = ?`, dupEventID).Scan(&n)
	if n != 2 {
		t.Fatalf("expected 2 per-studio dedup rows for %s, got %d", dupEventID, n)
	}
}
