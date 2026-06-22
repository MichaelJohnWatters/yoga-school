package store

import (
	"context"
	"sort"
	"testing"
	"time"
)

// TestCreatePurchase_SnapshotsProductFieldsOntoEntitlement locks in the
// spec's load-bearing decision (#1, "Snapshotting in four places"): the
// entitlement captures the product's name, pass_kind, credits, and validity
// at purchase time. A later edit to the product must not retroactively
// rewrite live entitlements.
//
// Also asserts the class-type coverage is copied — the deeper of the two
// snapshots, and the easiest to silently lose.
func TestCreatePurchase_SnapshotsProductFieldsOntoEntitlement(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// A second class type so we can prove BOTH coverage rows copy.
	pilatesID, err := s.CreateClassType(ctx, f.studioID, f.instructorID, ClassTypeInput{
		Name: "Pilates", Discipline: "mat",
	})
	if err != nil {
		t.Fatalf("class type: %v", err)
	}

	// 10-pack covering yoga + pilates with a 60-day validity window.
	productID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		    (id, studio_id, name, price_minor, billing_type, pass_kind,
		     credits, validity_days)
		    VALUES (?, ?, 'Original 10 Pack', 5000, 'one_time', 'credit', 10, 60)`,
		productID, f.studioID,
	); err != nil {
		t.Fatalf("seed product: %v", err)
	}
	for _, ct := range []string{f.classTypeID, pilatesID} {
		if _, err := s.db.ExecContext(ctx,
			`INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
			productID, ct,
		); err != nil {
			t.Fatal(err)
		}
	}

	purchaseID, entID, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", "")
	if err != nil {
		t.Fatalf("CreatePurchase: %v", err)
	}
	if purchaseID == "" || entID == "" {
		t.Fatalf("ids: purchase=%q ent=%q", purchaseID, entID)
	}

	// Scalar snapshot fields.
	var (
		label, passKind, status string
		creditsT, creditsR     int
		expiresStr             string
	)
	if err := s.db.QueryRowContext(ctx, `
		SELECT label, pass_kind, status,
		       credits_total, credits_remaining, COALESCE(expires_at,'')
		  FROM entitlements WHERE id = ?`, entID,
	).Scan(&label, &passKind, &status, &creditsT, &creditsR, &expiresStr); err != nil {
		t.Fatalf("read entitlement: %v", err)
	}
	if label != "Original 10 Pack" {
		t.Errorf("label: got %q want Original 10 Pack", label)
	}
	if passKind != "credit" {
		t.Errorf("pass_kind: got %q want credit", passKind)
	}
	if creditsT != 10 || creditsR != 10 {
		t.Errorf("credits: total=%d remaining=%d want 10/10", creditsT, creditsR)
	}
	if status != "active" {
		t.Errorf("status: got %q want active", status)
	}
	// Expires roughly 60 days out (±1 hour for clock drift).
	expires, err := time.Parse(time.RFC3339, expiresStr)
	if err != nil {
		t.Fatalf("expires_at parse: %v", err)
	}
	want := time.Now().UTC().Add(60 * 24 * time.Hour)
	if diff := want.Sub(expires); diff > time.Hour || diff < -time.Hour {
		t.Errorf("expires_at: got %s want ~%s (diff %s)", expires, want, diff)
	}

	// Coverage snapshot — both class types should be on the entitlement.
	rows, err := s.db.QueryContext(ctx,
		`SELECT class_type_id FROM entitlement_class_types WHERE entitlement_id = ?
		  ORDER BY class_type_id`, entID,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		got = append(got, id)
	}
	want2 := []string{f.classTypeID, pilatesID}
	sort.Strings(got)
	sort.Strings(want2)
	if len(got) != len(want2) || got[0] != want2[0] || got[1] != want2[1] {
		t.Errorf("coverage: got %v want %v", got, want2)
	}

	// Now mutate the product — coverage drops to yoga only, credits drop to
	// 5, name changes. The existing entitlement must NOT change.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE products SET name='Renamed', credits=5 WHERE id = ?`, productID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM product_class_types WHERE product_id = ? AND class_type_id = ?`,
		productID, pilatesID,
	); err != nil {
		t.Fatal(err)
	}

	var labelAfter string
	var creditsTAfter int
	if err := s.db.QueryRowContext(ctx,
		`SELECT label, credits_total FROM entitlements WHERE id = ?`, entID,
	).Scan(&labelAfter, &creditsTAfter); err != nil {
		t.Fatal(err)
	}
	if labelAfter != "Original 10 Pack" || creditsTAfter != 10 {
		t.Errorf("entitlement was mutated by product edit: label=%q credits=%d", labelAfter, creditsTAfter)
	}
	var coverAfter int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM entitlement_class_types WHERE entitlement_id = ?`, entID,
	).Scan(&coverAfter); err != nil {
		t.Fatal(err)
	}
	if coverAfter != 2 {
		t.Errorf("coverage drifted after product edit: got %d want 2", coverAfter)
	}

	// Purchase row links to the entitlement.
	var resulting string
	if err := s.db.QueryRowContext(ctx,
		`SELECT resulting_entitlement_id FROM purchases WHERE id = ?`, purchaseID,
	).Scan(&resulting); err != nil {
		t.Fatal(err)
	}
	if resulting != entID {
		t.Errorf("purchase link: got %s want %s", resulting, entID)
	}
}

// TestCreatePurchase_UnlimitedHasNoCreditColumns checks the pass_kind=unlimited
// branch: credits_total / credits_remaining stay NULL, validity still flows.
func TestCreatePurchase_UnlimitedHasNoCreditColumns(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	productID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO products
		    (id, studio_id, name, price_minor, billing_type, pass_kind,
		     validity_days)
		    VALUES (?, ?, 'Unlimited Monthly', 8800, 'recurring', 'unlimited', 30)`,
		productID, f.studioID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`,
		productID, f.classTypeID,
	); err != nil {
		t.Fatal(err)
	}

	_, entID, err := s.CreatePurchase(ctx, f.studioID, f.studentID, productID, "dev_stub", "")
	if err != nil {
		t.Fatalf("purchase: %v", err)
	}

	var (
		passKind  string
		creditsT  *int
		creditsR  *int
	)
	row := s.db.QueryRowContext(ctx, `
		SELECT pass_kind, credits_total, credits_remaining
		  FROM entitlements WHERE id = ?`, entID)
	if err := row.Scan(&passKind, &creditsT, &creditsR); err != nil {
		t.Fatal(err)
	}
	if passKind != "unlimited" {
		t.Errorf("pass_kind: got %q want unlimited", passKind)
	}
	if creditsT != nil || creditsR != nil {
		t.Errorf("credit columns: got total=%v remaining=%v want both NULL", creditsT, creditsR)
	}
}
