package store

import (
	"context"
	"testing"
)

func TestUpdateDiscount(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	code := "SPRING"
	created, err := s.CreateDiscount(ctx, f.studioID, f.instructorID, DiscountCreate{
		Code: &code, Kind: DiscountKindPercent, Value: 10,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}

	// Edit the value + notes.
	newCode := "SPRING25"
	updated, err := s.UpdateDiscount(ctx, f.studioID, f.instructorID, created.ID, DiscountCreate{
		Code: &newCode, Kind: DiscountKindPercent, Value: 25, Notes: "bumped",
	})
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if updated.Value != 25 || updated.Code == nil || *updated.Code != "SPRING25" || updated.Notes != "bumped" {
		t.Errorf("update didn't apply: %+v", updated)
	}
	if n := auditCount(t, s, f.studioID, "discount_update"); n != 1 {
		t.Errorf("discount_update audit = %d, want 1", n)
	}

	// Archived discounts can't be edited.
	if err := s.ArchiveDiscount(ctx, f.studioID, f.instructorID, created.ID); err != nil {
		t.Fatalf("archive: %v", err)
	}
	if _, err := s.UpdateDiscount(ctx, f.studioID, f.instructorID, created.ID, DiscountCreate{
		Kind: DiscountKindPercent, Value: 5,
	}); err != ErrNotFound {
		t.Errorf("update archived = %v, want ErrNotFound", err)
	}
}
