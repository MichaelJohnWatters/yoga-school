package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

type ThemeRow struct {
	ID       string      `json:"id"`
	Name     string      `json:"name"`
	IsPreset bool        `json:"is_preset"`
	Mode     string      `json:"mode"`
	Tokens   ThemeTokens `json:"tokens"`
	// IsActive stays for back-compat with any consumer still reading the
	// single-slot flag — it's true iff the theme is the studio's active
	// LIGHT theme (the original meaning).
	IsActive      bool   `json:"is_active"`
	IsActiveLight bool   `json:"is_active_light"`
	IsActiveDark  bool   `json:"is_active_dark"`
	CreatedAt     string `json:"created_at"`
}

func (s *Store) ListThemes(ctx context.Context, studioID string) ([]ThemeRow, error) {
	const q = `
		SELECT t.id, t.name, t.is_preset, t.mode, t.tokens, t.created_at,
		       (CASE WHEN t.id = s.active_theme_id      THEN 1 ELSE 0 END) AS is_active_light,
		       (CASE WHEN t.id = s.active_dark_theme_id THEN 1 ELSE 0 END) AS is_active_dark
		  FROM themes t
		  JOIN studios s ON s.id = t.studio_id
		 WHERE t.studio_id = ?
		 ORDER BY t.is_preset DESC, t.created_at ASC`
	rows, err := s.db.QueryContext(ctx, q, studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ThemeRow, 0)
	for rows.Next() {
		var (
			r              ThemeRow
			preset, l, d   int
			tokensJSON     string
		)
		if err := rows.Scan(&r.ID, &r.Name, &preset, &r.Mode, &tokensJSON, &r.CreatedAt, &l, &d); err != nil {
			return nil, err
		}
		r.IsPreset = preset != 0
		r.IsActiveLight = l != 0
		r.IsActiveDark = d != 0
		r.IsActive = r.IsActiveLight
		if err := json.Unmarshal([]byte(tokensJSON), &r.Tokens); err != nil {
			return nil, fmt.Errorf("parse tokens: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type ThemeInput struct {
	Name   string      `json:"name"`
	Mode   string      `json:"mode"`
	Tokens ThemeTokens `json:"tokens"`
}

func (s *Store) CreateTheme(ctx context.Context, studioID, actorID string, in ThemeInput) (string, error) {
	if in.Mode != "light" && in.Mode != "dark" {
		in.Mode = "light"
	}
	if err := validateThemeContrast(in.Tokens); err != nil {
		return "", err
	}
	tokensJSON, err := json.Marshal(in.Tokens)
	if err != nil {
		return "", err
	}
	id := NewID()
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO themes (id, studio_id, name, is_preset, mode, tokens)
		     VALUES (?, ?, ?, 0, ?, ?)`,
		id, studioID, in.Name, in.Mode, string(tokensJSON),
	)
	if err != nil {
		return "", err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "theme_create", "theme", id, map[string]any{
		"name": in.Name,
		"mode": in.Mode,
	})
	return id, nil
}

type ThemePatch struct {
	Name   *string      `json:"name,omitempty"`
	Mode   *string      `json:"mode,omitempty"`
	Tokens *ThemeTokens `json:"tokens,omitempty"`
}

func (s *Store) UpdateTheme(ctx context.Context, studioID, actorID, themeID string, p ThemePatch) error {
	// Snapshot prior values BEFORE the UPDATE so the audit detail can
	// show "previous_name → name" / "previous_mode → mode" diffs. The
	// theme's current name also serves as a fallback subject when a
	// patch only touched tokens (no name/mode field at all).
	var prevName, prevMode string
	_ = s.db.QueryRowContext(ctx,
		`SELECT name, mode FROM themes WHERE id = ? AND studio_id = ?`,
		themeID, studioID,
	).Scan(&prevName, &prevMode)
	// Composed set list. Keep it small + explicit.
	set := []string{}
	args := []any{}
	if p.Name != nil {
		set = append(set, "name = ?")
		args = append(args, *p.Name)
	}
	if p.Mode != nil {
		if *p.Mode != "light" && *p.Mode != "dark" {
			return errors.New("mode must be 'light' or 'dark'")
		}
		set = append(set, "mode = ?")
		args = append(args, *p.Mode)
	}
	if p.Tokens != nil {
		if err := validateThemeContrast(*p.Tokens); err != nil {
			return err
		}
		b, err := json.Marshal(*p.Tokens)
		if err != nil {
			return err
		}
		set = append(set, "tokens = ?")
		args = append(args, string(b))
	}
	if len(set) == 0 {
		return nil
	}
	args = append(args, themeID, studioID)
	q := "UPDATE themes SET "
	for i, s := range set {
		if i > 0 {
			q += ", "
		}
		q += s
	}
	q += " WHERE id = ? AND studio_id = ?"
	res, err := s.db.ExecContext(ctx, q, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	// Always carry the theme's current name on the row so a tokens-only
	// edit still reads as "THEME EDIT · Warm Clay" rather than dropping
	// the subject. Patch fields take precedence below.
	detail := map[string]any{"name": prevName}
	if p.Name != nil {
		detail["name"] = *p.Name
		if prevName != "" && prevName != *p.Name {
			detail["previous_name"] = prevName
		}
	}
	if p.Mode != nil {
		detail["mode"] = *p.Mode
		if prevMode != "" && prevMode != *p.Mode {
			detail["previous_mode"] = prevMode
		}
	}
	if p.Tokens != nil {
		detail["tokens_updated"] = true
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "theme_update", "theme", themeID, detail)
	return nil
}

// ErrThemeModeMismatch is returned when the caller tries to activate a
// theme into the wrong slot — e.g. dropping a light theme into the dark
// slot. The mode field on themes drives presentational defaults and the
// expectation is that the slot matches it; the API layer maps this to a
// 400 with code theme_mode_mismatch.
var ErrThemeModeMismatch = errors.New("theme mode does not match target slot")

// ActivateTheme is a thin alias for the light slot, kept so older call
// sites still compile. New code should call ActivateThemeAs.
func (s *Store) ActivateTheme(ctx context.Context, studioID, actorID, themeID string) error {
	return s.ActivateThemeAs(ctx, studioID, actorID, themeID, "light")
}

// ActivateThemeAs sets the studio's active theme for the given slot
// ("light" or "dark"). The theme must belong to the studio and its own
// mode must match the slot — refusing this avoids a "Mono Light" picked
// as the dark slot rendering broken contrast on a dark-mode user.
func (s *Store) ActivateThemeAs(ctx context.Context, studioID, actorID, themeID, slot string) error {
	if slot != "light" && slot != "dark" {
		return errors.New("slot must be 'light' or 'dark'")
	}
	// Verify ownership + mode in a single round-trip. Also pick up the
	// theme name so the audit row can render "THEME ACTIVE · Warm Clay"
	// rather than an opaque theme id.
	var mode, name string
	err := s.db.QueryRowContext(ctx,
		`SELECT mode, name FROM themes WHERE id = ? AND studio_id = ?`,
		themeID, studioID,
	).Scan(&mode, &name)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if mode != slot {
		return ErrThemeModeMismatch
	}
	col := "active_theme_id"
	if slot == "dark" {
		col = "active_dark_theme_id"
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE studios SET `+col+` = ? WHERE id = ?`,
		themeID, studioID,
	); err != nil {
		return err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "theme_activate", "theme", themeID, map[string]any{
		"slot": slot,
		"name": name,
	})
	return nil
}

// StudioConfigPatch is the subset of studios fields editable via
// PATCH /admin/studio/config. Pointers so absent fields are no-ops.
type StudioConfigPatch struct {
	FreeCancelCutoffHours *int    `json:"free_cancel_cutoff_hours,omitempty"`
	AllowStudentPlusOne   *bool   `json:"allow_student_plus_one,omitempty"`
	BuyLayout             *string `json:"buy_layout,omitempty"`
	WelcomeMessage        *string `json:"welcome_message,omitempty"`
	Timezone              *string `json:"timezone,omitempty"`
}

func (s *Store) UpdateStudioConfig(ctx context.Context, studioID, actorID string, p StudioConfigPatch) error {
	// Snapshot the patch-touched columns' BEFORE values so the audit
	// row can render "free_cancel_cutoff_hours: 24 → 12". Only fetch
	// fields the patch actually touches — a no-op patch shouldn't
	// fire a SELECT.
	var (
		prevCutoff      int
		prevAllowPlus1  int
		prevBuyLayout   string
		prevWelcomeMsg  string
		prevTimezone    string
	)
	if p.FreeCancelCutoffHours != nil || p.AllowStudentPlusOne != nil ||
		p.BuyLayout != nil || p.WelcomeMessage != nil || p.Timezone != nil {
		_ = s.db.QueryRowContext(ctx,
			`SELECT free_cancel_cutoff_hours, allow_student_plus_one,
			        COALESCE(buy_layout,''), COALESCE(welcome_message,''),
			        COALESCE(timezone,'')
			   FROM studios WHERE id = ?`, studioID,
		).Scan(&prevCutoff, &prevAllowPlus1, &prevBuyLayout, &prevWelcomeMsg, &prevTimezone)
	}
	set := []string{}
	args := []any{}
	if p.FreeCancelCutoffHours != nil {
		set = append(set, "free_cancel_cutoff_hours = ?")
		args = append(args, *p.FreeCancelCutoffHours)
	}
	if p.AllowStudentPlusOne != nil {
		v := 0
		if *p.AllowStudentPlusOne {
			v = 1
		}
		set = append(set, "allow_student_plus_one = ?")
		args = append(args, v)
	}
	if p.BuyLayout != nil {
		switch *p.BuyLayout {
		case "grid", "list", "grouped":
		default:
			return errors.New("buy_layout must be grid|list|grouped")
		}
		set = append(set, "buy_layout = ?")
		args = append(args, *p.BuyLayout)
	}
	if p.WelcomeMessage != nil {
		set = append(set, "welcome_message = ?")
		args = append(args, *p.WelcomeMessage)
	}
	if p.Timezone != nil {
		// Validate the IANA name actually parses before persisting — a
		// typo'd "Europe/Lndon" would otherwise silently fall back to UTC
		// at read time and the manager would have no idea why their
		// dashboard rolled over wrong.
		if _, err := time.LoadLocation(*p.Timezone); err != nil {
			return errors.New("timezone must be a valid IANA name (e.g. Europe/London, Australia/Sydney)")
		}
		set = append(set, "timezone = ?")
		args = append(args, *p.Timezone)
	}
	if len(set) == 0 {
		return nil
	}
	args = append(args, studioID)
	q := "UPDATE studios SET "
	for i, s := range set {
		if i > 0 {
			q += ", "
		}
		q += s
	}
	q += " WHERE id = ?"
	res, err := s.db.ExecContext(ctx, q, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	// Drop the cached *time.Location so the next request sees the new tz.
	// Cheap; safe to call even when the patch didn't touch the column.
	if p.Timezone != nil {
		InvalidateStudioLocation(studioID)
	}
	// Build the audit detail with before/after pairs so the activity
	// log can render "free_cancel_cutoff_hours: 24 → 12" diffs. Only
	// include the previous value when it actually differs from the
	// new one (a save that didn't change a field is noise on the log).
	detail := map[string]any{}
	if p.FreeCancelCutoffHours != nil {
		detail["free_cancel_cutoff_hours"] = *p.FreeCancelCutoffHours
		if prevCutoff != *p.FreeCancelCutoffHours {
			detail["previous_free_cancel_cutoff_hours"] = prevCutoff
		}
	}
	if p.AllowStudentPlusOne != nil {
		detail["allow_student_plus_one"] = *p.AllowStudentPlusOne
		prev := prevAllowPlus1 != 0
		if prev != *p.AllowStudentPlusOne {
			detail["previous_allow_student_plus_one"] = prev
		}
	}
	if p.BuyLayout != nil {
		detail["buy_layout"] = *p.BuyLayout
		if prevBuyLayout != "" && prevBuyLayout != *p.BuyLayout {
			detail["previous_buy_layout"] = prevBuyLayout
		}
	}
	if p.WelcomeMessage != nil {
		detail["welcome_message"] = *p.WelcomeMessage
		if prevWelcomeMsg != *p.WelcomeMessage {
			detail["previous_welcome_message"] = prevWelcomeMsg
		}
	}
	if p.Timezone != nil {
		detail["timezone"] = *p.Timezone
		if prevTimezone != "" && prevTimezone != *p.Timezone {
			detail["previous_timezone"] = prevTimezone
		}
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "studio_config_update", "studio", studioID, detail)
	return nil
}
