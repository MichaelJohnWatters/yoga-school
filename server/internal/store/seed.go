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
// Idempotent: re-running is a no-op (uses fixed slug IDs + INSERT OR IGNORE).
func (s *Store) SeedDev(ctx context.Context) error {
	if err := s.seedStatics(ctx); err != nil {
		return err
	}
	if err := s.seedSchedule(ctx); err != nil {
		return err
	}
	if err := s.seedCommunity(ctx); err != nil {
		return err
	}
	// Backfill single-use check-in tokens for every seeded booking. The
	// hand-written INSERTs above don't supply the column, but live bookings
	// minted by CreateBooking / PromoteWaitlist do — this keeps the dev
	// /me/checkin-code endpoint surfacing a scannable QR without bloating
	// every seed INSERT with a token literal.
	_, err := s.db.ExecContext(ctx, `
		UPDATE bookings
		   SET checkin_token = lower(hex(randomblob(8)))
		 WHERE checkin_token IS NULL`,
	)
	return err
}

// --- fixed IDs (so the dev client can reference them and re-seeds are stable) ---
//
// Real rows minted by the API get random 12-char NanoIDs via store.NewID().
// These hand-written slugs are obviously seed data when you see them in logs.

const (
	StudioID  = "s52"
	UserMaya  = "u_maya"
	UserPriya = "u_priya"

	InstructorAsha  = "u_asha"
	InstructorJonas = "u_jonas"
	InstructorMara  = "u_mara"

	Room1        = "rm_one"
	RoomReformer = "rm_reform"

	ClassTypeYoga         = "ct_yoga"
	ClassTypeReformer     = "ct_reform"
	ClassTypeBeginnersSum = "ct_beg_s26"

	ProductBeginnersCourse = "prod_beg"
	EnrollmentBeginners    = "enr_beg_s26"

	EntitlementMayaUnlimited = "ent_maya"

	ThemeClay      = "th_clay"
	ThemeSlate     = "th_slate"
	ThemeSage      = "th_sage"
	ThemeCitrus    = "th_citrus"
	ThemeNoir      = "th_noir"      // dark-mode preset
	ThemeRose      = "th_rose"
	ThemeOcean     = "th_ocean"
	ThemeForest    = "th_forest"
	ThemeMoss      = "th_moss"
	ThemeMonoLight = "th_mono_l"
	ThemeMonoDark  = "th_mono_d"

	ProductDropIn           = "prod_drop"
	ProductFivePack         = "prod_5pack"
	ProductTenPack          = "prod_10pack"
	ProductUnlimitedMonthly = "prod_unlimited"
	ProductReformerFive     = "prod_reform_5"
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
		// Additional presets — give managers a broader starter palette
		// without forcing them into the custom-token editor. Two dark
		// modes (Noir + Mono Dark) cover the "studio shows look in low
		// light" case; the rest are alternative light palettes tuned
		// for different brand vibes.
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Rose Plaster', 1, 'light',
				 '{"primary":"#C66B7A","accent":"#A38462","background":"#FBF3F1","surface":"#FFFFFF","text":"#2A1F22","textMuted":"#8A7479"}')`,
			[]any{ThemeRose, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Deep Ocean', 1, 'light',
				 '{"primary":"#1F6F8B","accent":"#E0A458","background":"#F1F6F8","surface":"#FFFFFF","text":"#13232E","textMuted":"#69808C"}')`,
			[]any{ThemeOcean, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Forest Dawn', 1, 'light',
				 '{"primary":"#2E5339","accent":"#D08C5D","background":"#F1F4EE","surface":"#FFFFFF","text":"#16201A","textMuted":"#6E7B72"}')`,
			[]any{ThemeForest, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Soft Moss', 1, 'light',
				 '{"primary":"#7A8C5B","accent":"#C77F5E","background":"#F7F6EE","surface":"#FFFFFF","text":"#1F2418","textMuted":"#7D8068"}')`,
			[]any{ThemeMoss, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Mono Light', 1, 'light',
				 '{"primary":"#1A1A1A","accent":"#6B6B6B","background":"#FAFAFA","surface":"#FFFFFF","text":"#0E0E0E","textMuted":"#7A7A7A"}')`,
			[]any{ThemeMonoLight, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Studio Noir', 1, 'dark',
				 '{"primary":"#E0A458","accent":"#C66B7A","background":"#15171A","surface":"#1E2126","text":"#F3EFE6","textMuted":"#9CA0A8"}')`,
			[]any{ThemeNoir, StudioID},
		},
		{
			`INSERT OR IGNORE INTO themes (id, studio_id, name, is_preset, mode, tokens)
			 VALUES (?, ?, 'Mono Dark', 1, 'dark',
				 '{"primary":"#EFEFEF","accent":"#9C9C9C","background":"#0E0E0E","surface":"#1A1A1A","text":"#F3F3F3","textMuted":"#9A9A9A"}')`,
			[]any{ThemeMonoDark, StudioID},
		},
		// Default both slots so a fresh seed has a coherent light/dark pair
		// out of the box — Studio Clay for light, Studio Noir for dark.
		{
			`UPDATE studios SET active_theme_id = ?, active_dark_theme_id = ? WHERE id = ?`,
			[]any{ThemeClay, ThemeNoir, StudioID},
		},
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
		// source_product_id is set so the buy-flow duplicate-pass guard can
		// recognise "you already own this".
		{
			`INSERT OR IGNORE INTO entitlements
			    (id, studio_id, user_id, pass_kind, label, expires_at, status,
			     source_product_id)
			    VALUES (?, ?, ?, 'unlimited', 'Unlimited Monthly',
			            strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+60 days'),
			            'active', ?)`,
			[]any{EntitlementMayaUnlimited, StudioID, UserMaya, ProductUnlimitedMonthly},
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
		classID := fmt.Sprintf("cls_crs_%d", w+1)
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

	// Generate two weeks of the standard schedule so there's always a
	// healthy mix of past + future classes for dev/test, regardless of what
	// day of the week the seeder runs on. Without this, running on a Sunday
	// leaves no bookable yoga classes ahead (everything Mon-Sat is past) and
	// integration tests targeting "book a class" have nothing to click.
	for weekIdx := 0; weekIdx < 2; weekIdx++ {
		weekStart := monday.AddDate(0, 0, 7*weekIdx)
		for i, f := range fixtures {
			dayOffset := (int(f.day) + 6) % 7 // Mon=0, Tue=1, ..., Sun=6
			start := weekStart.Add(time.Duration(dayOffset)*24*time.Hour +
				time.Duration(f.hour)*time.Hour +
				time.Duration(f.min)*time.Minute)
			end := start.Add(time.Duration(f.durMins) * time.Minute)
			// Deterministic class IDs so re-seed doesn't duplicate. Week
			// index is part of the id so the two weeks don't collide.
			id := fmt.Sprintf("cls_wk%d_%02d", weekIdx, i+1)
			if _, err := s.db.ExecContext(ctx, ins,
				id, StudioID, f.typeID, f.instructor, f.room, f.title,
				start.Format(time.RFC3339), end.Format(time.RFC3339), f.capacity,
			); err != nil {
				return fmt.Errorf("seed class %d/%d: %w", weekIdx, i, err)
			}
		}
	}

	// Pre-existing booking for Maya — the next future class in the week — so
	// Home's "Upcoming" section always shows real data on first launch.
	const mayaBookingID = "bk_maya_upcoming"
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

	// Per-booking check-in tokens are minted in a post-processing pass at
	// the end of SeedDev so the same backfill catches rows added by
	// seedCommunity too.

	// Seed a few notifications so the feed isn't empty.
	notifs := []struct {
		id, kind, title, body string
		ageMinutes            int
		unread                bool
	}{
		{
			"nf_maya_01",
			"booking_confirmed",
			"You're booked into Candlelit Slow Flow",
			"Tonight at 19:00 · Room 1 · with Mara Kovac",
			180,
			true,
		},
		{
			"nf_maya_02",
			"waitlist_promoted",
			"A spot opened — claim it by 11:15",
			"Reformer Pilates · Tomorrow 9:00 · Jonas Meyer",
			720,
			true,
		},
		{
			"nf_maya_03",
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
		classID := fmt.Sprintf("cls_past_%d", w)
		bookingID := fmt.Sprintf("bk_maya_past_%d", w)
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

// ============================== community seed ==============================
//
// seedCommunity layers in a believable community of students on top of the
// schedule:
//   - 10 extra students with varied photos/names
//   - Each student bought a product → purchase row → entitlement row, with
//     backdated created_at so the data looks like it accreted over weeks
//   - Bookings sprinkled across the current week so popular classes look full,
//     including a fully-booked midday Yin class with a 3-person waitlist
//   - Past attendance + a couple of no_shows + a couple of cancellations
//   - A second promotion + a "low credits" notification + a manager audit row
//
// Everything is idempotent via fixed slug IDs / INSERT OR IGNORE.
func (s *Store) seedCommunity(ctx context.Context) error {
	now := time.Now().UTC()
	offset := (int(now.Weekday()) + 6) % 7
	monday := time.Date(now.Year(), now.Month(), now.Day()-offset, 0, 0, 0, 0, time.UTC)

	// Stable, readable seed IDs — e.g. uid("ent", 3) → "sd_ent_003".
	// Real rows minted by the API get random NanoIDs via store.NewID().
	uid := func(prefix string, n int) string {
		return fmt.Sprintf("sd_%s_%03d", prefix, n)
	}

	// --- Students ---------------------------------------------------------
	type student struct {
		id, fullName, email string
		// Joined: number of days ago this account was created (drives
		// notifications + first-purchase timing).
		joinedDaysAgo int
	}
	students := []student{
		{"u_aria", "Aria Lin", "aria.lin@studio52.dev", 64},
		{"u_ben", "Ben Carter", "ben.carter@studio52.dev", 28},
		{"u_chen", "Chen Wei", "chen.wei@studio52.dev", 92},
		{"u_diego", "Diego Rivera", "diego.rivera@studio52.dev", 5},
		{"u_elena", "Elena Petrov", "elena.petrov@studio52.dev", 47},
		{"u_felix", "Felix Schmidt", "felix.schmidt@studio52.dev", 121},
		{"u_grace", "Grace Okoye", "grace.okoye@studio52.dev", 14},
		{"u_hiro", "Hiro Tanaka", "hiro.tanaka@studio52.dev", 75},
		{"u_ivy", "Ivy Nakamura", "ivy.nakamura@studio52.dev", 156},
		{"u_joel", "Joel Ngata", "joel.ngata@studio52.dev", 9},
		{"u_kira", "Kira Walker", "kira.walker@studio52.dev", 41},
	}
	for _, st := range students {
		joinedAt := now.AddDate(0, 0, -st.joinedDaysAgo).Format(time.RFC3339)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO users
			    (id, studio_id, role, email, full_name, photo_url, created_at)
			    VALUES (?, ?, 'student', ?, ?, ?, ?)`,
			st.id, StudioID, st.email, st.fullName,
			fmt.Sprintf("https://i.pravatar.cc/200?u=%s", st.email),
			joinedAt,
		); err != nil {
			return fmt.Errorf("seed student %s: %w", st.email, err)
		}
	}

	// --- Purchases + entitlements ----------------------------------------
	// Each row captures: the buyer, what they bought, how many credits remain
	// (for credit passes), how long ago they purchased, and the entitlement
	// expiry. Purchase and entitlement IDs are derived from `n` so re-seeds
	// are stable.
	type purchase struct {
		n                int
		userID           string
		productID        string
		amountMinor      int
		passKind         string
		label            string
		creditsTotal     int    // 0 for unlimited
		creditsRemaining int    // 0 for unlimited
		daysAgo          int    // purchase date
		validityDays     int    // entitlement window
		paymentMethod    string // matches schema
		actorRole        string // matches schema
		initiatedBy      string // student or manager id
	}
	purchases := []purchase{
		// Aria — 10-pack, halfway through.
		{1, students[0].id, ProductTenPack, 11000, "credit", "10-Class Pack",
			10, 5, 50, 90, "card", "student", students[0].id},
		// Ben — unlimited monthly, fresh.
		{2, students[1].id, ProductUnlimitedMonthly, 8800, "unlimited", "Unlimited Monthly",
			0, 0, 12, 30, "card", "student", students[1].id},
		// Chen — reformer 5-pack, used 3.
		{3, students[2].id, ProductReformerFive, 9500, "credit", "5 Reformer Sessions",
			5, 2, 30, 60, "card", "student", students[2].id},
		// Diego — single drop-in, all used.
		{4, students[3].id, ProductDropIn, 1600, "credit", "Single Class",
			1, 0, 4, 14, "card", "student", students[3].id},
		// Elena — 5-pack, partial.
		{5, students[4].id, ProductFivePack, 6000, "credit", "5-Class Pack",
			5, 2, 40, 60, "card", "student", students[4].id},
		// Felix — unlimited monthly, manager comped (cash grant scenario).
		{6, students[5].id, ProductUnlimitedMonthly, 0, "unlimited", "Unlimited Monthly (comp)",
			0, 0, 22, 30, "comp", "manager", UserPriya},
		// Grace — 5-pack, only used 1 so far.
		{7, students[6].id, ProductFivePack, 6000, "credit", "5-Class Pack",
			5, 4, 11, 60, "card", "student", students[6].id},
		// Hiro — reformer 5-pack, mostly used.
		{8, students[7].id, ProductReformerFive, 9500, "credit", "5 Reformer Sessions",
			5, 1, 55, 60, "card", "student", students[7].id},
		// Ivy — 10-pack, big regular.
		{9, students[8].id, ProductTenPack, 11000, "credit", "10-Class Pack",
			10, 2, 70, 90, "card_present", "student", students[8].id},
		// Joel — unlimited monthly, brand new.
		{10, students[9].id, ProductUnlimitedMonthly, 8800, "unlimited", "Unlimited Monthly",
			0, 0, 6, 30, "card", "student", students[9].id},
		// Kira — 10-pack, mid-use.
		{11, students[10].id, ProductTenPack, 11000, "credit", "10-Class Pack",
			10, 6, 26, 90, "card", "student", students[10].id},
		// --- Multi-pass wallets ------------------------------------------
		// Some students hold more than one entitlement at a time. The
		// pattern mirrors what we expect in real life: a student upgrades
		// mid-cycle, branches into a second discipline, or keeps a
		// depleted pass in their history for the wallet UI.
		//
		// Aria upgraded from her 10-pack (n=1, 5 credits remaining) to an
		// Unlimited Monthly 10 days ago. Both stay in her wallet; new
		// bookings count against Unlimited (see entFor override below).
		{12, students[0].id, ProductUnlimitedMonthly, 8800, "unlimited", "Unlimited Monthly",
			0, 0, 10, 30, "card", "student", students[0].id},
		// Ben (Unlimited Monthly) added a Reformer 5-pack 6 days ago.
		// His Unlimited already covers Reformer, but he reaches for the
		// pack to ration usage. Wallet shows two active entries.
		{13, students[1].id, ProductReformerFive, 9500, "credit", "5 Reformer Sessions",
			5, 4, 6, 60, "card", "student", students[1].id},
		// Ivy (heavy 10-pack regular) added a Reformer 5-pack 18 days ago
		// to branch into apparatus work. Yoga bookings still draw from
		// the 10-pack.
		{14, students[8].id, ProductReformerFive, 9500, "credit", "5 Reformer Sessions",
			5, 4, 18, 60, "card", "student", students[8].id},
		// Kira's history — an older 10-pack she fully used 4 months ago,
		// before her current one. Demonstrates the "depleted past pass"
		// state in the wallet history view.
		{15, students[10].id, ProductTenPack, 11000, "credit", "10-Class Pack",
			10, 0, 130, 90, "card", "student", students[10].id},
		// Aria's pre-history — a 5-pack from 6 months back, fully used.
		// Combined with n=1 and n=12 she has three lifetime entitlements.
		{16, students[0].id, ProductFivePack, 6000, "credit", "5-Class Pack",
			5, 0, 180, 60, "card", "student", students[0].id},
	}
	// Eligibility map by product → class types.
	productToTypes := map[string][]string{
		ProductDropIn:           {ClassTypeYoga},
		ProductFivePack:         {ClassTypeYoga},
		ProductTenPack:          {ClassTypeYoga},
		ProductUnlimitedMonthly: {ClassTypeYoga, ClassTypeReformer},
		ProductReformerFive:     {ClassTypeReformer},
	}
	for _, p := range purchases {
		purchaseID := uid("0b", p.n)      // 00000000-...-0b001 etc
		entitlementID := uid("05", 1+p.n) // 052 onwards (051 is Maya)
		purchasedAt := now.AddDate(0, 0, -p.daysAgo)
		expiresAt := purchasedAt.AddDate(0, 0, p.validityDays).Format(time.RFC3339)
		var creditsTotal, creditsRemaining any
		if p.passKind == "credit" {
			creditsTotal = p.creditsTotal
			creditsRemaining = p.creditsRemaining
		}
		entStatus := "active"
		if p.passKind == "credit" && p.creditsRemaining == 0 {
			entStatus = "depleted"
		}
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO entitlements
			    (id, studio_id, user_id, source_product_id, pass_kind, label,
			     credits_total, credits_remaining, expires_at, status, created_at)
			    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			entitlementID, StudioID, p.userID, p.productID, p.passKind, p.label,
			creditsTotal, creditsRemaining, expiresAt, entStatus,
			purchasedAt.Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed entitlement %s: %w", entitlementID, err)
		}
		for _, ctID := range productToTypes[p.productID] {
			if _, err := s.db.ExecContext(ctx,
				`INSERT OR IGNORE INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
				entitlementID, ctID,
			); err != nil {
				return err
			}
		}
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO purchases
			    (id, studio_id, user_id, product_id, list_price_minor, amount_minor, currency,
			     payment_method, initiated_by, actor_role, status,
			     resulting_entitlement_id, created_at)
			    VALUES (?, ?, ?, ?, ?, ?, 'GBP', ?, ?, ?, 'completed', ?, ?)`,
			purchaseID, StudioID, p.userID, p.productID, p.amountMinor, p.amountMinor,
			p.paymentMethod, p.initiatedBy, p.actorRole,
			entitlementID, purchasedAt.Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed purchase %s: %w", purchaseID, err)
		}
	}

	// Pre-fetch entitlement IDs so we can attach bookings to them.
	entFor := map[string]string{} // userID → entitlementID
	for _, p := range purchases {
		entFor[p.userID] = uid("05", 1+p.n)
	}
	entFor[UserMaya] = EntitlementMayaUnlimited
	// Multi-pass users — the auto-loop above just overwrites with the last
	// purchase per user, which is the wrong choice for these four. Bookings
	// should attach to the broadest, currently-active pass:
	//   Aria → new Unlimited (n=12) — not her old 5-pack (n=16)
	//   Ben  → Unlimited (n=2)      — not the Reformer pack (n=13)
	//   Ivy  → 10-pack (n=9)        — yoga bookings can't use Reformer (n=14)
	//   Kira → current 10-pack (n=11) — not the depleted historical one (n=15)
	entFor[students[0].id] = uid("05", 1+12)
	entFor[students[1].id] = uid("05", 1+2)
	entFor[students[8].id] = uid("05", 1+9)
	entFor[students[10].id] = uid("05", 1+11)

	// --- Bookings on this week's classes ---------------------------------
	// Each entry: classKey → list of (userID, status). classKey is the same
	// index used in the schedule fixture above (1-based hex within prefix
	// 0000...0010xx). Statuses default to 'booked' for future classes; for
	// past classes we mark 'attended' / 'no_show'.
	type bookingPlan struct {
		classIdx int // 1..16 within the week schedule
		userID   string
		status   string // booked | attended | no_show | cancelled
		bookedBy string // student | manager
	}
	// Reference of the fixtures order (1-based):
	//   1  Mon 07:30 Vinyasa     Asha   Room1   cap 14
	//   2  Mon 17:45 Power       Asha   Room1   cap 14
	//   3  Tue 09:00 Reformer    Jonas  R-Ref   cap 8
	//   4  Tue 18:30 Yin         Mara   Room1   cap 16
	//   5  Wed 07:30 Vinyasa     Asha   Room1   cap 14
	//   6  Wed 12:15 Yin         Mara   Room1   cap 16
	//   7  Wed 19:00 Candlelit   Mara   Room1   cap 14
	//   8  Thu 07:30 Vinyasa     Asha   Room1   cap 14
	//   9  Thu 09:00 Reformer    Jonas  R-Ref   cap 8
	//  10  Thu 17:45 Power       Asha   Room1   cap 14
	//  11  Fri 07:30 Vinyasa     Asha   Room1   cap 14
	//  12  Fri 19:00 Candlelit   Mara   Room1   cap 14
	//  13  Sat 09:00 Reformer    Jonas  R-Ref   cap 8
	//  14  Sat 11:00 Vinyasa     Asha   Room1   cap 14
	plans := []bookingPlan{
		// Monday early flow — moderate.
		{1, students[0].id, "booked", "student"},
		{1, students[1].id, "booked", "student"},
		{1, students[4].id, "booked", "student"},
		{1, students[8].id, "booked", "student"},
		// Monday evening Power Vinyasa — popular.
		{2, students[0].id, "booked", "student"},
		{2, students[1].id, "booked", "student"},
		{2, students[5].id, "booked", "student"},
		{2, students[6].id, "booked", "student"},
		{2, students[8].id, "booked", "student"},
		{2, students[9].id, "booked", "student"},
		// Tuesday reformer — small room.
		{3, students[2].id, "booked", "student"},
		{3, students[7].id, "booked", "student"},
		{3, students[1].id, "booked", "student"},
		// Tuesday evening Yin.
		{4, students[3].id, "booked", "student"},
		{4, students[4].id, "booked", "student"},
		{4, students[5].id, "booked", "student"},
		{4, students[8].id, "booked", "student"},
		{4, students[9].id, "booked", "student"},
		// Wed 12:15 Yin — completely full (cap 16) — fill with everyone.
		{6, students[0].id, "booked", "student"},
		{6, students[1].id, "booked", "student"},
		{6, students[2].id, "booked", "student"},
		{6, students[3].id, "booked", "student"},
		{6, students[4].id, "booked", "student"},
		{6, students[5].id, "booked", "student"},
		{6, students[6].id, "booked", "student"},
		{6, students[7].id, "booked", "student"},
		{6, students[8].id, "booked", "student"},
		{6, students[9].id, "booked", "student"},
		{6, UserMaya, "booked", "student"},
		// Manager-booked the last 5 spots to fill capacity.
		// Wed evening Candlelit — popular.
		{7, students[0].id, "booked", "student"},
		{7, students[5].id, "booked", "student"},
		{7, students[8].id, "booked", "student"},
		{7, students[1].id, "booked", "student"},
		// Thursday reformer.
		{9, students[2].id, "booked", "student"},
		{9, students[7].id, "booked", "student"},
		// Thursday evening Power.
		{10, students[0].id, "booked", "student"},
		{10, students[8].id, "booked", "student"},
		{10, students[1].id, "booked", "student"},
		// Friday morning Vinyasa.
		{11, students[8].id, "booked", "student"},
		{11, students[1].id, "booked", "student"},
		{11, students[5].id, "booked", "student"},
		// Friday Candlelit.
		{12, students[0].id, "booked", "student"},
		{12, students[4].id, "booked", "student"},
		{12, students[6].id, "booked", "student"},
		// Saturday reformer.
		{13, students[2].id, "booked", "student"},
		{13, students[7].id, "booked", "student"},
		{13, students[1].id, "booked", "student"},
		// Saturday late-morning flow.
		{14, students[8].id, "booked", "student"},
		{14, students[9].id, "booked", "student"},
		{14, students[5].id, "booked", "student"},
		{14, students[0].id, "booked", "student"},
	}

	// Past-class bookings: attendances/no_shows on the 6 historical Wednesday
	// classes for select regulars, to fill out reports.
	// Past class IDs are 00000000-...-0000000020XX where XX = week-ago (1..6).
	pastAttendances := []struct {
		weeksAgo int
		userID   string
		status   string
	}{
		// Ivy is the regular — she attended each of the last 6 weeks.
		{1, students[8].id, "attended"}, {2, students[8].id, "attended"},
		{3, students[8].id, "attended"}, {4, students[8].id, "attended"},
		{5, students[8].id, "attended"}, {6, students[8].id, "no_show"},
		// Aria & Ben also appear most weeks.
		{1, students[0].id, "attended"}, {2, students[0].id, "attended"},
		{3, students[0].id, "attended"}, {5, students[0].id, "attended"},
		{1, students[1].id, "attended"}, {2, students[1].id, "no_show"},
		{4, students[1].id, "attended"}, {5, students[1].id, "attended"},
		// Felix (the comped student) attended a couple.
		{2, students[5].id, "attended"}, {3, students[5].id, "attended"},
	}

	// --- Insert the current-week bookings --------------------------------
	// Booking row IDs: 0062 + idx — start above Maya's existing 0061.
	bookingCounter := 1
	for _, bp := range plans {
		// Current week's class — week index 0 in the two-week generator.
		classID := fmt.Sprintf("cls_wk0_%02d", bp.classIdx)
		entID := entFor[bp.userID]
		if entID == "" {
			return fmt.Errorf("no entitlement for user %s", bp.userID)
		}
		bookingID := uid("06", 1+bookingCounter) // 062, 063, ... (avoid 061)
		bookingCounter++
		// Backdate created_at: 1..7 days ago, deterministic per index.
		created := now.AddDate(0, 0, -((bookingCounter % 7) + 1)).Format(time.RFC3339)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id,
			     booked_by_role, cancel_cutoff_hours, status, created_at)
			    VALUES (?, ?, ?, ?, ?, ?, 12, ?, ?)`,
			bookingID, StudioID, classID, bp.userID, entID,
			bp.bookedBy, bp.status, created,
		); err != nil {
			return fmt.Errorf("seed booking %s: %w", bookingID, err)
		}
	}

	// --- Small high-demand workshop with waitlist -----------------------
	// Insert a one-off Saturday-morning "Handstands Workshop" with capacity
	// 6 — Mara's marquee class. Fill it to cap, then waitlist 3 more
	// students so the waitlist promotion flow has real data behind it.
	workshopID := "cls_workshop_handstand"
	workshopStart := monday.AddDate(0, 0, 5).Add(10 * time.Hour) // Saturday 10:00
	if _, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO classes
		    (id, studio_id, class_type_id, instructor_id, room_id, title,
		     starts_at, ends_at, capacity)
		    VALUES (?, ?, ?, ?, ?, 'Handstands Workshop', ?, ?, 6)`,
		workshopID, StudioID, ClassTypeYoga, InstructorMara, Room1,
		workshopStart.Format(time.RFC3339),
		workshopStart.Add(90*time.Minute).Format(time.RFC3339),
	); err != nil {
		return fmt.Errorf("seed workshop: %w", err)
	}
	// Five real bookings — one seat sits "occupied" by Kira's late cancel
	// below, so the visible roster looks full but promote can fill the
	// open seat from the waitlist.
	for i, uID := range []string{
		students[0].id, students[1].id, students[4].id, students[5].id,
		UserMaya,
	} {
		bookingID := uid("07", 1+i) // 0701, 0702, ...
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id,
			     booked_by_role, cancel_cutoff_hours, status, created_at)
			    VALUES (?, ?, ?, ?, ?, 'student', 12, 'booked', ?)`,
			bookingID, StudioID, workshopID, uID, entFor[uID],
			now.AddDate(0, 0, -(i+1)).Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed workshop booking %s: %w", bookingID, err)
		}
	}
	// Three students on the waitlist — none of them are booked above.
	// Joel first so the "promote" demo always succeeds (he has unlimited);
	// Diego (drop-in, no credits left) sits at the back where the manager
	// would naturally skip past him.
	for i, uID := range []string{students[9].id, students[6].id, students[3].id} {
		wlID := uid("0c", i+1)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO waitlist_entries
			    (id, class_id, user_id, position, created_at)
			    VALUES (?, ?, ?, ?, ?)`,
			wlID, workshopID, uID, i+1,
			now.Add(-time.Duration(2*(i+1))*time.Hour).Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed waitlist %s: %w", wlID, err)
		}
	}

	// --- Past attendance + no_show rows ---------------------------------
	for i, pa := range pastAttendances {
		classID := fmt.Sprintf("cls_past_%d", pa.weeksAgo)
		entID := entFor[pa.userID]
		if entID == "" {
			continue
		}
		bookingID := uid("0a", i+1) // 0a01..
		// Created in the week the class happened.
		classStart := monday.AddDate(0, 0, -7*pa.weeksAgo+2).Add(19 * time.Hour)
		created := classStart.Add(-2 * 24 * time.Hour).Format(time.RFC3339)
		var outcome any
		if pa.status == "no_show" {
			outcome = "no_show_burned"
		}
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO bookings
			    (id, studio_id, class_id, user_id, entitlement_id,
			     booked_by_role, cancel_cutoff_hours, status, outcome, created_at)
			    VALUES (?, ?, ?, ?, ?, 'student', 12, ?, ?, ?)`,
			bookingID, StudioID, classID, pa.userID, entID, pa.status, outcome, created,
		); err != nil {
			return fmt.Errorf("seed past attendance %s: %w", bookingID, err)
		}
	}

	// --- A couple of student-side cancellations on past classes ---------
	// Diego cancelled out of week-6 Vinyasa well outside the cutoff (a day+
	// ahead) — counts as a clean cancel, not a late one.
	cancelClassID := fmt.Sprintf("cls_past_%d", 6)
	cancelBookingID := uid("0a", 99)
	cancelCreated := monday.AddDate(0, 0, -42-1).Format(time.RFC3339)
	cancelTime := monday.AddDate(0, 0, -42).Format(time.RFC3339)
	if _, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id,
		     booked_by_role, cancel_cutoff_hours, status, outcome,
		     created_at, cancelled_at)
		    VALUES (?, ?, ?, ?, ?, 'student', 12, 'cancelled',
		            'cancelled_free', ?, ?)`,
		cancelBookingID, StudioID, cancelClassID, students[3].id,
		entFor[students[3].id], cancelCreated, cancelTime,
	); err != nil {
		return fmt.Errorf("seed cancellation: %w", err)
	}

	// And a *late* cancellation on the Saturday handstands workshop — Kira
	// pulled out 2 hours before the start with a 12h cutoff, so the pass
	// was consumed but a seat is free. Surfaces the Late-cancel tab + the
	// waitlist promote-into-an-empty-seat flow.
	lateBookingID := uid("0a", 100)
	lateCreated := workshopStart.AddDate(0, 0, -3).Format(time.RFC3339)
	lateCancelled := workshopStart.Add(-2 * time.Hour).Format(time.RFC3339)
	if _, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO bookings
		    (id, studio_id, class_id, user_id, entitlement_id,
		     booked_by_role, cancel_cutoff_hours, status, outcome,
		     created_at, cancelled_at)
		    VALUES (?, ?, ?, ?, ?, 'student', 12, 'cancelled',
		            'cancelled_late_burned', ?, ?)`,
		lateBookingID, StudioID, workshopID, students[10].id,
		entFor[students[10].id], lateCreated, lateCancelled,
	); err != nil {
		return fmt.Errorf("seed late cancellation: %w", err)
	}

	// --- Beginners' Course enrollments ----------------------------------
	// Grace + Diego signed up for the course. The API creates one enrollment
	// entitlement per signup, scoped to the course's class_type.
	courseSignups := []string{students[6].id, students[3].id, students[8].id}
	for i, uID := range courseSignups {
		entID := uid("0e", 10+i)      // 00000000-...-0e00a..
		purchaseID := uid("0e", 20+i) // 00000000-...-0e014..
		signupDay := now.AddDate(0, 0, -(3 + i*2))
		// Entitlement scoped to the course's class_type — gives them access to
		// all 6 sessions and nothing else.
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO entitlements
			    (id, studio_id, user_id, source_product_id, pass_kind, label,
			     expires_at, status, created_at)
			    VALUES (?, ?, ?, ?, 'unlimited', ?, ?, 'active', ?)`,
			entID, StudioID, uID, ProductBeginnersCourse,
			"Beginners' Course · Summer 2026",
			monday.AddDate(0, 0, 7*7).Format(time.RFC3339), // course ends ~7 weeks out
			signupDay.Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed enrollment entitlement: %w", err)
		}
		if _, err := s.db.ExecContext(ctx,
			`INSERT OR IGNORE INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
			entID, ClassTypeBeginnersSum,
		); err != nil {
			return fmt.Errorf("seed enrollment entitlement_class_types: %w", err)
		}
		// Purchase row.
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO purchases
			    (id, studio_id, user_id, product_id, list_price_minor, amount_minor, currency,
			     payment_method, initiated_by, actor_role, status,
			     resulting_entitlement_id, created_at)
			    VALUES (?, ?, ?, ?, 6000, 6000, 'GBP', 'card', ?, 'student',
			            'completed', ?, ?)`,
			purchaseID, StudioID, uID, ProductBeginnersCourse, uID,
			entID, signupDay.Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed enrollment purchase: %w", err)
		}
		// enrollment_bookings link.
		ebID := uid("0e", 30+i)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO enrollment_bookings
			    (id, enrollment_id, user_id, entitlement_id, status, created_at)
			    VALUES (?, ?, ?, ?, 'active', ?)`,
			ebID, EnrollmentBeginners, uID, entID,
			signupDay.Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed enrollment_bookings: %w", err)
		}
		// Pre-create booking rows on the first two sessions so the series
		// roster has visible attendance state from the start.
		for w := 1; w <= 2; w++ {
			sessionID := fmt.Sprintf("cls_crs_%d", w)
			bookingID := uid("0e", 40+i*10+w)
			if _, err := s.db.ExecContext(ctx, `
				INSERT OR IGNORE INTO bookings
				    (id, studio_id, class_id, user_id, entitlement_id,
				     booked_by_role, cancel_cutoff_hours, status, created_at)
				    VALUES (?, ?, ?, ?, ?, 'student', 12, 'booked', ?)`,
				bookingID, StudioID, sessionID, uID, entID,
				signupDay.Format(time.RFC3339),
			); err != nil {
				return fmt.Errorf("seed course session booking: %w", err)
			}
		}
	}

	// --- Notifications for other students --------------------------------
	moreNotifs := []struct {
		n            int
		userID, kind string
		title, body  string
		hoursAgo     int
		unread       bool
	}{
		{1, students[1].id, "booking_confirmed",
			"You're booked into Power Vinyasa",
			"Monday 17:45 · Room 1 · with Asha Patel", 6, true},
		{2, students[1].id, "system",
			"Welcome to Studio 52",
			"Your Unlimited Monthly pass is active.", 12 * 24, false},
		{3, students[8].id, "booking_confirmed",
			"You're booked into Wednesday Yin",
			"Wednesday 12:15 · Room 1 · with Mara Kovac", 18, true},
		{4, students[4].id, "low_credits",
			"Only 2 classes left on your pack",
			"Your 5-Class Pack has 2 credits remaining.", 36, true},
		{5, students[6].id, "system",
			"Beginners' Course starts next week",
			"6 Wednesdays · 18:00 · with Mara Kovac", 24, false},
		{6, students[3].id, "waitlist_added",
			"You're on the waitlist · position 1",
			"Wednesday Yin · 12:15 with Mara Kovac. We'll text you when a spot opens.", 4, true},
		{7, UserPriya, "system",
			"Daily roster ready",
			"4 classes today · 28 enrolments across rooms.", 1, true},
	}
	for _, n := range moreNotifs {
		var readAt any
		if !n.unread {
			readAt = now.Add(-time.Duration(n.hoursAgo/2) * time.Hour).Format(time.RFC3339)
		}
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO notifications
			    (id, studio_id, user_id, type, title, body, payload, read_at, created_at)
			    VALUES (?, ?, ?, ?, ?, ?, '{}', ?, ?)`,
			uid("09", 100+n.n), StudioID, n.userID, n.kind, n.title, n.body,
			readAt,
			now.Add(-time.Duration(n.hoursAgo)*time.Hour).Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed notification %d: %w", n.n, err)
		}
	}

	// --- Promotions ------------------------------------------------------
	promos := []struct {
		n           int
		title, body string
		image       string
		startsDays  int // ago (negative = future)
		endsDays    int // future
	}{
		{1, "Summer membership",
			"15% off Unlimited Monthly through August. Use code SUMMER15 at checkout.",
			"https://picsum.photos/seed/studio52-summer/1200/600",
			10, 60},
		{2, "Bring a friend Fridays",
			"Members can bring a guest free to every Friday class — just add them at check-in.",
			"https://picsum.photos/seed/studio52-friends/1200/600",
			3, 28},
	}
	for _, p := range promos {
		startsAt := now.AddDate(0, 0, -p.startsDays).Format(time.RFC3339)
		endsAt := now.AddDate(0, 0, p.endsDays).Format(time.RFC3339)
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO promotions
			    (id, studio_id, title, body, image_url, starts_at, ends_at,
			     is_archived, created_at)
			    VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)`,
			uid("0f", p.n), StudioID, p.title, p.body, p.image,
			startsAt, endsAt, startsAt,
		); err != nil {
			return fmt.Errorf("seed promotion %d: %w", p.n, err)
		}
	}

	// --- Audit log entries (manager actions) -----------------------------
	// Priya comped Felix's unlimited pass — corresponding audit row + the
	// "cash_grant" row for a 50 GBP comp credit she added to Hiro.
	audits := []struct {
		n          int
		actor      string
		action     string
		targetType string
		targetID   string
		detail     string
		hoursAgo   int
	}{
		{1, UserPriya, "comp_grant", "entitlement",
			uid("05", 1+6), // Felix's entitlement
			`{"product":"Unlimited Monthly","amount_minor":0,"reason":"VIP comp"}`,
			22 * 24},
		{2, UserPriya, "credit_adjust", "entitlement",
			uid("05", 1+8), // Hiro's
			`{"delta":+2,"reason":"two classes were cancelled by studio"}`,
			3 * 24},
		{3, UserPriya, "class_cancel", "class",
			"cls_past_5", // a past class
			`{"bookings_cancelled":1,"credits_returned":1,"notifications_sent":1}`,
			5 * 24},
	}
	for _, a := range audits {
		if _, err := s.db.ExecContext(ctx, `
			INSERT OR IGNORE INTO audit_log
			    (id, studio_id, actor_id, action, target_type, target_id,
			     detail, created_at)
			    VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			uid("0d", a.n), StudioID, a.actor, a.action, a.targetType,
			a.targetID, a.detail,
			now.Add(-time.Duration(a.hoursAgo)*time.Hour).Format(time.RFC3339),
		); err != nil {
			return fmt.Errorf("seed audit %d: %w", a.n, err)
		}
	}

	return nil
}
