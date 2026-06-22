package store

import (
	"context"
	"errors"
	"testing"
)

func mkUser(t *testing.T, s *Store, studioID, role, email string) string {
	t.Helper()
	id := NewID()
	if _, err := s.db.ExecContext(context.Background(),
		`INSERT INTO users (id, studio_id, role, email, full_name) VALUES (?,?,?,?,?)`,
		id, studioID, role, email, email,
	); err != nil {
		t.Fatalf("mkUser: %v", err)
	}
	return id
}

func auditCount(t *testing.T, s *Store, studioID, action string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM audit_log WHERE studio_id = ? AND action = ?`,
		studioID, action,
	).Scan(&n); err != nil {
		t.Fatalf("auditCount: %v", err)
	}
	return n
}

// Group happy path: a staff member creates a room with a student, posts two
// messages, and the unread count + read receipts move as the student reads.
func TestChat_GroupHappyPath(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	staff := f.instructorID
	student := f.studentID

	conv, err := s.CreateConversation(ctx, f.studioID, staff, "Morning Crew", []string{student})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if conv.Kind != "group" || conv.Title != "Morning Crew" {
		t.Fatalf("unexpected conv: %+v", conv)
	}
	if len(conv.Members) != 2 {
		t.Fatalf("want 2 members, got %d", len(conv.Members))
	}

	if _, err := s.SendMessage(ctx, f.studioID, staff, conv.ID, "morning!"); err != nil {
		t.Fatalf("send 1: %v", err)
	}
	m2, err := s.SendMessage(ctx, f.studioID, staff, conv.ID, "class at 9")
	if err != nil {
		t.Fatalf("send 2: %v", err)
	}
	if m2.Seq != 2 {
		t.Fatalf("want seq 2, got %d", m2.Seq)
	}

	// The student sees both as unread; the sender's own count is zero.
	studentConvs, err := s.ListConversations(ctx, f.studioID, student)
	if err != nil {
		t.Fatalf("list (student): %v", err)
	}
	if len(studentConvs) != 1 || studentConvs[0].UnreadCount != 2 {
		t.Fatalf("student unread: %+v", studentConvs)
	}
	if studentConvs[0].LastMessage == nil || studentConvs[0].LastMessage.Body != "class at 9" {
		t.Fatalf("last message preview wrong: %+v", studentConvs[0].LastMessage)
	}
	staffConvs, _ := s.ListConversations(ctx, f.studioID, staff)
	if staffConvs[0].UnreadCount != 0 {
		t.Fatalf("sender should have 0 unread, got %d", staffConvs[0].UnreadCount)
	}

	// Student reads up to seq 2 → unread clears, receipts on both messages.
	if err := s.MarkConversationRead(ctx, student, conv.ID, 2); err != nil {
		t.Fatalf("mark read: %v", err)
	}
	studentConvs, _ = s.ListConversations(ctx, f.studioID, student)
	if studentConvs[0].UnreadCount != 0 {
		t.Fatalf("want 0 unread after read, got %d", studentConvs[0].UnreadCount)
	}
	msgs, err := s.ListMessages(ctx, staff, conv.ID, 0, 0, 0)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("want 2 messages, got %d", len(msgs))
	}
	for _, m := range msgs {
		if m.ReadByCount != 1 {
			t.Errorf("seq %d: want read_by 1 (the student), got %d", m.Seq, m.ReadByCount)
		}
	}
}

// MarkConversationRead never rolls the high-water mark backwards.
func TestChat_MarkReadMonotonic(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	conv, _ := s.CreateConversation(ctx, f.studioID, f.instructorID, "G", []string{f.studentID})
	for i := 0; i < 3; i++ {
		if _, err := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "x"); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.MarkConversationRead(ctx, f.studentID, conv.ID, 3); err != nil {
		t.Fatal(err)
	}
	// A stale client tries to mark an older seq — must not regress.
	if err := s.MarkConversationRead(ctx, f.studentID, conv.ID, 1); err != nil {
		t.Fatal(err)
	}
	convs, _ := s.ListConversations(ctx, f.studioID, f.studentID)
	if convs[0].UnreadCount != 0 {
		t.Fatalf("stale mark-read regressed unread to %d", convs[0].UnreadCount)
	}
}

// Non-members can neither read, post, nor mark a conversation read.
func TestChat_MembershipEnforced(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	outsider := mkUser(t, s, f.studioID, "student", "outsider@test.com")

	conv, _ := s.CreateConversation(ctx, f.studioID, f.instructorID, "Private", []string{f.studentID})

	if _, err := s.ListMessages(ctx, outsider, conv.ID, 0, 0, 0); !errors.Is(err, ErrNotMember) {
		t.Errorf("list as outsider: want ErrNotMember, got %v", err)
	}
	if _, err := s.SendMessage(ctx, f.studioID, outsider, conv.ID, "hi"); !errors.Is(err, ErrNotMember) {
		t.Errorf("send as outsider: want ErrNotMember, got %v", err)
	}
	if err := s.MarkConversationRead(ctx, outsider, conv.ID, 1); !errors.Is(err, ErrNotMember) {
		t.Errorf("mark read as outsider: want ErrNotMember, got %v", err)
	}
}

// A student cannot read (or even see) a DM between staff and a *different*
// student. This is the privacy guarantee for direct messages — the same
// membership gate as groups, asserted here by name for the DM case.
func TestChat_DMPrivacyFromOtherStudent(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	// f.studentID is student A (the DM recipient); add a second student B.
	studentB := mkUser(t, s, f.studioID, "student", "studentB@test.com")

	// Staff opens a DM with student A and sends a private message.
	dm, err := s.OpenDM(ctx, f.studioID, f.instructorID, f.studentID)
	if err != nil {
		t.Fatalf("open dm: %v", err)
	}
	if _, err := s.SendMessage(ctx, f.studioID, f.instructorID, dm.ID, "your pass expires Friday"); err != nil {
		t.Fatalf("send: %v", err)
	}

	// Student B is not a participant — every access path is refused.
	if _, err := s.ListMessages(ctx, studentB, dm.ID, 0, 0, 0); !errors.Is(err, ErrNotMember) {
		t.Errorf("studentB reads the DM: want ErrNotMember, got %v", err)
	}
	if _, err := s.SendMessage(ctx, f.studioID, studentB, dm.ID, "let me in"); !errors.Is(err, ErrNotMember) {
		t.Errorf("studentB posts to the DM: want ErrNotMember, got %v", err)
	}
	if err := s.MarkConversationRead(ctx, studentB, dm.ID, 1); !errors.Is(err, ErrNotMember) {
		t.Errorf("studentB marks the DM read: want ErrNotMember, got %v", err)
	}

	// And the DM never appears in student B's conversation list...
	bConvs, err := s.ListConversations(ctx, f.studioID, studentB)
	if err != nil {
		t.Fatalf("list (studentB): %v", err)
	}
	for _, c := range bConvs {
		if c.ID == dm.ID {
			t.Fatalf("DM leaked into a non-participant's conversation list")
		}
	}
	// ...while student A (the actual recipient) does see it. Positive control.
	aConvs, _ := s.ListConversations(ctx, f.studioID, f.studentID)
	var aSeesIt bool
	for _, c := range aConvs {
		if c.ID == dm.ID {
			aSeesIt = true
		}
	}
	if !aSeesIt {
		t.Fatalf("DM recipient (student A) cannot see their own DM")
	}
}

// Opening a dm twice returns the same room and audits exactly once.
func TestChat_OpenDMIdempotent(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	a, err := s.OpenDM(ctx, f.studioID, f.instructorID, f.studentID)
	if err != nil {
		t.Fatalf("open 1: %v", err)
	}
	b, err := s.OpenDM(ctx, f.studioID, f.instructorID, f.studentID)
	if err != nil {
		t.Fatalf("open 2: %v", err)
	}
	if a.ID != b.ID {
		t.Fatalf("dm not idempotent: %s != %s", a.ID, b.ID)
	}
	// Opening from the other side resolves to the same conversation too.
	c, _ := s.OpenDM(ctx, f.studioID, f.studentID, f.instructorID)
	if c.ID != a.ID {
		t.Fatalf("reverse open made a new dm: %s != %s", c.ID, a.ID)
	}
	if n := auditCount(t, s, f.studioID, "dm_open"); n != 1 {
		t.Fatalf("want 1 dm_open audit row, got %d", n)
	}
	if _, err := s.OpenDM(ctx, f.studioID, f.instructorID, f.instructorID); !errors.Is(err, ErrSelfDM) {
		t.Errorf("self-dm: want ErrSelfDM, got %v", err)
	}
}

// Edit + delete are sender-gated; a soft delete keeps the row but blanks it.
func TestChat_EditAndDelete(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	conv, _ := s.CreateConversation(ctx, f.studioID, f.instructorID, "G", []string{f.studentID})
	msg, _ := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "original")

	// Non-sender can't edit or delete.
	if _, err := s.EditMessage(ctx, f.studioID, f.studentID, conv.ID, msg.ID, "nope"); !errors.Is(err, ErrNotSender) {
		t.Errorf("edit by non-sender: want ErrNotSender, got %v", err)
	}
	if err := s.DeleteMessage(ctx, f.studioID, f.studentID, conv.ID, msg.ID); !errors.Is(err, ErrNotSender) {
		t.Errorf("delete by non-sender: want ErrNotSender, got %v", err)
	}

	edited, err := s.EditMessage(ctx, f.studioID, f.instructorID, conv.ID, msg.ID, "fixed")
	if err != nil {
		t.Fatalf("edit: %v", err)
	}
	if edited.Body != "fixed" || edited.EditedAt == nil {
		t.Fatalf("edit didn't stamp: %+v", edited)
	}

	if err := s.DeleteMessage(ctx, f.studioID, f.instructorID, conv.ID, msg.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	msgs, _ := s.ListMessages(ctx, f.instructorID, conv.ID, 0, 0, 0)
	if len(msgs) != 1 {
		t.Fatalf("soft delete should keep the row, got %d", len(msgs))
	}
	if msgs[0].Body != "" || msgs[0].DeletedAt == nil {
		t.Fatalf("deleted message not blanked: %+v", msgs[0])
	}
	// Editing a deleted message is no longer possible.
	if _, err := s.EditMessage(ctx, f.studioID, f.instructorID, conv.ID, msg.ID, "back"); !errors.Is(err, ErrNotFound) {
		t.Errorf("edit deleted: want ErrNotFound, got %v", err)
	}
}

// Keyset pagination walks history in both directions, oldest→newest.
func TestChat_Pagination(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	conv, _ := s.CreateConversation(ctx, f.studioID, f.instructorID, "G", []string{f.studentID})
	for i := 0; i < 5; i++ {
		if _, err := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "m"); err != nil {
			t.Fatal(err)
		}
	}

	seqs := func(ms []ChatMessage) []int {
		out := make([]int, len(ms))
		for i, m := range ms {
			out[i] = m.Seq
		}
		return out
	}

	// Newest page (default).
	page, _ := s.ListMessages(ctx, f.instructorID, conv.ID, 0, 0, 2)
	if got := seqs(page); len(got) != 2 || got[0] != 4 || got[1] != 5 {
		t.Fatalf("newest page: want [4 5], got %v", got)
	}
	// Scroll back before seq 4.
	older, _ := s.ListMessages(ctx, f.instructorID, conv.ID, 4, 0, 2)
	if got := seqs(older); len(got) != 2 || got[0] != 2 || got[1] != 3 {
		t.Fatalf("before page: want [2 3], got %v", got)
	}
	// Poll for everything after seq 3.
	newer, _ := s.ListMessages(ctx, f.instructorID, conv.ID, 0, 3, 0)
	if got := seqs(newer); len(got) != 2 || got[0] != 4 || got[1] != 5 {
		t.Fatalf("after page: want [4 5], got %v", got)
	}
}

// A member from another studio (or a bogus id) is rejected at creation.
func TestChat_CrossStudioMemberRejected(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	otherStudio := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO studios (id, name) VALUES (?, 'Other')`, otherStudio); err != nil {
		t.Fatal(err)
	}
	foreign := mkUser(t, s, otherStudio, "student", "foreign@test.com")

	if _, err := s.CreateConversation(ctx, f.studioID, f.instructorID, "X", []string{foreign}); !errors.Is(err, ErrInvalidMember) {
		t.Errorf("foreign member: want ErrInvalidMember, got %v", err)
	}
	if _, err := s.CreateConversation(ctx, f.studioID, f.instructorID, "X", []string{"does-not-exist"}); !errors.Is(err, ErrInvalidMember) {
		t.Errorf("bogus member: want ErrInvalidMember, got %v", err)
	}
}

// Every chat mutation leaves the expected audit trail.
func TestChat_AuditTrail(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	extra := mkUser(t, s, f.studioID, "student", "extra@test.com")

	conv, _ := s.CreateConversation(ctx, f.studioID, f.instructorID, "G", []string{f.studentID})
	msg, _ := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "hi")
	if _, err := s.EditMessage(ctx, f.studioID, f.instructorID, conv.ID, msg.ID, "hello"); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteMessage(ctx, f.studioID, f.instructorID, conv.ID, msg.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.AddMembers(ctx, f.studioID, f.instructorID, conv.ID, []string{extra}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.OpenDM(ctx, f.studioID, f.instructorID, f.studentID); err != nil {
		t.Fatal(err)
	}

	for action, want := range map[string]int{
		"conversation_create":     1,
		"message_send":            1,
		"message_edit":            1,
		"message_delete":          1,
		"conversation_member_add": 1,
		"dm_open":                 1,
	} {
		if got := auditCount(t, s, f.studioID, action); got != want {
			t.Errorf("audit %q: want %d, got %d", action, want, got)
		}
	}
	// Reads are deliberately not audited.
	if err := s.MarkConversationRead(ctx, f.studentID, conv.ID, 1); err != nil {
		t.Fatal(err)
	}
	if got := auditCount(t, s, f.studioID, "conversation_read"); got != 0 {
		t.Errorf("reads should not be audited, got %d rows", got)
	}
}

// AddMembers is group-only and idempotent.
func TestChat_AddMembersGroupOnly(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	dm, _ := s.OpenDM(ctx, f.studioID, f.instructorID, f.studentID)
	if err := s.AddMembers(ctx, f.studioID, f.instructorID, dm.ID, []string{mkUser(t, s, f.studioID, "student", "z@test.com")}); !errors.Is(err, ErrNotGroup) {
		t.Errorf("add to dm: want ErrNotGroup, got %v", err)
	}

	extra := mkUser(t, s, f.studioID, "student", "y@test.com")
	conv, _ := s.CreateConversation(ctx, f.studioID, f.instructorID, "G", nil)
	if err := s.AddMembers(ctx, f.studioID, f.instructorID, conv.ID, []string{extra}); err != nil {
		t.Fatal(err)
	}
	// Re-adding is a no-op, not an error or a duplicate.
	if err := s.AddMembers(ctx, f.studioID, f.instructorID, conv.ID, []string{extra}); err != nil {
		t.Fatalf("re-add: %v", err)
	}
	full, _ := s.conversationByID(ctx, f.instructorID, conv.ID)
	if len(full.Members) != 2 { // creator + extra
		t.Fatalf("want 2 members, got %d", len(full.Members))
	}
}

// Empty / blank bodies are rejected.
func TestChat_EmptyMessageRejected(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)
	conv, _ := s.CreateConversation(ctx, f.studioID, f.instructorID, "G", nil)
	if _, err := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "   "); !errors.Is(err, ErrEmptyMessage) {
		t.Errorf("blank send: want ErrEmptyMessage, got %v", err)
	}
}
