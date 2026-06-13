package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// SeedDev populates the database with a fully-formed example studio:
//   - Studio 52 + Warm Clay theme + Maya (student) + 3 instructors + 2 rooms
//   - 2 class types (yoga / reformer)
//   - A week's worth of classes anchored on Monday of the current week
//   - Maya holds one unlimited yoga+reformer pass and one pre-existing
//     booking so Home shows real data immediately.
//
// Idempotent: re-running is a no-op (uses fixed UUIDs + INSERT OR IGNORE).
func (s *Store) SeedDev(ctx context.Context) error {
	if err := s.seedStatics(ctx); err != nil {
		return err
	}
	return s.seedSchedule(ctx)
}

// --- fixed IDs (so the dev client can reference them and re-seeds are stable) ---

const (
	StudioID  = "00000000-0000-0000-0000-000000000001"
	UserMaya  = "00000000-0000-0000-0000-000000000010"
	UserPriya = "00000000-0000-0000-0000-000000000011"

	InstructorAsha  = "00000000-0000-0000-0000-000000000021"
	InstructorJonas = "00000000-0000-0000-0000-000000000022"
	InstructorMara  = "00000000-0000-0000-0000-000000000023"

	Room1     = "00000000-0000-0000-0000-000000000031"
	RoomReformer = "00000000-0000-0000-0000-000000000032"

	ClassTypeYoga         = "00000000-0000-0000-0000-000000000041"
	ClassTypeReformer     = "00000000-0000-0000-0000-000000000042"
	ClassTypeBeginnersSum = "00000000-0000-0000-0000-000000000043"

	ProductBeginnersCourse = "00000000-0000-0000-0000-000000000076"
	EnrollmentBeginners    = "00000000-0000-0000-0000-000000000081"

	EntitlementMayaUnlimited = "00000000-0000-0000-0000-000000000051"

	ThemeClay   = "00000000-0000-0000-0000-0000000000a1"
	ThemeSlate  = "00000000-0000-0000-0000-0000000000a2"
	ThemeSage   = "00000000-0000-0000-0000-0000000000a3"
	ThemeCitrus = "00000000-0000-0000-0000-0000000000a4"

	ProductDropIn           = "00000000-0000-0000-0000-000000000071"
	ProductFivePack         = "00000000-0000-0000-0000-000000000072"
	ProductTenPack          = "00000000-0000-0000-0000-000000000073"
	ProductUnlimitedMonthly = "00000000-0000-0000-0000-000000000074"
	ProductReformerFive     = "00000000-0000-0000-0000-000000000075"
)

func (s *Store) seedStatics(ctx context.Context) error {
	stmts := []struct {
		sql  string
		args []any
	}{
		// Studio.
		{
			`INSERT OR IGNORE INTO studios (id, name, timezone, currency, allow_student_plus_one, welcome_message, buy_layout)
			 VALUES (?, 'Studio 52', 'Europe/London', 'GBP', 1, 'Welcome to Studio 52', 'grouped')`,
			[]any{StudioID},
		},
		// All four starter presets — Warm Clay is the default active one.
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens, splash_image_url)
			 VALUES (?, ?, 'Warm Clay', 1, 'light',
				 '{"primary":"#B05C3B","accent":"#C8973F","background":"#FAF5EF","surface":"#FFFFFF","text":"#2D2218","textMuted":"#8F8174"}',
				 'https://picsum.photos/seed/studio52-warm-clay/1600/1000')`,
			[]any{ThemeClay, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Cool Slate', 1, 'light',
				 '{"primary":"#3A5E7E","accent":"#64998F","background":"#F4F6F8","surface":"#FFFFFF","text":"#1E2730","textMuted":"#75828E"}')`,
			[]any{ThemeSlate, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Earthy Sage', 1, 'light',
				 '{"primary":"#5E7153","accent":"#A9744A","background":"#F6F5EE","surface":"#FFFFFF","text":"#272B20","textMuted":"#82876F"}')`,
			[]any{ThemeSage, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Bright Citrus', 1, 'light',
				 '{"primary":"#D94F24","accent":"#17A398","background":"#FFFBF5","surface":"#FFFFFF","text":"#25211E","textMuted":"#8B8480"}')`,
			[]any{ThemeCitrus, StudioID},
		},
		{`UPDATE studios SET active_theme_id = ? WHERE id = ?`, []any{ThemeClay, StudioID}},
		// Users.
		{
			`INSERT OR IGNORE INTO users (id, studio_id, firebase_uid, role, email, full_name, photo_url)
			 VALUES (?, ?, 'dev-firebase-uid-maya', 'student', 'maya@studio52.dev', 'Maya Rowe',
			   'https://i.pravatar.cc/200?u=maya@studio52.dev')`,
			[]any{UserMaya, StudioID},
		},
		{
			`INSERT OR IGNORE INTO users (id, studio_id, firebase_uid, role, email, full_name, photo_url)
			 VALUES (?, ?, 'dev-firebase-uid-priya', 'manager', 'priya@studio52.dev', 'Priya Shah',
			   'https://i.pravatar.cc/200?u=priya@studio52.dev')`,
			[]any{UserPriya, StudioID},
		},
		{
			`INSERT OR IGNORE INTO users (id, studio_id, role, email, full_name, photo_url)
			 VALUES (?, ?, 'instructor', 'asha@studio52.dev', 'Asha Patel',
			   'https://i.pravatar.cc/200?u=asha@studio52.dev')`,
			[]any{InstructorAsha, StudioID},
		},
		{
			`INSERT OR IGNORE INTO users (id, studio_id, role, email, full_name, photo_url)
			 VALUES (?, ?, 'instructor', 'jonas@studio52.dev', 'Jonas Meyer',
			   'https://i.pravatar.cc/200?u=jonas@studio52.dev')`,
			[]any{InstructorJonas, StudioID},
		},
		{
			`INSERT OR IGNORE INTO users (id, studio_id, role, email, full_name, photo_url)
			 VALUES (?, ?, 'instructor', 'mara@studio52.dev', 'Mara Kovac',
			   'https://i.pravatar.cc/200?u=mara@studio52.dev')`,
			[]any{InstructorMara, StudioID},
		},
		// Rooms.
		{`INSERT OR IGNORE INTO rooms (id, studio_id, name) VALUES (?, ?, 'Room 1')`, []any{Room1, StudioID}},
		{`INSERT OR IGNORE INTO rooms (id, studio_id, name) VALUES (?, ?, 'Room 2 · Reformer')`, []any{RoomReformer, StudioID}},
		// Class types.
		{`INSERT OR IGNORE INTO class_types (id, studio_id, name, discipline) VALUES (?, ?, 'Yoga', 'yoga')`, []any{ClassTypeYoga, StudioID}},
		{`INSERT OR IGNORE INTO class_types (id, studio_id, name, discipline) VALUES (?, ?, 'Reformer', 'reformer')`, []any{ClassTypeReformer, StudioID}},
		// Per-series class type so an enrollment's entitlement is naturally
		// scoped to just the series' own sessions.
		{`INSERT OR IGNORE INTO class_types (id, studio_id, name, discipline) VALUES (?, ?, ?, 'yoga')`,
			[]any{ClassTypeBeginnersSum, StudioID, "Beginners' Course · Summer 2026"}},
		// Maya's unlimited entitlement (covers yoga + reformer for 60 days).
		{
			`INSERT OR IGNORE INTO entitlements (id, studio_id, user_id, pass_kind, label, expires_at, status)
			 VALUES (?, ?, ?, 'unlimited', 'Unlimited Monthly',
				 strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+60 days'), 'active')`,
			[]any{EntitlementMayaUnlimited, StudioID, UserMaya},
		},
		// Eligible types for that entitlement.
		{
			`INSERT OR IGNORE INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
			[]any{EntitlementMayaUnlimited, ClassTypeYoga},
		},
		{
			`INSERT OR IGNORE INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
			[]any{EntitlementMayaUnlimited, ClassTypeReformer},
		},
		// Products. Prices in minor units (pence). is_hero=1 → Buy hero card.
		{
			`INSERT OR IGNORE INTO products
			 (id, studio_id, name, description, price_minor, billing_type, pass_kind, credits, validity_days, is_hero, display_order)
			 VALUES (?, ?, 'Unlimited Monthly',
			   'All yoga + reformer, every day, for a month.', 8800, 'recurring', 'unlimited', NULL, 30, 1, 0)`,
			[]any{ProductUnlimitedMonthly, StudioID},
		},
		{
			`INSERT OR IGNORE INTO products
			 (id, studio_id, name, description, price_minor, billing_type, pass_kind, credits, validity_days, is_hero, display_order)
			 VALUES (?, ?, 'Single Class',
			   'One yoga class — use within 14 days.', 1600, 'one_time', 'credit', 1, 14, 0, 1)`,
			[]any{ProductDropIn, StudioID},
		},
		{
			`INSERT OR IGNORE INTO products
			 (id, studio_id, name, description, price_minor, billing_type, pass_kind, credits, validity_days, is_hero, display_order)
			 VALUES (?, ?, '5-Class Pack',
			   '5 yoga classes — use within 2 months.', 6000, 'one_time', 'credit', 5, 60, 0, 2)`,
			[]any{ProductFivePack, StudioID},
		},
		{
			`INSERT OR IGNORE INTO products
			 (id, studio_id, name, description, price_minor, billing_type, pass_kind, credits, validity_days, is_hero, display_order)
			 VALUES (?, ?, '10-Class Pack',
			   '10 yoga classes — use within 3 months.', 11000, 'one_time', 'credit', 10, 90, 0, 3)`,
			[]any{ProductTenPack, StudioID},
		},
		{
			`INSERT OR IGNORE INTO products
			 (id, studio_id, name, description, price_minor, billing_type, pass_kind, credits, validity_days, is_hero, display_order)
			 VALUES (?, ?, '5 Reformer Sessions',
			   '5 reformer classes — small group only.', 9500, 'one_time', 'credit', 5, 60, 0, 4)`,
			[]any{ProductReformerFive, StudioID},
		},
		// Beginners' Course product (drives the enrollment series — surfaced
		// in the Enrollments tab rather than the Buy tab).
		{
			`INSERT OR IGNORE INTO products
			 (id, studio_id, name, description, price_minor, billing_type, pass_kind, credits, validity_days, is_hero, display_order, is_archived)
			 VALUES (?, ?, 'Beginners'' Course (6 weeks)',
			   '6 weekly classes — sold as a course, not a single drop-in.', 6000,
			   'one_time', 'unlimited', NULL, 60, 0, 99, 0)`,
			[]any{ProductBeginnersCourse, StudioID},
		},
		// Product → class type junctions.
		{`INSERT OR IGNORE INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`, []any{ProductUnlimitedMonthly, ClassTypeYoga}},
		{`INSERT OR IGNORE INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`, []any{ProductUnlimitedMonthly, ClassTypeReformer}},
		{`INSERT OR IGNORE INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`, []any{ProductDropIn, ClassTypeYoga}},
		{`INSERT OR IGNORE INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`, []any{ProductFivePack, ClassTypeYoga}},
		{`INSERT OR IGNORE INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`, []any{ProductTenPack, ClassTypeYoga}},
		{`INSERT OR IGNORE INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`, []any{ProductReformerFive, ClassTypeReformer}},
		{`INSERT OR IGNORE INTO product_class_types (product_id, class_type_id) VALUES (?, ?)`, []any{ProductBeginnersCourse, ClassTypeBeginnersSum}},
		// Enrollment row pointing at the product + class type.
		{
			`INSERT OR IGNORE INTO enrollments (id, studio_id, title, description, product_id, session_count, capacity)
			 VALUES (?, ?, 'Beginners'' Course · Summer 2026',
			   '6 Wednesdays · gentle pace, no experience needed.', ?, 6, 10)`,
			[]any{EnrollmentBeginners, StudioID, ProductBeginnersCourse},
		},
	}
	for _, st := range stmts {
		if _, err := s.db.ExecContext(ctx, st.sql, st.args...); err != nil {
			return fmt.Errorf("seed: %w (sql=%s)", err, st.sql)
		}
	}
	return nil
}

// classFixture is one row in the seeded weekly schedule.
type classFixture struct {
	day        time.Weekday
	hour, min  int
	durMins    int
	typeID     string
	title      string
	instructor string
	room       string
	capacity   int
}

func (s *Store) seedSchedule(ctx context.Context) error {
	// Anchor on Monday 00:00 of the current week in UTC. (Studio TZ is
	// Europe/London — close enough for dev.)
	now := time.Now().UTC()
	offset := (int(now.Weekday()) + 6) % 7 // Sun=6, Mon=0, ..., Sat=5
	monday := time.Date(now.Year(), now.Month(), now.Day()-offset, 0, 0, 0, 0, time.UTC)

	fixtures := []classFixture{
		// Monday
		{time.Monday, 7, 30, 60, ClassTypeYoga, "Vinyasa Flow", InstructorAsha, Room1, 14},
		{time.Monday, 17, 45, 60, ClassTypeYoga, "Power Vinyasa", InstructorAsha, Room1, 14},
		// Tuesday
		{time.Tuesday, 9, 0, 50, ClassTypeReformer, "Reformer Pilates", InstructorJonas, RoomReformer, 8},
		{time.Tuesday, 18, 30, 75, ClassTypeYoga, "Yin & Restore", InstructorMara, Room1, 16},
		// Wednesday
		{time.Wednesday, 7, 30, 60, ClassTypeYoga, "Vinyasa Flow", InstructorAsha, Room1, 14},
		{time.Wednesday, 12, 15, 75, ClassTypeYoga, "Yin & Restore", InstructorMara, Room1, 16},
		{time.Wednesday, 19, 0, 60, ClassTypeYoga, "Candlelit Slow Flow", InstructorMara, Room1, 14},
		// Thursday
		{time.Thursday, 7, 30, 60, ClassTypeYoga, "Vinyasa Flow", InstructorAsha, Room1, 14},
		{time.Thursday, 9, 0, 50, ClassTypeReformer, "Reformer Pilates", InstructorJonas, RoomReformer, 8},
		{time.Thursday, 17, 45, 60, ClassTypeYoga, "Power Vinyasa", InstructorAsha, Room1, 14},
		// Friday
		{time.Friday, 7, 30, 60, ClassTypeYoga, "Vinyasa Flow", InstructorAsha, Room1, 14},
		{time.Friday, 19, 0, 60, ClassTypeYoga, "Candlelit Slow Flow", InstructorMara, Room1, 14},
		// Saturday
		{time.Saturday, 9, 0, 50, ClassTypeReformer, "Reformer Pilates", InstructorJonas, RoomReformer, 8},
		{time.Saturday, 11, 0, 60, ClassTypeYoga, "Vinyasa Flow", InstructorAsha, Room1, 14},
		// Sunday — deliberately empty to exercise the rest-day state.
	}

	// Beginners' Course series — 6 Wednesdays at 18:00 starting next week.
	// Sessions are class rows linked to the enrollment.
	for w := 0; w < 6; w++ {
		// Anchor on next week's Monday so the whole series is in the future.
		weekStart := monday.AddDate(0, 0, 7*(w+1))
		classStart := weekStart.AddDate(0, 0, 2). // Wednesday
								Add(18 * time.Hour) // 18:00
		classID := fmt.Sprintf("00000000-0000-0000-0000-0000000040%02x", w+1)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO classes
			    (id, studio_id, class_type_id, instructor_id, room_id, enrollment_id,
			     title, starts_at, ends_at, capacity)
			    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 10)`,
			classID, StudioID, ClassTypeBeginnersSum, InstructorMara, Room1,
			EnrollmentBeginners,
			fmt.Sprintf("Beginners' wk %d/6", w+1),
			classStart.Format(time.RFC3339),
			classStart.Add(60*time.Minute).Format(time.RFC3339),
		); err != nil {
			return err
		}
	}

	const ins = `INSERT OR IGNORE INTO classes
		(id, studio_id, class_type_id, instructor_id, room_id, title, starts_at, ends_at, capacity)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`

	for i, f := range fixtures {
		dayOffset := (int(f.day) + 6) % 7 // Mon=0, Tue=1, ..., Sun=6
		start := monday.Add(time.Duration(dayOffset)*24*time.Hour +
			time.Duration(f.hour)*time.Hour +
			time.Duration(f.min)*time.Minute)
		end := start.Add(time.Duration(f.durMins) * time.Minute)
		// Deterministic class IDs so re-seed doesn't duplicate.
		id := fmt.Sprintf("00000000-0000-0000-0000-0000000010%02x", i+1)
		if _, err := s.db.ExecContext(ctx, ins,
			id, StudioID, f.typeID, f.instructor, f.room, f.title,
			start.Format(time.RFC3339), end.Format(time.RFC3339), f.capacity,
		); err != nil {
			return fmt.Errorf("seed class %d: %w", i, err)
		}
	}

	// Pre-existing booking for Maya — the next future class in the week — so
	// Home's "Upcoming" section always shows real data on first launch.
	const mayaBookingID = "00000000-0000-0000-0000-000000000061"
	var futureClassID string
	err := s.db.QueryRowContext(ctx, `
		SELECT id FROM classes
		 WHERE studio_id = ? AND starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now')
		 ORDER BY starts_at ASC LIMIT 1`,
		StudioID,
	).Scan(&futureClassID)
	if errors.Is(err, sql.ErrNoRows) {
		// All seeded classes are past — nothing to book into.
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO bookings
			(id, studio_id, class_id, user_id, entitlement_id, booked_by_role, cancel_cutoff_hours, status)
			VALUES (?, ?, ?, ?, ?, 'student', 12, 'booked')`,
		mayaBookingID, StudioID, futureClassID, UserMaya, EntitlementMayaUnlimited,
	); err != nil {
		return err
	}

	// Seed Maya's check-in token (rotates in real implementation).
	if _, err := s.db.ExecContext(ctx,
		`UPDATE users SET checkin_token = ? WHERE id = ?`,
		"S52-MAYA-7C4A2", UserMaya,
	); err != nil {
		return err
	}

	// Seed a few notifications so the feed isn't empty.
	notifs := []struct {
		id, kind, title, body string
		ageMinutes            int
		unread                bool
	}{
		{
			"00000000-0000-0000-0000-000000000091",
			"booking_confirmed",
			"You're booked into Candlelit Slow Flow",
			"Tonight at 19:00 · Room 1 · with Mara Kovac",
			180,
			true,
		},
		{
			"00000000-0000-0000-0000-000000000092",
			"waitlist_promoted",
			"A spot opened — claim it by 11:15",
			"Reformer Pilates · Tomorrow 9:00 · Jonas Meyer",
			720,
			true,
		},
		{
			"00000000-0000-0000-0000-000000000093",
			"system",
			"Welcome to Studio 52",
			"Your account is ready. Browse classes any time from the Book tab.",
			4320,
			false,
		},
	}
	for _, n := range notifs {
		var readAt any
		if !n.unread {
			readAt = time.Now().UTC().Add(-time.Duration(n.ageMinutes/2) * time.Minute).Format(time.RFC3339)
		}
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO notifications
			    (id, studio_id, user_id, type, title, body, payload, read_at, created_at)
			    VALUES (?, ?, ?, ?, ?, ?, '{}', ?, ?)`,
			n.id, StudioID, UserMaya, n.kind, n.title, n.body,
			readAt,
			time.Now().UTC().Add(-time.Duration(n.ageMinutes)*time.Minute).Format(time.RFC3339),
		); err != nil {
			return err
		}
	}

	// Seed past attendance so the Profile bar chart isn't empty: for each of
	// the last 6 weeks, plant one Wednesday-evening class and mark Maya
	// attended. (No interactions with the current-week schedule.)
	for w := 1; w <= 6; w++ {
		weekStart := monday.AddDate(0, 0, -7*w)
		classStart := weekStart.AddDate(0, 0, 2). // Wednesday
								Add(19 * time.Hour) // 19:00
		classID := fmt.Sprintf("00000000-0000-0000-0000-0000000020%02x", w)
		bookingID := fmt.Sprintf("00000000-0000-0000-0000-0000000030%02x", w)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO classes
			    (id, studio_id, class_type_id, instructor_id, room_id, title,
			     starts_at, ends_at, capacity)
			    VALUES (?, ?, ?, ?, ?, 'Vinyasa Flow', ?, ?, ?)`,
			classID, StudioID, ClassTypeYoga, InstructorAsha, Room1,
			classStart.Format(time.RFC3339),
			classStart.Add(60*time.Minute).Format(time.RFC3339),
			14,
		); err != nil {
			return err
		}
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id,
			     booked_by_role, cancel_cutoff_hours, status)
			    VALUES (?, ?, ?, ?, ?, 'student', 12, 'attended')`,
			bookingID, StudioID, classID, UserMaya, EntitlementMayaUnlimited,
		); err != nil {
			return err
		}
	}
	return nil
}
