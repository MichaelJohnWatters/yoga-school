package api

import "testing"

// TestPaymentMethodAllowed locks in the prod-safety gate: only `card` settles a
// self-serve purchase in production; dev_stub / cash / comp are dev-only.
func TestPaymentMethodAllowed(t *testing.T) {
	// Prod-shaped: no auth emulator.
	t.Setenv("FIREBASE_AUTH_EMULATOR_HOST", "")
	for _, m := range []string{"dev_stub", "cash", "comp", "card_present", "transfer", ""} {
		if paymentMethodAllowed(m) {
			t.Errorf("prod: payment method %q must be rejected", m)
		}
	}
	if !paymentMethodAllowed("card") {
		t.Error("prod: card must be allowed")
	}

	// Dev: auth emulator active → everything allowed (tests / dev_stub).
	t.Setenv("FIREBASE_AUTH_EMULATOR_HOST", "localhost:9099")
	for _, m := range []string{"dev_stub", "cash", "comp", "card"} {
		if !paymentMethodAllowed(m) {
			t.Errorf("dev: payment method %q should be allowed", m)
		}
	}
}
