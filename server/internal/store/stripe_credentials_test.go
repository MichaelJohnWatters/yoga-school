package store

import (
	"context"
	"strings"
	"testing"

	"github.com/studio52/yoga-school/server/internal/secrets"
)

func TestStripeCredentials_EmptyRowSurfacesEncryptionStatus(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	s.SetSealer(secrets.NewTestSealer())
	view, err := s.StripeCredentialsFor(ctx, f.studioID)
	if err != nil {
		t.Fatal(err)
	}
	if view.SecretKeySet || view.WebhookSecretSet {
		t.Errorf("fresh row shouldn't report set: %+v", view)
	}
	if !view.EncryptionConfigured {
		t.Error("EncryptionConfigured should be true when sealer is set")
	}
}

func TestStripeCredentials_UpdateAndMask(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	s.SetSealer(secrets.NewTestSealer())

	pk := "pk_test_12345"
	sk := "sk_test_ABCDEFGHIJKL"
	wh := "whsec_XYZ123456"
	view, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		PublishableKey: &pk,
		SecretKey:      &sk,
		WebhookSecret:  &wh,
	})
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	// Plaintext secrets never leak back through the view.
	if !view.SecretKeySet || view.SecretKeyLast4 == nil || *view.SecretKeyLast4 != "IJKL" {
		t.Errorf("secret_key_last4: got %+v want IJKL", view.SecretKeyLast4)
	}
	if !view.WebhookSecretSet || view.WebhookSecretLast4 == nil || *view.WebhookSecretLast4 != "3456" {
		t.Errorf("webhook_secret_last4: got %+v want 3456", view.WebhookSecretLast4)
	}
	if view.PublishableKey == nil || *view.PublishableKey != pk {
		t.Errorf("publishable: got %v want %s", view.PublishableKey, pk)
	}

	// LoadStripeKeysForUse round-trips the plaintext.
	keys, err := s.LoadStripeKeysForUse(ctx, f.studioID)
	if err != nil {
		t.Fatalf("load for use: %v", err)
	}
	if keys.SecretKey != sk || keys.WebhookSecret != wh {
		t.Errorf("decrypted mismatch: secret=%q webhook=%q", keys.SecretKey, keys.WebhookSecret)
	}
}

func TestStripeCredentials_PartialPatchPreservesOthers(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	s.SetSealer(secrets.NewTestSealer())

	pk1 := "pk_test_first"
	sk1 := "sk_test_first_abcd"
	if _, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		PublishableKey: &pk1, SecretKey: &sk1,
	}); err != nil {
		t.Fatal(err)
	}
	// Rotate just the publishable; secret must stay intact.
	pk2 := "pk_test_second"
	view, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		PublishableKey: &pk2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if view.PublishableKey == nil || *view.PublishableKey != pk2 {
		t.Errorf("pub key: got %v want %s", view.PublishableKey, pk2)
	}
	if !view.SecretKeySet || view.SecretKeyLast4 == nil || *view.SecretKeyLast4 != "abcd" {
		t.Errorf("secret should still be set with last4 abcd: %+v", view)
	}
	keys, _ := s.LoadStripeKeysForUse(ctx, f.studioID)
	if keys.SecretKey != sk1 {
		t.Errorf("secret round-trip after partial patch: got %q want %q", keys.SecretKey, sk1)
	}
}

func TestStripeCredentials_EmptyStringClearsSecret(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	s.SetSealer(secrets.NewTestSealer())

	sk := "sk_test_xyz789"
	if _, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		SecretKey: &sk,
	}); err != nil {
		t.Fatal(err)
	}
	empty := ""
	view, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		SecretKey: &empty,
	})
	if err != nil {
		t.Fatal(err)
	}
	if view.SecretKeySet || view.SecretKeyLast4 != nil {
		t.Errorf("empty string should clear: %+v", view)
	}
}

func TestStripeCredentials_RefusesSecretWriteWithoutSealer(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	// No sealer attached → secret writes refused.
	sk := "sk_test_doomed"
	_, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		SecretKey: &sk,
	})
	if err == nil || !strings.Contains(err.Error(), "encryption") {
		t.Errorf("expected encryption-not-configured error, got %v", err)
	}
}

func TestStripeCredentials_AllowsPublishableWithoutSealer(t *testing.T) {
	// Publishable key is meant for client embedding — no encryption needed.
	// A studio with no master key set should still be able to save it.
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	pk := "pk_test_safe"
	view, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		PublishableKey: &pk,
	})
	if err != nil {
		t.Fatalf("publishable-only patch failed: %v", err)
	}
	if view.PublishableKey == nil || *view.PublishableKey != pk {
		t.Errorf("publishable not saved: %+v", view)
	}
}

func TestStripeCredentials_AuditRowNeverContainsSecret(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	s.SetSealer(secrets.NewTestSealer())

	sk := "sk_test_NEVER_LEAK_ME_ABCDEFG"
	if _, err := s.UpdateStripeCredentials(ctx, f.studioID, f.instructorID, StripeCredentialsPatch{
		SecretKey: &sk,
	}); err != nil {
		t.Fatal(err)
	}
	// Scan every audit_log row for the literal key. Catches a future
	// "let's log the secret for debugging" regression.
	rows, err := s.db.QueryContext(ctx,
		`SELECT detail FROM audit_log WHERE action = 'stripe_credentials_update'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(d, "NEVER_LEAK") {
			t.Errorf("audit row leaked secret: %s", d)
		}
	}
}

func TestStripeCredentials_LoadForUseFailsWithoutSealer(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	_, err := s.LoadStripeKeysForUse(ctx, f.studioID)
	if err != secrets.ErrNoMasterKey {
		t.Errorf("got %v want ErrNoMasterKey", err)
	}
}
