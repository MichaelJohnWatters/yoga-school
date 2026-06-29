package store

import (
	"context"
	"testing"
)

func seedPassProduct(t *testing.T, s *Store, studioID, passKind string, credits, validityDays int, policy string) string {
	t.Helper()
	id := NewID()
	var creditsArg any
	if passKind == "credit" {
		creditsArg = credits
	}
	mustExec(t, s, `
		INSERT INTO products
		  (id, studio_id, name, price_minor, billing_type, pass_kind, credits, validity_days, duplicate_policy)
		VALUES (?, ?, 'Pass', 5000, 'one_time', ?, ?, ?, ?)`,
		id, studioID, passKind, creditsArg, validityDays, policy)
	return id
}

func countEntitlements(t *testing.T, s *Store, userID, productID string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM entitlements WHERE user_id = ? AND source_product_id = ?`,
		userID, productID).Scan(&n); err != nil {
		t.Fatalf("count entitlements: %v", err)
	}
	return n
}

// allow (default): a second purchase mints a separate entitlement.
func TestDuplicatePolicy_Allow(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	p := seedPassProduct(t, s, f.studioID, "credit", 5, 30, "allow")

	for i := 0; i < 2; i++ {
		if _, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, p, "cash", ""); err != nil {
			t.Fatalf("purchase %d: %v", i, err)
		}
	}
	if n := countEntitlements(t, s, f.studentID, p); n != 2 {
		t.Errorf("entitlements = %d, want 2 (separate passes)", n)
	}
}

// prevent: a second purchase while a usable pass is held is refused; once the
// pass is used up it's allowed again.
func TestDuplicatePolicy_Prevent(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	p := seedPassProduct(t, s, f.studioID, "credit", 5, 30, "prevent")

	_, entID, err := s.CreatePurchase(ctx, f.studioID, f.studentID, p, "cash", "")
	if err != nil {
		t.Fatalf("first purchase: %v", err)
	}
	if _, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, p, "cash", ""); err != ErrDuplicatePass {
		t.Fatalf("second purchase err = %v, want ErrDuplicatePass", err)
	}

	// Deplete the pass → no longer usable → a new purchase is allowed.
	mustExec(t, s, `UPDATE entitlements SET credits_remaining = 0 WHERE id = ?`, entID)
	if _, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, p, "cash", ""); err != nil {
		t.Errorf("purchase after depletion should be allowed, got: %v", err)
	}
}

// topup: a second purchase merges into the existing pass — no new entitlement,
// credits accumulate.
func TestDuplicatePolicy_TopUp(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	p := seedPassProduct(t, s, f.studioID, "credit", 5, 30, "topup")

	_, entID, err := s.CreatePurchase(ctx, f.studioID, f.studentID, p, "cash", "")
	if err != nil {
		t.Fatalf("first purchase: %v", err)
	}
	_, entID2, err := s.CreatePurchase(ctx, f.studioID, f.studentID, p, "cash", "")
	if err != nil {
		t.Fatalf("second purchase: %v", err)
	}
	if entID2 != entID {
		t.Errorf("top-up should reuse the same entitlement; got %q then %q", entID, entID2)
	}
	if n := countEntitlements(t, s, f.studentID, p); n != 1 {
		t.Errorf("entitlements = %d, want 1 (merged)", n)
	}
	var total, remaining int
	if err := s.db.QueryRowContext(ctx,
		`SELECT credits_total, credits_remaining FROM entitlements WHERE id = ?`, entID).
		Scan(&total, &remaining); err != nil {
		t.Fatalf("read entitlement: %v", err)
	}
	if total != 10 || remaining != 10 {
		t.Errorf("after top-up credits total=%d remaining=%d, want 10/10", total, remaining)
	}
}
