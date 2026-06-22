package store

// UK GDPR data-subject rights: Right of Access / Portability (Art. 15 & 20)
// and Right to Erasure (Art. 17). ExportUserData assembles everything we hold
// about one person into a machine-readable bundle; EraseUser pseudonymises
// that same person while keeping the financial + audit skeletons the law
// requires us to retain (see docs/data-retention.md).

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// SubjectExport is the full Art. 15 / 20 bundle for one user. Every category
// of personal data we store is represented; the handler serialises this to
// JSON and hands it to the studio as the subject-access response.
type SubjectExport struct {
	GeneratedAt   string                  `json:"generated_at"`
	Profile       SubjectProfile          `json:"profile"`
	Entitlements  []EntitlementWalletItem `json:"entitlements"`
	Purchases     []MyPurchase            `json:"purchases"`
	Bookings      []ExportBooking         `json:"bookings"`
	Waitlist      []ExportWaitlistEntry   `json:"waitlist"`
	Achievements  []ExportAchievement     `json:"achievements"`
	Notifications []ExportNotification    `json:"notifications"`
	Messages      []ExportMessage         `json:"messages"`
	Conversations []ExportConversation    `json:"conversations"`
}

type SubjectProfile struct {
	ID            string  `json:"id"`
	FullName      string  `json:"full_name"`
	Email         string  `json:"email"`
	PhotoURL      *string `json:"photo_url,omitempty"`
	Role          string  `json:"role"`
	ThemeModePref string  `json:"theme_mode_pref"`
	CreatedAt     string  `json:"created_at"`
}

type ExportBooking struct {
	ID          string  `json:"id"`
	ClassID     string  `json:"class_id"`
	ClassTitle  string  `json:"class_title"`
	StartsAt    string  `json:"starts_at"`
	Status      string  `json:"status"`
	IsPlusOne   bool    `json:"is_plus_one"`
	PlusOneName *string `json:"plus_one_name,omitempty"`
	Outcome     *string `json:"outcome,omitempty"`
	CreatedAt   string  `json:"created_at"`
}

type ExportWaitlistEntry struct {
	ClassID   string `json:"class_id"`
	Position  int    `json:"position"`
	Status    string `json:"status"`
	CreatedAt string `json:"created_at"`
}

type ExportAchievement struct {
	BadgeKey string `json:"badge_key"`
	EarnedAt string `json:"earned_at"`
}

type ExportNotification struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	CreatedAt string `json:"created_at"`
}

type ExportMessage struct {
	ConversationID string `json:"conversation_id"`
	Body           string `json:"body"`
	CreatedAt      string `json:"created_at"`
	EditedAt       string `json:"edited_at,omitempty"`
}

type ExportConversation struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"`
	Title    string `json:"title,omitempty"`
	JoinedAt string `json:"joined_at"`
}

// ExportUserData gathers every category of personal data we hold about a user.
// Read-only — reuses the same wallet/booking read-models the user sees in the
// app plus direct reads for the categories that have no existing surface
// (waitlist history, sent messages, conversation membership). studioID scopes
// the lookup so one studio's manager can't export another tenant's subject.
func (s *Store) ExportUserData(ctx context.Context, studioID, userID string) (*SubjectExport, error) {
	out := &SubjectExport{GeneratedAt: time.Now().UTC().Format(time.RFC3339)}

	var photo sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT id, full_name, email, photo_url, role, theme_mode_pref, created_at
		  FROM users WHERE id = ? AND studio_id = ? AND erased_at IS NULL`,
		userID, studioID,
	).Scan(&out.Profile.ID, &out.Profile.FullName, &out.Profile.Email, &photo,
		&out.Profile.Role, &out.Profile.ThemeModePref, &out.Profile.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if photo.Valid {
		out.Profile.PhotoURL = &photo.String
	}

	if out.Entitlements, err = s.MyEntitlements(ctx, userID); err != nil {
		return nil, fmt.Errorf("export entitlements: %w", err)
	}
	if out.Purchases, err = s.MyPurchases(ctx, userID); err != nil {
		return nil, fmt.Errorf("export purchases: %w", err)
	}

	if out.Bookings, err = s.exportBookings(ctx, studioID, userID); err != nil {
		return nil, fmt.Errorf("export bookings: %w", err)
	}
	if out.Waitlist, err = s.exportWaitlist(ctx, userID); err != nil {
		return nil, fmt.Errorf("export waitlist: %w", err)
	}
	if out.Achievements, err = s.exportAchievements(ctx, userID); err != nil {
		return nil, fmt.Errorf("export achievements: %w", err)
	}
	if out.Notifications, err = s.exportNotifications(ctx, userID); err != nil {
		return nil, fmt.Errorf("export notifications: %w", err)
	}
	if out.Messages, err = s.exportMessages(ctx, userID); err != nil {
		return nil, fmt.Errorf("export messages: %w", err)
	}
	if out.Conversations, err = s.exportConversations(ctx, userID); err != nil {
		return nil, fmt.Errorf("export conversations: %w", err)
	}
	return out, nil
}

func (s *Store) exportBookings(ctx context.Context, studioID, userID string) ([]ExportBooking, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT b.id, b.class_id, COALESCE(NULLIF(c.title,''), ct.name),
		       c.starts_at, b.status, b.is_plus_one, b.plus_one_name,
		       b.outcome, b.created_at
		  FROM bookings b
		  JOIN classes c     ON c.id = b.class_id
		  JOIN class_types ct ON ct.id = c.class_type_id
		 WHERE b.user_id = ? AND b.studio_id = ?
		 ORDER BY c.starts_at DESC`,
		userID, studioID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ExportBooking, 0)
	for rows.Next() {
		var (
			b                ExportBooking
			plusOne, outcome sql.NullString
			isPlusOne        int
		)
		if err := rows.Scan(&b.ID, &b.ClassID, &b.ClassTitle, &b.StartsAt,
			&b.Status, &isPlusOne, &plusOne, &outcome, &b.CreatedAt); err != nil {
			return nil, err
		}
		b.IsPlusOne = isPlusOne != 0
		if plusOne.Valid {
			b.PlusOneName = &plusOne.String
		}
		if outcome.Valid {
			b.Outcome = &outcome.String
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (s *Store) exportWaitlist(ctx context.Context, userID string) ([]ExportWaitlistEntry, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT class_id, position, status, created_at
		  FROM waitlist_entries WHERE user_id = ?
		 ORDER BY created_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ExportWaitlistEntry, 0)
	for rows.Next() {
		var e ExportWaitlistEntry
		if err := rows.Scan(&e.ClassID, &e.Position, &e.Status, &e.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Store) exportAchievements(ctx context.Context, userID string) ([]ExportAchievement, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT badge_key, earned_at FROM achievements WHERE user_id = ?
		 ORDER BY earned_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ExportAchievement, 0)
	for rows.Next() {
		var a ExportAchievement
		if err := rows.Scan(&a.BadgeKey, &a.EarnedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (s *Store) exportNotifications(ctx context.Context, userID string) ([]ExportNotification, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT type, title, COALESCE(body,''), created_at
		  FROM notifications WHERE user_id = ?
		 ORDER BY created_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ExportNotification, 0)
	for rows.Next() {
		var n ExportNotification
		if err := rows.Scan(&n.Type, &n.Title, &n.Body, &n.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

func (s *Store) exportMessages(ctx context.Context, userID string) ([]ExportMessage, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT conversation_id, body, created_at, COALESCE(edited_at,'')
		  FROM messages
		 WHERE sender_id = ? AND deleted_at IS NULL
		 ORDER BY created_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ExportMessage, 0)
	for rows.Next() {
		var m ExportMessage
		if err := rows.Scan(&m.ConversationID, &m.Body, &m.CreatedAt, &m.EditedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Store) exportConversations(ctx context.Context, userID string) ([]ExportConversation, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT c.id, c.kind, COALESCE(c.title,''), m.joined_at
		  FROM conversation_members m
		  JOIN conversations c ON c.id = m.conversation_id
		 WHERE m.user_id = ?
		 ORDER BY m.joined_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ExportConversation, 0)
	for rows.Next() {
		var c ExportConversation
		if err := rows.Scan(&c.ID, &c.Kind, &c.Title, &c.JoinedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// EraseResult carries what the handler needs after the DB transaction commits.
// FirebaseUID is the (now-cleared) external auth id so the handler can delete
// the matching Firebase Auth account — that holds the email separately and
// must be removed for the erasure to be complete.
type EraseResult struct {
	FirebaseUID string
}

// auditPIIKeys are the detail-JSON keys that can hold a person's identifying
// data. On erasure their values are overwritten with the erasedTombstone in
// every audit row that references the subject — the row, action, actor and
// timestamp survive (accountability), the PII does not (data minimisation).
var auditPIIKeys = []string{
	"email", "name", "full_name", "student_name",
	"plus_one_name", "friend_name", "note",
}

const erasedTombstone = "[erased]"

// EraseUser fulfils a UK GDPR Art. 17 erasure request by pseudonymising a
// student rather than deleting them: the user row stays (financial + audit
// records reference user_id and must be retained — HMRC 6yr / accountability),
// but every column and related row that identifies the person is tombstoned,
// scrubbed, or deleted. See docs/data-retention.md for the per-category basis.
//
// All DB work runs in one transaction so the erasure is atomic. The caller
// deletes the Firebase Auth account afterwards using the returned UID.
func (s *Store) EraseUser(ctx context.Context, studioID, actorID, userID string) (*EraseResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Lock onto a live student row. Already-erased or non-student ids fall
	// through to ErrNotFound so erasure is idempotent and can't be aimed at
	// staff (whose created_by references need a different, manual process).
	var fbUID sql.NullString
	err = tx.QueryRowContext(ctx, `
		SELECT firebase_uid FROM users
		 WHERE id = ? AND studio_id = ? AND role = 'student' AND erased_at IS NULL`,
		userID, studioID,
	).Scan(&fbUID)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// 1. Tombstone the anchor row. The id-derived email keeps UNIQUE
	//    (studio_id, email) satisfied and the NOT NULL constraint happy; the
	//    .invalid TLD (RFC 2606) can never collide with a real address.
	tombstoneEmail := fmt.Sprintf("erased+%s@deleted.invalid", userID)
	if _, err := tx.ExecContext(ctx, `
		UPDATE users
		   SET email = ?, full_name = ?, photo_url = NULL, firebase_uid = NULL,
		       erased_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ?`,
		tombstoneEmail, erasedTombstone, userID,
	); err != nil {
		return nil, err
	}

	// 2. Scrub chat message bodies they authored (reuses the soft-delete
	//    semantics: blank body + deleted_at stamp keeps seq/receipts intact
	//    while the client renders "message removed").
	if _, err := tx.ExecContext(ctx, `
		UPDATE messages
		   SET body = '', deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE sender_id = ? AND deleted_at IS NULL`,
		userID,
	); err != nil {
		return nil, err
	}

	// 3. Scrub the +1 guest names they declared — that's a *third party's*
	//    personal data carried on this user's bookings.
	if _, err := tx.ExecContext(ctx, `
		UPDATE bookings SET plus_one_name = ?
		 WHERE user_id = ? AND plus_one_name IS NOT NULL`,
		erasedTombstone, userID,
	); err != nil {
		return nil, err
	}

	// 4. Drop free-text refund notes on their purchases (the money figures
	//    stay for HMRC; the note may name them).
	if _, err := tx.ExecContext(ctx, `
		UPDATE purchases SET refund_note = NULL
		 WHERE user_id = ? AND refund_note IS NOT NULL`,
		userID,
	); err != nil {
		return nil, err
	}

	// 5. Redact PII from audit_log detail blobs that reference the subject —
	//    as actor, as target, or named inside the JSON (detail.student_id).
	if err := redactAuditPII(ctx, tx, studioID, userID); err != nil {
		return nil, err
	}

	// 6. Delete the purely transient / device-bound categories outright —
	//    nothing legal requires their retention.
	for _, stmt := range []string{
		`DELETE FROM notifications     WHERE user_id = ?`,
		`DELETE FROM device_tokens     WHERE user_id = ?`,
		`DELETE FROM notification_prefs WHERE user_id = ?`,
		`DELETE FROM achievements      WHERE user_id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, stmt, userID); err != nil {
			return nil, err
		}
	}

	// 7. Record that the erasure happened (accountability). Detail is PII-free
	//    by construction — just the categories actioned.
	if err := s.writeAuditTx(ctx, tx, studioID, actorID, "user_erased", "user", userID, map[string]any{
		"basis": "gdpr_art17_erasure",
	}); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	res := &EraseResult{}
	if fbUID.Valid {
		res.FirebaseUID = fbUID.String
	}
	return res, nil
}

// redactAuditPII overwrites known PII keys in the detail JSON of every audit
// row touching the subject. Bounded to one studio's log; for a studio-scale
// deployment that's a small, one-off scan. The detail LIKE catches rows where
// the user is named in the body (e.g. detail.student_id) but isn't the actor
// or target_id.
func redactAuditPII(ctx context.Context, tx *sql.Tx, studioID, userID string) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT id, detail FROM audit_log
		 WHERE studio_id = ?
		   AND (actor_id = ? OR target_id = ? OR detail LIKE ?)`,
		studioID, userID, userID, "%"+userID+"%",
	)
	if err != nil {
		return err
	}
	type redaction struct{ id, detail string }
	var pending []redaction
	for rows.Next() {
		var id, detailJSON string
		if err := rows.Scan(&id, &detailJSON); err != nil {
			rows.Close()
			return err
		}
		var detail map[string]any
		if err := json.Unmarshal([]byte(detailJSON), &detail); err != nil {
			continue // non-object / malformed detail — nothing keyed to redact
		}
		changed := false
		for _, k := range auditPIIKeys {
			if _, ok := detail[k]; ok {
				detail[k] = erasedTombstone
				changed = true
			}
		}
		if !changed {
			continue
		}
		b, err := json.Marshal(detail)
		if err != nil {
			rows.Close()
			return err
		}
		pending = append(pending, redaction{id, string(b)})
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	for _, p := range pending {
		if _, err := tx.ExecContext(ctx,
			`UPDATE audit_log SET detail = ? WHERE id = ?`, p.detail, p.id,
		); err != nil {
			return err
		}
	}
	return nil
}
