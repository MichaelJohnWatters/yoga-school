package secrets

import "testing"

func TestSealer_RoundTrip(t *testing.T) {
	s := NewTestSealer()
	ct, nonce, err := s.Encrypt("sk_test_abcdef")
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	got, err := s.Decrypt(ct, nonce)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if got != "sk_test_abcdef" {
		t.Errorf("plaintext: got %q want sk_test_abcdef", got)
	}
}

func TestSealer_FreshNoncePerCall(t *testing.T) {
	s := NewTestSealer()
	_, n1, _ := s.Encrypt("x")
	_, n2, _ := s.Encrypt("x")
	if string(n1) == string(n2) {
		t.Error("nonce reuse — Encrypt should mint a fresh nonce per call")
	}
}

func TestSealer_TamperFailsAuth(t *testing.T) {
	s := NewTestSealer()
	ct, nonce, _ := s.Encrypt("sk_live_secret")
	// Flip one byte. GCM should reject the ciphertext.
	ct[0] ^= 0x01
	if _, err := s.Decrypt(ct, nonce); err == nil {
		t.Error("tampered ciphertext decrypted successfully")
	}
}

func TestSealer_NilReceiverErrors(t *testing.T) {
	var s *Sealer
	if _, _, err := s.Encrypt("anything"); err != ErrNoMasterKey {
		t.Errorf("encrypt with nil sealer: got %v want ErrNoMasterKey", err)
	}
	if _, err := s.Decrypt([]byte("x"), []byte("y")); err != ErrNoMasterKey {
		t.Errorf("decrypt with nil sealer: got %v want ErrNoMasterKey", err)
	}
	if s.Available() {
		t.Error("nil sealer reports Available")
	}
}

func TestSealerFromEnv_RejectsBadLength(t *testing.T) {
	t.Setenv("STRIPE_KEY_ENC_MASTER", "abcd") // 2 bytes, not 32
	if _, err := SealerFromEnv(); err == nil {
		t.Error("expected error for short master key")
	}
}

func TestSealerFromEnv_AllowsUnset(t *testing.T) {
	t.Setenv("STRIPE_KEY_ENC_MASTER", "")
	s, err := SealerFromEnv()
	if err != nil {
		t.Errorf("unset env should not error, got %v", err)
	}
	if s != nil {
		t.Errorf("unset env should yield nil sealer, got %+v", s)
	}
}
