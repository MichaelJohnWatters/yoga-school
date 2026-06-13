package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"github.com/google/uuid"
)

// StaffMember is one row in GET /admin/staff. Includes role so the UI can
// render badges and gate destructive actions.
type StaffMember struct {
	ID       string  `json:"id"`
	Role     string  `json:"role"`
	Email    string  `json:"email"`
	FullName string  `json:"full_name"`
	PhotoURL *string `json:"photo_url,omitempty"`
}

type StaffInput struct {
	Role     string `json:"role"` // instructor | manager | owner
	Email    string `json:"email"`
	FullName string `json:"full_name"`
	PhotoURL string `json:"photo_url"`
}

func validStaffRole(r string) bool {
	return r == "instructor" || r == "manager" || r == "owner"
}

func (s *Store) ListAdminStaff(ctx context.Context, studioID string) ([]StaffMember, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, role, email, full_name, photo_url
		  FROM users
		 WHERE studio_id = ? AND role IN ('instructor','manager','owner')
		 ORDER BY role, full_name ASC`,
		studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []StaffMember{}
	for rows.Next() {
		var (
			m        StaffMember
			photoURL sql.NullString
		)
		if err := rows.Scan(&m.ID, &m.Role, &m.Email, &m.FullName, &photoURL); err != nil {
			return nil, err
		}
		if photoURL.Valid {
			v := photoURL.String
			m.PhotoURL = &v
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Store) CreateStaff(ctx context.Context, studioID, actorID string, in StaffInput) (string, error) {
	email := strings.TrimSpace(in.Email)
	name := strings.TrimSpace(in.FullName)
	if email == "" {
		return "", fmt.Errorf("email is required")
	}
	if name == "" {
		return "", fmt.Errorf("full_name is required")
	}
	if !validStaffRole(in.Role) {
		return "", fmt.Errorf("role must be instructor, manager, or owner")
	}
	id := uuid.NewString()
	photo := sql.NullString{String: strings.TrimSpace(in.PhotoURL), Valid: in.PhotoURL != ""}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO users (id, studio_id, role, email, full_name, photo_url)
		     VALUES (?, ?, ?, ?, ?, ?)`,
		id, studioID, in.Role, email, name, photo,
	)
	if err != nil {
		// Unique (studio_id, email) violation — surface cleanly.
		if strings.Contains(err.Error(), "UNIQUE") {
			return "", fmt.Errorf("email already in use")
		}
		return "", err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "staff_create", "user", id, map[string]any{
		"role":  in.Role,
		"email": email,
	})
	return id, nil
}

func (s *Store) UpdateStaff(ctx context.Context, studioID, actorID, id string, in StaffInput) error {
	email := strings.TrimSpace(in.Email)
	name := strings.TrimSpace(in.FullName)
	if email == "" {
		return fmt.Errorf("email is required")
	}
	if name == "" {
		return fmt.Errorf("full_name is required")
	}
	if !validStaffRole(in.Role) {
		return fmt.Errorf("role must be instructor, manager, or owner")
	}
	// Capture the prior role so we can record role transitions in the audit.
	var priorRole string
	if err := s.db.QueryRowContext(ctx,
		`SELECT role FROM users WHERE id = ? AND studio_id = ?
		   AND role IN ('instructor','manager','owner')`,
		id, studioID,
	).Scan(&priorRole); err != nil {
		if err == sql.ErrNoRows {
			return ErrNotFound
		}
		return err
	}
	photo := sql.NullString{String: strings.TrimSpace(in.PhotoURL), Valid: in.PhotoURL != ""}
	res, err := s.db.ExecContext(ctx, `
		UPDATE users
		   SET role = ?, email = ?, full_name = ?, photo_url = ?
		 WHERE id = ? AND studio_id = ?
		   AND role IN ('instructor','manager','owner')`,
		in.Role, email, name, photo, id, studioID,
	)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return fmt.Errorf("email already in use")
		}
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "staff_update", "user", id, map[string]any{
		"role":       in.Role,
		"prior_role": priorRole,
		"email":      email,
	})
	return nil
}

