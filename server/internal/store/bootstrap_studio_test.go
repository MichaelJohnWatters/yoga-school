package store

import (
	"context"
	"testing"
)

// TestProvisionStudio_CreatesCleanSingleStudio verifies the production
// onboarding path: one studio + a starter active theme + an owner, no demo
// data, and the single-studio invariant preserved so student auto-provisioning
// still resolves.
func TestProvisionStudio_CreatesCleanSingleStudio(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	sid, oid, err := s.ProvisionStudio(ctx, StudioBootstrapInput{
		Name:       "Bloom Yoga",
		OwnerEmail: "owner@bloom.test",
	})
	if err != nil {
		t.Fatalf("ProvisionStudio: %v", err)
	}

	// Exactly one studio, with an active theme set.
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM studios`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("studio count = %d, want 1", count)
	}
	var name, activeTheme string
	if err := s.db.QueryRowContext(ctx,
		`SELECT name, COALESCE(active_theme_id,'') FROM studios WHERE id = ?`, sid).
		Scan(&name, &activeTheme); err != nil {
		t.Fatal(err)
	}
	if name != "Bloom Yoga" {
		t.Fatalf("name = %q, want Bloom Yoga", name)
	}
	if activeTheme == "" {
		t.Fatal("active_theme_id not set — app would have no theme to render")
	}

	// Owner resolves by email (the link the auth middleware relies on) and is role owner.
	u, err := s.UserByEmail(ctx, "owner@bloom.test")
	if err != nil {
		t.Fatalf("UserByEmail(owner): %v", err)
	}
	if u.ID != oid {
		t.Fatalf("owner id = %q, want %q", u.ID, oid)
	}
	if u.Role != "owner" {
		t.Fatalf("owner role = %q, want owner", u.Role)
	}
	if u.StudioID != sid {
		t.Fatalf("owner studio = %q, want %q", u.StudioID, sid)
	}

	// Single-studio invariant: a student with a new email auto-provisions (would
	// return ErrMultipleStudios if a second studio had been created).
	if _, err := s.ProvisionStudentFromFirebase(ctx, "fb-stu", "student@bloom.test", "", ""); err != nil {
		t.Fatalf("student auto-provision after bootstrap: %v", err)
	}

	// Defaults applied.
	var tz, currency string
	if err := s.db.QueryRowContext(ctx,
		`SELECT timezone, currency FROM studios WHERE id = ?`, sid).Scan(&tz, &currency); err != nil {
		t.Fatal(err)
	}
	if tz != "Europe/London" || currency != "GBP" {
		t.Fatalf("defaults: tz=%q currency=%q, want Europe/London / GBP", tz, currency)
	}
}

// TestProvisionStudio_RefusesSecondStudio guards the single-studio invariant:
// provisioning must refuse when a studio already exists.
func TestProvisionStudio_RefusesSecondStudio(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	if _, _, err := s.ProvisionStudio(ctx, StudioBootstrapInput{Name: "A", OwnerEmail: "a@a.test"}); err != nil {
		t.Fatalf("first provision: %v", err)
	}
	if _, _, err := s.ProvisionStudio(ctx, StudioBootstrapInput{Name: "B", OwnerEmail: "b@b.test"}); err == nil {
		t.Fatal("second provision succeeded; want refusal (a deploy hosts one studio)")
	}
}

// TestProvisionStudio_Validates checks the required fields.
func TestProvisionStudio_Validates(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)

	if _, _, err := s.ProvisionStudio(ctx, StudioBootstrapInput{OwnerEmail: "a@a.test"}); err == nil {
		t.Fatal("missing name accepted; want error")
	}
	if _, _, err := s.ProvisionStudio(ctx, StudioBootstrapInput{Name: "A"}); err == nil {
		t.Fatal("missing owner email accepted; want error")
	}
}
