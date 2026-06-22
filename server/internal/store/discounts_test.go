package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// seedAdminUser inserts a manager user we can list as the discount author.
func seedAdminUser(t *testing.T, s *Store, studioID string) string {
	t.Helper()
	id := NewID()
	if _, err := s.db.ExecContext(context.Background(),
		`INSERT INTO users (id, studio_id, role, email, full_name)
		 VALUES (?, ?, 'manager', 'mgr@test.com', 'Mgr')`,
		id, studioID,
	); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestComputeDiscountMinor(t *testing.T) {
	cases := []struct {
		kind  string
		value int
		list  int
		want  int
	}{
		{DiscountKindPercent, 10, 1000, 100},
		{DiscountKindPercent, 15, 1555, 233}, // (1555*15+50)/100 = 23375/100 = 233
		{DiscountKindPercent, 100, 2000, 2000},
		{DiscountKindPercent, 50, 999, 500}, // (999*50+50)/100 = 49.99 → 500 round-half-up
		{DiscountKindFixedMinor, 500, 1000, 500},
		{DiscountKindFixedMinor, 5000, 1000, 1000}, // capped at list
		{DiscountKindComp, 0, 1234, 1234},
		{"unknown", 0, 100, 0},
	}
	for _, c := range cases {
		got := computeDiscountMinor(c.kind, c.value, c.list)
		if got != c.want {
			t.Errorf("computeDiscountMinor(%s, %d, %d) = %d; want %d",
				c.kind, c.value, c.list, got, c.want)
		}
	}
}

func TestCreatePurchase_AppliesPercentDiscount(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	adminID := seedAdminUser(t, s, f.studioID)
	productID := seedTenPack(t, s, f) // price 5000

	code := "WELCOME10"
	if _, err := s.CreateDiscount(ctx, f.studioID, adminID, DiscountCreate{
		Code:  &code,
		Kind:  DiscountKindPercent,
		Value: 10,
	}); err != nil {
		t.Fatalf("CreateDiscount: %v", err)
	}

	purchaseID, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", code)
	if err != nil {
		t.Fatalf("CreatePurchase: %v", err)
	}

	var listMinor, amountMinor, discountMinor int
	var discountID *string
	if err := s.db.QueryRowContext(ctx, `
		SELECT list_price_minor, amount_minor, discount_minor, discount_id
		  FROM purchases WHERE id = ?`, purchaseID,
	).Scan(&listMinor, &amountMinor, &discountMinor, &discountID); err != nil {
		t.Fatal(err)
	}
	if listMinor != 5000 {
		t.Errorf("list_price_minor = %d; want 5000", listMinor)
	}
	if discountMinor != 500 {
		t.Errorf("discount_minor = %d; want 500", discountMinor)
	}
	if amountMinor != 4500 {
		t.Errorf("amount_minor = %d; want 4500", amountMinor)
	}
	if discountID == nil {
		t.Error("discount_id should not be null")
	}
}

func TestCreatePurchase_DiscountUnknownCode(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	productID := seedTenPack(t, s, f)

	_, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", "NOPE")
	var be *BookingError
	if !errors.As(err, &be) || be.Code != "discount_not_found" {
		t.Fatalf("expected BookingError discount_not_found, got %v", err)
	}
}

func TestCreatePurchase_DiscountExpired(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	adminID := seedAdminUser(t, s, f.studioID)
	productID := seedTenPack(t, s, f)

	code := "OLDCODE"
	expired := time.Now().UTC().Add(-24 * time.Hour)
	if _, err := s.CreateDiscount(ctx, f.studioID, adminID, DiscountCreate{
		Code:    &code,
		Kind:    DiscountKindPercent,
		Value:   10,
		ValidTo: &expired,
	}); err != nil {
		t.Fatalf("CreateDiscount: %v", err)
	}

	_, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", code)
	var be *BookingError
	if !errors.As(err, &be) || be.Code != "discount_expired" {
		t.Fatalf("expected BookingError discount_expired, got %v", err)
	}
}

func TestCreatePurchase_DiscountWrongProduct(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	adminID := seedAdminUser(t, s, f.studioID)
	productID := seedTenPack(t, s, f)
	otherProductID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		    (id, studio_id, name, price_minor, billing_type, pass_kind,
		     credits, validity_days)
		    VALUES (?, ?, 'Other', 2000, 'one_time', 'credit', 5, 30)`,
		otherProductID, f.studioID,
	); err != nil {
		t.Fatal(err)
	}

	code := "OTHERONLY"
	if _, err := s.CreateDiscount(ctx, f.studioID, adminID, DiscountCreate{
		Code:               &code,
		Kind:               DiscountKindPercent,
		Value:              20,
		AppliesToProductID: &otherProductID,
	}); err != nil {
		t.Fatalf("CreateDiscount: %v", err)
	}

	_, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", code)
	var be *BookingError
	if !errors.As(err, &be) || be.Code != "discount_wrong_product" {
		t.Fatalf("expected BookingError discount_wrong_product, got %v", err)
	}
}

func TestCreatePurchase_DiscountMaxUses(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	adminID := seedAdminUser(t, s, f.studioID)
	productID := seedTenPack(t, s, f)
	other := insertOtherStudent(t, s, f.studioID)

	code := "ONESHOT"
	max := 1
	if _, err := s.CreateDiscount(ctx, f.studioID, adminID, DiscountCreate{
		Code:    &code,
		Kind:    DiscountKindPercent,
		Value:   10,
		MaxUses: &max,
	}); err != nil {
		t.Fatalf("CreateDiscount: %v", err)
	}
	if _, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", code); err != nil {
		t.Fatalf("first use: %v", err)
	}
	_, _, err := s.CreatePurchase(ctx, f.studioID, other, productID, "dev_stub", code)
	var be *BookingError
	if !errors.As(err, &be) || be.Code != "discount_max_uses" {
		t.Fatalf("expected BookingError discount_max_uses, got %v", err)
	}
}

func TestRefundPurchase_FullAndPartial(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	adminID := seedAdminUser(t, s, f.studioID)
	productID := seedTenPack(t, s, f) // price 5000

	purchaseID, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", "")
	if err != nil {
		t.Fatalf("CreatePurchase: %v", err)
	}

	// Partial refund of 2000: status stays 'completed', refund total 2000.
	if err := s.RefundPurchase(ctx, f.studioID, adminID, purchaseID, 2000, "first half"); err != nil {
		t.Fatalf("partial refund: %v", err)
	}
	var status string
	var refundTotal int
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, refund_amount_minor FROM purchases WHERE id = ?`, purchaseID,
	).Scan(&status, &refundTotal); err != nil {
		t.Fatal(err)
	}
	if status != "completed" || refundTotal != 2000 {
		t.Errorf("after partial: status=%s refund=%d; want completed/2000", status, refundTotal)
	}

	// Top-up refund of 3000: flips to 'refunded'.
	if err := s.RefundPurchase(ctx, f.studioID, adminID, purchaseID, 3000, "remainder"); err != nil {
		t.Fatalf("top-up refund: %v", err)
	}
	if err := s.db.QueryRowContext(ctx,
		`SELECT status, refund_amount_minor FROM purchases WHERE id = ?`, purchaseID,
	).Scan(&status, &refundTotal); err != nil {
		t.Fatal(err)
	}
	if status != "refunded" || refundTotal != 5000 {
		t.Errorf("after top-up: status=%s refund=%d; want refunded/5000", status, refundTotal)
	}

	// Over-refund rejected.
	if err := s.RefundPurchase(ctx, f.studioID, adminID, purchaseID, 1, "extra"); err == nil {
		t.Error("expected error on refund after fully refunded")
	}
}

func TestListDiscounts_Stats(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	adminID := seedAdminUser(t, s, f.studioID)
	productID := seedTenPack(t, s, f)

	code := "STATS10"
	d, err := s.CreateDiscount(ctx, f.studioID, adminID, DiscountCreate{
		Code: &code, Kind: DiscountKindPercent, Value: 10,
	})
	if err != nil {
		t.Fatalf("CreateDiscount: %v", err)
	}
	if _, _, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", code); err != nil {
		t.Fatalf("CreatePurchase: %v", err)
	}

	rows, err := s.ListDiscounts(ctx, f.studioID, false)
	if err != nil {
		t.Fatal(err)
	}
	var found *Discount
	for i := range rows {
		if rows[i].ID == d.ID {
			found = &rows[i]
			break
		}
	}
	if found == nil {
		t.Fatal("created discount not in list")
	}
	if found.TimesUsed != 1 || found.TotalGivenMinor != 500 {
		t.Errorf("stats = used %d, given %d; want 1 / 500",
			found.TimesUsed, found.TotalGivenMinor)
	}
}
