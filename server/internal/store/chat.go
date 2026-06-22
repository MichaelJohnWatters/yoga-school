package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ---- chat domain types ----------------------------------------------------

// Conversation is a group room or a 1:1 dm. Title is empty for dms — the
// client derives a label from the other member. LastMessage / UnreadCount
// are populated by ListConversations for the list view and left zero by
// the create/open paths (a fresh conversation has neither).
type Conversation struct {
	ID          string               `json:"id"`
	Kind        string               `json:"kind"` // group | dm
	Title       string               `json:"title"`
	CreatedBy   string               `json:"created_by"`
	CreatedAt   string               `json:"created_at"`
	Members     []ConversationMember `json:"members"`
	LastMessage *ChatMessage         `json:"last_message,omitempty"`
	UnreadCount int                  `json:"unread_count"`
}

// ConversationMember pairs a participant with their read high-water mark.
// FullName / PhotoURL / Role are denormalised from users so the client can
// render avatars + dm titles without a second round-trip.
type ConversationMember struct {
	UserID      string  `json:"user_id"`
	FullName    string  `json:"full_name"`
	PhotoURL    *string `json:"photo_url,omitempty"`
	Role        string  `json:"role"`
	LastReadSeq int     `json:"last_read_seq"`
}

// ChatMessage is a single posted message. A soft-deleted message keeps its
// row (so seq + receipts stay stable) but reports an empty Body and a
// non-nil DeletedAt; the client renders "message removed". ReadByCount is
// the number of OTHER members who have read up to this seq — the read
// receipt — and is only filled in by ListMessages.
type ChatMessage struct {
	ID             string  `json:"id"`
	ConversationID string  `json:"conversation_id"`
	Seq            int     `json:"seq"`
	SenderID       string  `json:"sender_id"`
	SenderName     string  `json:"sender_name"`
	Body           string  `json:"body"`
	CreatedAt      string  `json:"created_at"`
	EditedAt       *string `json:"edited_at,omitempty"`
	DeletedAt      *string `json:"deleted_at,omitempty"`
	ReadByCount    int     `json:"read_by_count"`
}

// Chat sentinels. The API layer maps these to 403/400 via mapStoreError.
var (
	// ErrNotMember: the caller isn't a participant in the conversation —
	// they may not read or post. Also returned (rather than ErrNotFound)
	// when the conversation doesn't exist, so we don't leak existence of
	// rooms the caller can't see.
	ErrNotMember = errors.New("not a member of this conversation")
	// ErrNotSender: edit/delete attempted on someone else's message.
	ErrNotSender = errors.New("can only edit or delete your own messages")
	// ErrEmptyMessage: blank body submitted.
	ErrEmptyMessage = errors.New("message body cannot be empty")
	// ErrNotGroup: a group-only operation (e.g. add members) hit a dm.
	ErrNotGroup = errors.New("operation is only valid on group conversations")
	// ErrInvalidMember: a member id doesn't resolve to a user in the studio.
	ErrInvalidMember = errors.New("member is not a user in this studio")
	// ErrEmptyTitle: group created without a name.
	ErrEmptyTitle = errors.New("group name is required")
	// ErrSelfDM: caller tried to dm themselves.
	ErrSelfDM = errors.New("cannot start a direct message with yourself")
	// ErrMessageTooLong: body exceeds maxMessageLen.
	ErrMessageTooLong = errors.New("message is too long")
)

// maxMessageLen caps a single message. Generous for chat; mostly a guard
// against unbounded rows. Mirrored client-side as a soft hint.
const maxMessageLen = 4000

// CreateConversation creates a named group room owned by actorID and seeds
// its membership with actor + memberIDs (deduped; the actor is always a
// member even if omitted). Staff-only at the route layer. Writes a
// conversation_create audit row in the same tx.
func (s *Store) CreateConversation(
	ctx context.Context, studioID, actorID, title string, memberIDs []string,
) (*Conversation, error) {
	title = strings.TrimSpace(title)
	if title == "" {
		return nil, ErrEmptyTitle
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	members := dedupeWithActor(actorID, memberIDs)
	if err := assertUsersInStudioTx(ctx, tx, studioID, members); err != nil {
		return nil, err
	}

	convID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO conversations (id, studio_id, kind, title, created_by)
		     VALUES (?, ?, 'group', ?, ?)`,
		convID, studioID, title, actorID,
	); err != nil {
		return nil, fmt.Errorf("insert conversation: %w", err)
	}
	for _, uid := range members {
		if err := addMemberTx(ctx, tx, convID, uid); err != nil {
			return nil, err
		}
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"conversation_create", "conversation", convID, map[string]any{
			"title":        title,
			"member_count": len(members),
		}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.conversationByID(ctx, actorID, convID)
}

// OpenDM returns the existing 1:1 dm between actorID and targetUserID, or
// creates one. Idempotent: re-opening a dm returns the same conversation
// rather than spawning duplicates. Staff-only at the route layer (the
// requireStaff gate is what enforces "staff initiate to students"; the
// store allows any same-studio target so staff can also dm each other).
// A dm_open audit row is written only when a new room is created.
func (s *Store) OpenDM(
	ctx context.Context, studioID, actorID, targetUserID string,
) (*Conversation, error) {
	if targetUserID == actorID {
		return nil, ErrSelfDM
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	if err := assertUsersInStudioTx(ctx, tx, studioID, []string{targetUserID}); err != nil {
		return nil, err
	}

	// Existing dm? A dm is the conversation of kind 'dm' that has exactly
	// these two members. Find one both users belong to.
	var existingID string
	err = tx.QueryRowContext(ctx, `
		SELECT c.id
		  FROM conversations c
		  JOIN conversation_members a ON a.conversation_id = c.id AND a.user_id = ?
		  JOIN conversation_members b ON b.conversation_id = c.id AND b.user_id = ?
		 WHERE c.kind = 'dm' AND c.studio_id = ?
		 LIMIT 1`,
		actorID, targetUserID, studioID,
	).Scan(&existingID)
	if err == nil {
		// Already exists — commit the (read-only) tx and return it. No
		// audit row: opening an existing dm isn't a mutation.
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return s.conversationByID(ctx, actorID, existingID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	convID := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO conversations (id, studio_id, kind, title, created_by)
		     VALUES (?, ?, 'dm', NULL, ?)`,
		convID, studioID, actorID,
	); err != nil {
		return nil, fmt.Errorf("insert dm: %w", err)
	}
	if err := addMemberTx(ctx, tx, convID, actorID); err != nil {
		return nil, err
	}
	if err := addMemberTx(ctx, tx, convID, targetUserID); err != nil {
		return nil, err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"dm_open", "conversation", convID, map[string]any{
			"target_user_id": targetUserID,
		}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.conversationByID(ctx, actorID, convID)
}

// AddMembers adds users to an existing group conversation (no-op for ids
// already present). Group-only; staff-only at the route layer. Writes one
// conversation_member_add audit row covering the batch.
func (s *Store) AddMembers(
	ctx context.Context, studioID, actorID, conversationID string, memberIDs []string,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	kind, _, err := conversationKindTx(ctx, tx, studioID, conversationID)
	if err != nil {
		return err
	}
	if kind != "group" {
		return ErrNotGroup
	}
	// The actor must be a member to manage the room.
	if ok, err := isMemberTx(ctx, tx, conversationID, actorID); err != nil {
		return err
	} else if !ok {
		return ErrNotMember
	}

	members := dedupe(memberIDs)
	if err := assertUsersInStudioTx(ctx, tx, studioID, members); err != nil {
		return err
	}
	for _, uid := range members {
		if err := addMemberTx(ctx, tx, conversationID, uid); err != nil {
			return err
		}
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"conversation_member_add", "conversation", conversationID, map[string]any{
			"added": members,
		}); err != nil {
		return err
	}
	return tx.Commit()
}

// SendMessage posts body to a conversation the caller is a member of. It
// assigns the next per-conversation seq (MAX+1) inside the tx, guarded by
// uq_messages_conv_seq, and retries on the unique-violation a concurrent
// sender can cause under Postgres' looser write concurrency. The sender's
// own last_read_seq advances to the new message (you've "read" what you
// just sent). A message_send audit row is written in the same tx.
func (s *Store) SendMessage(
	ctx context.Context, studioID, userID, conversationID, body string,
) (*ChatMessage, error) {
	body = strings.TrimSpace(body)
	if body == "" {
		return nil, ErrEmptyMessage
	}
	if len(body) > maxMessageLen {
		return nil, ErrMessageTooLong
	}

	const maxAttempts = 5
	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		msg, err := s.trySendMessage(ctx, studioID, userID, conversationID, body)
		if err == nil {
			return msg, nil
		}
		if isUniqueViolation(err) {
			// A concurrent sender grabbed the same seq. Recompute + retry.
			lastErr = err
			continue
		}
		return nil, err
	}
	return nil, fmt.Errorf("send message: exhausted seq retries: %w", lastErr)
}

func (s *Store) trySendMessage(
	ctx context.Context, studioID, userID, conversationID, body string,
) (*ChatMessage, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	if ok, err := isMemberTx(ctx, tx, conversationID, userID); err != nil {
		return nil, err
	} else if !ok {
		return nil, ErrNotMember
	}

	var maxSeq sql.NullInt64
	if err := tx.QueryRowContext(ctx,
		`SELECT MAX(seq) FROM messages WHERE conversation_id = ?`, conversationID,
	).Scan(&maxSeq); err != nil {
		return nil, err
	}
	seq := 1
	if maxSeq.Valid {
		seq = int(maxSeq.Int64) + 1
	}

	id := NewID()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO messages (id, conversation_id, seq, sender_id, body)
		     VALUES (?, ?, ?, ?, ?)`,
		id, conversationID, seq, userID, body,
	); err != nil {
		return nil, fmt.Errorf("insert message: %w", err)
	}
	// Sender has implicitly read their own message.
	if _, err := tx.ExecContext(ctx, `
		UPDATE conversation_members SET last_read_seq = ?
		 WHERE conversation_id = ? AND user_id = ? AND last_read_seq < ?`,
		seq, conversationID, userID, seq,
	); err != nil {
		return nil, err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"message_send", "message", id, map[string]any{
			"conversation_id": conversationID,
			"seq":             seq,
			// Body intentionally omitted — the audit log is visible to
			// managers; we record that a message was sent, not its content.
		}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}

	var name string
	_ = s.db.QueryRowContext(ctx, `SELECT full_name FROM users WHERE id = ?`, userID).Scan(&name)
	var created string
	_ = s.db.QueryRowContext(ctx, `SELECT created_at FROM messages WHERE id = ?`, id).Scan(&created)
	return &ChatMessage{
		ID:             id,
		ConversationID: conversationID,
		Seq:            seq,
		SenderID:       userID,
		SenderName:     name,
		Body:           body,
		CreatedAt:      created,
	}, nil
}

// EditMessage rewrites the body of the caller's own live message and stamps
// edited_at. Refuses (ErrNotSender) on another user's message and
// (ErrNotFound) on a missing or already-deleted one. Audited as
// message_edit.
func (s *Store) EditMessage(
	ctx context.Context, studioID, userID, conversationID, messageID, body string,
) (*ChatMessage, error) {
	body = strings.TrimSpace(body)
	if body == "" {
		return nil, ErrEmptyMessage
	}
	if len(body) > maxMessageLen {
		return nil, ErrMessageTooLong
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	sender, err := messageSenderTx(ctx, tx, conversationID, messageID)
	if err != nil {
		return nil, err
	}
	if sender != userID {
		return nil, ErrNotSender
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE messages
		   SET body = ?, edited_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ? AND deleted_at IS NULL`,
		body, messageID,
	); err != nil {
		return nil, err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"message_edit", "message", messageID, map[string]any{
			"conversation_id": conversationID,
		}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.messageByID(ctx, messageID)
}

// DeleteMessage soft-deletes the caller's own message: body is blanked and
// deleted_at stamped, but the row (and its seq) stays so numbering and read
// receipts don't shift. Audited as message_delete.
func (s *Store) DeleteMessage(
	ctx context.Context, studioID, userID, conversationID, messageID string,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	sender, err := messageSenderTx(ctx, tx, conversationID, messageID)
	if err != nil {
		return err
	}
	if sender != userID {
		return ErrNotSender
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE messages
		   SET body = '', deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE id = ? AND deleted_at IS NULL`,
		messageID,
	); err != nil {
		return err
	}
	if err := s.writeAuditTx(ctx, tx, studioID, userID,
		"message_delete", "message", messageID, map[string]any{
			"conversation_id": conversationID,
		}); err != nil {
		return err
	}
	return tx.Commit()
}

// MarkConversationRead advances the caller's last_read_seq to upToSeq (a
// no-op when they're already at or beyond it — the WHERE guard keeps it
// monotonic so a stale client can't roll the marker backwards). Not
// audited: read tracking is high-frequency, driven by polling, and carries
// no managerial significance — mirrors the unaudited notification reads.
func (s *Store) MarkConversationRead(
	ctx context.Context, userID, conversationID string, upToSeq int,
) error {
	res, err := s.db.ExecContext(ctx, `
		UPDATE conversation_members
		   SET last_read_seq = ?
		 WHERE conversation_id = ? AND user_id = ? AND last_read_seq < ?`,
		upToSeq, conversationID, userID, upToSeq,
	)
	if err != nil {
		return err
	}
	// RowsAffected==0 is fine (already read up to here). But if the caller
	// isn't a member at all we want ErrNotMember, not a silent success.
	if n, _ := res.RowsAffected(); n == 0 {
		ok, err := s.isMember(ctx, conversationID, userID)
		if err != nil {
			return err
		}
		if !ok {
			return ErrNotMember
		}
	}
	return nil
}

// ListConversations returns every conversation the caller belongs to, newest
// activity first, each hydrated with its members, last message, and the
// caller's unread count. Empty conversations sort by their creation time.
func (s *Store) ListConversations(
	ctx context.Context, studioID, userID string,
) ([]Conversation, error) {
	const q = `
		SELECT c.id, c.kind, COALESCE(c.title,''), c.created_by, c.created_at,
		       cm.last_read_seq,
		       (SELECT COUNT(*) FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.seq > cm.last_read_seq
		           AND m.deleted_at IS NULL) AS unread,
		       COALESCE((SELECT MAX(m2.created_at) FROM messages m2
		                  WHERE m2.conversation_id = c.id), c.created_at) AS last_activity
		  FROM conversations c
		  JOIN conversation_members cm
		    ON cm.conversation_id = c.id AND cm.user_id = ?
		 WHERE c.studio_id = ?
		 ORDER BY last_activity DESC`
	rows, err := s.db.QueryContext(ctx, q, userID, studioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Conversation, 0)
	for rows.Next() {
		var (
			c           Conversation
			lastReadSeq int
			lastAct     string
		)
		if err := rows.Scan(&c.ID, &c.Kind, &c.Title, &c.CreatedBy, &c.CreatedAt,
			&lastReadSeq, &c.UnreadCount, &lastAct); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Hydrate members + last message per conversation. N+1 but N is the
	// number of rooms one user is in — small. Revisit with a join if a
	// power user ever lands in hundreds of rooms.
	for i := range out {
		members, err := s.loadMembers(ctx, out[i].ID)
		if err != nil {
			return nil, err
		}
		out[i].Members = members
		last, err := s.loadLastMessage(ctx, out[i].ID)
		if err != nil {
			return nil, err
		}
		out[i].LastMessage = last
	}
	return out, nil
}

// ListMessages returns a page of messages for a conversation the caller is
// a member of, ordered oldest→newest. Keyset paginated:
//   - beforeSeq > 0: messages with seq < beforeSeq (scroll back into history)
//   - afterSeq  > 0: messages with seq > afterSeq  (the poll for new ones)
//   - neither: the most recent `limit` messages
//
// limit is clamped to [1,100] (default 30). ReadByCount is filled per row.
func (s *Store) ListMessages(
	ctx context.Context, userID, conversationID string, beforeSeq, afterSeq, limit int,
) ([]ChatMessage, error) {
	if ok, err := s.isMember(ctx, conversationID, userID); err != nil {
		return nil, err
	} else if !ok {
		return nil, ErrNotMember
	}
	if limit <= 0 || limit > 100 {
		limit = 30
	}

	// "Read by" = members (excluding the sender) whose last_read_seq has
	// reached this message's seq.
	const cols = `
		SELECT m.id, m.conversation_id, m.seq, m.sender_id, u.full_name,
		       CASE WHEN m.deleted_at IS NULL THEN m.body ELSE '' END,
		       m.created_at, m.edited_at, m.deleted_at,
		       (SELECT COUNT(*) FROM conversation_members cm
		         WHERE cm.conversation_id = m.conversation_id
		           AND cm.user_id != m.sender_id
		           AND cm.last_read_seq >= m.seq) AS read_by
		  FROM messages m
		  JOIN users u ON u.id = m.sender_id
		 WHERE m.conversation_id = ?`

	var (
		q    string
		args []any
	)
	switch {
	case afterSeq > 0:
		// Ascending; the poll wants everything newer in order.
		q = cols + ` AND m.seq > ? ORDER BY m.seq ASC LIMIT ?`
		args = []any{conversationID, afterSeq, limit}
	case beforeSeq > 0:
		// Grab the newest `limit` rows below the cursor, then flip to
		// ascending so the caller always gets oldest→newest.
		q = `SELECT * FROM (` + cols +
			` AND m.seq < ? ORDER BY m.seq DESC LIMIT ?) ORDER BY seq ASC`
		args = []any{conversationID, beforeSeq, limit}
	default:
		q = `SELECT * FROM (` + cols +
			` ORDER BY m.seq DESC LIMIT ?) ORDER BY seq ASC`
		args = []any{conversationID, limit}
	}

	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanMessages(rows)
}

// ---- internal helpers -----------------------------------------------------

func scanMessages(rows *sql.Rows) ([]ChatMessage, error) {
	out := make([]ChatMessage, 0)
	for rows.Next() {
		var (
			m        ChatMessage
			editedAt sql.NullString
			delAt    sql.NullString
		)
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.Seq, &m.SenderID,
			&m.SenderName, &m.Body, &m.CreatedAt, &editedAt, &delAt,
			&m.ReadByCount); err != nil {
			return nil, err
		}
		if editedAt.Valid {
			m.EditedAt = &editedAt.String
		}
		if delAt.Valid {
			m.DeletedAt = &delAt.String
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Store) loadMembers(ctx context.Context, conversationID string) ([]ConversationMember, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT cm.user_id, u.full_name, u.photo_url, u.role, cm.last_read_seq
		  FROM conversation_members cm
		  JOIN users u ON u.id = cm.user_id
		 WHERE cm.conversation_id = ?
		 ORDER BY cm.joined_at ASC`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ConversationMember, 0)
	for rows.Next() {
		var (
			m     ConversationMember
			photo sql.NullString
		)
		if err := rows.Scan(&m.UserID, &m.FullName, &photo, &m.Role, &m.LastReadSeq); err != nil {
			return nil, err
		}
		if photo.Valid {
			m.PhotoURL = &photo.String
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// loadLastMessage returns the highest-seq message (deleted or not) so the
// list preview can show "message removed" rather than skipping to an older
// live one. Nil when the conversation has no messages yet.
func (s *Store) loadLastMessage(ctx context.Context, conversationID string) (*ChatMessage, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.id, m.conversation_id, m.seq, m.sender_id, u.full_name,
		       CASE WHEN m.deleted_at IS NULL THEN m.body ELSE '' END,
		       m.created_at, m.edited_at, m.deleted_at, 0
		  FROM messages m
		  JOIN users u ON u.id = m.sender_id
		 WHERE m.conversation_id = ?
		 ORDER BY m.seq DESC LIMIT 1`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	msgs, err := scanMessages(rows)
	if err != nil {
		return nil, err
	}
	if len(msgs) == 0 {
		return nil, nil
	}
	return &msgs[0], nil
}

func (s *Store) conversationByID(ctx context.Context, userID, conversationID string) (*Conversation, error) {
	var c Conversation
	err := s.db.QueryRowContext(ctx, `
		SELECT id, kind, COALESCE(title,''), created_by, created_at
		  FROM conversations WHERE id = ?`, conversationID,
	).Scan(&c.ID, &c.Kind, &c.Title, &c.CreatedBy, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	members, err := s.loadMembers(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	c.Members = members
	last, err := s.loadLastMessage(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	c.LastMessage = last
	return &c, nil
}

func (s *Store) messageByID(ctx context.Context, messageID string) (*ChatMessage, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.id, m.conversation_id, m.seq, m.sender_id, u.full_name,
		       CASE WHEN m.deleted_at IS NULL THEN m.body ELSE '' END,
		       m.created_at, m.edited_at, m.deleted_at,
		       (SELECT COUNT(*) FROM conversation_members cm
		         WHERE cm.conversation_id = m.conversation_id
		           AND cm.user_id != m.sender_id
		           AND cm.last_read_seq >= m.seq)
		  FROM messages m
		  JOIN users u ON u.id = m.sender_id
		 WHERE m.id = ?`, messageID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	msgs, err := scanMessages(rows)
	if err != nil {
		return nil, err
	}
	if len(msgs) == 0 {
		return nil, ErrNotFound
	}
	return &msgs[0], nil
}

func (s *Store) isMember(ctx context.Context, conversationID, userID string) (bool, error) {
	var one int
	err := s.db.QueryRowContext(ctx, `
		SELECT 1 FROM conversation_members
		 WHERE conversation_id = ? AND user_id = ? LIMIT 1`,
		conversationID, userID,
	).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func isMemberTx(ctx context.Context, tx *sql.Tx, conversationID, userID string) (bool, error) {
	var one int
	err := tx.QueryRowContext(ctx, `
		SELECT 1 FROM conversation_members
		 WHERE conversation_id = ? AND user_id = ? LIMIT 1`,
		conversationID, userID,
	).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// addMemberTx inserts a membership row, ignoring a re-add of an existing
// member (INSERT OR IGNORE on the composite PK).
func addMemberTx(ctx context.Context, tx *sql.Tx, conversationID, userID string) error {
	_, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO conversation_members (conversation_id, user_id)
		     VALUES (?, ?)`,
		conversationID, userID,
	)
	return err
}

// conversationKindTx fetches a conversation's kind + studio, scoped to the
// given studio. ErrNotFound when it doesn't exist in that studio.
func conversationKindTx(ctx context.Context, tx *sql.Tx, studioID, conversationID string) (kind, owner string, err error) {
	err = tx.QueryRowContext(ctx, `
		SELECT kind, created_by FROM conversations
		 WHERE id = ? AND studio_id = ?`,
		conversationID, studioID,
	).Scan(&kind, &owner)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrNotFound
	}
	return kind, owner, err
}

// messageSenderTx returns the sender of a live (non-deleted) message that
// belongs to the named conversation. ErrNotFound when missing, deleted, or
// in a different conversation.
func messageSenderTx(ctx context.Context, tx *sql.Tx, conversationID, messageID string) (string, error) {
	var sender string
	err := tx.QueryRowContext(ctx, `
		SELECT sender_id FROM messages
		 WHERE id = ? AND conversation_id = ? AND deleted_at IS NULL`,
		messageID, conversationID,
	).Scan(&sender)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return sender, err
}

// assertUsersInStudioTx fails with ErrInvalidMember unless every id is a
// user in the given studio. An empty list passes.
func assertUsersInStudioTx(ctx context.Context, tx *sql.Tx, studioID string, ids []string) error {
	for _, id := range ids {
		var one int
		err := tx.QueryRowContext(ctx,
			`SELECT 1 FROM users WHERE id = ? AND studio_id = ?`, id, studioID,
		).Scan(&one)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrInvalidMember
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func dedupe(ids []string) []string {
	seen := make(map[string]bool, len(ids))
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, id)
	}
	return out
}

func dedupeWithActor(actorID string, ids []string) []string {
	return dedupe(append([]string{actorID}, ids...))
}

// isUniqueViolation reports whether err is a UNIQUE/primary-key constraint
// failure. Matches both the SQLite driver's text ("UNIQUE constraint
// failed") and Postgres' ("duplicate key value violates unique" / SQLSTATE
// 23505) so the SendMessage retry loop works against either backend.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	s := strings.ToLower(err.Error())
	return strings.Contains(s, "unique constraint") ||
		strings.Contains(s, "duplicate key") ||
		strings.Contains(s, "23505")
}
