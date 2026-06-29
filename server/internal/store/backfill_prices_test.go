package store

import (
	"context"
	"testing"

	"github.com/studio52/yoga-school/server/internal/secrets"
)

// Saving a usable secret key backfills Stripe Prices for live recurring
// memberships that lack one, while leaving archived and one-time products
// alone.
func TestUpdateStripeCredentials_BackfillsRecurringPrices(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	g := &fakeGateway{intents: map[string]string{}}
	s.SetPaymentGateway(g) // gateway present BEFORE keys are saved
	s.SetSealer(secrets.NewTestSealer())

	// Live recurring, no stripe ids → should get backfilled.
	live := NewID()
	mustExec(t, s, `
		INSERT INTO products (id, studio_id, name, price_minor, billing_type, billing_interval, pass_kind, validity_days)
		VALUES (?, ?, 'Unlimited Monthly', 8800, 'recurring', 'month', 'unlimited', 30)`,
		live, f.studioID)
	// Archived recurring → should be skipped.
	archived := NewID()
	mustExec(t, s, `
		INSERT INTO products (id, studio_id, name, price_minor, billing_type, billing_interval, pass_kind, validity_days, is_archived)
		VALUES (?, ?, 'Old Membership', 5000, 'recurring', 'month', 'unlimited', 30, 1)`,
		archived, f.studioID)
	// One-time → should be skipped (no Price needed).
	oneTime := NewID()
	mustExec(t, s, `
		INSERT INTO products (id, studio_id, name, price_minor, billing_type, pass_kind, credits, validity_days)
		VALUES (?, ?, '10-pack', 9000, 'one_time', 'credit', 10, 90)`,
		oneTime, f.studioID)

	if _, err := s.UpdateStripeCredentials(ctx, f.studioID, f.studentID,
		StripeCredentialsPatch{SecretKey: strptr("sk_test_123")}); err != nil {
		t.Fatalf("save creds: %v", err)
	}

	if got := priceIDOf(t, s, live); got == "" {
		t.Error("live recurring product was not backfilled with a stripe_price_id")
	}
	if got := priceIDOf(t, s, archived); got != "" {
		t.Errorf("archived product should not be backfilled, got %q", got)
	}
	if got := priceIDOf(t, s, oneTime); got != "" {
		t.Errorf("one-time product should not be backfilled, got %q", got)
	}
}

func mustExec(t *testing.T, s *Store, q string, args ...any) {
	t.Helper()
	if _, err := s.db.ExecContext(context.Background(), q, args...); err != nil {
		t.Fatalf("exec: %v", err)
	}
}

func priceIDOf(t *testing.T, s *Store, productID string) string {
	t.Helper()
	var pid *string
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT stripe_price_id FROM products WHERE id = ?`, productID).Scan(&pid); err != nil {
		t.Fatalf("read price id: %v", err)
	}
	if pid == nil {
		return ""
	}
	return *pid
}
