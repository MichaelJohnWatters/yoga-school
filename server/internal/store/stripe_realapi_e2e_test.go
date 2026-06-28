//go:build stripe_e2e

// This file is behind the `stripe_e2e` build tag so it's excluded from the
// normal `go test ./...` (which must stay fast + offline). Run it deliberately
// via the Tilt `yoga-e2e-stripe-go` button or `go test -tags stripe_e2e`. When
// Stripe keys are present in repo-root .env it hits the live test API for real;
// when they're absent it skips (so the tagged run doesn't error on a machine
// without keys). Keys are loaded from .env automatically.

package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	stripe "github.com/stripe/stripe-go/v83"
	"github.com/stripe/stripe-go/v83/client"

	"github.com/studio52/yoga-school/server/internal/payments"
	"github.com/studio52/yoga-school/server/internal/secrets"
)

// loadDotenv walks up from the test's working dir to the repo-root .env and
// loads simple KEY=VALUE lines into the process env (without clobbering vars
// already set explicitly). Lets the e2e "just work" from a dev checkout.
func loadDotenv(t *testing.T) {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		return
	}
	for d := dir; d != "/" && d != ""; d = filepath.Dir(d) {
		b, err := os.ReadFile(filepath.Join(d, ".env"))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "export "))
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			k = strings.TrimSpace(k)
			v = strings.Trim(strings.TrimSpace(v), `"'`)
			if os.Getenv(k) == "" {
				t.Setenv(k, v)
			}
		}
		return
	}
}

// TestStripeRealAPI_E2E is a true money→pass round-trip against Stripe's live
// test API.
//
// Flow (no browser, no webhook forwarding):
//  1. Our CreatePendingPurchase → real PaymentIntent on Stripe.
//  2. We confirm that intent via the Stripe API with the test PaymentMethod
//     pm_card_visa (stands in for a typed-in card).
//  3. Our ConfirmPurchase → real PaymentIntents.Get → sees succeeded → mints.
//  4. Our RefundPurchase → real Stripe refund.
func TestStripeRealAPI_E2E(t *testing.T) {
	loadDotenv(t)
	sk := os.Getenv("STRIPE_E2E_SECRET_KEY")
	if sk == "" {
		sk = os.Getenv("STRIPE_SECRET_KEY")
	}
	if sk == "" {
		// Reachable only under `-tags stripe_e2e` (the build tag already keeps
		// this out of the normal suite). Skip rather than fail so running the
		// tagged tests on a machine without Stripe keys doesn't error.
		t.Skip("no Stripe test secret key in .env (STRIPE_E2E_SECRET_KEY / STRIPE_SECRET_KEY) — skipping live e2e")
	}
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	// Wire the studio's real test key + the real gateway.
	s.SetSealer(secrets.NewTestSealer())
	if _, err := s.UpdateStripeCredentials(ctx, f.studioID, f.studentID,
		StripeCredentialsPatch{SecretKey: &sk}); err != nil {
		t.Fatalf("set creds: %v", err)
	}
	s.SetPaymentGateway(payments.NewStripeGateway())
	productID := seedTenPack(t, s, f)

	// 1. Create the pending purchase → real PaymentIntent.
	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatalf("CreatePendingPurchase (real Stripe): %v", err)
	}
	if pending.StripePaymentID[:3] != "pi_" {
		t.Fatalf("expected a real pi_ id, got %q", pending.StripePaymentID)
	}

	// 2. Confirm the intent with a test card via the Stripe API directly.
	sc := &client.API{}
	sc.Init(sk, nil)
	confirmed, err := sc.PaymentIntents.Confirm(pending.StripePaymentID, &stripe.PaymentIntentConfirmParams{
		PaymentMethod: stripe.String("pm_card_visa"),
		ReturnURL:     stripe.String("https://example.com/return"),
	})
	if err != nil {
		t.Fatalf("stripe confirm: %v", err)
	}
	if confirmed.Status != stripe.PaymentIntentStatusSucceeded {
		t.Fatalf("intent status = %s, want succeeded", confirmed.Status)
	}

	// 3. Our confirm verifies against Stripe and mints the pass.
	entID, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatalf("ConfirmPurchase: %v", err)
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "completed")
	assertEntitlementStatus(t, s, entID, "active")

	// 4. A real Stripe refund of the whole thing.
	if err := s.RefundPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID, 5000, "e2e refund"); err != nil {
		t.Fatalf("RefundPurchase (real Stripe): %v", err)
	}
	assertPurchaseStatus(t, s, pending.PurchaseID, "refunded")
}
