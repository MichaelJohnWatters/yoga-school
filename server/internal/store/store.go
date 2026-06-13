package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

func Open(ctx context.Context, path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	if err := db.PingContext(ctx); err != nil {
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// NewFromDB wraps an already-open *sql.DB. Used by tests in other packages
// that need to seed via raw SQL before constructing the Store.
func NewFromDB(db *sql.DB) *Store { return &Store{db: db} }

// TestDB exposes the underlying handle for test-only setup. Production code
// should never call this — the Store's methods are the supported surface.
func TestDB(s *Store) *sql.DB { return s.db }

// ApplySQLFile executes every statement in a .sql file. Used for schema + seed.
func (s *Store) ApplySQLFile(ctx context.Context, path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	if _, err := s.db.ExecContext(ctx, string(b)); err != nil {
		return fmt.Errorf("apply %s: %w", path, err)
	}
	return nil
}

// ---- domain types ---------------------------------------------------------

type ThemeTokens struct {
	Primary    string `json:"primary"`
	Accent     string `json:"accent"`
	Background string `json:"background"`
	Surface    string `json:"surface"`
	Text       string `json:"text"`
	TextMuted  string `json:"textMuted"`
}

type Studio struct {
	ID                     string      `json:"id"`
	Name                   string      `json:"name"`
	Timezone               string      `json:"timezone"`
	Currency               string      `json:"currency"`
	FreeCancelCutoffHours  int         `json:"free_cancel_cutoff_hours"`
	AllowStudentPlusOne    bool        `json:"allow_student_plus_one"`
	WelcomeMessage         string      `json:"welcome_message"`
	BuyLayout              string      `json:"buy_layout"`
	ActiveThemeID          string      `json:"active_theme_id"`
	ActiveThemeName        string      `json:"active_theme_name"`
	ActiveThemeMode        string      `json:"active_theme_mode"`
	ActiveThemeTokens      ThemeTokens `json:"active_theme_tokens"`
	ActiveThemeSplashImage *string     `json:"active_theme_splash_image,omitempty"`
}

type User struct {
	ID       string  `json:"id"`
	StudioID string  `json:"studio_id"`
	Role     string  `json:"role"`
	Email    string  `json:"email"`
	FullName string  `json:"full_name"`
	PhotoURL *string `json:"photo_url,omitempty"`
}

// ---- queries --------------------------------------------------------------

var ErrNotFound = errors.New("not found")

func (s *Store) StudioConfig(ctx context.Context, studioID string) (*Studio, error) {
	const q = `
		SELECT s.id, s.name, s.timezone, s.currency,
		       s.free_cancel_cutoff_hours, s.allow_student_plus_one,
		       COALESCE(s.welcome_message,''), s.buy_layout,
		       t.id, t.name, t.mode, t.tokens, t.splash_image_url
		  FROM studios s
		  JOIN themes  t ON t.id = s.active_theme_id
		 WHERE s.id = ?`
	var (
		out         Studio
		tokensJSON  string
		plusOneInt  int
		splashImage sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, studioID).Scan(
		&out.ID, &out.Name, &out.Timezone, &out.Currency,
		&out.FreeCancelCutoffHours, &plusOneInt,
		&out.WelcomeMessage, &out.BuyLayout,
		&out.ActiveThemeID, &out.ActiveThemeName, &out.ActiveThemeMode,
		&tokensJSON, &splashImage,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	out.AllowStudentPlusOne = plusOneInt != 0
	if splashImage.Valid {
		out.ActiveThemeSplashImage = &splashImage.String
	}
	if err := json.Unmarshal([]byte(tokensJSON), &out.ActiveThemeTokens); err != nil {
		return nil, fmt.Errorf("parse theme tokens: %w", err)
	}
	return &out, nil
}

func (s *Store) UserByFirebaseUID(ctx context.Context, uid string) (*User, error) {
	const q = `
		SELECT id, studio_id, role, email, full_name, photo_url
		  FROM users
		 WHERE firebase_uid = ?`
	var (
		out      User
		photoURL sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, uid).Scan(
		&out.ID, &out.StudioID, &out.Role, &out.Email, &out.FullName, &photoURL,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if photoURL.Valid {
		out.PhotoURL = &photoURL.String
	}
	return &out, nil
}

// UserByEmail is the auth lookup path now that we verify Firebase tokens —
// the token's email claim is what links the external identity to our row.
func (s *Store) UserByEmail(ctx context.Context, email string) (*User, error) {
	const q = `
		SELECT id, studio_id, role, email, full_name, photo_url
		  FROM users
		 WHERE email = ?`
	var (
		out      User
		photoURL sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, email).Scan(
		&out.ID, &out.StudioID, &out.Role, &out.Email, &out.FullName, &photoURL,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if photoURL.Valid {
		out.PhotoURL = &photoURL.String
	}
	return &out, nil
}
