package store

import (
	"context"
	"strings"
	"testing"
)

func TestRegisterDevice_StoresToken(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	if err := s.RegisterDevice(ctx, f.studentID, RegisterDeviceInput{
		FCMToken: "fcm-token-abc",
		Platform: "ios",
	}); err != nil {
		t.Fatalf("register: %v", err)
	}

	var userID, platform string
	if err := s.db.QueryRowContext(ctx,
		`SELECT user_id, COALESCE(platform,'') FROM device_tokens WHERE fcm_token = ?`,
		"fcm-token-abc",
	).Scan(&userID, &platform); err != nil {
		t.Fatal(err)
	}
	if userID != f.studentID {
		t.Errorf("user_id: got %s want %s", userID, f.studentID)
	}
	if platform != "ios" {
		t.Errorf("platform: got %q want ios", platform)
	}
}

func TestRegisterDevice_RejectsEmptyToken(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	err := s.RegisterDevice(ctx, f.studentID, RegisterDeviceInput{})
	if err == nil {
		t.Error("expected error for empty token")
	}
}

func TestRegisterDevice_RejectsUnknownPlatform(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	err := s.RegisterDevice(ctx, f.studentID, RegisterDeviceInput{
		FCMToken: "ok",
		Platform: "blackberry",
	})
	if err == nil || !strings.Contains(err.Error(), "platform") {
		t.Errorf("expected platform error, got %v", err)
	}
}

// TestRegisterDevice_TransfersOwnershipOnReRegister covers the account-switch
// scenario: same physical device, new user — the token row's user_id moves
// over to the new account so push doesn't keep reaching the old one.
func TestRegisterDevice_TransfersOwnershipOnReRegister(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	other := insertOtherStudent(t, s, f.studioID)

	if err := s.RegisterDevice(ctx, f.studentID, RegisterDeviceInput{
		FCMToken: "shared-handset", Platform: "android",
	}); err != nil {
		t.Fatal(err)
	}
	// Same token, new user.
	if err := s.RegisterDevice(ctx, other, RegisterDeviceInput{
		FCMToken: "shared-handset", Platform: "android",
	}); err != nil {
		t.Fatal(err)
	}

	var owner string
	if err := s.db.QueryRowContext(ctx,
		`SELECT user_id FROM device_tokens WHERE fcm_token = ?`,
		"shared-handset",
	).Scan(&owner); err != nil {
		t.Fatal(err)
	}
	if owner != other {
		t.Errorf("ownership: got %s want %s (re-register should transfer)", owner, other)
	}
	// Exactly one row — the upsert shouldn't proliferate.
	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM device_tokens WHERE fcm_token = ?`,
		"shared-handset",
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("row count: got %d want 1", n)
	}
}
