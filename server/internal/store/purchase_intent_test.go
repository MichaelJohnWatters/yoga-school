package store

import (
	"context"
	"strings"
	"testing"
)

// helper: seed a credit-pack product covering the fixture's class type.
func seedTenPack(t *testing.T, s *Store, f fixture) string {
	t.Helper()
	id := NewID()
	if _, err := s.db.ExecContext(context.Background(), `
		INSERT INTO products
		    (id, studio_id, name, price_minor, billing_type, pass_kind,
		     credits, validity_days)
		    VALUES (?, ?, '10-Pack', 5000, 'one_time', 'credit', 10, 60)`,
		id, f.studioID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(context.Background(),
		`INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
		id, f.classTypeID,
	); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestCreatePendingPurchase_DoesNotMintEntitlementYet(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	productID := seedTenPack(t, s, f)

	out, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatalf("intent: %v", err)
	}
	if out.PurchaseID == "" || out.ClientSecret == "" {
		t.Errorf("intent response missing fields: %+v", *out)
	}
	if !strings.HasPrefix(out.StripePaymentID, "pi_stub_") {
		t.Errorf("expected dev-stub pi_, got %q", out.StripePaymentID)
	}

	// Purchase row exists with status='pending' and no entitlement linked.
	var status string
	var ent *string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, resulting_entitlement_id FROM purchases WHERE id = ?`,
		out.PurchaseID,
	).Scan(&status, &ent); err != nil {
		t.Fatal(err)
	}
	if status != "pending" {
		t.Errorf("status: got %q want pending", status)
	}
	if ent != nil {
		t.Errorf("entitlement should be nil pre-confirm, got %v", *ent)
	}

	// No entitlement minted at all for this user yet.
	var count int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM entitlements WHERE user_id = ? AND source_product_id = ?`,
		f.studentID, productID,
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Errorf("entitlement minted prematurely: %d rows", count)
	}
}

func TestConfirmPurchase_MintsEntitlementAndFlipsStatus(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	productID := seedTenPack(t, s, f)

	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatal(err)
	}
	entID, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if entID == "" {
		t.Fatal("confirm returned empty entitlement id")
	}

	// Purchase status + back-link.
	var status, linkedEnt string
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, COALESCE(resulting_entitlement_id,'') FROM purchases WHERE id = ?`,
		pending.PurchaseID,
	).Scan(&status, &linkedEnt); err != nil {
		t.Fatal(err)
	}
	if status != "completed" {
		t.Errorf("status: got %q want completed", status)
	}
	if linkedEnt != entID {
		t.Errorf("resulting_entitlement_id: got %s want %s", linkedEnt, entID)
	}

	// Entitlement actually exists with snapshot fields.
	var credits, total int
	var label string
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_total, credits_remaining, label FROM entitlements WHERE id = ?`,
		entID,
	).Scan(&total, &credits, &label); err != nil {
		t.Fatal(err)
	}
	if total != 10 || credits != 10 {
		t.Errorf("credits snapshot: total=%d remaining=%d want 10/10", total, credits)
	}
	if label != "10-Pack" {
		t.Errorf("label: got %q want 10-Pack", label)
	}
}

func TestConfirmPurchase_IsIdempotent(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	productID := seedTenPack(t, s, f)

	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatal(err)
	}
	first, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.ConfirmPurchase(ctx, f.studioID, f.studentID, pending.PurchaseID)
	if err != nil {
		t.Fatalf("re-confirm: %v", err)
	}
	if first != second {
		t.Errorf("idempotent confirm returned different ids: %s vs %s", first, second)
	}
	// Only ONE entitlement was minted for this purchase.
	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM entitlements WHERE source_product_id = ? AND user_id = ?`,
		productID, f.studentID,
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("entitlement count: got %d want 1 (re-confirm should not duplicate)", n)
	}
}

func TestConfirmPurchase_RefusesNonPendingStatus(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	productID := seedTenPack(t, s, f)

	// Synchronous (already-completed) purchase via the legacy path.
	syncID, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "cash", "")
	if err != nil {
		t.Fatal(err)
	}
	// Trying to "confirm" a row that's already completed but came through
	// the cash path (no resulting_entitlement_id mismatch — it does have
	// one, the back-link is set) is idempotent. Force-flag the row to
	// 'refunded' so we can prove the error branch fires for genuinely
	// non-pending non-completed rows.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE purchases SET status = 'refunded' WHERE id = ?`, syncID,
	); err != nil {
		t.Fatal(err)
	}
	_, err = s.ConfirmPurchase(ctx, f.studioID, f.studentID, syncID)
	if err == nil || !strings.Contains(err.Error(), "refunded") {
		t.Errorf("expected refusal mentioning refunded, got %v", err)
	}
}

func TestConfirmPurchase_NotFoundCrossUser(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	productID := seedTenPack(t, s, f)

	pending, err := s.CreatePendingPurchase(ctx, f.studioID, f.studentID, productID, "card", "")
	if err != nil {
		t.Fatal(err)
	}
	other := insertOtherStudent(t, s, f.studioID)
	if _, err := s.ConfirmPurchase(ctx, f.studioID, other, pending.PurchaseID); err != ErrNotFound {
		t.Errorf("confirm by other user: got %v want ErrNotFound", err)
	}
}
