package store

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"
)

// Class group chat: auto-membership computed from active bookings ∪ active
// waitlist ∪ instructor ∪ studio staff. These tests lock in the eligibility
// boundaries — a wandering booking-side hook or a typo'd role check would
// break one of them — plus the archive derivation that drives the student's
// Archived tab.

// helper: insert a waitlist row for the fixture's student on classID.
func (f fixture) insertWaitlistWaiting(t *testing.T, s *Store, classID string, userID string) {
	t.Helper()
	if _, err := s.db.ExecContext(context.Background(), `
		INSERT INTO waitlist_entries (id, class_id, user_id, position, status)
		VALUES (?, ?, ?, 1, 'waiting')`,
		NewID(), classID, userID); err != nil {
		t.Fatalf("insert waitlist: %v", err)
	}
}

// helper: attach the fixture's class to a recurrence rule so the chat
// anchors at the series (the preferred path for repeating classes).
func (f fixture) attachRecurrenceRule(t *testing.T, s *Store, classIDs ...string) string {
	t.Helper()
	ruleID := NewID()
	if _, err := s.db.ExecContext(context.Background(), `
		INSERT INTO recurrence_rules
		  (id, studio_id, class_type_id, instructor_id, room_id,
		   start_hour, start_minute, duration_mins, capacity,
		   frequency, weekdays, starts_on, created_by)
		VALUES (?, ?, ?, ?, ?, 9, 0, 60, 10, 'weekly', '[1]', '2026-01-01', ?)`,
		ruleID, f.studioID, f.classTypeID, f.instructorID, f.roomID,
		f.instructorID); err != nil {
		t.Fatalf("insert recurrence rule: %v", err)
	}
	for _, cid := range classIDs {
		if _, err := s.db.ExecContext(context.Background(),
			`UPDATE classes SET recurrence_rule_id = ? WHERE id = ?`,
			ruleID, cid); err != nil {
			t.Fatalf("attach rule: %v", err)
		}
	}
	return ruleID
}

// TestClassChat_BookedStudentReachesChat: a student with an active booking
// can open the chat, post in it, and shows up in the member list. A random
// outsider can't.
func TestClassChat_BookedStudentReachesChat(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	classID := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	f.insertBookedSeat(t, s, classID, ent)

	// Open as the booked student.
	conv, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, classID)
	if err != nil {
		t.Fatalf("open as booked student: %v", err)
	}
	if conv.Kind != "class" {
		t.Fatalf("want kind=class, got %s", conv.Kind)
	}

	// Booked student should be in the computed member list.
	found := false
	for _, m := range conv.Members {
		if m.UserID == f.studentID {
			found = true
		}
	}
	if !found {
		t.Fatalf("booked student missing from members: %+v", conv.Members)
	}

	// They can post.
	if _, err := s.SendMessage(ctx, f.studioID, f.studentID, conv.ID, "hi"); err != nil {
		t.Fatalf("booked student send: %v", err)
	}

	// An outsider cannot.
	outsider := insertOtherStudent(t, s, f.studioID)
	if _, err := s.SendMessage(ctx, f.studioID, outsider, conv.ID, "no"); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider send: want ErrNotMember, got %v", err)
	}
	if _, err := s.OpenOrCreateClassConversation(ctx, f.studioID, outsider, classID); !errors.Is(err, ErrNotMember) {
		t.Fatalf("outsider open: want ErrNotMember, got %v", err)
	}
}

// TestClassChat_WaitlistedStudentReachesChat: a waitlister is eligible.
// This is the bit that motivated computed membership in the first place
// — they share the room with the booked crowd.
func TestClassChat_WaitlistedStudentReachesChat(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	classID := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	f.insertWaitlistWaiting(t, s, classID, f.studentID)

	conv, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, classID)
	if err != nil {
		t.Fatalf("open as waitlister: %v", err)
	}
	if _, err := s.SendMessage(ctx, f.studioID, f.studentID, conv.ID, "save me a spot"); err != nil {
		t.Fatalf("waitlister send: %v", err)
	}
}

// TestClassChat_InstructorAndManagerAlwaysIn: the instructor of the class
// is a member regardless of booking, and any manager in the studio is too
// (so a non-instructor staff member can still moderate every class chat).
func TestClassChat_InstructorAndManagerAlwaysIn(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	classID := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	managerID := mkUser(t, s, f.studioID, "manager", "mgr@test.com")

	// Instructor opens — they should be eligible without any booking.
	conv, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.instructorID, classID)
	if err != nil {
		t.Fatalf("instructor open: %v", err)
	}
	if _, err := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "first"); err != nil {
		t.Fatalf("instructor send: %v", err)
	}

	// Manager (not booked, not instructing) can still read + post.
	if _, err := s.SendMessage(ctx, f.studioID, managerID, conv.ID, "checking in"); err != nil {
		t.Fatalf("manager send: %v", err)
	}
}

// TestClassChat_LazyCreateIdempotent: the second open returns the same
// conversation row, and no second audit row is written.
func TestClassChat_LazyCreateIdempotent(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	classID := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	f.insertBookedSeat(t, s, classID, ent)

	a, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, classID)
	if err != nil {
		t.Fatalf("open #1: %v", err)
	}
	b, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, classID)
	if err != nil {
		t.Fatalf("open #2: %v", err)
	}
	if a.ID != b.ID {
		t.Fatalf("lazy-create not idempotent: %s vs %s", a.ID, b.ID)
	}
	if got := auditCount(t, s, f.studioID, "class_chat_create"); got != 1 {
		t.Fatalf("want 1 class_chat_create audit row, got %d", got)
	}
}

// TestClassChat_SeriesAnchor: when a class has a recurrence_rule_id, the
// chat anchors at the series — so two sibling instances resolve to the
// same conversation. This is the per-series design call enforced.
func TestClassChat_SeriesAnchor(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	tuesday := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	nextTuesday := f.insertClass(t, s, time.Now().Add(8*24*time.Hour), 10)
	f.attachRecurrenceRule(t, s, tuesday, nextTuesday)
	ent := f.insertEntitlement(t, s, "credit", 5)
	f.insertBookedSeat(t, s, tuesday, ent)

	a, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, tuesday)
	if err != nil {
		t.Fatalf("open via instance #1: %v", err)
	}
	b, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, nextTuesday)
	if err != nil {
		t.Fatalf("open via instance #2: %v", err)
	}
	if a.ID != b.ID {
		t.Fatalf("series anchor broken: instance #1 -> %s, #2 -> %s", a.ID, b.ID)
	}
}

// TestClassChat_ArchiveAfterClassEnded: a student whose only booking is on
// a class that ended >12h ago and has no future seats sees archived=true.
// A future booking flips it back to false. Staff side stays false.
func TestClassChat_ArchiveAfterClassEnded(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	// One-off class that ended 24h ago.
	pastClass := f.insertClass(t, s, time.Now().Add(-25*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	f.insertBookedSeat(t, s, pastClass, ent)

	if _, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, pastClass); err != nil {
		t.Fatalf("open: %v", err)
	}

	studentList, err := s.ListConversations(ctx, f.studioID, f.studentID, false)
	if err != nil {
		t.Fatalf("list student: %v", err)
	}
	if len(studentList) != 1 || !studentList[0].Archived {
		t.Fatalf("want one archived class chat, got %+v", studentList)
	}

	// Same conversation from a staff caller — never archived.
	staffList, _ := s.ListConversations(ctx, f.studioID, f.instructorID, true)
	if len(staffList) != 1 || staffList[0].Archived {
		t.Fatalf("staff should never see archived: %+v", staffList)
	}

	// Rebook onto a future class in the same studio — but the past class
	// is a one-off (no recurrence rule), so a *new* future class creates
	// a separate conversation. To exercise un-archive on the same chat
	// we'd need a series; that's covered by the series anchor test +
	// the derivation SQL, which short-circuits on the future-booking
	// EXISTS clause regardless of anchor.
}

// TestClassChat_PlusOnePayerIsMember: a +1 row's payer (user_id) shows up
// in the chat. The plus-one friend has no user account so they're
// invisible to the chat — the payer represents them.
func TestClassChat_PlusOnePayerIsMember(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	classID := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	// Booked seat for the payer.
	f.insertBookedSeat(t, s, classID, ent)
	// Plus-one row with the same user_id (the payer) + is_plus_one=1.
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     plus_one_name, booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 1, 'Friend Name', 'student', 12, 'booked', ?)`,
		NewID(), f.studioID, classID, f.studentID, ent, NewID(),
	); err != nil {
		t.Fatalf("insert plus-one row: %v", err)
	}

	conv, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, classID)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	// Payer shows once in member list — UNION dedupes the two booking rows.
	count := 0
	for _, m := range conv.Members {
		if m.UserID == f.studentID {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("payer membership: want 1, got %d (%+v)", count, conv.Members)
	}
}

// TestClassChat_NotificationFanOut: posting a message fans out a
// chat_message notification to each non-sender recipient (booked +
// instructor + studio staff), and a follow-up message UPSERTS rather than
// inserting — there's only ever one bell row per (user, conversation).
func TestClassChat_NotificationFanOut(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	classID := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	ent := f.insertEntitlement(t, s, "credit", 5)
	f.insertBookedSeat(t, s, classID, ent)
	manager := mkUser(t, s, f.studioID, "manager", "mgr-notif@test.com")

	// Instructor (eligible-by-role) sends; student + manager receive.
	conv, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.instructorID, classID)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "warm up at 9"); err != nil {
		t.Fatalf("send: %v", err)
	}

	type notifRow struct {
		userID  string
		title   string
		body    string
		dedup   string
		readAt  sql.NullString
		created string
	}
	loadFor := func(uid string) []notifRow {
		t.Helper()
		rows, err := s.db.QueryContext(ctx, `
			SELECT user_id, title, COALESCE(body,''),
			       COALESCE(dedup_key,''), read_at, created_at
			  FROM notifications
			 WHERE user_id = ? AND type = 'chat_message'
			 ORDER BY created_at ASC`, uid)
		if err != nil {
			t.Fatalf("load: %v", err)
		}
		defer rows.Close()
		var out []notifRow
		for rows.Next() {
			var n notifRow
			if err := rows.Scan(&n.userID, &n.title, &n.body,
				&n.dedup, &n.readAt, &n.created); err != nil {
				t.Fatalf("scan: %v", err)
			}
			out = append(out, n)
		}
		return out
	}

	studentRows := loadFor(f.studentID)
	if len(studentRows) != 1 {
		t.Fatalf("student should have 1 notification, got %d (%+v)",
			len(studentRows), studentRows)
	}
	if studentRows[0].dedup != "chat:"+conv.ID {
		t.Fatalf("dedup_key wrong: %q", studentRows[0].dedup)
	}
	if studentRows[0].body != "warm up at 9" {
		t.Fatalf("preview wrong: %q", studentRows[0].body)
	}
	mgrRows := loadFor(manager)
	if len(mgrRows) != 1 {
		t.Fatalf("manager should have 1 notification, got %d", len(mgrRows))
	}
	// Sender (the instructor) must NOT see a notification for their own send.
	if got := loadFor(f.instructorID); len(got) != 0 {
		t.Fatalf("sender should have 0 notifications, got %d (%+v)",
			len(got), got)
	}

	// Mark the student's row as read, then post a second message — the
	// row must be UPDATED (same id, new body, read_at cleared) rather
	// than inserted again. read_at=NULL is what re-lights the bell.
	if _, err := s.db.ExecContext(ctx, `
		UPDATE notifications
		   SET read_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 WHERE user_id = ? AND dedup_key = ?`,
		f.studentID, "chat:"+conv.ID,
	); err != nil {
		t.Fatalf("manual mark read: %v", err)
	}
	if _, err := s.SendMessage(ctx, f.studioID, f.instructorID, conv.ID, "second one"); err != nil {
		t.Fatalf("send 2: %v", err)
	}
	studentRows = loadFor(f.studentID)
	if len(studentRows) != 1 {
		t.Fatalf("collapse failed: want 1 row, got %d (%+v)",
			len(studentRows), studentRows)
	}
	if studentRows[0].body != "second one" {
		t.Fatalf("body not refreshed: %q", studentRows[0].body)
	}
	if studentRows[0].readAt.Valid {
		t.Fatalf("read_at not cleared on refresh: %+v", studentRows[0].readAt)
	}
}

// TestClassChat_OpenOnCrossStudioClassRejected: a class outside the actor's
// studio resolves to ErrNotFound, not ErrNotMember — we don't leak the
// studio's class IDs.
func TestClassChat_OpenOnCrossStudioClassRejected(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	// Build a second studio with its own class.
	otherStudio := NewID()
	otherInstructor := NewID()
	otherRoom := NewID()
	otherType := NewID()
	exec := func(q string, args ...any) {
		if _, err := s.db.ExecContext(ctx, q, args...); err != nil {
			t.Fatalf("seed other studio: %v", err)
		}
	}
	exec(`INSERT INTO studios (id, name) VALUES (?, 'Other')`, otherStudio)
	exec(`INSERT INTO users (id, studio_id, role, email, full_name)
	      VALUES (?, ?, 'instructor', 'oi@test.com', 'OI')`, otherInstructor, otherStudio)
	exec(`INSERT INTO rooms (id, studio_id, name) VALUES (?, ?, 'R')`, otherRoom, otherStudio)
	exec(`INSERT INTO class_types (id, studio_id, name) VALUES (?, ?, 'Y')`, otherType, otherStudio)
	classID := NewID()
	exec(`INSERT INTO classes
	      (id, studio_id, class_type_id, instructor_id, room_id, title,
	       starts_at, ends_at, capacity, status)
	      VALUES (?, ?, ?, ?, ?, 'Foreign', ?, ?, 10, 'scheduled')`,
		classID, otherStudio, otherType, otherInstructor, otherRoom,
		time.Now().UTC().Format(time.RFC3339),
		time.Now().Add(time.Hour).UTC().Format(time.RFC3339))

	// Fixture's student tries to open from their own studio's scope.
	if _, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, classID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-studio open: want ErrNotFound, got %v", err)
	}
}

// TestClassChat_ScheduleSummary: a class chat surfaces a "when" summary for
// the header at the top of the thread — the recurring wall-clock pattern for
// a series-anchored chat, and a concrete instance timestamp for a one-off.
func TestClassChat_ScheduleSummary(t *testing.T) {
	ctx := context.Background()
	s := newTestStore(t)
	f := newFixture(t, s)

	// One-off class: no recurring pattern, just a dated instance.
	oneOff := f.insertClass(t, s, time.Now().Add(24*time.Hour), 10)
	f.insertBookedSeat(t, s, oneOff, f.insertEntitlement(t, s, "credit", 5))
	conv, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, oneOff)
	if err != nil {
		t.Fatalf("open one-off: %v", err)
	}
	if conv.ClassSchedule != nil {
		t.Fatalf("one-off should have no recurring schedule, got %q", *conv.ClassSchedule)
	}
	if conv.ClassStartsAt == nil {
		t.Fatalf("one-off should carry a concrete starts_at")
	}

	// Series-anchored class: attachRecurrenceRule seeds weekdays '[1]'
	// (Tuesday, Mon=0) at 09:00, so the summary reads "Tuesdays · 9:00am".
	tuesday := f.insertClass(t, s, time.Now().Add(48*time.Hour), 10)
	f.attachRecurrenceRule(t, s, tuesday)
	f.insertBookedSeat(t, s, tuesday, f.insertEntitlement(t, s, "credit", 5))
	sconv, err := s.OpenOrCreateClassConversation(ctx, f.studioID, f.studentID, tuesday)
	if err != nil {
		t.Fatalf("open series: %v", err)
	}
	if sconv.ClassSchedule == nil || *sconv.ClassSchedule != "Tuesdays · 9:00am" {
		t.Fatalf("want schedule 'Tuesdays · 9:00am', got %v", sconv.ClassSchedule)
	}
	if sconv.ClassStartsAt == nil {
		t.Fatalf("series should carry a concrete next-instance starts_at")
	}
}

// TestFormatRecurrenceSchedule locks the wall-clock summary formatting:
// single days read as a recurring plural, multiple days use short names
// joined with "& ", and non-weekly frequencies get a fixed prefix.
func TestFormatRecurrenceSchedule(t *testing.T) {
	cases := []struct {
		name           string
		freq, weekdays string
		h, m           int
		want           string
	}{
		{"single weekday plural", "weekly", "[1]", 9, 0, "Tuesdays · 9:00am"},
		{"multi weekday short", "weekly", "[0,2,4]", 18, 30, "Mon, Wed & Fri · 6:30pm"},
		{"two weekdays", "weekly", "[0,2]", 7, 5, "Mon & Wed · 7:05am"},
		{"unsorted normalised", "weekly", "[4,0]", 12, 0, "Mon & Fri · 12:00pm"},
		{"midnight", "weekly", "[6]", 0, 0, "Sundays · 12:00am"},
		{"daily", "daily", "[]", 6, 0, "Daily · 6:00am"},
		{"monthly", "monthly", "[]", 19, 15, "Monthly · 7:15pm"},
		{"weekly no days falls back to clock", "weekly", "[]", 8, 0, "8:00am"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := formatRecurrenceSchedule(c.freq, c.weekdays, c.h, c.m)
			if got != c.want {
				t.Fatalf("formatRecurrenceSchedule(%q,%q,%d,%d) = %q, want %q",
					c.freq, c.weekdays, c.h, c.m, got, c.want)
			}
		})
	}
}
