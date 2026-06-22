package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	_ "modernc.org/sqlite"

	"github.com/studio52/yoga-school/server/internal/secrets"
)

// PushDispatcher fans an in-app notification out to a user's registered
// devices. The store calls Dispatch *after* a successful commit — never
// inside a transaction — so a rolled-back write never produces a push.
// A nil dispatcher is allowed; the store treats it as a log-only no-op.
type PushDispatcher interface {
	Dispatch(userID, notifType, title, body, payloadJSON string)
}

type Store struct {
	db         *sql.DB
	sealer     *secrets.Sealer
	dispatcher PushDispatcher
}

// SetPushDispatcher wires the FCM fan-out into the store. Calling this with
// nil is allowed and disables push (tests + dev without Firebase keys).
func (s *Store) SetPushDispatcher(d PushDispatcher) { s.dispatcher = d }

// DB returns the underlying handle. Exposed for the push package, which
// reads device_tokens and prunes dead rows independently of store methods.
func (s *Store) DB() *sql.DB { return s.db }

// dispatchPush is the private fire-and-forget call site. nil-receiver-safe
// so non-push deployments don't need to special-case.
func (s *Store) dispatchPush(userID, notifType, title, body, payloadJSON string) {
	if s.dispatcher == nil {
		return
	}
	s.dispatcher.Dispatch(userID, notifType, title, body, payloadJSON)
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
	// Light slot — always present (StudioConfig fails if the active light
	// theme is missing). Kept under the legacy `active_theme_*` names so
	// existing client code keeps reading the light tokens by default.
	ActiveThemeID          string      `json:"active_theme_id"`
	ActiveThemeName        string      `json:"active_theme_name"`
	ActiveThemeMode        string      `json:"active_theme_mode"`
	ActiveThemeTokens      ThemeTokens `json:"active_theme_tokens"`
	ActiveThemeSplashImage *string     `json:"active_theme_splash_image,omitempty"`

	// Dark slot — optional. Null when the manager hasn't picked one yet,
	// in which case the client falls back to the light slot for a dark
	// preference rather than rendering broken colours.
	ActiveDarkThemeID          *string      `json:"active_dark_theme_id,omitempty"`
	ActiveDarkThemeName        *string      `json:"active_dark_theme_name,omitempty"`
	ActiveDarkThemeMode        *string      `json:"active_dark_theme_mode,omitempty"`
	ActiveDarkThemeTokens      *ThemeTokens `json:"active_dark_theme_tokens,omitempty"`
	ActiveDarkThemeSplashImage *string      `json:"active_dark_theme_splash_image,omitempty"`
}

type User struct {
	ID            string  `json:"id"`
	StudioID      string  `json:"studio_id"`
	Role          string  `json:"role"`
	Email         string  `json:"email"`
	FullName      string  `json:"full_name"`
	PhotoURL      *string `json:"photo_url,omitempty"`
	ThemeModePref string  `json:"theme_mode_pref"`
	CreatedAt     string  `json:"created_at"`
}

// ---- queries --------------------------------------------------------------

var ErrNotFound = errors.New("not found")

// ErrClassStarted is returned by CancelBooking when the class has already
// begun. Distinct from late-cancel (which still goes through and burns the
// pass) — at this point the class is in flight or over and cancellation is
// nonsensical, so the action is refused outright. The API layer maps this
// to a 409 with code class_already_started.
var ErrClassStarted = errors.New("class already started")

// JoinWaitlist refuses with these when the caller's existing relationship
// with the class makes a waitlist entry meaningless — already booked into
// the class or already holding a queue slot. The API layer maps both to
// 409 with specific codes so the UI can render the correct affordance.
var (
	ErrAlreadyBooked     = errors.New("already booked for this class")
	ErrAlreadyOnWaitlist = errors.New("already on the waitlist for this class")
)

func (s *Store) StudioConfig(ctx context.Context, studioID string) (*Studio, error) {
	// Light slot is INNER JOIN'd — every studio must have an active light
	// theme. Dark slot is LEFT JOIN'd so studios that haven't picked one
	// yet still load. Distinct join aliases keep the column list readable.
	const q = `
		SELECT s.id, s.name, s.timezone, s.currency,
		       s.free_cancel_cutoff_hours, s.allow_student_plus_one,
		       COALESCE(s.welcome_message,''), s.buy_layout,
		       lt.id, lt.name, lt.mode, lt.tokens, lt.splash_image_url,
		       dt.id, dt.name, dt.mode, dt.tokens, dt.splash_image_url
		  FROM studios s
		  JOIN  themes lt ON lt.id = s.active_theme_id
		  LEFT JOIN themes dt ON dt.id = s.active_dark_theme_id
		 WHERE s.id = ?`
	var (
		out              Studio
		lightTokens      string
		plusOneInt       int
		lightSplash      sql.NullString
		darkID           sql.NullString
		darkName         sql.NullString
		darkMode         sql.NullString
		darkTokens       sql.NullString
		darkSplashString sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, studioID).Scan(
		&out.ID, &out.Name, &out.Timezone, &out.Currency,
		&out.FreeCancelCutoffHours, &plusOneInt,
		&out.WelcomeMessage, &out.BuyLayout,
		&out.ActiveThemeID, &out.ActiveThemeName, &out.ActiveThemeMode,
		&lightTokens, &lightSplash,
		&darkID, &darkName, &darkMode, &darkTokens, &darkSplashString,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	out.AllowStudentPlusOne = plusOneInt != 0
	if lightSplash.Valid {
		out.ActiveThemeSplashImage = &lightSplash.String
	}
	if err := json.Unmarshal([]byte(lightTokens), &out.ActiveThemeTokens); err != nil {
		return nil, fmt.Errorf("parse light theme tokens: %w", err)
	}
	if darkID.Valid {
		out.ActiveDarkThemeID = &darkID.String
		out.ActiveDarkThemeName = &darkName.String
		out.ActiveDarkThemeMode = &darkMode.String
		var dt ThemeTokens
		if err := json.Unmarshal([]byte(darkTokens.String), &dt); err != nil {
			return nil, fmt.Errorf("parse dark theme tokens: %w", err)
		}
		out.ActiveDarkThemeTokens = &dt
		if darkSplashString.Valid {
			out.ActiveDarkThemeSplashImage = &darkSplashString.String
		}
	}
	return &out, nil
}

func (s *Store) UserByFirebaseUID(ctx context.Context, uid string) (*User, error) {
	const q = `
		SELECT id, studio_id, role, email, full_name, photo_url, theme_mode_pref, created_at
		  FROM users
		 WHERE firebase_uid = ? AND erased_at IS NULL`
	var (
		out      User
		photoURL sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, uid).Scan(
		&out.ID, &out.StudioID, &out.Role, &out.Email, &out.FullName, &photoURL,
		&out.ThemeModePref, &out.CreatedAt,
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

// LinkFirebaseUID writes the Firebase UID onto an existing user row when
// the column is missing or stale. Called from the auth middleware on first
// sign-in for users who were pre-seeded (e.g. via an invite import) and so
// don't yet have a UID linked. Idempotent: the WHERE clause skips writes
// when the column already matches.
func (s *Store) LinkFirebaseUID(ctx context.Context, userID, uid string) error {
	if uid == "" {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE users
		   SET firebase_uid = ?
		 WHERE id = ?
		   AND (firebase_uid IS NULL OR firebase_uid != ?)`,
		uid, userID, uid,
	)
	return err
}

// UserByEmail is the auth lookup path now that we verify Firebase tokens —
// the token's email claim is what links the external identity to our row.
func (s *Store) UserByEmail(ctx context.Context, email string) (*User, error) {
	const q = `
		SELECT id, studio_id, role, email, full_name, photo_url, theme_mode_pref, created_at
		  FROM users
		 WHERE email = ? AND erased_at IS NULL`
	var (
		out      User
		photoURL sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, email).Scan(
		&out.ID, &out.StudioID, &out.Role, &out.Email, &out.FullName, &photoURL,
		&out.ThemeModePref, &out.CreatedAt,
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

// ErrMultipleStudios signals that ProvisionStudentFromFirebase couldn't
// auto-pick a tenant — the deployment has more than one studio and the
// Firebase token doesn't carry a studio claim. Callers should refuse the
// sign-in with a clear "talk to your studio" error in this case.
var ErrMultipleStudios = errors.New("multiple studios — cannot auto-provision")

// ProvisionStudentFromFirebase creates a student row for a brand-new
// Firebase identity. It runs on first sign-in when UserByEmail returns
// ErrNotFound — the spec's "Splash" flow describes this onboarding step.
//
// Single-studio deployments (the common case for now) auto-resolve the
// studio. Multi-studio deployments need a studio claim on the token or a
// per-studio sign-up URL — we surface ErrMultipleStudios so the caller can
// tell the user which path to take.
//
// firebase_uid is set on creation so subsequent lookups by either email or
// UID resolve to the same row. Display name + photo come from the token's
// optional "name" / "picture" claims; a sensible fallback derives the name
// from the email local-part.
func (s *Store) ProvisionStudentFromFirebase(
	ctx context.Context, firebaseUID, email, fullName, photoURL string,
) (*User, error) {
	if email == "" {
		return nil, fmt.Errorf("provision: empty email")
	}

	var studioCount int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM studios`,
	).Scan(&studioCount); err != nil {
		return nil, fmt.Errorf("provision: count studios: %w", err)
	}
	if studioCount == 0 {
		return nil, fmt.Errorf("provision: no studio configured")
	}
	if studioCount > 1 {
		return nil, ErrMultipleStudios
	}

	var studioID string
	if err := s.db.QueryRowContext(ctx,
		`SELECT id FROM studios LIMIT 1`,
	).Scan(&studioID); err != nil {
		return nil, fmt.Errorf("provision: pick studio: %w", err)
	}

	if fullName == "" {
		// Cheap fallback so the row has *something* renderable. The user
		// can edit their display name from the profile screen later.
		if at := strings.IndexByte(email, '@'); at > 0 {
			fullName = email[:at]
		} else {
			fullName = email
		}
	}

	id := NewID()
	var photoArg any
	if photoURL != "" {
		photoArg = photoURL
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO users (id, studio_id, firebase_uid, role, email, full_name, photo_url)
		     VALUES (?, ?, ?, 'student', ?, ?, ?)`,
		id, studioID, firebaseUID, email, fullName, photoArg,
	); err != nil {
		return nil, fmt.Errorf("provision: insert user: %w", err)
	}

	// Re-read so we pick up the DEFAULT created_at written by SQLite — easier
	// than mirroring strftime in Go and matches whatever format the rest of
	// the codebase reads from this column.
	var createdAt string
	if err := s.db.QueryRowContext(ctx,
		`SELECT created_at FROM users WHERE id = ?`, id,
	).Scan(&createdAt); err != nil {
		return nil, fmt.Errorf("provision: re-read created_at: %w", err)
	}

	out := &User{
		ID:            id,
		StudioID:      studioID,
		Role:          "student",
		Email:         email,
		FullName:      fullName,
		ThemeModePref: "light", // matches the schema DEFAULT
		CreatedAt:     createdAt,
	}
	if photoURL != "" {
		out.PhotoURL = &photoURL
	}
	return out, nil
}

// UpdateUserThemeMode persists the user's light/dark/system preference.
// Validates the value because we never want a sneaky junk pref breaking
// the bootstrap on the next request.
func (s *Store) UpdateUserThemeMode(ctx context.Context, userID, pref string) error {
	switch pref {
	case "light", "dark", "system":
	default:
		return errors.New("theme_mode_pref must be one of light|dark|system")
	}
	res, err := s.db.ExecContext(ctx,
		`UPDATE users SET theme_mode_pref = ? WHERE id = ?`,
		pref, userID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
