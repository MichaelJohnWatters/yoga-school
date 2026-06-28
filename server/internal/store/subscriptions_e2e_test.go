//go:build stripe_e2e

// Behind the `stripe_e2e` build tag (see stripe_realapi_e2e_test.go). Exercises
// the subscription *create* path against the live Stripe test API: mirror a
// recurring Price, ensure a Customer, and open a subscription Checkout Session.
// The full renewal round-trip needs Stripe test clocks to advance invoices and
// isn't automated here — the mocked-gateway TestSubscriptionLifecycle covers the
// fulfilment logic; this proves our params are accepted by the real API.

package store

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/studio52/yoga-school/server/internal/payments"
	"github.com/studio52/yoga-school/server/internal/secrets"
)

func TestStripeRealAPI_Subscription_CreateSide(t *testing.T) {
	loadDotenv(t)
	sk := os.Getenv("STRIPE_E2E_SECRET_KEY")
	if sk == "" {
		sk = os.Getenv("STRIPE_SECRET_KEY")
	}
	if sk == "" {
		t.Skip("no Stripe test secret key in .env — skipping live subscription e2e")
	}
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	s.SetSealer(secrets.NewTestSealer())
	if _, err := s.UpdateStripeCredentials(ctx, f.studioID, f.studentID,
		StripeCredentialsPatch{SecretKey: &sk}); err != nil {
		t.Fatalf("set creds: %v", err)
	}
	s.SetPaymentGateway(payments.NewStripeGateway())

	// A recurring product mirrors to a real Stripe Product + Price.
	name, price, billing, interval := "E2E Unlimited", 8800, "recurring", "month"
	productID, err := s.CreateAdminProduct(ctx, f.studioID, f.studentID, AdminProductInput{
		Name: &name, PriceMinor: &price, BillingType: &billing,
		BillingInterval: &interval, PassKind: strptrLocal("unlimited"),
		ClassTypeIDs: []string{f.classTypeID},
	})
	if err != nil {
		t.Fatalf("create recurring product: %v", err)
	}
	var priceID string
	s.db.QueryRowContext(ctx, `SELECT COALESCE(stripe_price_id,'') FROM products WHERE id=?`, productID).Scan(&priceID)
	if !strings.HasPrefix(priceID, "price_") {
		t.Fatalf("expected a real price id, got %q", priceID)
	}

	// A subscription Checkout Session opens against that Price + a real Customer.
	out, err := s.CreateCheckoutSubscription(ctx, f.studioID, f.studentID, productID,
		"https://example.com/ok", "https://example.com/no")
	if err != nil {
		t.Fatalf("create subscription checkout: %v", err)
	}
	if !strings.Contains(out.URL, "checkout.stripe.com") {
		t.Fatalf("expected a real checkout URL, got %q", out.URL)
	}
}

func strptrLocal(s string) *string { return &s }
