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

// NewApp initialises the shared Firebase application. Both Auth (token
// verification) and Messaging (push fan-out) hang off the same app.
//
// Reads FIREBASE_PROJECT_ID from the env (default 'yoga-school-dev'). When
// FIREBASE_AUTH_EMULATOR_HOST is set, the SDK skips real credential
// resolution and points at the emulator — no service account needed.
func NewApp(ctx context.Context) (*firebase.App, error) {
	projectID := os.Getenv("FIREBASE_PROJECT_ID")
	if projectID == "" {
		projectID = "yoga-school-dev"
	}
	cfg := &firebase.Config{ProjectID: projectID}
	app, err := firebase.NewApp(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("firebase init: %w", err)
	}
	return app, nil
}

// NewClient initializes a Firebase Auth client (back-compat wrapper around
// NewApp + app.Auth).
func NewClient(ctx context.Context) (*auth.Client, error) {
	app, err := NewApp(ctx)
	if err != nil {
		return nil, err
	}
	return app.Auth(ctx)
}

// Verified is the subset of claims we care about per request.
type Verified struct {
	UID      string
	Email    string
	FullName string // best-effort: from token "name" claim, may be empty
	PhotoURL string // best-effort: from token "picture" claim, may be empty
}

var ErrInvalidToken = errors.New("invalid id token")

// Verify checks an ID token and returns the relevant claims. The SDK already
// does signature, expiry, audience, and issuer checks against the project ID
// we configured. Display-name and photo come from the optional "name" and
// "picture" claims (set by federated providers + by clients that called
// updateProfile). Both may be empty for an email/password account.
func Verify(ctx context.Context, c *auth.Client, idToken string) (*Verified, error) {
	tok, err := c.VerifyIDToken(ctx, idToken)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}
	email, _ := tok.Claims["email"].(string)
	name, _ := tok.Claims["name"].(string)
	picture, _ := tok.Claims["picture"].(string)
	return &Verified{
		UID:      tok.UID,
		Email:    email,
		FullName: name,
		PhotoURL: picture,
	}, nil
}
