// Package auth wires Firebase Auth ID-token verification.
//
// In dev, FIREBASE_AUTH_EMULATOR_HOST is set to localhost:9099. The Admin
// SDK automatically routes signature lookups + token verification through
// the emulator when that env var is present, so initialization is the same
// shape for both modes.

package auth

import (
	"context"
	"errors"
	"fmt"
	"os"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/auth"
)

// NewClient initializes a Firebase Auth client.
//
// Reads FIREBASE_PROJECT_ID from the env (default 'yoga-school-dev'). When
// FIREBASE_AUTH_EMULATOR_HOST is set, the SDK skips real credential
// resolution and points at the emulator — no service account needed.
func NewClient(ctx context.Context) (*auth.Client, error) {
	projectID := os.Getenv("FIREBASE_PROJECT_ID")
	if projectID == "" {
		projectID = "yoga-school-dev"
	}
	cfg := &firebase.Config{ProjectID: projectID}
	app, err := firebase.NewApp(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("firebase init: %w", err)
	}
	return app.Auth(ctx)
}

// Verified is the subset of claims we care about per request.
type Verified struct {
	UID   string
	Email string
}

var ErrInvalidToken = errors.New("invalid id token")

// Verify checks an ID token and returns the relevant claims. The SDK already
// does signature, expiry, audience, and issuer checks against the project ID
// we configured.
func Verify(ctx context.Context, c *auth.Client, idToken string) (*Verified, error) {
	tok, err := c.VerifyIDToken(ctx, idToken)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}
	email, _ := tok.Claims["email"].(string)
	return &Verified{UID: tok.UID, Email: email}, nil
}
