package store

import (
	"context"
	"errors"
	"testing"
)

// TestGetEntitlement_ScopedToOwner guards the defensive scoping on
// GetEntitlement: the snapshot only loads for the owning (studio, user). A
// foreign studio or user resolves zero rows, so a future caller that forwards
// a client-supplied id can't turn it into a cross-tenant / cross-user read.
func TestGetEntitlement_ScopedToOwner(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	entID := f.insertEntitlement(t, s, "credit", 5) // owned by f.studentID in f.studioID

	// Correct owner → found.
	if _, err := s.GetEntitlement(ctx, f.studioID, f.studentID, entID); err != nil {
		t.Fatalf("owner read: %v", err)
	}

	// Wrong studio → not found.
	if _, err := s.GetEntitlement(ctx, "other-studio", f.studentID, entID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-studio read: want ErrNotFound, got %v", err)
	}

	// Wrong user → not found.
	if _, err := s.GetEntitlement(ctx, f.studioID, "other-user", entID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user read: want ErrNotFound, got %v", err)
	}
}
