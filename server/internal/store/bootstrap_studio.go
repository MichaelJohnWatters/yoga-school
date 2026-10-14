package store

import (
	"context"
	"fmt"
	"strings"
)

// StudioBootstrapInput is the minimal set of facts needed to stand up a real
// customer studio: the studio's display identity and its first owner. Everything
// else (class types, rooms, products, themes beyond the starter) is created by
// the owner through the normal admin UI once they sign in.
type StudioBootstrapInput struct {
	Name           string // required, e.g. "Bloom Yoga"
	Timezone       string // IANA tz; defaults to Europe/London
	Currency       string // ISO 4217; defaults to GBP
	WelcomeMessage string // optional splash copy
	OwnerEmail     string // required; the owner signs in with exactly this address
	OwnerName      string // optional; derived from the email local-part if empty
}

// starterThemeTokens is the default light theme a new studio opens with (the
// "Warm Clay" preset from the demo seed). The owner can edit or replace it from
// Manager -> Themes; the point is only that every studio always has something to
// render, since the app joins on active_theme_id (not LEFT JOIN).
const starterThemeTokens = `{"primary":"#B05C3B","accent":"#C8973F","background":"#FAF5EF","surface":"#FFFFFF","text":"#2D2218","textMuted":"#8F8174"}`

// ProvisionStudio creates a brand-new, EMPTY studio and its first owner in one
// transaction: the studios row, a starter active theme, and one owner user keyed
// to OwnerEmail (firebase_uid backfills on the owner's first sign-in via the
// existing LinkFirebaseUID path). Unlike SeedDev this inserts no demo data, so
// it's the supported way to stand up a production instance.
//
// It refuses if any studio already exists — a deploy hosts exactly one studio
// (see ProvisionStudentFromFirebase, which only auto-resolves a single studio),
// and a second row would break student auto-provisioning with ErrMultipleStudios.
//
// Returns the new studio id and owner user id.
func (s *Store) ProvisionStudio(ctx context.Context, in StudioBootstrapInput) (studioID, ownerID string, err error) {
	name := strings.TrimSpace(in.Name)
	email := strings.TrimSpace(in.OwnerEmail)
	if name == "" {
		return "", "", fmt.Errorf("provision studio: name is required")
	}
	if email == "" {
		return "", "", fmt.Errorf("provision studio: owner email is required")
	}
	tz := strings.TrimSpace(in.Timezone)
	if tz == "" {
		tz = "Europe/London"
	}
	currency := strings.TrimSpace(in.Currency)
	if currency == "" {
		currency = "GBP"
	}
	ownerName := strings.TrimSpace(in.OwnerName)
	if ownerName == "" {
		// Same fallback as ProvisionStudentFromFirebase: the local-part of the
		// email, so the row always has something renderable.
		if at := strings.IndexByte(email, '@'); at > 0 {
			ownerName = email[:at]
		} else {
			ownerName = email
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", fmt.Errorf("provision studio: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op after a successful Commit

	var existing int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM studios`).Scan(&existing); err != nil {
		return "", "", fmt.Errorf("provision studio: count: %w", err)
	}
	if existing > 0 {
		return "", "", fmt.Errorf("provision studio: a studio already exists — a deploy hosts exactly one")
	}

	studioID = NewID()
	themeID := NewID()
	ownerID = NewID()

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO studios (id, name, timezone, currency, welcome_message)
		     VALUES (?, ?, ?, ?, ?)`,
		studioID, name, tz, currency, in.WelcomeMessage,
	); err != nil {
		return "", "", fmt.Errorf("provision studio: insert studio: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO themes (id, studio_id, name, is_preset, mode, tokens)
		     VALUES (?, ?, 'Warm Clay', 1, 'light', ?)`,
		themeID, studioID, starterThemeTokens,
	); err != nil {
		return "", "", fmt.Errorf("provision studio: insert theme: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE studios SET active_theme_id = ? WHERE id = ?`,
		themeID, studioID,
	); err != nil {
		return "", "", fmt.Errorf("provision studio: set active theme: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO users (id, studio_id, role, email, full_name)
		     VALUES (?, ?, 'owner', ?, ?)`,
		ownerID, studioID, email, ownerName,
	); err != nil {
		return "", "", fmt.Errorf("provision studio: insert owner: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return "", "", fmt.Errorf("provision studio: commit: %w", err)
	}
	return studioID, ownerID, nil
}
