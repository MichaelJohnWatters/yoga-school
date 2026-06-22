package api

import (
	"context"
	"net/http"
	"testing"

	"github.com/studio52/yoga-school/server/internal/store"
)

// seedConversation creates a group conversation owned by the rig's manager
// (a member, so manager can post/edit). Used by the audit matrix + API tests.
func seedConversation(t *testing.T, r *testRig) string {
	t.Helper()
	conv, err := r.server.store.CreateConversation(
		context.Background(), r.studioID, r.mgrID, "Seed Room", nil)
	if err != nil {
		t.Fatalf("seedConversation: %v", err)
	}
	return conv.ID
}

// seedMessage posts a message from the manager into convID and returns its id.
func seedMessage(t *testing.T, r *testRig, convID string) string {
	t.Helper()
	msg, err := r.server.store.SendMessage(
		context.Background(), r.studioID, r.mgrID, convID, "seed message")
	if err != nil {
		t.Fatalf("seedMessage: %v", err)
	}
	return msg.ID
}

// End-to-end over HTTP: a manager opens a group with a student, posts a
// message, the student reads it back and clears their unread count.
func TestChatAPI_GroupRoundTrip(t *testing.T) {
	r := newRig(t)
	studentID := seedStudent(t, r) // email: derived below via lookup

	// Find the student's email so we can authenticate as them.
	var studentEmail string
	if err := store.TestDB(r.server.store).QueryRowContext(context.Background(),
		`SELECT email FROM users WHERE id = ?`, studentID,
	).Scan(&studentEmail); err != nil {
		t.Fatalf("student email: %v", err)
	}

	// Manager creates the group.
	res := r.do(http.MethodPost, "/conversations", map[string]any{
		"kind":       "group",
		"title":      "Sunrise Flow",
		"member_ids": []string{studentID},
	})
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("create: status %d", res.StatusCode)
	}
	conv := decode[store.Conversation](t, res)
	if len(conv.Members) != 2 {
		t.Fatalf("want 2 members, got %d", len(conv.Members))
	}

	// Manager posts.
	res = r.do(http.MethodPost, "/conversations/"+conv.ID+"/messages",
		map[string]any{"body": "welcome!"})
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("send: status %d", res.StatusCode)
	}

	// Student sees one unread.
	res = r.as(studentEmail).do(http.MethodGet, "/conversations", nil)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("student list: status %d", res.StatusCode)
	}
	convs := decode[[]store.Conversation](t, res)
	if len(convs) != 1 || convs[0].UnreadCount != 1 {
		t.Fatalf("student unread: %+v", convs)
	}

	// Student reads the messages, then marks read up to the last seq.
	res = r.do(http.MethodGet, "/conversations/"+conv.ID+"/messages", nil)
	msgs := decode[[]store.ChatMessage](t, res)
	if len(msgs) != 1 || msgs[0].Body != "welcome!" {
		t.Fatalf("student messages: %+v", msgs)
	}
	res = r.do(http.MethodPost, "/conversations/"+conv.ID+"/read",
		map[string]any{"up_to_seq": msgs[0].Seq})
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("mark read: status %d", res.StatusCode)
	}
	res = r.do(http.MethodGet, "/conversations", nil)
	convs = decode[[]store.Conversation](t, res)
	if convs[0].UnreadCount != 0 {
		t.Fatalf("want 0 unread after read, got %d", convs[0].UnreadCount)
	}
}

// Students cannot start conversations — the requireStaff gate rejects them.
func TestChatAPI_StudentCannotCreate(t *testing.T) {
	r := newRig(t)
	studentID := seedStudent(t, r)
	var studentEmail string
	if err := store.TestDB(r.server.store).QueryRowContext(context.Background(),
		`SELECT email FROM users WHERE id = ?`, studentID,
	).Scan(&studentEmail); err != nil {
		t.Fatalf("student email: %v", err)
	}

	res := r.as(studentEmail).do(http.MethodPost, "/conversations", map[string]any{
		"kind":  "group",
		"title": "Not allowed",
	})
	if res.StatusCode != http.StatusForbidden {
		t.Fatalf("student create: want 403, got %d", res.StatusCode)
	}
}

// A non-member is denied access to a conversation's messages (403, not 404 —
// but the body must not leak that the room exists beyond the access error).
func TestChatAPI_NonMemberForbidden(t *testing.T) {
	r := newRig(t)
	convID := seedConversation(t, r) // manager-only room

	studentID := seedStudent(t, r)
	var studentEmail string
	if err := store.TestDB(r.server.store).QueryRowContext(context.Background(),
		`SELECT email FROM users WHERE id = ?`, studentID,
	).Scan(&studentEmail); err != nil {
		t.Fatalf("student email: %v", err)
	}

	res := r.as(studentEmail).do(http.MethodGet, "/conversations/"+convID+"/messages", nil)
	if res.StatusCode != http.StatusForbidden {
		t.Fatalf("non-member read: want 403, got %d", res.StatusCode)
	}
}

// A student can neither read nor see a DM between the manager and a
// different student. The privacy guarantee, exercised over real HTTP.
func TestChatAPI_StudentCannotReadOthersDM(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()

	// Student A is the DM recipient; student B is the would-be snoop.
	studentA := seedStudent(t, r)
	studentB := seedStudent(t, r)
	var bEmail string
	if err := store.TestDB(r.server.store).QueryRowContext(ctx,
		`SELECT email FROM users WHERE id = ?`, studentB,
	).Scan(&bEmail); err != nil {
		t.Fatalf("studentB email: %v", err)
	}

	// Manager opens a DM with A and sends a private line.
	dm, err := r.server.store.OpenDM(ctx, r.studioID, r.mgrID, studentA)
	if err != nil {
		t.Fatalf("open dm: %v", err)
	}
	if _, err := r.server.store.SendMessage(ctx, r.studioID, r.mgrID, dm.ID, "between us"); err != nil {
		t.Fatalf("send: %v", err)
	}

	// B is refused the messages...
	res := r.as(bEmail).do(http.MethodGet, "/conversations/"+dm.ID+"/messages", nil)
	if res.StatusCode != http.StatusForbidden {
		t.Fatalf("studentB read others' DM: want 403, got %d", res.StatusCode)
	}
	// ...and the DM is absent from B's inbox entirely.
	res = r.do(http.MethodGet, "/conversations", nil)
	for _, c := range decode[[]store.Conversation](t, res) {
		if c.ID == dm.ID {
			t.Fatalf("DM leaked into a non-participant's conversation list")
		}
	}
}
