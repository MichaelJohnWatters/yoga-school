package store

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"log"
	"time"
)

func ptr[T any](v T) *T { return &v }

// seedSplashImage is a real studio photo bundled into the binary so the
// bootstrap-api seed can populate the media library through the actual
// UploadMedia path (and show off the splash). Only used when media storage is
// wired; otherwise the seed step lands in the skipped-steps summary.
//
//go:embed seeddata/studio_class.webp
var seedSplashImage []byte

// seedReport accumulates the best-effort failures across a bootstrap-api run.
// Individual steps still log as they happen (so the failure is visible inline),
// but the report lets SeedDevAPI print one consolidated summary at the end —
// the bit you actually scan to answer "did the seed run clean, and if not,
// what got skipped?" without combing through the whole startup log.
type seedReport struct{ skipped []string }

// note records a best-effort failure. Returns true when err was non-nil, so
// callers can keep using it as the `if failed { … }` guard they already had.
func (r *seedReport) note(step string, err error) bool {
	if err == nil {
		return false
	}
	log.Printf("bootstrap-api: skipped %q: %v", step, err)
	r.skipped = append(r.skipped, fmt.Sprintf("%s: %v", step, err))
	return true
}

// try runs a step and records it if it fails — the closure form used by the
// breadth / textures passes.
func (r *seedReport) try(step string, fn func() error) { r.note(step, fn()) }

// summary logs the end-of-run roundup.
func (r *seedReport) summary() {
	if len(r.skipped) == 0 {
		log.Printf("bootstrap-api: seed complete — all steps succeeded")
		return
	}
	log.Printf("bootstrap-api: seed complete — %d step(s) skipped:", len(r.skipped))
	for _, s := range r.skipped {
		log.Printf("bootstrap-api:   • %s", s)
	}
}

// SeedDevAPI builds the dev studio the same way a real one comes to life:
// a minimal hand-written *bootstrap* (the chicken-and-egg rows that have no
// "create" endpoint — studio, theme, users, rooms, class types, products,
// and the week of classes) followed by the transactional layer driven
// through the REAL, audited store methods (grants, bookings, attendance, …).
//
// Why bother vs the all-SQL SeedDev: those store methods are the same code
// paths the app uses, so the seeded data exercises real validation + credit
// math AND — the main reason — leaves proper rows in audit_log, so the
// manager Activity log isn't empty against a fresh seed.
//
// No clock/time overrides: we only drive methods that work at real "now"
// (book a genuinely-future class, mark attendance on any booking). The few
// rows that need to be *in the past* to exist (a booking on an already-ended
// class) stay as clearly-labelled SQL fixtures — see seedPastBookingFixture.
//
// Idempotent at the bootstrap layer (INSERT OR IGNORE + fixed IDs); the
// transactional layer is guarded so a re-run doesn't double-book.
func (s *Store) SeedDevAPI(ctx context.Context) error {
	// 1. Bootstrap — fixed-ID foundation the dev client + tests reference.
	if err := s.seedStatics(ctx); err != nil {
		return fmt.Errorf("bootstrap statics: %w", err)
	}
	if err := s.seedSchedule(ctx); err != nil {
		return fmt.Errorf("bootstrap schedule: %w", err)
	}
	// 2. Transactional layer — through the audited methods. Best-effort steps
	//    record into rep so we can print one summary at the end.
	rep := &seedReport{}
	if err := s.seedTransactionsAPI(ctx, rep); err != nil {
		return fmt.Errorf("api transactions: %w", err)
	}
	rep.summary()
	// Backfill check-in tokens for the SQL fixture bookings (live bookings
	// minted by CreateBooking already carry one).
	_, err := s.db.ExecContext(ctx, `
		UPDATE bookings SET checkin_token = lower(hex(randomblob(8)))
		 WHERE checkin_token IS NULL`)
	return err
}

// seedTransactionsAPI layers audited, method-built activity on top of the
// bootstrap so the Activity log has real entries to show. Each step is a
// no-op-friendly demonstration of one action type.
func (s *Store) seedTransactionsAPI(ctx context.Context, rep *seedReport) error {
	const manager = UserPriya // the bootstrap manager, actor for staff actions

	// Idempotent: if a prior bootstrap-api run already laid down the audited
	// transactional layer, don't double-book / double-grant on re-run.
	var priorGrants int
	if err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM audit_log
		 WHERE studio_id = ? AND action = 'cash_grant'`, StudioID,
	).Scan(&priorGrants); err != nil {
		return err
	}
	if priorGrants > 0 {
		return nil
	}

	if err := s.seedDemoStudents(ctx); err != nil {
		return err
	}
	classes, err := s.futureYogaClassIDs(ctx, 4)
	if err != nil {
		return err
	}

	// --- Maya: granted pass → books a future class → has past attendance ---

	// Manager grants Maya a 10-class yoga pass → audited (cash_grant) and
	// mints a real credit entitlement we can then book against.
	grant, err := s.GrantPass(ctx, StudioID, manager, UserMaya, GrantPassInput{
		ProductID:     ProductTenPack,
		PaymentMethod: "cash",
		Note:          "Bootstrap-api demo grant",
	})
	if err != nil {
		return fmt.Errorf("grant pass: %w", err)
	}
	// Maya self-books a future yoga class she isn't already on → audited
	// booking_create, decrements the granted pass for real.
	if classID, err := s.nextBookableYogaClass(ctx, UserMaya); err != nil {
		return err
	} else if classID != "" {
		if _, err := s.CreateBooking(
			ctx, StudioID, UserMaya, classID, grant.EntitlementID, false, "",
		); err != nil {
			return fmt.Errorf("maya booking: %w", err)
		}
	}
	// Past attendance through the real MarkAttendance. CreateBooking can't
	// make a booking on an already-ended class (correctly — it's a gate), so
	// the booking ROW is a labelled SQL fixture; the attendance MARK still
	// runs through the audited method (attendance_mark).
	if bookingID, err := s.seedPastBookingFixture(ctx, UserMaya, grant.EntitlementID); err != nil {
		return err
	} else if bookingID != "" {
		if err := s.MarkAttendance(ctx, manager, bookingID, "attended", "manual"); err != nil {
			return fmt.Errorf("mark attendance: %w", err)
		}
	}

	// --- Ben: buys a 5-pack → books → changes his mind and cancels ---
	// (purchase → booking_create → booking_cancel, credit refunded for real)
	if benEnt, err := s.demoPurchase(ctx, UserBen, ProductFivePack); err != nil {
		return err
	} else if len(classes) > 0 {
		bid, err := s.CreateBooking(ctx, StudioID, UserBen, classes[0], benEnt, false, "")
		if err != nil {
			return fmt.Errorf("ben booking: %w", err)
		}
		if err := s.CancelBooking(ctx, UserBen, bid); err != nil {
			return fmt.Errorf("ben cancel: %w", err)
		}
	}

	// --- Ivy: buys a 10-pack → books → brings a +1 ---
	// (purchase → booking_create → booking_plus_one, two credits spent)
	if ivyEnt, err := s.demoPurchase(ctx, UserIvy, ProductTenPack); err != nil {
		return err
	} else if len(classes) > 1 {
		if _, err := s.CreateBooking(ctx, StudioID, UserIvy, classes[1], ivyEnt, false, ""); err != nil {
			return fmt.Errorf("ivy booking: %w", err)
		}
		if _, err := s.AddPlusOneToBooking(ctx, StudioID, UserIvy, classes[1], ivyEnt, "Sam Patel"); err != nil {
			return fmt.Errorf("ivy +1: %w", err)
		}
	}

	// --- Kira: buys a 10-pack → a one-seat class fills → Ben joins waitlist ---
	// (purchase → class_create → booking_create → waitlist_join). We mint a
	// capacity-1 class so a single booking fills it without needing a crowd.
	if kiraEnt, err := s.demoPurchase(ctx, UserKira, ProductTenPack); err != nil {
		return err
	} else if small, err := s.seedSmallFutureClass(ctx, manager); err != nil {
		return err
	} else if small != "" {
		if _, err := s.CreateBooking(ctx, StudioID, UserKira, small, kiraEnt, false, ""); err != nil {
			return fmt.Errorf("kira booking: %w", err)
		}
		if _, err := s.JoinWaitlist(ctx, UserBen, small); err != nil {
			return fmt.Errorf("ben waitlist: %w", err)
		}
	}

	// Breadth pass: exercise as many of the remaining audited admin methods
	// as we can, so the Activity log shows the full range of action types.
	s.seedBreadthAPI(ctx, manager, classes, rep)

	// Variety pass: a real cast of regulars booked to a deliberate spread of
	// fill levels (empty / light / half / full + waitlist) across yoga AND
	// reformer, so the schedule looks alive rather than empty.
	s.seedFillVarietyAPI(ctx, manager, rep)

	// Friends pass: several students who book on a credit pass AND bring a
	// guest, so the schedule has a realistic spread of +1 bookings (not just
	// the single demo one). Plus-ones need a credit pass — these students get
	// one rather than the cohort's unlimited.
	s.seedFriendBookingsAPI(ctx, manager, rep)

	// Chat pass: a staff group, a student group, DMs, and a class chat with
	// real messages — so the Messages screen isn't empty after seeding.
	s.seedChatAPI(ctx, manager, rep)

	// History pass: give the cohort past attendance (mostly attended, a few
	// no-shows) so profile charts + reports aren't blank. Past bookings can't
	// be made via CreateBooking (gate), so the booking rows are SQL fixtures;
	// the attendance MARK still runs through the audited MarkAttendance.
	s.seedAttendanceHistoryAPI(ctx, manager, rep)

	// Waitlist dynamics: someone leaves a waitlist, and on a freshly-staged
	// full class a seat frees and the next waiter is promoted — completing the
	// join → leave → promote lifecycle (all audited).
	s.seedWaitlistDynamicsAPI(ctx, manager, rep)

	// Schedule edits: a class gets edited (class_update) and a populated class
	// gets cancelled (class_cancel with a real affected-students list).
	s.seedScheduleEditsAPI(ctx, manager, rep)

	// Final textures: a recurring series (rule_create), a partial refund, a
	// second void flavour, and a deliberately depleted pass for UI states.
	s.seedMoreTexturesAPI(ctx, manager, rep)
	return nil
}

// seedMoreTexturesAPI rounds out coverage with a recurrence rule, a purchase
// refund, an "unused" void, and a depleted credit pass. Best-effort.
func (s *Store) seedMoreTexturesAPI(ctx context.Context, manager string, rep *seedReport) {
	// A weekly recurring class (rule_create + generated instances). The
	// rule_create audit is written by the HTTP handler, not the store method,
	// so we replicate that WriteAudit here exactly as the handler does.
	rep.try("rule_create", func() error {
		title := "Tuesday Power Hour"
		res, err := s.CreateRecurringClasses(ctx, StudioID, manager, RecurrenceClassInput{
			Title: title, ClassTypeID: ClassTypeYoga,
			InstructorID: InstructorMara, RoomID: Room1,
			StartHour: 18, StartMinute: 30, DurationMins: 60, Capacity: 14,
			Recurrence: RecurrenceInput{
				Frequency: "weekly", Interval: 1, Weekdays: []int{1},
				StartsOn:    time.Now().UTC().AddDate(0, 0, 7).Format("2006-01-02"),
				Occurrences: 6,
			},
		})
		if err != nil {
			return err
		}
		return s.WriteAudit(ctx, StudioID, manager, "rule_create", "recurrence_rule", res.RuleID, map[string]any{
			"title":    title,
			"sessions": len(res.GeneratedClassIDs),
		})
	})

	// Partial refund on a real completed purchase (purchase_refund).
	rep.try("purchase_refund", func() error {
		var pid string
		if err := s.db.QueryRowContext(ctx, `
			SELECT id FROM purchases
			 WHERE studio_id = ? AND status = 'completed'
			 ORDER BY created_at DESC LIMIT 1`, StudioID,
		).Scan(&pid); err != nil {
			return err
		}
		return s.RefundPurchase(ctx, StudioID, manager, pid, 500, "Goodwill partial refund")
	})

	// A second void flavour ("unused" rather than "full").
	rep.try("void_unused", func() error {
		_, ent, err := s.CreatePurchase(ctx, StudioID, UserBen, ProductDropIn, "card", "")
		if err != nil {
			return err
		}
		_, err = s.VoidEntitlement(ctx, StudioID, manager, ent, VoidInput{
			Refund: "unused", Reason: "Changed to a class pack instead",
		})
		return err
	})

	// A deliberately depleted credit pass — a student granted a 5-pack whose
	// balance is then adjusted to zero, so the UI's "no credits" state has
	// real data to show.
	rep.try("depleted_pass", func() error {
		id := "u_depleted"
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO users (id, studio_id, role, email, full_name, photo_url)
			VALUES (?, ?, 'student', 'depleted@studio52.dev', 'Theo Marsh',
			        'https://i.pravatar.cc/200?u=depleted@studio52.dev')`,
			id, StudioID,
		); err != nil {
			return err
		}
		grant, err := s.GrantPass(ctx, StudioID, manager, id, GrantPassInput{
			ProductID: ProductFivePack, PaymentMethod: "card", Note: "Trial pack",
		})
		if err != nil {
			return err
		}
		return s.AdjustCredits(ctx, StudioID, manager, grant.EntitlementID, AdjustCreditsInput{
			Delta: -5, Reason: "Used in studio before the app rolled out",
		})
	})
}

// seedScheduleEditsAPI edits one class and cancels a populated one. class_update
// is audited in the HTTP handler (not the store method), so we replicate that
// WriteAudit here exactly as the handler does; class_cancel is store-audited.
func (s *Store) seedScheduleEditsAPI(ctx context.Context, manager string, rep *seedReport) {
	// --- Edit a future class (bump capacity by 2). ---
	var editID, editTitle string
	var oldCap int
	_ = s.db.QueryRowContext(ctx, `
		SELECT id, COALESCE(title,''), capacity FROM classes
		 WHERE studio_id = ? AND status = 'scheduled' AND title IS NOT NULL
		   AND starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY starts_at ASC LIMIT 1`, StudioID,
	).Scan(&editID, &editTitle, &oldCap)
	if editID != "" {
		newCap := oldCap + 2
		if err := s.UpdateAdminClass(ctx, StudioID, editID, AdminClassInput{Capacity: &newCap}); rep.note("class edit", err) {
		} else {
			_ = s.WriteAudit(ctx, StudioID, manager, "class_update", "class", editID, map[string]any{
				"class_title":       editTitle,
				"fields_changed":    []string{"capacity"},
				"previous_capacity": oldCap,
				"capacity":          newCap,
				"scope":             "this",
			})
		}
	}

	// --- Cancel a populated future class so the audit's affected-students
	//     strip shows real names + refund outcomes. ---
	var cancelID string
	_ = s.db.QueryRowContext(ctx, `
		SELECT c.id FROM classes c
		 WHERE c.studio_id = ? AND c.status = 'scheduled'
		   AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		   AND (SELECT COUNT(*) FROM bookings b
		         WHERE b.class_id = c.id AND b.status = 'booked') >= 3
		 ORDER BY c.starts_at DESC LIMIT 1`, StudioID,
	).Scan(&cancelID)
	if cancelID != "" {
		if _, err := s.CancelAdminClassWithAudit(ctx, StudioID, manager, cancelID); err != nil {
			rep.note("populated class cancel", err)
		}
	}
}

// seedWaitlistDynamicsAPI exercises waitlist_leave and waitlist_promote. The
// promote is staged deterministically (a one-seat class so a single cancel
// frees the seat) and promoted explicitly — the cancel's async auto-promote
// goroutine wouldn't survive this short-lived seed process.
func (s *Store) seedWaitlistDynamicsAPI(ctx context.Context, manager string, rep *seedReport) {
	// --- Leave: pull an existing waiter off their waitlist. ---
	var leaveUser, leaveClass string
	_ = s.db.QueryRowContext(ctx, `
		SELECT user_id, class_id FROM waitlist_entries
		 WHERE status = 'waiting' ORDER BY id LIMIT 1`,
	).Scan(&leaveUser, &leaveClass)
	if leaveUser != "" {
		if err := s.LeaveWaitlist(ctx, leaveUser, leaveClass); err != nil {
			rep.note("waitlist leave", err)
		}
	}

	// --- Promote: stage a one-seat class, fill it, waitlist a second
	//     student, cancel the seat, then promote the waiter. ---
	students := s.studentsWithPassFor(ctx, ClassTypeYoga, 2)
	if len(students) < 2 {
		return
	}
	startsAt := time.Now().UTC().Add(4 * 24 * time.Hour).Add(19 * time.Hour).Format(time.RFC3339)
	title := "Sunrise 1:1 Flow"
	// Yoga, so the common (yoga-covering) passes can book it.
	ct, inst, room, dur, cap := ClassTypeYoga, InstructorAsha, Room1, 60, 1
	classID, err := s.CreateAdminClassWithAudit(ctx, StudioID, manager, AdminClassInput{
		ClassTypeID: &ct, InstructorID: &inst, RoomID: &room, Title: &title,
		StartsAt: &startsAt, DurationMins: &dur, Capacity: &cap,
	})
	if rep.note("promote class", err) {
		return
	}
	bookingID, err := s.CreateBooking(ctx, StudioID, students[0].userID, classID, students[0].entID, false, "")
	if rep.note("promote book", err) {
		return
	}
	if _, err := s.JoinWaitlist(ctx, students[1].userID, classID); rep.note("promote waitlist", err) {
		return
	}
	if err := s.CancelBooking(ctx, students[0].userID, bookingID); rep.note("promote cancel", err) {
		return
	}
	if _, err := s.PromoteWaitlist(ctx, StudioID, manager, classID); err != nil {
		rep.note("promote", err)
	}
}

type studentPass struct{ userID, entID string }

// studentsWithPassFor returns up to n students that hold an active entitlement
// which COVERS classTypeID and is bookable (unlimited, or credits left) — so a
// booking staged against that class type will actually go through.
func (s *Store) studentsWithPassFor(ctx context.Context, classTypeID string, n int) []studentPass {
	rows, err := s.db.QueryContext(ctx, `
		SELECT u.id, MIN(e.id)
		  FROM users u
		  JOIN entitlements e               ON e.user_id = u.id
		  JOIN entitlement_class_types ect  ON ect.entitlement_id = e.id
		 WHERE u.studio_id = ? AND u.role = 'student' AND e.status = 'active'
		   AND ect.class_type_id = ?
		   AND (e.pass_kind = 'unlimited' OR e.credits_remaining > 0)
		 GROUP BY u.id LIMIT ?`, StudioID, classTypeID, n)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []studentPass
	for rows.Next() {
		var p studentPass
		if err := rows.Scan(&p.userID, &p.entID); err == nil {
			out = append(out, p)
		}
	}
	return out
}

// seedAttendanceHistoryAPI marks a spread of past attendances for the
// students who have a pass — attended for most, no_show for roughly every
// sixth — via the audited MarkAttendance. Booking rows on the (past) classes
// are labelled SQL fixtures.
func (s *Store) seedAttendanceHistoryAPI(ctx context.Context, manager string, rep *seedReport) {
	pastClasses := s.pastClassIDs(ctx, 10)
	if len(pastClasses) == 0 {
		return
	}
	type sp struct{ userID, entID string }
	var students []sp
	rows, err := s.db.QueryContext(ctx, `
		SELECT u.id, MIN(e.id)
		  FROM users u JOIN entitlements e ON e.user_id = u.id
		 WHERE u.studio_id = ? AND u.role = 'student' AND e.status = 'active'
		 GROUP BY u.id LIMIT 14`, StudioID)
	if rep.note("history students", err) {
		return
	}
	for rows.Next() {
		var p sp
		if err := rows.Scan(&p.userID, &p.entID); err == nil {
			students = append(students, p)
		}
	}
	rows.Close()

	n := 0
	for i, st := range students {
		// Two past sessions each, on different classes.
		for k := 0; k < 2; k++ {
			classID := pastClasses[(i+k)%len(pastClasses)]
			bookingID, err := s.pastBookingFixture(ctx, st.userID, classID, st.entID)
			if err != nil || bookingID == "" {
				continue
			}
			status := "attended"
			if n%6 == 5 {
				status = "no_show"
			}
			n++
			if err := s.MarkAttendance(ctx, manager, bookingID, status, "manual"); err != nil {
				rep.note("history mark", err)
			}
		}
	}
}

// pastClassIDs returns up to limit already-ended scheduled classes, most
// recent first.
func (s *Store) pastClassIDs(ctx context.Context, limit int) []string {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id FROM classes
		 WHERE studio_id = ? AND status = 'scheduled'
		   AND ends_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY starts_at DESC LIMIT ?`, StudioID, limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err == nil {
			out = append(out, id)
		}
	}
	return out
}

// pastBookingFixture inserts a single 'booked' row for userID on a specific
// (past) class, skipping if one already exists. Returns the booking id (or
// "" when skipped). The deliberate SQL fixture behind audited attendance.
func (s *Store) pastBookingFixture(ctx context.Context, userID, classID, entID string) (string, error) {
	var existing string
	if err := s.db.QueryRowContext(ctx, `
		SELECT id FROM bookings WHERE class_id = ? AND user_id = ? AND is_plus_one = 0`,
		classID, userID,
	).Scan(&existing); err == nil {
		return "", nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	id := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'booked', NULL)`,
		id, StudioID, classID, userID, entID,
	); err != nil {
		return "", err
	}
	return id, nil
}

// seedChatAPI populates the Messages surface through the real conversation +
// message methods: a staff group, a students group, two staff↔student DMs,
// and one class chat — each with a short, natural exchange. Best-effort.
func (s *Store) seedChatAPI(ctx context.Context, manager string, rep *seedReport) {
	send := func(sender, convID, body string) {
		if convID == "" {
			return
		}
		if _, err := s.SendMessage(ctx, StudioID, sender, convID, body); err != nil {
			rep.note("chat send", err)
		}
	}
	group := func(actor, title string, members []string, lines [][2]string) {
		conv, err := s.CreateConversation(ctx, StudioID, actor, title, members)
		if rep.note(fmt.Sprintf("chat group %q", title), err) {
			return
		}
		for _, l := range lines {
			send(l[0], conv.ID, l[1])
		}
	}

	// Staff team group.
	group(manager, "Studio 52 Team",
		[]string{InstructorAsha, InstructorJonas, InstructorMara},
		[][2]string{
			{manager, "Morning team 👋 new reformer mats land Thursday."},
			{InstructorAsha, "Finally! The old ones are on their last legs 😅"},
			{InstructorJonas, "I can take the Thursday 6pm if anyone needs cover."},
			{manager, "Perfect, thanks Jonas."},
		})

	// A regulars group (staff-started, includes students).
	group(InstructorAsha, "Vinyasa regulars 🌅",
		[]string{UserMaya, UserBen, "u_cast01", "u_cast02"},
		[][2]string{
			{InstructorAsha, "This week we're playing with longer holds — bring a strap if you have one."},
			{UserMaya, "Love that. See you Wednesday!"},
			{"u_cast01", "Can we work on crow again? 🐦"},
			{InstructorAsha, "Ha — yes, crow is on the menu."},
		})

	// Staff ↔ student DMs.
	if dm, err := s.OpenDM(ctx, StudioID, manager, UserMaya); err == nil {
		send(manager, dm.ID, "Hi Maya — your unlimited renews next week, all good?")
		send(UserMaya, dm.ID, "Yes, all good thanks! Loving the candlelit class 🕯️")
	} else {
		rep.note("dm", err)
	}
	if dm, err := s.OpenDM(ctx, StudioID, InstructorAsha, UserBen); err == nil {
		send(InstructorAsha, dm.ID, "Hey Ben — saw you waitlisted Sunset Slow Flow, I'll let you know the moment a spot opens.")
		send(UserBen, dm.ID, "Thanks Asha, appreciate it!")
	}

	// One class chat — anchored to a class that has bookings so a real
	// student is a member and can post.
	if classID, student := s.firstBookedFutureClass(ctx); classID != "" {
		if conv, err := s.OpenOrCreateClassConversation(ctx, StudioID, InstructorAsha, classID); err == nil {
			send(InstructorAsha, conv.ID, "Looking forward to seeing everyone! Doors open 10 min early.")
			if student != "" {
				send(student, conv.ID, "Should I bring my own block or are there spares?")
			}
			send(InstructorAsha, conv.ID, "Plenty of spares — just bring yourself ☺️")
		} else {
			rep.note("class chat", err)
		}
	}
}

// firstBookedFutureClass returns a future class that has at least one booked
// student, plus that student's id — so the class chat has a real member to
// post alongside staff.
func (s *Store) firstBookedFutureClass(ctx context.Context) (classID, studentID string) {
	_ = s.db.QueryRowContext(ctx, `
		SELECT b.class_id, b.user_id
		  FROM bookings b
		  JOIN classes c ON c.id = b.class_id
		 WHERE c.studio_id = ? AND b.status = 'booked' AND b.is_plus_one = 0
		   AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY c.starts_at ASC LIMIT 1`, StudioID,
	).Scan(&classID, &studentID)
	return classID, studentID
}

// friendBooking pairs a member with the guest they bring. thenCancels marks
// the ones who later cancel — exercising the +1 cascade (both seats released
// in one booking_cancel, cascade_count=2).
type friendBooking struct {
	memberName, friendName string
	thenCancels            bool
}

var friendBookings = []friendBooking{
	{memberName: "Hannah Wells", friendName: "Greg Wells"},
	{memberName: "Sam Okafor", friendName: "Tobi Okafor"},
	{memberName: "Lena Fischer", friendName: "Marta Fischer", thenCancels: true},
	{memberName: "Diego Alvarez", friendName: "Rosa Alvarez"},
	{memberName: "Priya Anand", friendName: "Karthik Anand", thenCancels: true},
}

// seedFriendBookingsAPI creates a few credit-pass students who each book a
// future class and bring a named +1 — all through GrantPass / CreateBooking /
// AddPlusOneToBooking, so each leaves real cash_grant + booking_create +
// booking_plus_one rows and two consumed credits. Best-effort per member.
func (s *Store) seedFriendBookingsAPI(ctx context.Context, manager string, rep *seedReport) {
	classes, err := s.futureYogaClassIDs(ctx, 8)
	if err != nil || len(classes) == 0 {
		return
	}
	for i, fb := range friendBookings {
		id := fmt.Sprintf("u_friend%02d", i+1)
		email := fmt.Sprintf("friend%02d@studio52.dev", i+1)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO users (id, studio_id, role, email, full_name, photo_url)
			VALUES (?, ?, 'student', ?, ?, ?)`,
			id, StudioID, email, fb.memberName, "https://i.pravatar.cc/200?u="+email,
		); rep.note(fmt.Sprintf("friend user %s", id), err) {
			continue
		}
		// Credit pass with room for a seat + a guest.
		grant, err := s.GrantPass(ctx, StudioID, manager, id, GrantPassInput{
			ProductID: ProductTenPack, PaymentMethod: "card",
			Note: "Joined with a friend",
		})
		if rep.note(fmt.Sprintf("friend pass %s", id), err) {
			continue
		}
		classID := classes[i%len(classes)]
		bookingID, err := s.CreateBooking(ctx, StudioID, id, classID, grant.EntitlementID, false, "")
		if rep.note(fmt.Sprintf("friend booking %s", id), err) {
			continue
		}
		if _, err := s.AddPlusOneToBooking(ctx, StudioID, id, classID, grant.EntitlementID, fb.friendName); rep.note(fmt.Sprintf("friend +1 %s", id), err) {
			continue
		}
		// Some change their mind — cancelling cascades to the guest's seat
		// too (one booking_cancel, both seats released).
		if fb.thenCancels {
			if err := s.CancelBooking(ctx, id, bookingID); err != nil {
				rep.note(fmt.Sprintf("friend cancel %s", id), err)
			}
		}
	}
}

// fillCastNames is the cohort of "regulars" the variety pass books around.
// Enough of them (16) to fill a normal-capacity class and still have a
// couple spare to sit on a waitlist.
var fillCastNames = []string{
	"Noah Bennett", "Emma Lopez", "Liam Walsh", "Ava Singh", "Oliver Reid",
	"Mia Fernandez", "Lucas Brandt", "Sophie Tan", "Ethan Cole", "Isla Murphy",
	"Mason Park", "Chloe Dubois", "Leo Schmidt", "Zara Ahmed", "Finn O'Connor",
	"Ruby Castellano",
}

type castMember struct{ userID, entitlementID string }

// seedFillVarietyAPI builds the cohort, gives each an unlimited pass (so any
// class type books cleanly), guarantees a couple of future reformer classes
// exist, then books the cohort to a varied fill pattern — all through the
// audited methods. Best-effort per step.
func (s *Store) seedFillVarietyAPI(ctx context.Context, manager string, rep *seedReport) {
	// 1. Build the cohort + grant each an unlimited (yoga+reformer) pass.
	var cast []castMember
	for i, name := range fillCastNames {
		id := fmt.Sprintf("u_cast%02d", i+1)
		email := fmt.Sprintf("cast%02d@studio52.dev", i+1)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO users (id, studio_id, role, email, full_name, photo_url)
			VALUES (?, ?, 'student', ?, ?, ?)`,
			id, StudioID, email, name, "https://i.pravatar.cc/200?u="+email,
		); rep.note(fmt.Sprintf("cast user %s", id), err) {
			continue
		}
		grant, err := s.GrantPass(ctx, StudioID, manager, id, GrantPassInput{
			ProductID: ProductUnlimitedMonthly, PaymentMethod: "comp",
			Note: "Founding-member comp",
		})
		if rep.note(fmt.Sprintf("cast pass %s", id), err) {
			continue
		}
		cast = append(cast, castMember{userID: id, entitlementID: grant.EntitlementID})
	}
	if len(cast) == 0 {
		return
	}

	// 2. Make sure there are a couple of future reformer classes to fill.
	for i := 0; i < 2; i++ {
		startsAt := time.Now().UTC().Add(time.Duration(2+i) * 24 * time.Hour).
			Add(18 * time.Hour).Format(time.RFC3339)
		title := fmt.Sprintf("Reformer Flow %d", i+1)
		ct, inst, room, dur, cap := ClassTypeReformer, InstructorJonas, RoomReformer, 60, 10
		if _, err := s.CreateAdminClassWithAudit(ctx, StudioID, manager, AdminClassInput{
			ClassTypeID: &ct, InstructorID: &inst, RoomID: &room, Title: &title,
			StartsAt: &startsAt, DurationMins: &dur, Capacity: &cap,
		}); err != nil {
			rep.note("reformer class", err)
		}
	}

	// 3. Curated fill targets across the next future classes (any type).
	type cls struct {
		id  string
		cap int
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, capacity FROM classes
		 WHERE studio_id = ? AND status = 'scheduled'
		   AND starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY starts_at ASC LIMIT 12`, StudioID)
	if rep.note("list future classes", err) {
		return
	}
	var classes []cls
	for rows.Next() {
		var c cls
		if err := rows.Scan(&c.id, &c.cap); err == nil {
			classes = append(classes, c)
		}
	}
	rows.Close()

	// Fraction-of-capacity per class — a spread from empty to full. 1.0
	// classes also get a couple of waitlisters.
	fracs := []float64{0.0, 0.25, 0.55, 1.0, 0.4, 0.1, 0.8, 0.0, 0.6, 1.0, 0.3, 0.5}
	for i, c := range classes {
		frac := fracs[i%len(fracs)]
		target := int(float64(c.cap)*frac + 0.5)
		if target > len(cast) {
			target = len(cast)
		}
		booked := s.bookCastInto(ctx, c.id, target, cast)
		if frac >= 1.0 {
			// Full → add up to two waitlisters from the remaining cohort.
			s.waitlistCastOnto(ctx, c.id, 2, cast, booked)
		}
	}
}

// bookCastInto books up to n cohort members (skipping any already on the
// class) via the real CreateBooking, returning the userIDs booked.
func (s *Store) bookCastInto(ctx context.Context, classID string, n int, cast []castMember) map[string]bool {
	booked := map[string]bool{}
	for _, m := range cast {
		if len(booked) >= n {
			break
		}
		if _, err := s.CreateBooking(ctx, StudioID, m.userID, classID, m.entitlementID, false, ""); err != nil {
			// Already booked / full / etc. — skip quietly, this is filler.
			continue
		}
		booked[m.userID] = true
	}
	return booked
}

// waitlistCastOnto joins up to n cohort members (not already booked) onto a
// full class's waitlist via the real JoinWaitlist.
func (s *Store) waitlistCastOnto(ctx context.Context, classID string, n int, cast []castMember, alreadyBooked map[string]bool) {
	joined := 0
	for _, m := range cast {
		if joined >= n {
			break
		}
		if alreadyBooked[m.userID] {
			continue
		}
		if _, err := s.JoinWaitlist(ctx, m.userID, classID); err != nil {
			continue
		}
		joined++
	}
}

// seedBreadthAPI fires a wide spread of audited admin methods so the seed
// covers nearly every action type the Activity log can render. Each step is
// best-effort: a step that can't run in the current state logs a warning and
// is skipped rather than aborting the whole seed — the point is breadth of
// coverage, not a transactional all-or-nothing.
func (s *Store) seedBreadthAPI(ctx context.Context, manager string, futureClasses []string, rep *seedReport) {

	// --- Money ---------------------------------------------------------
	rep.try("credit_adjust", func() error {
		ent, err := s.firstCreditEntitlement(ctx, UserIvy)
		if err != nil || ent == "" {
			return err
		}
		return s.AdjustCredits(ctx, StudioID, manager, ent, AdjustCreditsInput{
			Delta: 3, Reason: "Goodwill credit after a cancelled class",
		})
	})
	rep.try("void", func() error {
		// A throwaway pass to void, so we don't disturb the demo balances.
		_, ent, err := s.CreatePurchase(ctx, StudioID, UserKira, ProductDropIn, "card", "")
		if err != nil {
			return err
		}
		_, err = s.VoidEntitlement(ctx, StudioID, manager, ent, VoidInput{
			Refund: "full", Reason: "Bought the wrong class type",
		})
		return err
	})
	rep.try("discount", func() error {
		d, err := s.CreateDiscount(ctx, StudioID, manager, DiscountCreate{
			Code: ptr("WELCOME15"), Kind: "percent", Value: 15,
			Notes: "New-student welcome",
		})
		if err != nil {
			return err
		}
		return s.ArchiveDiscount(ctx, StudioID, manager, d.ID)
	})

	// --- Catalogue -----------------------------------------------------
	rep.try("product lifecycle", func() error {
		id, err := s.CreateAdminProduct(ctx, StudioID, manager, AdminProductInput{
			Name: ptr("Trial 3-pack"), PriceMinor: ptr(2400),
			BillingType: ptr("one_time"), PassKind: ptr("credit"), Credits: ptr(3),
			ValidityDays: ptr(60), ClassTypeIDs: []string{ClassTypeYoga},
		})
		if err != nil {
			return err
		}
		if err := s.UpdateAdminProduct(ctx, StudioID, manager, id, AdminProductInput{
			PriceMinor: ptr(2200),
		}); err != nil {
			return err
		}
		return s.ArchiveProduct(ctx, StudioID, manager, id)
	})
	rep.try("class_type_update", func() error {
		return s.UpdateClassType(ctx, StudioID, manager, ClassTypeYoga, ClassTypeInput{
			Name: "Yoga", Discipline: "yoga",
		})
	})

	// --- Schedule ------------------------------------------------------
	rep.try("class_cancel", func() error {
		// Cancel the furthest-out demo class so it doesn't pull the rug on
		// the bookings the earlier steps made.
		if len(futureClasses) < 4 {
			return nil
		}
		_, err := s.CancelAdminClassWithAudit(ctx, StudioID, manager, futureClasses[3])
		return err
	})
	rep.try("series_create", func() error {
		_, err := s.CreateSeries(ctx, StudioID, manager, NewSeriesInput{
			Title: "Intro to Reformer (4 wks)", Description: "Small-group beginner reformer.",
			PriceMinor: 12000, InstructorID: InstructorJonas, RoomID: RoomReformer,
			Weekday: 1, StartHour: 18, StartMinute: 0, DurationMins: 60,
			Capacity: 8, SessionCount: 4,
			StartsOn: time.Now().UTC().AddDate(0, 0, 14).Format("2006-01-02"),
		})
		return err
	})
	rep.try("series_join", func() error {
		_, err := s.JoinEnrollment(ctx, StudioID, UserBen, EnrollmentBeginners, "card", "")
		return err
	})
	rep.try("template_create", func() error {
		// Multi-slot template: a weekly schedule with two distinct slots
		// (different days, times and instructors) generated 4 weeks forward.
		_, err := s.CreateClassTemplateWithAudit(ctx, StudioID, manager, ClassTemplateInput{
			Title: "Weekend Flow (4 wks)", Weeks: 4,
			StartsOn: time.Now().UTC().AddDate(0, 0, 7).Format("2006-01-02"),
			Slots: []TemplateSlotInput{
				{
					Title: "Thursday Vinyasa", ClassTypeID: ClassTypeYoga,
					InstructorID: InstructorMara, RoomID: Room1,
					Weekday: 3, StartHour: 18, StartMinute: 30,
					DurationMins: 60, Capacity: 14,
				},
				{
					Title: "Saturday Slow Flow", ClassTypeID: ClassTypeYoga,
					InstructorID: InstructorAsha, RoomID: Room1,
					Weekday: 5, StartHour: 9, StartMinute: 30,
					DurationMins: 60, Capacity: 12,
				},
			},
		})
		return err
	})

	// --- Promotions ----------------------------------------------------
	rep.try("promotion lifecycle", func() error {
		id, err := s.CreatePromotion(ctx, StudioID, manager, PromotionInput{
			Title: "Summer unlimited −20%", Body: "All of July, go unlimited for less.",
		})
		if err != nil {
			return err
		}
		if err := s.UpdatePromotion(ctx, StudioID, manager, id, PromotionInput{
			Title: "Summer unlimited −25%", Body: "Even better — 25% off in July.",
		}); err != nil {
			return err
		}
		return s.ArchivePromotion(ctx, StudioID, manager, id)
	})

	// --- Access + studio ----------------------------------------------
	rep.try("staff lifecycle", func() error {
		id, err := s.CreateStaff(ctx, StudioID, manager, StaffInput{
			Role: "instructor", Email: "tariq@studio52.dev", FullName: "Tariq Hassan",
		})
		if err != nil {
			return err
		}
		return s.UpdateStaff(ctx, StudioID, manager, id, StaffInput{
			Role: "instructor", Email: "tariq@studio52.dev", FullName: "Tariq Hassan",
			PayRateMinor: ptr(3500),
		})
	})
	rep.try("theme_update", func() error {
		return s.UpdateTheme(ctx, StudioID, manager, ThemeSage, ThemePatch{
			Name: ptr("Sage (refined)"),
		})
	})
	rep.try("theme_activate", func() error {
		return s.ActivateTheme(ctx, StudioID, manager, ThemeClay)
	})
	// Populate the media library through the real upload path, then show it
	// off by setting the active theme's splash to the uploaded image. Skips
	// cleanly (ErrMediaStorageUnavailable) when no Storage bucket is wired —
	// the bootstrap then notes "media_upload" in its skipped summary.
	rep.try("media_upload", func() error {
		item, err := s.UploadMedia(ctx, StudioID, manager,
			"studio_class.webp", "image/webp", seedSplashImage)
		if err != nil {
			return err
		}
		return s.UpdateTheme(ctx, StudioID, manager, ThemeClay, ThemePatch{
			SplashImageURL: ptr(item.URL),
		})
	})
	rep.try("studio_config_update", func() error {
		return s.UpdateStudioConfig(ctx, StudioID, manager, StudioConfigPatch{
			WelcomeMessage: ptr("Welcome to Studio 52 — breathe, move, belong."),
		})
	})

	// --- Student notes -------------------------------------------------
	rep.try("student_note lifecycle", func() error {
		noteID, err := s.CreateStudentNote(ctx, StudioID, manager, UserBen,
			"Recovering from a knee injury — go easy on deep lunges.")
		if err != nil {
			return err
		}
		if err := s.UpdateStudentNote(ctx, StudioID, manager, noteID,
			"Knee cleared by physio — back to full range from next week."); err != nil {
			return err
		}
		return s.DeleteStudentNote(ctx, StudioID, manager, noteID)
	})

	// --- Manager-side booking + waitlist churn -------------------------
	rep.try("booking_create_admin", func() error {
		if len(futureClasses) < 3 {
			return nil
		}
		ent, err := s.firstCreditEntitlement(ctx, UserKira)
		if err != nil || ent == "" {
			return err
		}
		_, err = s.CreateAdminBooking(ctx, StudioID, manager, futureClasses[2], UserKira, ent, false, "")
		return err
	})
}

// firstCreditEntitlement returns a user's first active credit entitlement id
// (empty when they have none) — for adjust/admin-booking demos.
func (s *Store) firstCreditEntitlement(ctx context.Context, userID string) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `
		SELECT id FROM entitlements
		 WHERE user_id = ? AND pass_kind = 'credit' AND status = 'active'
		 ORDER BY created_at ASC LIMIT 1`, userID,
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// Demo students for the API seed. Fixed IDs (shared with the all-SQL seed's
// community block, so the two can coexist under INSERT OR IGNORE).
const (
	UserBen  = "u_ben"
	UserIvy  = "u_ivy"
	UserKira = "u_kira"
)

// seedDemoStudents inserts the handful of students the transactional layer
// acts as. Bootstrap-only (no create-user endpoint); everything they then do
// flows through the audited methods.
func (s *Store) seedDemoStudents(ctx context.Context) error {
	students := []struct{ id, email, name string }{
		{UserBen, "ben.carter@studio52.dev", "Ben Carter"},
		{UserIvy, "ivy.nakamura@studio52.dev", "Ivy Nakamura"},
		{UserKira, "kira.adams@studio52.dev", "Kira Adams"},
	}
	for _, st := range students {
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO users (id, studio_id, role, email, full_name, photo_url)
			VALUES (?, ?, 'student', ?, ?, ?)`,
			st.id, StudioID, st.email, st.name,
			"https://i.pravatar.cc/200?u="+st.email,
		); err != nil {
			return fmt.Errorf("seed student %s: %w", st.id, err)
		}
	}
	return nil
}

// demoPurchase runs a real student purchase (audited 'purchase' + minted
// entitlement) and returns the new entitlement id to book against.
func (s *Store) demoPurchase(ctx context.Context, userID, productID string) (string, error) {
	_, entitlementID, err := s.CreatePurchase(ctx, StudioID, userID, productID, "card", "")
	if err != nil {
		return "", fmt.Errorf("purchase %s for %s: %w", productID, userID, err)
	}
	return entitlementID, nil
}

// futureYogaClassIDs returns up to limit scheduled future yoga classes,
// soonest first — the pool the demo bookings draw from.
func (s *Store) futureYogaClassIDs(ctx context.Context, limit int) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id FROM classes
		 WHERE studio_id = ? AND class_type_id = ? AND status = 'scheduled'
		   AND starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY starts_at ASC LIMIT ?`,
		StudioID, ClassTypeYoga, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// seedSmallFutureClass mints a capacity-1 future yoga class through the
// audited CreateAdminClass path (so it leaves a class_create row) — used to
// stage a one-booking "full" class for the waitlist demo.
func (s *Store) seedSmallFutureClass(ctx context.Context, actorID string) (string, error) {
	startsAt := time.Now().UTC().Add(3 * 24 * time.Hour).Format(time.RFC3339)
	title := "Sunset Slow Flow (intimate)"
	ct, inst, room := ClassTypeYoga, InstructorAsha, Room1
	dur, cap := 60, 1
	id, err := s.CreateAdminClassWithAudit(ctx, StudioID, actorID, AdminClassInput{
		ClassTypeID:  &ct,
		InstructorID: &inst,
		RoomID:       &room,
		Title:        &title,
		StartsAt:     &startsAt,
		DurationMins: &dur,
		Capacity:     &cap,
	})
	if err != nil {
		return "", fmt.Errorf("create small class: %w", err)
	}
	return id, nil
}

// nextBookableYogaClass returns the soonest future yoga class the user has no
// active booking on (empty string when there are none — e.g. an all-past
// schedule), so the demo booking can't collide with the pre-seeded one.
func (s *Store) nextBookableYogaClass(ctx context.Context, userID string) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `
		SELECT c.id FROM classes c
		 WHERE c.studio_id = ? AND c.class_type_id = ? AND c.status = 'scheduled'
		   AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		   AND NOT EXISTS (
		     SELECT 1 FROM bookings b
		      WHERE b.class_id = c.id AND b.user_id = ? AND b.status = 'booked')
		 ORDER BY c.starts_at ASC LIMIT 1`,
		StudioID, ClassTypeYoga, userID,
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// seedPastBookingFixture inserts a single 'booked' row for userID on the most
// recent already-ended yoga class (so MarkAttendance has something real to
// act on). This is the one deliberate SQL fixture in the API seed: a booking
// on a past class can't be created through CreateBooking by design. Returns
// "" when there's no past class or the user already has a booking there.
func (s *Store) seedPastBookingFixture(ctx context.Context, userID, entitlementID string) (string, error) {
	var classID string
	err := s.db.QueryRowContext(ctx, `
		SELECT id FROM classes
		 WHERE studio_id = ? AND class_type_id = ? AND status = 'scheduled'
		   AND ends_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY starts_at DESC LIMIT 1`,
		StudioID, ClassTypeYoga,
	).Scan(&classID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	// Skip if a booking already exists (idempotent re-runs).
	var existing string
	if err := s.db.QueryRowContext(ctx, `
		SELECT id FROM bookings
		 WHERE class_id = ? AND user_id = ? AND is_plus_one = 0`,
		classID, userID,
	).Scan(&existing); err == nil {
		return "", nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	bookingID := NewID()
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id, is_plus_one,
		     booked_by_role, cancel_cutoff_hours, status, checkin_token)
		    VALUES (?, ?, ?, ?, ?, 0, 'student', 12, 'booked', NULL)`,
		bookingID, StudioID, classID, userID, entitlementID,
	); err != nil {
		return "", fmt.Errorf("insert past booking fixture: %w", err)
	}
	return bookingID, nil
}
