package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

// StaffMember is one row in GET /admin/staff. Includes role so the UI can
// render badges and gate destructive actions. PayRateMinor is only
// meaningful on instructor rows but surfaces on every row so the UI table
// is shape-stable.
type StaffMember struct {
	ID           string  `json:"id"`
	Role         string  `json:"role"`
	Email        string  `json:"email"`
	FullName     string  `json:"full_name"`
	PhotoURL     *string `json:"photo_url,omitempty"`
	PayRateMinor *int    `json:"pay_rate_minor,omitempty"`
}

// StaffInput is the body for POST/PATCH /admin/staff. PayRateMinor is a
// pointer so a PATCH that doesn't touch it leaves the column alone — sending
// 0 explicitly is a valid "this instructor is unpaid" setting.
type StaffInput struct {
	Role         string `json:"role"` // instructor | manager | owner
	Email        string `json:"email"`
	FullName     string `json:"full_name"`
	PhotoURL     string `json:"photo_url"`
	PayRateMinor *int   `json:"pay_rate_minor,omitempty"`
}

func validStaffRole(r string) bool {
	return r == "instructor" || r == "manager" || r == "owner"
}

func (s *Store) ListAdminStaff(ctx context.Context, studioID string) ([]StaffMember, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, role, email, full_name, photo_url, instructor_pay_rate_minor
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
			rate     sql.NullInt64
		)
		if err := rows.Scan(&m.ID, &m.Role, &m.Email, &m.FullName, &photoURL, &rate); err != nil {
			return nil, err
		}
		if photoURL.Valid {
			v := photoURL.String
			m.PhotoURL = &v
		}
		if rate.Valid {
			v := int(rate.Int64)
			m.PayRateMinor = &v
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
	id := NewID()
	photo := sql.NullString{String: strings.TrimSpace(in.PhotoURL), Valid: in.PhotoURL != ""}
	var rateArg any
	if in.PayRateMinor != nil {
		rateArg = *in.PayRateMinor
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO users (id, studio_id, role, email, full_name, photo_url,
		                   instructor_pay_rate_minor)
		     VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, studioID, in.Role, email, name, photo, rateArg,
	)
	if err != nil {
		// Unique (studio_id, email) violation — surface cleanly.
		if strings.Contains(err.Error(), "UNIQUE") {
			return "", fmt.Errorf("email already in use")
		}
		return "", err
	}
	detail := map[string]any{
		"role":  in.Role,
		"email": email,
	}
	if in.PayRateMinor != nil {
		detail["pay_rate_minor"] = *in.PayRateMinor
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "staff_create", "user", id, detail)
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
	// Capture the prior role + email + full_name so we can record what
	// changed in the audit row, not just the post-state. role transitions
	// (instructor → manager) are the most consequential thing to keep
	// visible, but email/name renames matter for tracing identity drift.
	var priorRole, priorEmail, priorFullName string
	if err := s.db.QueryRowContext(ctx,
		`SELECT role, email, full_name FROM users WHERE id = ? AND studio_id = ?
		   AND role IN ('instructor','manager','owner')`,
		id, studioID,
	).Scan(&priorRole, &priorEmail, &priorFullName); err != nil {
		if err == sql.ErrNoRows {
			return ErrNotFound
		}
		return err
	}
	photo := sql.NullString{String: strings.TrimSpace(in.PhotoURL), Valid: in.PhotoURL != ""}
	// PayRateMinor is patch-shape: nil → leave column alone; non-nil → set
	// (or NULL out via 0 if the manager explicitly wants to mark "no pay").
	var (
		setRate   string
		rateArg   any
		execArgs  []any
	)
	if in.PayRateMinor != nil {
		setRate = ", instructor_pay_rate_minor = ?"
		rateArg = *in.PayRateMinor
		execArgs = []any{in.Role, email, name, photo, rateArg, id, studioID}
	} else {
		execArgs = []any{in.Role, email, name, photo, id, studioID}
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE users
		   SET role = ?, email = ?, full_name = ?, photo_url = ?`+setRate+`
		 WHERE id = ? AND studio_id = ?
		   AND role IN ('instructor','manager','owner')`,
		execArgs...,
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
	detail := map[string]any{
		"role":      in.Role,
		"email":     email,
		"full_name": name,
	}
	if priorRole != "" && priorRole != in.Role {
		detail["previous_role"] = priorRole
		// Keep the legacy `prior_role` key around so any earlier
		// readers still find it without a rename.
		detail["prior_role"] = priorRole
	}
	if priorEmail != "" && priorEmail != email {
		detail["previous_email"] = priorEmail
	}
	if priorFullName != "" && priorFullName != name {
		detail["previous_full_name"] = priorFullName
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "staff_update", "user", id, detail)
	return nil
}
