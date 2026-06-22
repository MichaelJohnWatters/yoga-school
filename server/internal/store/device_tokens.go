package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// RegisterDeviceInput is the body for POST /me/devices.
type RegisterDeviceInput struct {
	FCMToken string `json:"fcm_token"`
	Platform string `json:"platform"` // ios | android | web — free-text, validated loosely
}

// RegisterDevice upserts an FCM token onto the caller's user. Because the
// fcm_token column is UNIQUE across users, a re-registration of the same
// token from a different account (account switch on the same device) takes
// ownership of the row — the previous user simply stops receiving pushes to
// that handset.
func (s *Store) RegisterDevice(ctx context.Context, userID string, in RegisterDeviceInput) error {
	tok := strings.TrimSpace(in.FCMToken)
	if tok == "" {
		return errors.New("fcm_token is required")
	}
	platform := strings.ToLower(strings.TrimSpace(in.Platform))
	if platform != "" && platform != "ios" && platform != "android" && platform != "web" {
		return fmt.Errorf("platform must be ios|android|web (got %q)", platform)
	}
	var platformArg any
	if platform != "" {
		platformArg = platform
	}
	// UPSERT on the unique (fcm_token) — transfer to caller on conflict.
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO device_tokens (id, user_id, fcm_token, platform)
		     VALUES (?, ?, ?, ?)
		ON CONFLICT(fcm_token) DO UPDATE SET
		     user_id  = excluded.user_id,
		     platform = COALESCE(excluded.platform, device_tokens.platform)`,
		NewID(), userID, tok, platformArg,
	)
	return err
}
