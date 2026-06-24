package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// MaxMediaBytes caps a single upload. Images for splash/logos/promos are well
// under this; the limit keeps a single request from buffering an unbounded
// blob in the app server's memory (uploads pass through Go).
const MaxMediaBytes = 5 << 20 // 5 MiB

// ErrMediaStorageUnavailable is returned when an upload is attempted but no
// blob backend is wired (e.g. dev without a Storage bucket). The API maps it
// to 503 so the manager sees "image storage isn't set up" rather than a 500.
var ErrMediaStorageUnavailable = errors.New("media storage is not configured")

// MediaRejected is a client-fixable upload rejection (wrong type, too big,
// empty). Its message is safe to show; the API maps it to 400. A storage
// failure is NOT a MediaRejected — that stays a 500 so we don't leak backend
// detail or imply the manager did something wrong.
type MediaRejected struct{ Msg string }

func (e MediaRejected) Error() string { return e.Msg }

// allowedImageMIME gates uploads to real image types and maps each to the
// extension used in the storage path (purely cosmetic — helps when browsing
// the bucket).
var allowedImageMIME = map[string]string{
	"image/png":  "png",
	"image/jpeg": "jpg",
	"image/webp": "webp",
	"image/gif":  "gif",
}

// MediaRow is one library image. URL is the persisted public download URL so
// every read path renders it with a plain Image.network.
type MediaRow struct {
	ID        string `json:"id"`
	URL       string `json:"url"`
	Mime      string `json:"mime"`
	SizeBytes int    `json:"size_bytes"`
	Filename  string `json:"filename"`
	CreatedBy string `json:"created_by,omitempty"`
	CreatedAt string `json:"created_at"`
}

// UploadMedia validates the file, pushes the bytes to the blob backend, and
// records a studio-scoped `media` row. Manager-only (gated at the route);
// audited as media_upload.
func (s *Store) UploadMedia(ctx context.Context, studioID, actorID, filename, mime string, data []byte) (*MediaRow, error) {
	if s.media == nil {
		return nil, ErrMediaStorageUnavailable
	}
	if len(data) == 0 {
		return nil, MediaRejected{Msg: "empty upload"}
	}
	if len(data) > MaxMediaBytes {
		return nil, MediaRejected{Msg: fmt.Sprintf("image too large (max %d MB)", MaxMediaBytes>>20)}
	}
	ext, ok := allowedImageMIME[mime]
	if !ok {
		return nil, MediaRejected{Msg: "unsupported image type — png, jpeg, webp or gif only"}
	}

	id := NewID()
	path := fmt.Sprintf("studios/%s/media/%s.%s", studioID, id, ext)
	url, err := s.media.Put(ctx, path, mime, data)
	if err != nil {
		return nil, fmt.Errorf("store media object: %w", err)
	}

	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO media (id, studio_id, storage_path, url, mime, size_bytes, filename, created_by, created_at)
		     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, studioID, path, url, mime, len(data), filename, actorID, now,
	); err != nil {
		// Don't strand the just-uploaded object if the row insert fails.
		_ = s.media.Delete(ctx, path)
		return nil, err
	}

	_ = s.WriteAudit(ctx, studioID, actorID, "media_upload", "media", id, map[string]any{
		"filename":   filename,
		"mime":       mime,
		"size_bytes": len(data),
	})

	return &MediaRow{
		ID:        id,
		URL:       url,
		Mime:      mime,
		SizeBytes: len(data),
		Filename:  filename,
		CreatedBy: actorID,
		CreatedAt: now,
	}, nil
}

// ListMedia returns a studio's library, newest first.
func (s *Store) ListMedia(ctx context.Context, studioID string) ([]MediaRow, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, url, mime, size_bytes, COALESCE(filename,''),
		       COALESCE(created_by,''), created_at
		  FROM media
		 WHERE studio_id = ?
		 ORDER BY created_at DESC`, studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]MediaRow, 0)
	for rows.Next() {
		var m MediaRow
		if err := rows.Scan(&m.ID, &m.URL, &m.Mime, &m.SizeBytes, &m.Filename, &m.CreatedBy, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// DeleteMedia removes the row and best-effort deletes the stored object.
// We drop the row even if the object delete fails (or storage is nil) so a
// missing object can't strand a library entry. Audited as media_delete.
//
// Note: this does not rewrite places that already reference the image by URL
// (a theme's splash, say) — those keep their now-dangling URL until edited,
// same as any externally-hosted link going away.
func (s *Store) DeleteMedia(ctx context.Context, studioID, actorID, id string) error {
	var path string
	err := s.db.QueryRowContext(ctx,
		`SELECT storage_path FROM media WHERE id = ? AND studio_id = ?`,
		id, studioID,
	).Scan(&path)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if s.media != nil {
		_ = s.media.Delete(ctx, path)
	}
	if _, err := s.db.ExecContext(ctx,
		`DELETE FROM media WHERE id = ? AND studio_id = ?`, id, studioID,
	); err != nil {
		return err
	}
	_ = s.WriteAudit(ctx, studioID, actorID, "media_delete", "media", id, map[string]any{})
	return nil
}
