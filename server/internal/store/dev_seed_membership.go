package store

import (
	"context"
	"database/sql"
	"fmt"

	stripe "github.com/stripe/stripe-go/v83"
	"github.com/stripe/stripe-go/v83/client"
)

// DevSeedRealMembership creates a genuine Stripe *test-mode* subscription for a
// seeded student, so dev always exercises real Stripe rather than placeholder
// rows. Server-side, no browser: it mirrors the product's recurring Price if
// needed, ensures a customer with a test card, records a pending subscription,
// and creates the Stripe subscription. The invoice.paid webhook then fulfils it
// (grants the pass, links the row, records the purchase, captures the PI) — so
// the studio's Stripe webhook forwarding must be running.
//
// Dev-only (called from /dev/seed-membership). Idempotent per (user, product).
func (s *Store) DevSeedRealMembership(ctx context.Context, studioID, email, productID string) error {
	if s.gateway == nil {
		return fmt.Errorf("payments gateway not configured")
	}
	var userID string
	if err := s.db.QueryRowContext(ctx,
		`SELECT id FROM users WHERE studio_id = ? AND email = ?`, studioID, email,
	).Scan(&userID); err != nil {
		return fmt.Errorf("resolve %s: %w", email, err)
	}

	// Idempotent — don't stack a second live/pending sub on repeat runs.
	var existing int
	s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM subscriptions
		 WHERE studio_id = ? AND user_id = ? AND product_id = ?
		   AND status IN ('active','past_due','pending')`,
		studioID, userID, productID).Scan(&existing)
	if existing > 0 {
		return nil
	}

	keys, err := s.LoadStripeKeysForUse(ctx, studioID)
	if err != nil {
		return fmt.Errorf("load stripe keys: %w", err)
	}

	// Product snapshot + ensure it has a Stripe recurring Price to charge against.
	var name, currency string
	var priceMinor int
	var priceID, interval sql.NullString
	if err := s.db.QueryRowContext(ctx, `
		SELECT p.name, p.price_minor, st.currency, p.stripe_price_id,
		       COALESCE(p.billing_interval,'month')
		  FROM products p JOIN studios st ON st.id = p.studio_id
		 WHERE p.id = ? AND p.studio_id = ? AND p.billing_type = 'recurring'`,
		productID, studioID,
	).Scan(&name, &priceMinor, &currency, &priceID, &interval); err != nil {
		return fmt.Errorf("load recurring product: %w", err)
	}
	stripePriceID := priceID.String
	if stripePriceID == "" {
		sp, prid, err := s.mirrorRecurringPrice(ctx, studioID, "recurring", name, priceMinor, interval.String)
		if err != nil {
			return fmt.Errorf("mirror price: %w", err)
		}
		if prid == "" {
			return ErrStripeNotConfigured
		}
		if _, err := s.db.ExecContext(ctx,
			`UPDATE products SET stripe_product_id = ?, stripe_price_id = ? WHERE id = ?`,
			nullableStr(sp), prid, productID); err != nil {
			return err
		}
		stripePriceID = prid
	}

	customerID, err := s.ensureStripeCustomer(ctx, keys.SecretKey, studioID, userID, email)
	if err != nil {
		return fmt.Errorf("ensure customer: %w", err)
	}

	sc := &client.API{}
	sc.Init(keys.SecretKey, nil)

	// Attach a test card + make it the customer's default so the subscription's
	// first invoice charges immediately (→ invoice.paid → our webhook fulfils).
	pm, err := sc.PaymentMethods.New(&stripe.PaymentMethodParams{
		Type: stripe.String("card"),
		Card: &stripe.PaymentMethodCardParams{Token: stripe.String("tok_visa")},
	})
	if err != nil {
		return fmt.Errorf("create payment method: %w", err)
	}
	if _, err := sc.PaymentMethods.Attach(pm.ID, &stripe.PaymentMethodAttachParams{
		Customer: stripe.String(customerID),
	}); err != nil {
		return fmt.Errorf("attach payment method: %w", err)
	}
	if _, err := sc.Customers.Update(customerID, &stripe.CustomerParams{
		InvoiceSettings: &stripe.CustomerInvoiceSettingsParams{
			DefaultPaymentMethod: stripe.String(pm.ID),
		},
	}); err != nil {
		return fmt.Errorf("set default payment method: %w", err)
	}

	// Pending row keyed on the customer so the invoice.paid webhook resolves it
	// (findSubscriptionForInvoiceTx), then grants + links.
	subID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO subscriptions
		  (id, studio_id, user_id, product_id, stripe_customer_id, status, currency, amount_minor)
		VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)`,
		subID, studioID, userID, productID, customerID, currency, priceMinor,
	); err != nil {
		return fmt.Errorf("insert pending subscription: %w", err)
	}

	if _, err := sc.Subscriptions.New(&stripe.SubscriptionParams{
		Customer: stripe.String(customerID),
		Items:    []*stripe.SubscriptionItemsParams{{Price: stripe.String(stripePriceID)}},
	}); err != nil {
		return fmt.Errorf("create subscription: %w", err)
	}
	return nil
}
