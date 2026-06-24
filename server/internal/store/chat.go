package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// rowQuerier is the subset of *sql.DB / *sql.Tx the label + schedule helpers
// need, so they work both inside a transaction (fan-out) and on the bare
// connection (conversation hydration).
type rowQuerier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// ---- chat domain types ----------------------------------------------------

// Conversation is one of: a staff-created group room, a 1:1 dm, or a class
// chat auto-bound to a recurrence series (or a one-off class) where the
// member set is computed at read time from bookings ∪ waitlist ∪ instructor
// ∪ studio staff. Title is empty for dm + class — the client derives a
// label from the anchor. LastMessage / UnreadCount are populated by
// ListConversations and left zero by the create/open paths.
type Conversation struct {
	ID               string               `json:"id"`
	Kind             string               `json:"kind"` // group | dm | class
	Title            string               `json:"title"`
	RecurrenceRuleID *string              `json:"recurrence_rule_id,omitempty"`
	ClassID          *string              `json:"class_id,omitempty"`
	Archived         bool                 `json:"archived"`
	CreatedBy        string               `json:"created_by"`
	CreatedAt        string               `json:"created_at"`
	Members          []ConversationMember `json:"members"`
	// MemberCount is the size of the full membership set, independent of
	// what Members carries. We redact Members for students viewing a
	// class chat (privacy: they don't get to see who else is booked /
	// waitlisted), but the count is fine to expose so the client can
	// still render "N members" in the header.
	MemberCount int          `json:"member_count"`
	LastMessage *ChatMessage `json:"last_message,omitempty"`
	UnreadCount int          `json:"unread_count"`
	// ClassSchedule + ClassStartsAt summarise *when* a class chat is about,
	// for the header at the top of the thread. Both nil for group/dm.
	//   - ClassSchedule: the recurring pattern in studio wall-clock time
	//     (e.g. "Tuesdays · 7:00am", "Mon & Wed · 6:30pm"). Set only for a
	//     series-anchored chat; nil for a one-off.
	//   - ClassStartsAt: a concrete instance timestamp (UTC) the client
	//     formats in local time — the next upcoming instance for a series
	//     (most recent past if none upcoming), or the single class's start
	//     for a one-off.
	ClassSchedule *string `json:"class_schedule,omitempty"`
	ClassStartsAt *string `json:"class_starts_at,omitempty"`
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

// OpenOrCreateClassConversation returns the class chat for classID, creating
// it lazily on first open. For a class with a recurrence_rule_id the chat is
// anchored at the series; otherwise (a one-off class) at the single class
// row. The caller must be eligible (booked, waitlisted, instructor of any
// matching class, or staff in the studio) — otherwise ErrNotMember.
//
// Idempotent: re-opening the same anchor returns the existing conversation.
// A class_chat_create audit row is written only on the create branch.
func (s *Store) OpenOrCreateClassConversation(
	ctx context.Context, studioID, actorID, classID string,
) (*Conversation, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Resolve the class so we know which anchor to use. Scope to studio so
	// a cross-studio classID returns ErrNotFound rather than leaking.
	var (
		clsStudio  string
		recRule    sql.NullString
		clsID      = classID
	)
	err = tx.QueryRowContext(ctx, `
		SELECT studio_id, recurrence_rule_id FROM classes
		 WHERE id = ? AND studio_id = ?`,
		classID, studioID,
	).Scan(&clsStudio, &recRule)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// Anchor: prefer the recurrence series for repeating classes (so all
	// instances share one chat); fall back to the single class row.
	var (
		anchorRecRule sql.NullString
		anchorClassID sql.NullString
	)
	if recRule.Valid && recRule.String != "" {
		anchorRecRule = recRule
	} else {
		anchorClassID = sql.NullString{String: clsID, Valid: true}
	}

	// Eligibility on the anchor (the conversation doesn't exist yet so we
	// can't reuse classEligibilitySQL which references c.*). Same shape;
	// just inlined with explicit params.
	var eligible bool
	if anchorRecRule.Valid {
		err = tx.QueryRowContext(ctx, `
			SELECT EXISTS (SELECT 1 FROM users u
			                WHERE u.id = ? AND u.studio_id = ?
			                  AND u.role IN ('instructor','manager','owner'))
			    OR EXISTS (SELECT 1 FROM bookings b
			                 JOIN classes cl ON cl.id = b.class_id
			                WHERE b.user_id = ?
			                  AND b.status IN ('booked','attended','no_show')
			                  AND cl.recurrence_rule_id = ?)
			    OR EXISTS (SELECT 1 FROM waitlist_entries w
			                 JOIN classes cl ON cl.id = w.class_id
			                WHERE w.user_id = ? AND w.status = 'waiting'
			                  AND cl.recurrence_rule_id = ?)
			    OR EXISTS (SELECT 1 FROM classes cl
			                WHERE cl.instructor_id = ?
			                  AND cl.recurrence_rule_id = ?)`,
			actorID, studioID,
			actorID, anchorRecRule.String,
			actorID, anchorRecRule.String,
			actorID, anchorRecRule.String,
		).Scan(&eligible)
	} else {
		err = tx.QueryRowContext(ctx, `
			SELECT EXISTS (SELECT 1 FROM users u
			                WHERE u.id = ? AND u.studio_id = ?
			                  AND u.role IN ('instructor','manager','owner'))
			    OR EXISTS (SELECT 1 FROM bookings
			                WHERE user_id = ? AND class_id = ?
			                  AND status IN ('booked','attended','no_show'))
			    OR EXISTS (SELECT 1 FROM waitlist_entries
			                WHERE user_id = ? AND class_id = ? AND status = 'waiting')
			    OR EXISTS (SELECT 1 FROM classes
			                WHERE id = ? AND instructor_id = ?)`,
			actorID, studioID,
			actorID, anchorClassID.String,
			actorID, anchorClassID.String,
			anchorClassID.String, actorID,
		).Scan(&eligible)
	}
	if err != nil {
		return nil, err
	}
	if !eligible {
		return nil, ErrNotMember
	}

	// Existing chat for this anchor?
	var existingID string
	if anchorRecRule.Valid {
		err = tx.QueryRowContext(ctx, `
			SELECT id FROM conversations
			 WHERE kind = 'class' AND recurrence_rule_id = ?`,
			anchorRecRule.String,
		).Scan(&existingID)
	} else {
		err = tx.QueryRowContext(ctx, `
			SELECT id FROM conversations
			 WHERE kind = 'class' AND class_id = ?`,
			anchorClassID.String,
		).Scan(&existingID)
	}
	if err == nil {
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
		INSERT INTO conversations
		  (id, studio_id, kind, title, recurrence_rule_id, class_id, created_by)
		VALUES (?, ?, 'class', NULL, ?, ?, ?)`,
		convID, studioID, anchorRecRule, anchorClassID, actorID,
	); err != nil {
		return nil, fmt.Errorf("insert class conversation: %w", err)
	}
	detail := map[string]any{"class_id": classID}
	if anchorRecRule.Valid {
		detail["recurrence_rule_id"] = anchorRecRule.String
	}
	if err := s.writeAuditTx(ctx, tx, studioID, actorID,
		"class_chat_create", "conversation", convID, detail,
	); err != nil {
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

	conv, err := conversationContextTx(ctx, tx, conversationID)
	if err != nil {
		return nil, err
	}
	if ok, err := isEligibleTx(ctx, tx, conv, userID); err != nil {
		return nil, err
	} else if !ok {
		return nil, ErrNotMember
	}
	// Class chats don't materialise membership upfront — write the row on
	// first send so the last_read_seq UPDATE below has something to bump.
	if conv.Kind == "class" {
		if err := addMemberTx(ctx, tx, conversationID, userID); err != nil {
			return nil, err
		}
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
	// Fan out a collapsed chat_message notification to every recipient
	// (membership minus the sender). For class chats the recipient set is
	// the same computed union ListConversations uses; for group/dm it's
	// the conversation_members ACL. Multiple messages in the same
	// conversation upsert to ONE row per (user, conv) so a busy class
	// chat doesn't flood the bell.
	if err := s.fanOutChatNotificationTx(
		ctx, tx, conv, userID, body,
	); err != nil {
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
// monotonic so a stale client can't roll the marker backwards). For class
// chats it also lazy-creates the conversation_members row on first read so
// subsequent unread maths has somewhere to record the high-water mark.
// Not audited: read tracking is high-frequency, driven by polling, and
// carries no managerial significance — mirrors unaudited notification reads.
func (s *Store) MarkConversationRead(
	ctx context.Context, userID, conversationID string, upToSeq int,
) error {
	conv, err := s.conversationContext(ctx, conversationID)
	if err != nil {
		return err
	}
	ok, err := s.isEligible(ctx, conv, userID)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotMember
	}
	if conv.Kind == "class" {
		// Lazy-insert + update under one tx so a concurrent sender can't
		// bump the seq forward between them.
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := addMemberTx(ctx, tx, conversationID, userID); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE conversation_members
			   SET last_read_seq = ?
			 WHERE conversation_id = ? AND user_id = ? AND last_read_seq < ?`,
			upToSeq, conversationID, userID, upToSeq,
		); err != nil {
			return err
		}
		return tx.Commit()
	}
	_, err = s.db.ExecContext(ctx, `
		UPDATE conversation_members
		   SET last_read_seq = ?
		 WHERE conversation_id = ? AND user_id = ? AND last_read_seq < ?`,
		upToSeq, conversationID, userID, upToSeq,
	)
	return err
}

// ListConversations returns every conversation the caller can read, newest
// activity first, each hydrated with its members, last message, the caller's
// unread count, and (for class chats viewed by a student) an archive flag.
//
// Visibility:
//   - group/dm: caller has a conversation_members row.
//   - class:    caller is booked / waitlisted / instructing the anchor, OR
//     is staff in the studio.
//
// Archive (per caller, per class chat):
//   - staff side: always false (they're the persistent owners).
//   - student side: true iff (a) no future booking or waitlist entry on the
//     anchor AND (b) at least one past instance the caller attended/booked/
//     no-showed ended >12h ago. Pure filter — flips back to false on rebook.
//
// Empty conversations sort by their creation time.
func (s *Store) ListConversations(
	ctx context.Context, studioID, userID string, isStaff bool,
) ([]Conversation, error) {
	frag, fragArgs := classEligibilitySQL(userID)
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	cutoff := time.Now().UTC().Add(-12 * time.Hour).Format("2006-01-02T15:04:05.000Z")
	isStaffInt := 0
	if isStaff {
		isStaffInt = 1
	}
	archivedSQL := `
		CASE
		  WHEN ? = 1 THEN 0
		  WHEN c.kind <> 'class' THEN 0
		  WHEN c.recurrence_rule_id IS NOT NULL THEN
		    CASE WHEN
		        NOT EXISTS (SELECT 1 FROM bookings b
		                      JOIN classes cl ON cl.id = b.class_id
		                     WHERE b.user_id = ? AND b.status = 'booked'
		                       AND cl.recurrence_rule_id = c.recurrence_rule_id
		                       AND cl.starts_at > ?)
		    AND NOT EXISTS (SELECT 1 FROM waitlist_entries w
		                      JOIN classes cl ON cl.id = w.class_id
		                     WHERE w.user_id = ? AND w.status = 'waiting'
		                       AND cl.recurrence_rule_id = c.recurrence_rule_id
		                       AND cl.starts_at > ?)
		    AND EXISTS (SELECT 1 FROM bookings b
		                  JOIN classes cl ON cl.id = b.class_id
		                 WHERE b.user_id = ?
		                   AND b.status IN ('booked','attended','no_show')
		                   AND cl.recurrence_rule_id = c.recurrence_rule_id
		                   AND cl.ends_at < ?)
		    THEN 1 ELSE 0 END
		  WHEN c.class_id IS NOT NULL THEN
		    -- One-off chat: archive once the class has ended >12h ago AND
		    -- the caller had an active seat on it. "No future booking"
		    -- is implied by the ends_at cutoff (the class can't be both
		    -- ended AND in the future). Waitlist status doesn't matter
		    -- for the same reason — a past class's waitlist is stale.
		    CASE WHEN
		        EXISTS (SELECT 1 FROM classes
		                 WHERE id = c.class_id AND ends_at < ?)
		    AND EXISTS (SELECT 1 FROM bookings
		                  WHERE user_id = ? AND class_id = c.class_id
		                    AND status IN ('booked','attended','no_show'))
		    THEN 1 ELSE 0 END
		  ELSE 0
		END AS archived`
	archivedArgs := []any{
		isStaffInt,
		userID, now, // series: future booking
		userID, now, // series: future waitlist
		userID, cutoff, // series: past attended >12h
		cutoff, // one-off: class ends_at < cutoff
		userID, // one-off: had a seat
	}

	q := `
		SELECT c.id, c.kind, COALESCE(c.title,''),
		       c.recurrence_rule_id, c.class_id,
		       c.created_by, c.created_at,
		       COALESCE(cm.last_read_seq, 0) AS last_read_seq,
		       (SELECT COUNT(*) FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.seq > COALESCE(cm.last_read_seq, 0)
		           AND m.deleted_at IS NULL) AS unread,
		       COALESCE((SELECT MAX(m2.created_at) FROM messages m2
		                  WHERE m2.conversation_id = c.id), c.created_at) AS last_activity,
		       ` + archivedSQL + `
		  FROM conversations c
		  LEFT JOIN conversation_members cm
		    ON cm.conversation_id = c.id AND cm.user_id = ?
		 WHERE c.studio_id = ?
		   AND (
		     (c.kind IN ('group','dm') AND cm.user_id IS NOT NULL)
		     OR
		     (c.kind = 'class' AND ` + frag + `)
		   )
		 ORDER BY last_activity DESC`
	args := []any{}
	args = append(args, archivedArgs...)
	args = append(args, userID, studioID)
	args = append(args, fragArgs...)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Conversation, 0)
	for rows.Next() {
		var (
			c           Conversation
			recRule     sql.NullString
			classID     sql.NullString
			lastReadSeq int
			lastAct     string
			archived    int
		)
		if err := rows.Scan(&c.ID, &c.Kind, &c.Title,
			&recRule, &classID,
			&c.CreatedBy, &c.CreatedAt,
			&lastReadSeq, &c.UnreadCount, &lastAct, &archived); err != nil {
			return nil, err
		}
		if recRule.Valid {
			c.RecurrenceRuleID = &recRule.String
		}
		if classID.Valid {
			c.ClassID = &classID.String
		}
		c.Archived = archived == 1
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Hydrate members + last message per conversation. N+1 but N is the
	// number of rooms one user is in — small. Revisit with a join if a
	// power user ever lands in hundreds of rooms.
	for i := range out {
		members, err := s.loadMembersFor(ctx, out[i])
		if err != nil {
			return nil, err
		}
		out[i].MemberCount = len(members)
		out[i].Members = members
		// Privacy: students shouldn't see who else is in a class chat
		// (their fellow students aren't theirs to enumerate). Keep just
		// the viewer's own row so last_read_seq is still computable
		// client-side.
		if !isStaff && out[i].Kind == "class" {
			out[i].Members = onlyViewer(members, userID)
		}
		// Summarise what + when a class chat is about for the list/header.
		if out[i].Kind == "class" {
			cc := convContextFor(out[i])
			if out[i].Title == "" {
				if label, lerr := chatLabel(ctx, s.db, cc); lerr == nil {
					out[i].Title = label
				}
			}
			if sched, startsAt, serr := classScheduleSummary(ctx, s.db, cc); serr == nil {
				out[i].ClassSchedule = sched
				out[i].ClassStartsAt = startsAt
			}
		}
		last, err := s.loadLastMessage(ctx, out[i].ID)
		if err != nil {
			return nil, err
		}
		out[i].LastMessage = last
	}
	return out, nil
}

// onlyViewer keeps just the viewer's own member row (or empty if absent —
// they may not have one yet on a class chat they've never opened).
func onlyViewer(members []ConversationMember, viewerID string) []ConversationMember {
	for _, m := range members {
		if m.UserID == viewerID {
			return []ConversationMember{m}
		}
	}
	return []ConversationMember{}
}

// convContextFor builds the eligibility/label context from a hydrated
// Conversation, mapping its *string anchors back to the sql.NullString shape
// the label + schedule helpers expect.
func convContextFor(c Conversation) convContext {
	cc := convContext{ID: c.ID, Kind: c.Kind}
	if c.RecurrenceRuleID != nil {
		cc.RecurrenceRuleID = sql.NullString{String: *c.RecurrenceRuleID, Valid: true}
	}
	if c.ClassID != nil {
		cc.ClassID = sql.NullString{String: *c.ClassID, Valid: true}
	}
	return cc
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
	conv, err := s.conversationContext(ctx, conversationID)
	if err != nil {
		return nil, err
	}
	if ok, err := s.isEligible(ctx, conv, userID); err != nil {
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

// loadMembersFor returns the member list appropriate to the conversation's
// kind. For group/dm it's the rows in conversation_members. For class it's
// the computed union (active bookings ∪ active waitlist ∪ instructors of
// any anchored class ∪ all studio staff) LEFT-JOINed to conversation_members
// so last_read_seq is filled in when present (0 otherwise).
func (s *Store) loadMembersFor(ctx context.Context, c Conversation) ([]ConversationMember, error) {
	if c.Kind != "class" {
		return s.loadMembersFromTable(ctx, c.ID)
	}
	return s.loadClassMembers(ctx, c)
}

func (s *Store) loadMembersFromTable(ctx context.Context, conversationID string) ([]ConversationMember, error) {
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

// loadClassMembers materialises the computed-membership set for a class
// chat. Sources are UNION'd so a user appearing in multiple roles
// (e.g. instructor who's also booked) is returned once. last_read_seq is
// LEFT-JOINed from conversation_members and defaults to 0.
func (s *Store) loadClassMembers(ctx context.Context, c Conversation) ([]ConversationMember, error) {
	// Build the per-anchor source query. Exactly one of the two branches
	// is active per row thanks to the CHECK on conversations.
	var sourceQ string
	var sourceArgs []any
	if c.RecurrenceRuleID != nil {
		sourceQ = `
			SELECT b.user_id FROM bookings b
			  JOIN classes cl ON cl.id = b.class_id
			 WHERE cl.recurrence_rule_id = ?
			   AND b.status IN ('booked','attended','no_show')
			UNION
			SELECT w.user_id FROM waitlist_entries w
			  JOIN classes cl ON cl.id = w.class_id
			 WHERE cl.recurrence_rule_id = ? AND w.status = 'waiting'
			UNION
			SELECT cl.instructor_id FROM classes cl
			 WHERE cl.recurrence_rule_id = ? AND cl.instructor_id IS NOT NULL`
		sourceArgs = []any{*c.RecurrenceRuleID, *c.RecurrenceRuleID, *c.RecurrenceRuleID}
	} else if c.ClassID != nil {
		sourceQ = `
			SELECT user_id FROM bookings
			 WHERE class_id = ?
			   AND status IN ('booked','attended','no_show')
			UNION
			SELECT user_id FROM waitlist_entries
			 WHERE class_id = ? AND status = 'waiting'
			UNION
			SELECT instructor_id FROM classes
			 WHERE id = ? AND instructor_id IS NOT NULL`
		sourceArgs = []any{*c.ClassID, *c.ClassID, *c.ClassID}
	} else {
		// Shouldn't happen — CHECK enforces an anchor for kind='class'.
		return nil, fmt.Errorf("class conversation %s has no anchor", c.ID)
	}
	// Studio-wide staff are members of every class chat in their studio.
	const staffQ = `SELECT u.id AS user_id FROM users u
	                 WHERE u.studio_id = ?
	                   AND u.role IN ('instructor','manager','owner')`

	// Resolve the conversation's studio (one extra round-trip vs threading
	// it through every call site).
	var studioID string
	if err := s.db.QueryRowContext(ctx,
		`SELECT studio_id FROM conversations WHERE id = ?`, c.ID,
	).Scan(&studioID); err != nil {
		return nil, err
	}

	q := `
		SELECT u.id, u.full_name, u.photo_url, u.role,
		       COALESCE(cm.last_read_seq, 0)
		  FROM (
		    ` + sourceQ + `
		    UNION
		    ` + staffQ + `
		  ) AS ids
		  JOIN users u ON u.id = ids.user_id
		  LEFT JOIN conversation_members cm
		    ON cm.conversation_id = ? AND cm.user_id = u.id
		 ORDER BY u.full_name ASC`
	args := append([]any{}, sourceArgs...)
	args = append(args, studioID, c.ID)
	rows, err := s.db.QueryContext(ctx, q, args...)
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
	var (
		c       Conversation
		recRule sql.NullString
		classID sql.NullString
	)
	err := s.db.QueryRowContext(ctx, `
		SELECT id, kind, COALESCE(title,''),
		       recurrence_rule_id, class_id,
		       created_by, created_at
		  FROM conversations WHERE id = ?`, conversationID,
	).Scan(&c.ID, &c.Kind, &c.Title, &recRule, &classID, &c.CreatedBy, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if recRule.Valid {
		c.RecurrenceRuleID = &recRule.String
	}
	if classID.Valid {
		c.ClassID = &classID.String
	}
	members, err := s.loadMembersFor(ctx, c)
	if err != nil {
		return nil, err
	}
	c.MemberCount = len(members)
	c.Members = members
	// Redact when the viewer is a student looking at a class chat.
	// One extra users-table read is fine on the open-the-chat path.
	if c.Kind == "class" {
		var role string
		_ = s.db.QueryRowContext(ctx,
			`SELECT role FROM users WHERE id = ?`, userID,
		).Scan(&role)
		if role == "student" {
			c.Members = onlyViewer(members, userID)
		}
		// Summarise what (label) and when (schedule / next instance) the
		// chat is about, for the header at the top of the thread.
		cc := convContext{ID: c.ID, Kind: c.Kind, RecurrenceRuleID: recRule, ClassID: classID}
		if c.Title == "" {
			if label, lerr := chatLabel(ctx, s.db, cc); lerr == nil {
				c.Title = label
			}
		}
		if sched, startsAt, serr := classScheduleSummary(ctx, s.db, cc); serr == nil {
			c.ClassSchedule = sched
			c.ClassStartsAt = startsAt
		}
	}
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

// ---- class-chat eligibility -----------------------------------------------

// convContext is the conversation-level metadata an eligibility check needs:
// the kind plus the class anchor (one of recurrence_rule_id / class_id for
// kind='class', both null otherwise — CHECK-enforced).
type convContext struct {
	ID               string
	Kind             string
	StudioID         string
	RecurrenceRuleID sql.NullString
	ClassID          sql.NullString
}

const convContextCols = `id, kind, studio_id, recurrence_rule_id, class_id`

type scanner interface {
	Scan(dest ...any) error
}

func scanConvContext(row scanner) (convContext, error) {
	var c convContext
	err := row.Scan(&c.ID, &c.Kind, &c.StudioID, &c.RecurrenceRuleID, &c.ClassID)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

func (s *Store) conversationContext(ctx context.Context, conversationID string) (convContext, error) {
	return scanConvContext(s.db.QueryRowContext(ctx,
		`SELECT `+convContextCols+` FROM conversations WHERE id = ?`, conversationID))
}

func conversationContextTx(ctx context.Context, tx *sql.Tx, conversationID string) (convContext, error) {
	return scanConvContext(tx.QueryRowContext(ctx,
		`SELECT `+convContextCols+` FROM conversations WHERE id = ?`, conversationID))
}

// classEligibilitySQL builds the boolean WHERE-fragment "userID may read +
// post in the class conversation aliased as `c` in the outer query". The
// fragment references c.studio_id / c.recurrence_rule_id / c.class_id so
// callers MUST alias `conversations` as `c`. Returns the SQL + the args
// (all userID, in the order the placeholders appear).
//
// Eligibility = active booking on a matching class ∪ active waitlist on a
// matching class ∪ instructor of any matching class ∪ any staff
// (instructor|manager|owner) in the conversation's studio.
func classEligibilitySQL(userID string) (string, []any) {
	const frag = `(
		EXISTS (SELECT 1 FROM users u
		         WHERE u.id = ? AND u.studio_id = c.studio_id
		           AND u.role IN ('instructor','manager','owner'))
		OR (c.recurrence_rule_id IS NOT NULL AND (
		      EXISTS (SELECT 1 FROM bookings b
		                JOIN classes cl ON cl.id = b.class_id
		               WHERE b.user_id = ?
		                 AND b.status IN ('booked','attended','no_show')
		                 AND cl.recurrence_rule_id = c.recurrence_rule_id)
		   OR EXISTS (SELECT 1 FROM waitlist_entries w
		                JOIN classes cl ON cl.id = w.class_id
		               WHERE w.user_id = ?
		                 AND w.status = 'waiting'
		                 AND cl.recurrence_rule_id = c.recurrence_rule_id)
		   OR EXISTS (SELECT 1 FROM classes cl
		               WHERE cl.instructor_id = ?
		                 AND cl.recurrence_rule_id = c.recurrence_rule_id)
		))
		OR (c.class_id IS NOT NULL AND (
		      EXISTS (SELECT 1 FROM bookings
		               WHERE user_id = ? AND class_id = c.class_id
		                 AND status IN ('booked','attended','no_show'))
		   OR EXISTS (SELECT 1 FROM waitlist_entries
		               WHERE user_id = ? AND class_id = c.class_id
		                 AND status = 'waiting')
		   OR EXISTS (SELECT 1 FROM classes
		               WHERE id = c.class_id AND instructor_id = ?)
		))
	)`
	return frag, []any{userID, userID, userID, userID, userID, userID, userID}
}

// isEligible reports whether userID may read+post in conv. group/dm
// dispatches to the conversation_members ACL; class kind uses
// classEligibilitySQL.
func (s *Store) isEligible(ctx context.Context, conv convContext, userID string) (bool, error) {
	if conv.Kind != "class" {
		return s.isMember(ctx, conv.ID, userID)
	}
	frag, args := classEligibilitySQL(userID)
	args = append([]any{conv.ID}, args...)
	var ok bool
	if err := s.db.QueryRowContext(ctx,
		`SELECT EXISTS (SELECT 1 FROM conversations c WHERE c.id = ? AND `+frag+`)`,
		args...,
	).Scan(&ok); err != nil {
		return false, err
	}
	return ok, nil
}

func isEligibleTx(ctx context.Context, tx *sql.Tx, conv convContext, userID string) (bool, error) {
	if conv.Kind != "class" {
		return isMemberTx(ctx, tx, conv.ID, userID)
	}
	frag, args := classEligibilitySQL(userID)
	args = append([]any{conv.ID}, args...)
	var ok bool
	if err := tx.QueryRowContext(ctx,
		`SELECT EXISTS (SELECT 1 FROM conversations c WHERE c.id = ? AND `+frag+`)`,
		args...,
	).Scan(&ok); err != nil {
		return false, err
	}
	return ok, nil
}

// ---- chat → notification fan-out ------------------------------------------

// fanOutChatNotificationTx upserts a 'chat_message' notification row for
// every recipient (membership minus the sender). Collapse model: at most
// one row per (user, conversation), dedup_key='chat:<conv_id>'. Subsequent
// messages refresh the existing row (title/body/payload/created_at) and
// clear read_at so the bell unread badge resurrects.
func (s *Store) fanOutChatNotificationTx(
	ctx context.Context, tx *sql.Tx, conv convContext, senderID, body string,
) error {
	recipients, err := chatRecipientsTx(ctx, tx, conv, senderID)
	if err != nil {
		return err
	}
	if len(recipients) == 0 {
		return nil
	}
	label, err := chatLabel(ctx, tx, conv)
	if err != nil {
		return err
	}
	senderName, err := userFullNameTx(ctx, tx, senderID)
	if err != nil {
		return err
	}
	preview := body
	if len(preview) > 140 {
		preview = preview[:140] + "…"
	}
	// Title: "Sender · Class Title" for groups/classes; just "Sender" for
	// DMs (the recipient already knows who they're chatting with — the
	// "·" prefix would be padding).
	title := senderName
	if conv.Kind != "dm" && label != "" {
		title = senderName + " · " + label
	}
	payloadBytes, err := json.Marshal(map[string]any{
		"conversation_id": conv.ID,
		"kind":            conv.Kind,
		"sender_id":       senderID,
		"sender_name":     senderName,
	})
	if err != nil {
		return err
	}
	payload := string(payloadBytes)
	dedupKey := "chat:" + conv.ID
	for _, uid := range recipients {
		if err := upsertChatNotificationTx(
			ctx, tx, conv.StudioID, uid, dedupKey, title, preview, payload,
		); err != nil {
			return err
		}
	}
	return nil
}

// chatRecipientsTx returns every user who should be notified about a new
// message in conv, except the sender. For class chats the union is
// computed (bookings ∪ waitlist ∪ instructor ∪ studio staff); for group/dm
// it's the conversation_members ACL.
func chatRecipientsTx(
	ctx context.Context, tx *sql.Tx, conv convContext, senderID string,
) ([]string, error) {
	if conv.Kind != "class" {
		return scanIDsTx(ctx, tx, `
			SELECT user_id FROM conversation_members
			 WHERE conversation_id = ? AND user_id <> ?`,
			conv.ID, senderID)
	}
	// Class chat: union of the four sources, excluding sender.
	var sourceQ string
	var args []any
	if conv.RecurrenceRuleID.Valid {
		sourceQ = `
			SELECT b.user_id FROM bookings b
			  JOIN classes cl ON cl.id = b.class_id
			 WHERE cl.recurrence_rule_id = ?
			   AND b.status IN ('booked','attended','no_show')
			UNION
			SELECT w.user_id FROM waitlist_entries w
			  JOIN classes cl ON cl.id = w.class_id
			 WHERE cl.recurrence_rule_id = ? AND w.status = 'waiting'
			UNION
			SELECT cl.instructor_id FROM classes cl
			 WHERE cl.recurrence_rule_id = ? AND cl.instructor_id IS NOT NULL`
		args = []any{conv.RecurrenceRuleID.String, conv.RecurrenceRuleID.String,
			conv.RecurrenceRuleID.String}
	} else if conv.ClassID.Valid {
		sourceQ = `
			SELECT user_id FROM bookings
			 WHERE class_id = ?
			   AND status IN ('booked','attended','no_show')
			UNION
			SELECT user_id FROM waitlist_entries
			 WHERE class_id = ? AND status = 'waiting'
			UNION
			SELECT instructor_id FROM classes
			 WHERE id = ? AND instructor_id IS NOT NULL`
		args = []any{conv.ClassID.String, conv.ClassID.String, conv.ClassID.String}
	} else {
		return nil, nil
	}
	args = append(args, conv.StudioID, senderID)
	q := `
		SELECT DISTINCT ids.user_id FROM (
		  ` + sourceQ + `
		  UNION
		  SELECT u.id AS user_id FROM users u
		   WHERE u.studio_id = ?
		     AND u.role IN ('instructor','manager','owner')
		) AS ids
		 WHERE ids.user_id <> ?`
	return scanIDsTx(ctx, tx, q, args...)
}

// chatLabelTx returns a human-readable label for the conversation, used in
// notification titles. Falls back through a small chain so we never end up
// with an empty "Anna ·  " entry.
func chatLabel(ctx context.Context, q rowQuerier, conv convContext) (string, error) {
	switch conv.Kind {
	case "group":
		var t sql.NullString
		err := q.QueryRowContext(ctx,
			`SELECT title FROM conversations WHERE id = ?`, conv.ID,
		).Scan(&t)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return "", err
		}
		return t.String, nil
	case "class":
		// Try the recurrence rule's title, then any anchored class's
		// title, then the class type's name.
		if conv.RecurrenceRuleID.Valid {
			var rt sql.NullString
			_ = q.QueryRowContext(ctx,
				`SELECT title FROM recurrence_rules WHERE id = ?`,
				conv.RecurrenceRuleID.String,
			).Scan(&rt)
			if rt.Valid && rt.String != "" {
				return rt.String, nil
			}
			var typeName string
			_ = q.QueryRowContext(ctx, `
				SELECT ct.name FROM recurrence_rules r
				  JOIN class_types ct ON ct.id = r.class_type_id
				 WHERE r.id = ?`,
				conv.RecurrenceRuleID.String,
			).Scan(&typeName)
			return typeName, nil
		}
		if conv.ClassID.Valid {
			var ct sql.NullString
			_ = q.QueryRowContext(ctx,
				`SELECT title FROM classes WHERE id = ?`,
				conv.ClassID.String,
			).Scan(&ct)
			if ct.Valid && ct.String != "" {
				return ct.String, nil
			}
			var typeName string
			_ = q.QueryRowContext(ctx, `
				SELECT ct.name FROM classes cl
				  JOIN class_types ct ON ct.id = cl.class_type_id
				 WHERE cl.id = ?`,
				conv.ClassID.String,
			).Scan(&typeName)
			return typeName, nil
		}
	}
	return "", nil
}

// classScheduleSummary returns the "when" descriptors for a class chat:
//   - schedule: the recurring wall-clock pattern for a series-anchored
//     chat ("Tuesdays · 7:00am"); nil for a one-off.
//   - startsAt: a concrete instance timestamp — the next upcoming instance
//     for a series (most recent past if none upcoming), or the single
//     class's start for a one-off; nil if it can't be resolved.
//
// Returns (nil, nil, nil) for a non-class conv or a missing anchor row.
func classScheduleSummary(
	ctx context.Context, q rowQuerier, conv convContext,
) (schedule *string, startsAt *string, err error) {
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	switch {
	case conv.RecurrenceRuleID.Valid:
		var (
			freq         string
			weekdaysJSON string
			startHour    int
			startMinute  int
		)
		err := q.QueryRowContext(ctx, `
			SELECT frequency, weekdays, start_hour, start_minute
			  FROM recurrence_rules WHERE id = ?`,
			conv.RecurrenceRuleID.String,
		).Scan(&freq, &weekdaysJSON, &startHour, &startMinute)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil, nil
		}
		if err != nil {
			return nil, nil, err
		}
		if sched := formatRecurrenceSchedule(freq, weekdaysJSON, startHour, startMinute); sched != "" {
			schedule = &sched
		}
		// Prefer the next upcoming instance; fall back to the latest past
		// one so an ended series still shows a concrete date.
		var at sql.NullString
		_ = q.QueryRowContext(ctx, `
			SELECT MIN(starts_at) FROM classes
			 WHERE recurrence_rule_id = ? AND status = 'scheduled'
			   AND starts_at > ?`,
			conv.RecurrenceRuleID.String, now,
		).Scan(&at)
		if !at.Valid {
			_ = q.QueryRowContext(ctx, `
				SELECT MAX(starts_at) FROM classes
				 WHERE recurrence_rule_id = ?`,
				conv.RecurrenceRuleID.String,
			).Scan(&at)
		}
		if at.Valid {
			startsAt = &at.String
		}
		return schedule, startsAt, nil
	case conv.ClassID.Valid:
		var at sql.NullString
		err := q.QueryRowContext(ctx,
			`SELECT starts_at FROM classes WHERE id = ?`, conv.ClassID.String,
		).Scan(&at)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil, nil
		}
		if err != nil {
			return nil, nil, err
		}
		if at.Valid {
			startsAt = &at.String
		}
		return nil, startsAt, nil
	}
	return nil, nil, nil
}

// formatRecurrenceSchedule renders a recurrence shape as a one-line summary
// in studio wall-clock time, e.g. "Tuesdays · 7:00am", "Mon & Wed · 6:30pm",
// "Daily · 6:00am". start_hour/start_minute are the literal displayed time
// (no timezone conversion needed — they're already wall-clock).
func formatRecurrenceSchedule(freq, weekdaysJSON string, startHour, startMinute int) string {
	clock := formatClock12(startHour, startMinute)
	switch freq {
	case "weekly":
		var days []int
		_ = json.Unmarshal([]byte(weekdaysJSON), &days)
		if d := formatWeekdays(days); d != "" {
			return d + " · " + clock
		}
		return clock
	case "daily":
		return "Daily · " + clock
	case "monthly":
		return "Monthly · " + clock
	}
	return clock
}

// formatWeekdays turns a set of weekday ints (Mon=0..Sun=6) into a label.
// A single day reads as a recurring plural ("Tuesdays"); multiple days use
// short names joined with an Oxford-ish "& " ("Mon, Wed & Fri").
func formatWeekdays(days []int) string {
	plural := [...]string{"Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"}
	short := [...]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
	valid := func(d int) bool { return d >= 0 && d <= 6 }
	sorted := append([]int(nil), days...)
	sort.Ints(sorted)
	parts := make([]string, 0, len(sorted))
	for _, d := range sorted {
		if valid(d) {
			parts = append(parts, short[d])
		}
	}
	switch len(parts) {
	case 0:
		return ""
	case 1:
		// Single valid day: use its plural form for a recurring read.
		for _, d := range sorted {
			if valid(d) {
				return plural[d]
			}
		}
		return parts[0]
	default:
		return strings.Join(parts[:len(parts)-1], ", ") + " & " + parts[len(parts)-1]
	}
}

// formatClock12 renders an hour (0..23) + minute as a 12-hour clock with a
// lowercase meridiem, e.g. 7:00am, 6:30pm, 12:00pm.
func formatClock12(h, m int) string {
	ap := "am"
	if h >= 12 {
		ap = "pm"
	}
	hh := h % 12
	if hh == 0 {
		hh = 12
	}
	return fmt.Sprintf("%d:%02d%s", hh, m, ap)
}

func userFullNameTx(ctx context.Context, tx *sql.Tx, userID string) (string, error) {
	var name string
	err := tx.QueryRowContext(ctx,
		`SELECT full_name FROM users WHERE id = ?`, userID,
	).Scan(&name)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	return name, nil
}

func scanIDsTx(ctx context.Context, tx *sql.Tx, q string, args ...any) ([]string, error) {
	rows, err := tx.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]string, 0)
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// upsertChatNotificationTx inserts a chat_message notification row for the
// (user, conversation) pair, or refreshes the existing one if dedup_key
// already exists. SELECT-then-INSERT/UPDATE rather than ON CONFLICT so the
// partial unique index is handled identically on SQLite + Postgres
// (Postgres requires the partial-index WHERE in the conflict target).
func upsertChatNotificationTx(
	ctx context.Context, tx *sql.Tx,
	studioID, userID, dedupKey, title, body, payload string,
) error {
	var existingID string
	err := tx.QueryRowContext(ctx, `
		SELECT id FROM notifications
		 WHERE user_id = ? AND dedup_key = ?`,
		userID, dedupKey,
	).Scan(&existingID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err == nil {
		_, err := tx.ExecContext(ctx, `
			UPDATE notifications
			   SET title = ?, body = ?, payload = ?,
			       read_at = NULL,
			       created_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
			 WHERE id = ?`,
			title, body, payload, existingID,
		)
		return err
	}
	_, err = tx.ExecContext(ctx, `
		INSERT INTO notifications
		  (id, studio_id, user_id, type, title, body, payload, dedup_key)
		VALUES (?, ?, ?, 'chat_message', ?, ?, ?, ?)`,
		NewID(), studioID, userID, title, body, payload, dedupKey,
	)
	return err
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
