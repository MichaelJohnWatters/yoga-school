package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

type ThemeRow struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	IsPreset   bool        `json:"is_preset"`
	Mode       string      `json:"mode"`
	Tokens     ThemeTokens `json:"tokens"`
	IsActive   bool        `json:"is_active"`
	CreatedAt  string      `json:"created_at"`
}

func (s *Store) ListThemes(ctx context.Context, studioID string) ([]ThemeRow, error) {
	const q = `
		SELECT t.id, t.name, t.is_preset, t.mode, t.tokens, t.created_at,
		       (CASE WHEN t.id = s.active_theme_id THEN 1 ELSE 0 END) AS is_active
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
			r          ThemeRow
			preset, ac int
			tokensJSON string
		)
		if err := rows.Scan(&r.ID, &r.Name, &preset, &r.Mode, &tokensJSON, &r.CreatedAt, &ac); err != nil {
			return nil, err
		}
		r.IsPreset = preset != 0
		r.IsActive = ac != 0
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

func (s *Store) CreateTheme(ctx context.Context, studioID string, in ThemeInput) (string, error) {
	if in.Mode != "light" && in.Mode != "dark" {
		in.Mode = "light"
	}
	tokensJSON, err := json.Marshal(in.Tokens)
	if err != nil {
		return "", err
	}
	id := uuid.NewString()
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO themes (id, studio_id, name, is_preset, mode, tokens)
		     VALUES (?, ?, ?, 0, ?, ?)`,
		id, studioID, in.Name, in.Mode, string(tokensJSON),
	)
	if err != nil {
		return "", err
	}
	return id, nil
}

type ThemePatch struct {
	Name   *string      `json:"name,omitempty"`
	Mode   *string      `json:"mode,omitempty"`
	Tokens *ThemeTokens `json:"tokens,omitempty"`
}

func (s *Store) UpdateTheme(ctx context.Context, studioID, themeID string, p ThemePatch) error {
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
	return nil
}

func (s *Store) ActivateTheme(ctx context.Context, studioID, themeID string) error {
	// Verify theme belongs to the studio.
	var owned int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM themes WHERE id = ? AND studio_id = ?`,
		themeID, studioID,
	).Scan(&owned)
	if err != nil {
		return err
	}
	if owned == 0 {
		return ErrNotFound
	}
	_, err = s.db.ExecContext(ctx,
		`UPDATE studios SET active_theme_id = ? WHERE id = ?`,
		themeID, studioID,
	)
	return err
}

// StudioConfigPatch is the subset of studios fields editable via
// PATCH /admin/studio/config. Pointers so absent fields are no-ops.
type StudioConfigPatch struct {
	FreeCancelCutoffHours *int    `json:"free_cancel_cutoff_hours,omitempty"`
	AllowStudentPlusOne   *bool   `json:"allow_student_plus_one,omitempty"`
	BuyLayout             *string `json:"buy_layout,omitempty"`
	WelcomeMessage        *string `json:"welcome_message,omitempty"`
}

func (s *Store) UpdateStudioConfig(ctx context.Context, studioID string, p StudioConfigPatch) error {
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
	return nil
}
