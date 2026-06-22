package store

import (
	"context"
	"testing"
)

// insertProductWithCoverage inserts a product + optional product_class_types
// rows. Returns the product id.
func insertProductWithCoverage(t *testing.T, s *Store, studioID, name string, classTypeIDs []string) string {
	t.Helper()
	ctx := context.Background()
	id := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		    (id, studio_id, name, price_minor, billing_type, pass_kind, credits)
		    VALUES (?, ?, ?, 1000, 'one_time', 'unlimited', NULL)`,
		id, studioID, name,
	); err != nil {
		t.Fatal(err)
	}
	for _, ctID := range classTypeIDs {
		if _, err := s.db.ExecContext(ctx,
			`INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
			id, ctID,
		); err != nil {
			t.Fatal(err)
		}
	}
	return id
}

func TestListProducts_NoFilterReturnsAll(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	a := insertProductWithCoverage(t, s, f.studioID, "Pass A", []string{f.classTypeID})
	b := insertProductWithCoverage(t, s, f.studioID, "Pass B", nil)

	rows, err := s.ListProducts(ctx, f.studioID, "")
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, r := range rows {
		ids = append(ids, r.ID)
	}
	if !contains(ids, a) || !contains(ids, b) {
		t.Errorf("unfiltered list should include both: got %v", ids)
	}
}

func TestListProducts_FiltersByClassType(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Second class type for negative coverage.
	otherCT := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO class_types (id, studio_id, name) VALUES (?, ?, 'Pilates')`,
		otherCT, f.studioID,
	); err != nil {
		t.Fatal(err)
	}

	a := insertProductWithCoverage(t, s, f.studioID, "Yoga Pass", []string{f.classTypeID})
	b := insertProductWithCoverage(t, s, f.studioID, "Pilates Pass", []string{otherCT})
	c := insertProductWithCoverage(t, s, f.studioID, "Open Pass", []string{f.classTypeID, otherCT})

	yoga, err := s.ListProducts(ctx, f.studioID, f.classTypeID)
	if err != nil {
		t.Fatal(err)
	}
	yids := productIDsOf(yoga)
	if !contains(yids, a) || !contains(yids, c) {
		t.Errorf("yoga filter should include A and C: got %v", yids)
	}
	if contains(yids, b) {
		t.Errorf("yoga filter should NOT include pilates-only: %v", yids)
	}

	pilates, err := s.ListProducts(ctx, f.studioID, otherCT)
	if err != nil {
		t.Fatal(err)
	}
	pids := productIDsOf(pilates)
	if !contains(pids, b) || !contains(pids, c) {
		t.Errorf("pilates filter should include B and C: got %v", pids)
	}
	if contains(pids, a) {
		t.Errorf("pilates filter should NOT include yoga-only: %v", pids)
	}
}

func TestListProducts_FilterEmptyResult(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	insertProductWithCoverage(t, s, f.studioID, "No Coverage", nil)

	rows, err := s.ListProducts(ctx, f.studioID, NewID()) // unknown class type
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("unknown class type should yield empty: got %d rows", len(rows))
	}
}

func productIDsOf(ps []Product) []string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = p.ID
	}
	return out
}
