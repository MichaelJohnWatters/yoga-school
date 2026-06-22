package store

import (
	"context"
	"database/sql"
	"testing"
)

func TestLinkFirebaseUID_BackfillsWhenEmpty(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Fixture's student row has no firebase_uid (the fixture INSERTs don't
	// set it). Linking should populate it.
	before := readUID(t, s, f.studentID)
	if before.Valid {
		t.Fatalf("precondition: fixture user already has uid %q", before.String)
	}
	if err := s.LinkFirebaseUID(ctx, f.studentID, "fb-uid-rotated-001"); err != nil {
		t.Fatalf("Link: %v", err)
	}
	after := readUID(t, s, f.studentID)
	if !after.Valid || after.String != "fb-uid-rotated-001" {
		t.Errorf("uid after link: got %+v want fb-uid-rotated-001", after)
	}
}

func TestLinkFirebaseUID_NoopWhenSameValue(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	if err := s.LinkFirebaseUID(ctx, f.studentID, "fb-stable"); err != nil {
		t.Fatal(err)
	}
	// Re-linking with the same value is a no-op (no error, no change).
	if err := s.LinkFirebaseUID(ctx, f.studentID, "fb-stable"); err != nil {
		t.Fatal(err)
	}
	after := readUID(t, s, f.studentID)
	if after.String != "fb-stable" {
		t.Errorf("uid drifted: %+v", after)
	}
}

func TestLinkFirebaseUID_OverwritesStaleValue(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	if err := s.LinkFirebaseUID(ctx, f.studentID, "fb-old"); err != nil {
		t.Fatal(err)
	}
	// Firebase emulator UID rotates between local restarts — overwriting is
	// the desired behavior. (Not a security risk: the email claim is what
	// auth gates on; UID is bookkeeping.)
	if err := s.LinkFirebaseUID(ctx, f.studentID, "fb-new"); err != nil {
		t.Fatal(err)
	}
	after := readUID(t, s, f.studentID)
	if after.String != "fb-new" {
		t.Errorf("uid: got %+v want fb-new", after)
	}
}

func TestLinkFirebaseUID_EmptyUIDIsNoop(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	// Empty UID would null out a real value — guard explicitly.
	if err := s.LinkFirebaseUID(ctx, f.studentID, ""); err != nil {
		t.Fatal(err)
	}
	after := readUID(t, s, f.studentID)
	if after.Valid {
		t.Errorf("empty link wrote a value: %+v", after)
	}
}

func readUID(t *testing.T, s *Store, userID string) sql.NullString {
	t.Helper()
	var got sql.NullString
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT firebase_uid FROM users WHERE id = ?`, userID,
	).Scan(&got); err != nil {
		t.Fatalf("read: %v", err)
	}
	return got
}
