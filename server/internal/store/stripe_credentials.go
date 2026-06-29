package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"

	"github.com/studio52/yoga-school/server/internal/secrets"
)

// SetSealer wires the Sealer at server startup. Optional — when nil, the
// PATCH handler refuses requests that would set a secret. GET still works
// (it reads metadata, not plaintext) so the manager UI can render an
// "encryption not configured" empty state.
func (s *Store) SetSealer(sealer *secrets.Sealer) { s.sealer = sealer }

// HasEncryptedStripeKeys counts the rows with non-empty secret_key_cipher.
// The server boot uses it to detect the "ops disabled the master key but
// the DB still has encrypted secrets" pairing and refuse to start.
func (s *Store) HasEncryptedStripeKeys(ctx context.Context) (int, error) {
	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM studio_stripe_credentials WHERE secret_key_cipher IS NOT NULL`,
	).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

// StripeCredentialsView is the safe-to-return shape for GET
// /admin/studio/stripe-credentials. Secrets never leave the server: the
// last-4 lets the UI show "•••• abcd"; the *_set bools drive
// "set / clear / replace" UI affordances.
type StripeCredentialsView struct {
	Mode               string  `json:"mode"`
	AccountID          *string `json:"account_id,omitempty"`
	PublishableKey     *string `json:"publishable_key,omitempty"`
	SecretKeyLast4     *string `json:"secret_key_last4,omitempty"`
	SecretKeySet       bool    `json:"secret_key_set"`
	WebhookSecretLast4 *string `json:"webhook_secret_last4,omitempty"`
	WebhookSecretSet   bool    `json:"webhook_secret_set"`
	// Wallet (Apple Pay / Google Pay) presentation config — not secrets.
	// These drive what the client PaymentSheet renders; actual availability
	// also depends on the studio's Stripe Dashboard (dynamic methods).
	ApplePayEnabled     bool    `json:"apple_pay_enabled"`
	GooglePayEnabled    bool    `json:"google_pay_enabled"`
	MerchantDisplayName *string `json:"merchant_display_name,omitempty"`
	MerchantCountryCode *string `json:"merchant_country_code,omitempty"`
	UpdatedBy           *string `json:"updated_by,omitempty"`
	UpdatedAt           string  `json:"updated_at,omitempty"`
	// EncryptionConfigured tells the UI whether the server has a master
	// key. When false, the panel should disable secret-setting fields and
	// surface an "ask ops to set STRIPE_KEY_ENC_MASTER" hint.
	EncryptionConfigured bool `json:"encryption_configured"`
}

// StripeCredentialsFor reads (and masks) the studio's row. Returns a zero
// value with EncryptionConfigured set when no row exists yet — the GET
// endpoint should still 200 so the UI can render the empty form.
func (s *Store) StripeCredentialsFor(ctx context.Context, studioID string) (*StripeCredentialsView, error) {
	out := &StripeCredentialsView{
		Mode:                 "test",
		EncryptionConfigured: s.sealer.Available(),
	}
	var (
		mode                                                    string
		accountID, pubKey, secretLast4, webhookLast4, updatedBy sql.NullString
		updatedAt                                               sql.NullString
		merchantName, merchantCountry                           sql.NullString
		applePay, googlePay                                     int
		secretCipher, webhookCipher                             []byte
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT mode, account_id, publishable_key,
		       secret_key_cipher, secret_key_last4,
		       webhook_secret_cipher, webhook_secret_last4,
		       apple_pay_enabled, google_pay_enabled,
		       merchant_display_name, merchant_country_code,
		       updated_by, updated_at
		  FROM studio_stripe_credentials
		 WHERE studio_id = ?`,
		studioID,
	).Scan(&mode, &accountID, &pubKey,
		&secretCipher, &secretLast4,
		&webhookCipher, &webhookLast4,
		&applePay, &googlePay,
		&merchantName, &merchantCountry,
		&updatedBy, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return out, nil // empty form
	}
	if err != nil {
		return nil, err
	}
	out.Mode = mode
	out.ApplePayEnabled = applePay != 0
	out.GooglePayEnabled = googlePay != 0
	if merchantName.Valid {
		v := merchantName.String
		out.MerchantDisplayName = &v
	}
	if merchantCountry.Valid {
		v := merchantCountry.String
		out.MerchantCountryCode = &v
	}
	if accountID.Valid {
		v := accountID.String
		out.AccountID = &v
	}
	if pubKey.Valid {
		v := pubKey.String
		out.PublishableKey = &v
	}
	out.SecretKeySet = len(secretCipher) > 0
	if secretLast4.Valid {
		v := secretLast4.String
		out.SecretKeyLast4 = &v
	}
	out.WebhookSecretSet = len(webhookCipher) > 0
	if webhookLast4.Valid {
		v := webhookLast4.String
		out.WebhookSecretLast4 = &v
	}
	if updatedBy.Valid {
		v := updatedBy.String
		out.UpdatedBy = &v
	}
	if updatedAt.Valid {
		out.UpdatedAt = updatedAt.String
	}
	return out, nil
}

// StripeCredentialsPatch is the partial-update body for PATCH
// /admin/studio/stripe-credentials. Fields are pointers so a request that
// doesn't touch a column leaves it alone. Pass an empty string to clear a
// previously-set secret (the *_set bool flips back to false).
type StripeCredentialsPatch struct {
	Mode           *string `json:"mode,omitempty"`           // "test" | "live"
	AccountID      *string `json:"account_id,omitempty"`
	PublishableKey *string `json:"publishable_key,omitempty"`
	SecretKey      *string `json:"secret_key,omitempty"`     // plaintext sk_…
	WebhookSecret  *string `json:"webhook_secret,omitempty"` // plaintext whsec_…
	// Wallet config (not secrets). nil → unchanged.
	ApplePayEnabled     *bool   `json:"apple_pay_enabled,omitempty"`
	GooglePayEnabled    *bool   `json:"google_pay_enabled,omitempty"`
	MerchantDisplayName *string `json:"merchant_display_name,omitempty"` // "" clears
	MerchantCountryCode *string `json:"merchant_country_code,omitempty"` // "" clears
}

// UpdateStripeCredentials upserts the row. Secrets pass through the
// configured Sealer; if the master key isn't set and the caller tries to
// touch one, we refuse — saving a key only the DB can read defeats the
// whole point.
func (s *Store) UpdateStripeCredentials(ctx context.Context, studioID, actorID string, in StripeCredentialsPatch) (*StripeCredentialsView, error) {
	// Validate mode early so a typo doesn't leave a half-applied row.
	if in.Mode != nil && *in.Mode != "test" && *in.Mode != "live" {
		return nil, fmt.Errorf("mode must be test|live")
	}
	// Refuse secret writes when there's no Sealer. GET still works.
	if (in.SecretKey != nil && *in.SecretKey != "") ||
		(in.WebhookSecret != nil && *in.WebhookSecret != "") {
		if !s.sealer.Available() {
			return nil, fmt.Errorf("encryption not configured: set STRIPE_KEY_ENC_MASTER")
		}
	}

	// Pull the current row so we preserve untouched columns through the
	// upsert. Saves a "COALESCE on every field" SQL noise pile.
	cur, err := s.StripeCredentialsFor(ctx, studioID)
	if err != nil {
		return nil, err
	}

	// Apply patch onto a working set.
	mode := cur.Mode
	if in.Mode != nil {
		mode = *in.Mode
	}
	var accountID, pubKey any
	if cur.AccountID != nil {
		accountID = *cur.AccountID
	}
	if in.AccountID != nil {
		if *in.AccountID == "" {
			accountID = nil
		} else {
			accountID = *in.AccountID
		}
	}
	if cur.PublishableKey != nil {
		pubKey = *cur.PublishableKey
	}
	if in.PublishableKey != nil {
		if *in.PublishableKey == "" {
			pubKey = nil
		} else {
			pubKey = *in.PublishableKey
		}
	}

	// Wallet config (not secrets). Bools: nil → unchanged. Strings: nil →
	// unchanged, "" → clear.
	applePay := boolToInt(cur.ApplePayEnabled)
	if in.ApplePayEnabled != nil {
		applePay = boolToInt(*in.ApplePayEnabled)
	}
	googlePay := boolToInt(cur.GooglePayEnabled)
	if in.GooglePayEnabled != nil {
		googlePay = boolToInt(*in.GooglePayEnabled)
	}
	var merchantName, merchantCountry any
	if cur.MerchantDisplayName != nil {
		merchantName = *cur.MerchantDisplayName
	}
	if in.MerchantDisplayName != nil {
		if *in.MerchantDisplayName == "" {
			merchantName = nil
		} else {
			merchantName = *in.MerchantDisplayName
		}
	}
	if cur.MerchantCountryCode != nil {
		merchantCountry = *cur.MerchantCountryCode
	}
	if in.MerchantCountryCode != nil {
		if *in.MerchantCountryCode == "" {
			merchantCountry = nil
		} else {
			merchantCountry = *in.MerchantCountryCode
		}
	}

	// Secrets: nil → unchanged, "" → clear, non-empty → re-encrypt.
	var (
		secretCipher, secretNonce []byte
		secretLast4               any
		secretChanged             bool
	)
	if in.SecretKey != nil {
		secretChanged = true
		if *in.SecretKey != "" {
			ct, n, err := s.sealer.Encrypt(*in.SecretKey)
			if err != nil {
				return nil, fmt.Errorf("encrypt secret: %w", err)
			}
			secretCipher, secretNonce = ct, n
			secretLast4 = last4(*in.SecretKey)
		} // else: clearing — cipher/nonce/last4 all stay nil
	}

	var (
		webhookCipher, webhookNonce []byte
		webhookLast4                any
		webhookChanged              bool
	)
	if in.WebhookSecret != nil {
		webhookChanged = true
		if *in.WebhookSecret != "" {
			ct, n, err := s.sealer.Encrypt(*in.WebhookSecret)
			if err != nil {
				return nil, fmt.Errorf("encrypt webhook secret: %w", err)
			}
			webhookCipher, webhookNonce = ct, n
			webhookLast4 = last4(*in.WebhookSecret)
		}
	}

	// Build the UPSERT. Touched fields override; untouched fields fall
	// back to the current row via excluded-vs-existing in DO UPDATE.
	// Conflict target is studio_id (PK).
	q := `
		INSERT INTO studio_stripe_credentials
		    (studio_id, mode, account_id, publishable_key,
		     apple_pay_enabled, google_pay_enabled,
		     merchant_display_name, merchant_country_code,
		     secret_key_cipher, secret_key_nonce, secret_key_last4,
		     webhook_secret_cipher, webhook_secret_nonce, webhook_secret_last4,
		     updated_by, updated_at)
		    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
		            strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		ON CONFLICT(studio_id) DO UPDATE SET
		    mode = excluded.mode,
		    account_id = excluded.account_id,
		    publishable_key = excluded.publishable_key,
		    apple_pay_enabled = excluded.apple_pay_enabled,
		    google_pay_enabled = excluded.google_pay_enabled,
		    merchant_display_name = excluded.merchant_display_name,
		    merchant_country_code = excluded.merchant_country_code,
		    secret_key_cipher = CASE WHEN ? THEN excluded.secret_key_cipher
		                             ELSE studio_stripe_credentials.secret_key_cipher END,
		    secret_key_nonce = CASE WHEN ? THEN excluded.secret_key_nonce
		                            ELSE studio_stripe_credentials.secret_key_nonce END,
		    secret_key_last4 = CASE WHEN ? THEN excluded.secret_key_last4
		                            ELSE studio_stripe_credentials.secret_key_last4 END,
		    webhook_secret_cipher = CASE WHEN ? THEN excluded.webhook_secret_cipher
		                                 ELSE studio_stripe_credentials.webhook_secret_cipher END,
		    webhook_secret_nonce = CASE WHEN ? THEN excluded.webhook_secret_nonce
		                                ELSE studio_stripe_credentials.webhook_secret_nonce END,
		    webhook_secret_last4 = CASE WHEN ? THEN excluded.webhook_secret_last4
		                                ELSE studio_stripe_credentials.webhook_secret_last4 END,
		    updated_by = excluded.updated_by,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')`

	args := []any{
		studioID, mode, accountID, pubKey,
		applePay, googlePay, merchantName, merchantCountry,
		secretCipher, secretNonce, secretLast4,
		webhookCipher, webhookNonce, webhookLast4,
		actorID,
		secretChanged, secretChanged, secretChanged,
		webhookChanged, webhookChanged, webhookChanged,
	}
	if _, err := s.db.ExecContext(ctx, q, args...); err != nil {
		return nil, fmt.Errorf("upsert stripe creds: %w", err)
	}

	// Audit — note which fields changed, never the values.
	detail := map[string]any{"mode": mode}
	if secretChanged {
		if in.SecretKey != nil && *in.SecretKey == "" {
			detail["secret_key"] = "cleared"
		} else {
			detail["secret_key"] = "rotated"
		}
	}
	if webhookChanged {
		if in.WebhookSecret != nil && *in.WebhookSecret == "" {
			detail["webhook_secret"] = "cleared"
		} else {
			detail["webhook_secret"] = "rotated"
		}
	}
	if in.PublishableKey != nil {
		detail["publishable_key"] = "set"
	}
	if in.ApplePayEnabled != nil {
		detail["apple_pay_enabled"] = *in.ApplePayEnabled
	}
	if in.GooglePayEnabled != nil {
		detail["google_pay_enabled"] = *in.GooglePayEnabled
	}
	if in.MerchantDisplayName != nil {
		detail["merchant_display_name"] = "set"
	}
	if in.MerchantCountryCode != nil {
		detail["merchant_country_code"] = "set"
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "stripe_credentials_update",
		"studio", studioID, detail)

	// Now that the studio has a usable secret key, mint Stripe Prices for any
	// recurring memberships that lack one (e.g. the seeded "Unlimited Monthly",
	// created before Stripe was configured) so they're buyable immediately
	// rather than self-healing on the first purchase. Best-effort: the keys are
	// already saved, so a Stripe hiccup here must not fail the request.
	if secretChanged && in.SecretKey != nil && *in.SecretKey != "" {
		if err := s.backfillRecurringPrices(ctx, studioID); err != nil {
			log.Printf("backfill recurring prices for %s: %v", studioID, err)
		}
	}

	return s.StripeCredentialsFor(ctx, studioID)
}

// DecryptedStripeKeys is the internal-only view returned to the few server
// code paths that need to actually call Stripe — e.g. a future
// PaymentIntents.Create. NEVER serialise this struct.
type DecryptedStripeKeys struct {
	Mode           string
	AccountID      string
	PublishableKey string
	SecretKey      string
	WebhookSecret  string
}

// LoadStripeKeysForUse decrypts a studio's stored credentials. Returns
// ErrNotFound when no row exists. Loud comment because forgetting which
// of the two getters to call is the kind of mistake that exfiltrates
// secrets onto an API response.
func (s *Store) LoadStripeKeysForUse(ctx context.Context, studioID string) (*DecryptedStripeKeys, error) {
	if !s.sealer.Available() {
		return nil, secrets.ErrNoMasterKey
	}
	var (
		mode                                                  string
		accountID, pubKey                                     sql.NullString
		secretCipher, secretNonce, webhookCipher, webhookNonce []byte
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT mode, account_id, publishable_key,
		       secret_key_cipher, secret_key_nonce,
		       webhook_secret_cipher, webhook_secret_nonce
		  FROM studio_stripe_credentials
		 WHERE studio_id = ?`,
		studioID,
	).Scan(&mode, &accountID, &pubKey,
		&secretCipher, &secretNonce, &webhookCipher, &webhookNonce)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	out := &DecryptedStripeKeys{Mode: mode}
	if accountID.Valid {
		out.AccountID = accountID.String
	}
	if pubKey.Valid {
		out.PublishableKey = pubKey.String
	}
	if len(secretCipher) > 0 {
		v, err := s.sealer.Decrypt(secretCipher, secretNonce)
		if err != nil {
			return nil, fmt.Errorf("decrypt secret key: %w", err)
		}
		out.SecretKey = v
	}
	if len(webhookCipher) > 0 {
		v, err := s.sealer.Decrypt(webhookCipher, webhookNonce)
		if err != nil {
			return nil, fmt.Errorf("decrypt webhook secret: %w", err)
		}
		out.WebhookSecret = v
	}
	return out, nil
}

// PublicPaymentConfig is the non-secret subset a signed-in student needs to
// drive the client-side PaymentSheet. The publishable key is safe to expose
// (it's meant for client use); secrets never appear here.
type PublicPaymentConfig struct {
	PublishableKey      string `json:"publishable_key"`
	Mode                string `json:"mode"` // "test" | "live"
	ApplePayEnabled     bool   `json:"apple_pay_enabled"`
	GooglePayEnabled    bool   `json:"google_pay_enabled"`
	MerchantDisplayName string `json:"merchant_display_name"`
	MerchantCountryCode string `json:"merchant_country_code"`
}

// PaymentConfigFor returns the studio's public payment config for the client.
// Reuses StripeCredentialsFor (which already masks secrets) and flattens it to
// the safe-to-send shape. PublishableKey is empty when the studio hasn't
// configured Stripe — the client treats that as "card payments unavailable".
func (s *Store) PaymentConfigFor(ctx context.Context, studioID string) (*PublicPaymentConfig, error) {
	v, err := s.StripeCredentialsFor(ctx, studioID)
	if err != nil {
		return nil, err
	}
	out := &PublicPaymentConfig{
		Mode:             v.Mode,
		ApplePayEnabled:  v.ApplePayEnabled,
		GooglePayEnabled: v.GooglePayEnabled,
	}
	if v.PublishableKey != nil {
		out.PublishableKey = *v.PublishableKey
	}
	if v.MerchantDisplayName != nil {
		out.MerchantDisplayName = *v.MerchantDisplayName
	}
	if v.MerchantCountryCode != nil {
		out.MerchantCountryCode = *v.MerchantCountryCode
	}
	return out, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// last4 returns the last 4 chars of a key for masked display. Returns the
// whole string for very short inputs so a placeholder/test key still
// renders something readable.
func last4(s string) string {
	s = strings.TrimSpace(s)
	if len(s) <= 4 {
		return s
	}
	return s[len(s)-4:]
}
