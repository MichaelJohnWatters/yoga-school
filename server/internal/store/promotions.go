package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// Promotion is one studio promotion. starts_at / ends_at delimit the active
// window; either bound may be NULL ("open-ended"). Student-facing list filters
// to the active window; admin list returns everything (including archived).
type Promotion struct {
	ID         string  `json:"id"`
	Title      string  `json:"title"`
	Body       string  `json:"body,omitempty"`
	ImageURL   string  `json:"image_url,omitempty"`
	StartsAt   *string `json:"starts_at,omitempty"`
	EndsAt     *string `json:"ends_at,omitempty"`
	IsArchived bool    `json:"is_archived"`
}

type PromotionInput struct {
	Title    string  `json:"title"`
	Body     string  `json:"body"`
	ImageURL string  `json:"image_url"`
	StartsAt *string `json:"starts_at"` // RFC3339 or nil
	EndsAt   *string `json:"ends_at"`
}

// ListActivePromotions returns promotions visible to a student right now:
// not archived, current time inside [starts_at, ends_at] (open bounds count).
func (s *Store) ListActivePromotions(ctx context.Context, studioID string) ([]Promotion, error) {
	const q = `
		SELECT id, title, COALESCE(body,''), COALESCE(image_url,''),
		       starts_at, ends_at, is_archived
		  FROM promotions
		 WHERE studio_id = ?
		   AND is_archived = 0
		   AND (starts_at IS NULL OR starts_at <= strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		   AND (ends_at   IS NULL OR ends_at   >= strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		 ORDER BY COALESCE(starts_at, created_at) DESC`
	return s.queryPromotions(ctx, q, studioID)
}

// ListAdminPromotions returns every promotion in the studio — past, future,
// archived. For the manager console.
func (s *Store) ListAdminPromotions(ctx context.Context, studioID string) ([]Promotion, error) {
	const q = `
		SELECT id, title, COALESCE(body,''), COALESCE(image_url,''),
		       starts_at, ends_at, is_archived
		  FROM promotions
		 WHERE studio_id = ?
		 ORDER BY COALESCE(starts_at, created_at) DESC`
	return s.queryPromotions(ctx, q, studioID)
}

func (s *Store) queryPromotions(ctx context.Context, q, studioID string) ([]Promotion, error) {
	rows, err := s.db.QueryContext(ctx, q, studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Promotion, 0)
	for rows.Next() {
		var (
			p            Promotion
			starts, ends sql.NullString
			archivedInt  int
		)
		if err := rows.Scan(&p.ID, &p.Title, &p.Body, &p.ImageURL,
			&starts, &ends, &archivedInt); err != nil {
			return nil, err
		}
		if starts.Valid {
			p.StartsAt = &starts.String
		}
		if ends.Valid {
			p.EndsAt = &ends.String
		}
		p.IsArchived = archivedInt != 0
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) CreatePromotion(ctx context.Context, studioID, actorID string, in PromotionInput) (string, error) {
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return "", fmt.Errorf("title is required")
	}
	if err := validatePromotionWindow(in.StartsAt, in.EndsAt); err != nil {
		return "", err
	}
	id := NewID()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO promotions (id, studio_id, title, body, image_url, starts_at, ends_at)
		     VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, studioID, title,
		nullableString(in.Body), nullableString(in.ImageURL),
		nullableTimePtr(in.StartsAt), nullableTimePtr(in.EndsAt),
	)
	if err != nil {
		return "", err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "promotion_create", "promotion", id, map[string]any{
		"title": title,
	})
	return id, nil
}

func (s *Store) UpdatePromotion(ctx context.Context, studioID, actorID, id string, in PromotionInput) error {
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return fmt.Errorf("title is required")
	}
	if err := validatePromotionWindow(in.StartsAt, in.EndsAt); err != nil {
		return err
	}
	res, err := s.db.ExecContext(ctx, `
		UPDATE promotions
		   SET title     = ?,
		       body      = ?,
		       image_url = ?,
		       starts_at = ?,
		       ends_at   = ?
		 WHERE id = ? AND studio_id = ?`,
		title,
		nullableString(in.Body), nullableString(in.ImageURL),
		nullableTimePtr(in.StartsAt), nullableTimePtr(in.EndsAt),
		id, studioID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "promotion_update", "promotion", id, map[string]any{
		"title": title,
	})
	return nil
}

// ArchivePromotion is a soft delete — keeps the row for audit but hides it
// from student-facing feeds. Admin listings still surface it with the
// is_archived flag.
func (s *Store) ArchivePromotion(ctx context.Context, studioID, actorID, id string) error {
	// Snapshot title before archiving so the audit row reads as
	// "PROMOTION ARCHIVED · Spring sale" rather than an opaque id.
	var title string
	_ = s.db.QueryRowContext(ctx,
		`SELECT title FROM promotions WHERE id = ? AND studio_id = ?`,
		id, studioID,
	).Scan(&title)
	res, err := s.db.ExecContext(ctx,
		`UPDATE promotions SET is_archived = 1 WHERE id = ? AND studio_id = ?`,
		id, studioID,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "promotion_archive", "promotion", id,
		map[string]any{"title": title})
	return nil
}

func validatePromotionWindow(starts, ends *string) error {
	if starts == nil || ends == nil {
		return nil
	}
	sT, err := time.Parse(time.RFC3339, *starts)
	if err != nil {
		return fmt.Errorf("starts_at: %w", err)
	}
	eT, err := time.Parse(time.RFC3339, *ends)
	if err != nil {
		return fmt.Errorf("ends_at: %w", err)
	}
	if !eT.After(sT) {
		return fmt.Errorf("ends_at must be after starts_at")
	}
	return nil
}

func nullableString(v string) any {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return v
}

func nullableTimePtr(v *string) any {
	if v == nil || strings.TrimSpace(*v) == "" {
		return nil
	}
	return *v
}
