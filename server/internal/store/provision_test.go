package store

import (
	"context"
	"testing"
)

func TestProvisionStudentFromFirebase_CreatesStudentInLoneStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	u, err := s.ProvisionStudentFromFirebase(ctx, "fb-uid-new", "newby@studio52.dev", "New Byrne", "https://x/y.png")
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	if u.StudioID != f.studioID {
		t.Errorf("studio: got %s want %s", u.StudioID, f.studioID)
	}
	if u.Role != "student" {
		t.Errorf("role: got %s want student", u.Role)
	}
	if u.FullName != "New Byrne" {
		t.Errorf("full_name: got %q want New Byrne", u.FullName)
	}
	if u.PhotoURL == nil || *u.PhotoURL != "https://x/y.png" {
		t.Errorf("photo: got %v want https://x/y.png", u.PhotoURL)
	}

	// firebase_uid persisted so lookup-by-UID works too.
	got, err := s.UserByFirebaseUID(ctx, "fb-uid-new")
	if err != nil {
		t.Fatalf("UserByFirebaseUID: %v", err)
	}
	if got.ID != u.ID {
		t.Errorf("uid lookup: got %s want %s", got.ID, u.ID)
	}
}

func TestProvisionStudentFromFirebase_DerivesNameFromEmailWhenMissing(t *testing.T) {
	s := newTestStore(t)
	newFixture(t, s)
	ctx := context.Background()

	u, err := s.ProvisionStudentFromFirebase(ctx, "fb-2", "jane.doe@example.com", "", "")
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	if u.FullName != "jane.doe" {
		t.Errorf("full_name fallback: got %q want jane.doe", u.FullName)
	}
	if u.PhotoURL != nil {
		t.Errorf("photo should be nil when empty: got %v", u.PhotoURL)
	}
}

func TestProvisionStudentFromFirebase_RefusesMultiTenant(t *testing.T) {
	s := newTestStore(t)
	newFixture(t, s)
	ctx := context.Background()
	// Add a second studio so the auto-resolver should refuse.
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO studios (id, name, welcome_message) VALUES (?, 'Other', 'Hi')`,
		NewID(),
	); err != nil {
		t.Fatal(err)
	}
	_, err := s.ProvisionStudentFromFirebase(ctx, "fb-x", "ambiguous@example.com", "", "")
	if err != ErrMultipleStudios {
		t.Errorf("got %v want ErrMultipleStudios", err)
	}
}

func TestProvisionStudentFromFirebase_DuplicateEmailFails(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	// Fixture already inserted student@test.com — second provision with the
	// same email must hit the (studio_id, email) UNIQUE constraint.
	_, err := s.ProvisionStudentFromFirebase(ctx, "fb-dup", "student@test.com", "Dup", "")
	if err == nil {
		t.Error("expected duplicate-email failure, got nil")
	}
	_ = f
}
