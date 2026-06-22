package store

import (
	"context"
	"testing"
	"time"
)

func TestRunBuilder_RejectsUnknownDatasetColumnOperator(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	cases := []struct {
		name string
		spec BuilderSpec
	}{
		{"unknown dataset", BuilderSpec{Dataset: "secrets"}},
		{"unknown column", BuilderSpec{Dataset: "customers", Columns: []string{"firebase_uid"}}},
		{"unknown sort", BuilderSpec{Dataset: "customers", Sort: "password"}},
		{"unknown filter", BuilderSpec{Dataset: "customers",
			Filters: []BuilderFilterCond{{Field: "ssn", Operator: "eq", Value: "x"}}}},
		{"operator not allowed", BuilderSpec{Dataset: "customers",
			Filters: []BuilderFilterCond{{Field: "joined", Operator: "contains", Value: "x"}}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := s.RunBuilder(ctx, f.studioID, tc.spec)
			if _, ok := err.(*BuilderError); !ok {
				t.Fatalf("want *BuilderError, got %v", err)
			}
		})
	}
}

func TestRunBuilder_ForcesStudioScope(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s) // fixture seeds one student in studioID
	ctx := context.Background()

	// Second studio with its own student.
	other := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO studios (id, name, welcome_message) VALUES (?, 'Other', 'Hi')`, other); err != nil {
		t.Fatalf("other studio: %v", err)
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO users (id, studio_id, role, email, full_name)
		 VALUES (?, ?, 'student', 'leak@o.com', 'Leaky McLeak')`,
		NewID(), other); err != nil {
		t.Fatalf("other student: %v", err)
	}

	res, err := s.RunBuilder(ctx, f.studioID, BuilderSpec{
		Dataset: "customers",
		Columns: []string{"name", "email"},
	})
	if err != nil {
		t.Fatalf("RunBuilder: %v", err)
	}
	for _, row := range res.Rows {
		for _, cell := range row {
			if cell == "Leaky McLeak" || cell == "leak@o.com" {
				t.Fatalf("cross-studio row leaked: %v", row)
			}
		}
	}
	// Sanity: our own student is present.
	found := false
	for _, row := range res.Rows {
		if row[0] == "Student" {
			found = true
		}
	}
	if !found {
		t.Fatalf("own student missing from builder result: %v", res.Rows)
	}
}

func TestRunBuilder_FiltersAndMoneyFormatting(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	loc := s.StudioLocation(ctx, f.studioID)

	f.insertPurchaseAt(t, s, time.Date(2026, 6, 2, 12, 0, 0, 0, loc), "card", 2500)
	f.insertPurchaseAt(t, s, time.Date(2026, 6, 3, 12, 0, 0, 0, loc), "cash", 1000)

	res, err := s.RunBuilder(ctx, f.studioID, BuilderSpec{
		Dataset: "purchases",
		Columns: []string{"amount", "method"},
		Filters: []BuilderFilterCond{
			{Field: "method", Operator: "eq", Value: "card"},
		},
		Sort:    "amount",
		SortDir: "desc",
	})
	if err != nil {
		t.Fatalf("RunBuilder: %v", err)
	}
	if len(res.Rows) != 1 {
		t.Fatalf("rows = %d, want 1 (cash filtered out)", len(res.Rows))
	}
	if res.Rows[0][0] != "25.00" {
		t.Errorf("money cell = %q, want 25.00", res.Rows[0][0])
	}
	if res.Rows[0][1] != "card" {
		t.Errorf("method cell = %q, want card", res.Rows[0][1])
	}
}

func TestRunBuilder_LimitClamped(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	res, err := s.RunBuilder(ctx, f.studioID, BuilderSpec{
		Dataset: "customers",
		Limit:   999999, // must be clamped, not error
	})
	if err != nil {
		t.Fatalf("RunBuilder: %v", err)
	}
	if res == nil {
		t.Fatal("nil result")
	}
}
