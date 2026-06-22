package store

import (
	"context"
	"testing"
	"time"
)

// helper: attendance row for the fixture's student on a class that
// started `pastHours` ago. Returns the booking id so the caller can
// inspect it if needed.
func attendPast(t *testing.T, s *Store, f fixture, ent string, pastHours int) string {
	t.Helper()
	ctx := context.Background()
	// Anchor the class start to today's noon UTC so the hour-of-day is
	// always 12 — that keeps test runs from accidentally triggering
	// early_bird (<08:00) or night_owl (>=19:00) badges depending on the
	// wall clock when the suite happens to run.
	now := time.Now().UTC()
	base := time.Date(now.Year(), now.Month(), now.Day(), 12, 0, 0, 0, time.UTC)
	class := f.insertClass(t, s, base.Add(-time.Duration(pastHours)*time.Hour), 10)
	// CreateBooking refuses past classes (the "doors closed" gate), so seed
	// the booked row directly — these fixtures represent classes that were
	// booked while still future and have since happened.
	bookingID := f.insertBookedSeat(t, s, class, ent)
	if err := s.MarkAttendance(ctx, "actor-test", bookingID, "attended", "manual"); err != nil {
		t.Fatalf("mark attended: %v", err)
	}
	return bookingID
}

// hasBadge searches a slice for an EARNED badge by key. The response
// includes the full catalogue with locked entries (EarnedAt == nil), so
// "in the slice" is not the same as "earned" — only the latter counts.
func hasBadge(rows []Achievement, key string) bool {
	for _, r := range rows {
		if r.BadgeKey == key && r.EarnedAt != nil {
			return true
		}
	}
	return false
}

// earnedOnly filters the catalogue response to the badges the user has
// actually earned.
func earnedOnly(rows []Achievement) []Achievement {
	out := make([]Achievement, 0, len(rows))
	for _, r := range rows {
		if r.EarnedAt != nil {
			out = append(out, r)
		}
	}
	return out
}

func mustReadAchievements(t *testing.T, s *Store, userID string) []Achievement {
	t.Helper()
	rows, err := s.MyAchievements(context.Background(), userID)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func ptrEq(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func derefPtr(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

func TestAchievements_NoAttendanceNoBadges(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	rows, err := s.MyAchievements(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if e := earnedOnly(rows); len(e) != 0 {
		t.Errorf("zero-attendance user has earned badges: %+v", e)
	}
}

// TestAchievements_CatalogueShape — the response always returns every rule
// in the catalogue, locked rows with EarnedAt=nil. The full screen depends
// on this shape so it can render dim variants without a second request.
func TestAchievements_CatalogueShape(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	rows, err := s.MyAchievements(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != len(allRules) {
		t.Fatalf("catalogue size: got %d want %d", len(rows), len(allRules))
	}
	// Every row carries title + sub; every key matches a rule.
	keys := map[string]bool{}
	for _, r := range allRules {
		keys[r.key] = true
	}
	for _, r := range rows {
		if !keys[r.BadgeKey] {
			t.Errorf("unknown badge_key returned: %q", r.BadgeKey)
		}
		if r.Title == "" || r.Sub == "" {
			t.Errorf("badge missing title/sub: %+v", r)
		}
		if r.EarnedAt != nil {
			t.Errorf("zero-attendance user should have all locked; %s has earned_at=%v",
				r.BadgeKey, *r.EarnedAt)
		}
	}
}

// TestAchievements_CatalogueIncludesEarnedAndLocked — once a user earns
// first_class, the response still returns all 8 entries — earned with a
// non-nil EarnedAt, the other 7 still locked.
func TestAchievements_CatalogueIncludesEarnedAndLocked(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	attendPast(t, s, f, ent, 24) // one past attended class → first_class

	rows, err := s.MyAchievements(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != len(allRules) {
		t.Fatalf("catalogue size after earning one: got %d want %d",
			len(rows), len(allRules))
	}
	var earned, locked int
	for _, r := range rows {
		if r.EarnedAt != nil {
			earned++
		} else {
			locked++
		}
	}
	if earned != 1 {
		t.Errorf("expected exactly 1 earned (first_class); got %d", earned)
	}
	if locked != len(allRules)-1 {
		t.Errorf("expected %d locked; got %d", len(allRules)-1, locked)
	}
}

func TestAchievements_FirstClass(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	attendPast(t, s, f, ent, 24)

	rows, err := s.MyAchievements(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if !hasBadge(rows, "first_class") {
		t.Errorf("first_class not granted: %+v", rows)
	}
}

func TestAchievements_RegularAtFive(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	for i := 1; i <= 5; i++ {
		attendPast(t, s, f, ent, i*24+1) // each one a different hour, different past day
	}
	rows, err := s.MyAchievements(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if !hasBadge(rows, "first_class") || !hasBadge(rows, "regular") {
		t.Errorf("expected first_class + regular: %+v", rows)
	}
	if hasBadge(rows, "devotee") {
		t.Errorf("devotee shouldn't fire below 25: %+v", rows)
	}
}

func TestAchievements_EarlyBird(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	// A class at 06:00 — explicitly past, but at that hour-of-day.
	morning := time.Date(time.Now().UTC().Year(), 1, 5, 6, 0, 0, 0, time.UTC)
	class := f.insertClass(t, s, morning, 10)
	bid := f.insertBookedSeat(t, s, class, ent)
	if err := s.MarkAttendance(ctx, "actor-test", bid, "attended", "manual"); err != nil {
		t.Fatal(err)
	}

	rows, err := s.MyAchievements(ctx, f.studentID)
	if err != nil {
		t.Fatal(err)
	}
	if !hasBadge(rows, "early_bird") {
		t.Errorf("early_bird missing: %+v", rows)
	}
	if hasBadge(rows, "night_owl") {
		t.Errorf("night_owl shouldn't fire from a 06:00 class: %+v", rows)
	}
}

func TestAchievements_NightOwl(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	evening := time.Date(time.Now().UTC().Year(), 1, 5, 19, 30, 0, 0, time.UTC)
	class := f.insertClass(t, s, evening, 10)
	bid := f.insertBookedSeat(t, s, class, ent)
	if err := s.MarkAttendance(ctx, "actor-test", bid, "attended", "manual"); err != nil {
		t.Fatal(err)
	}

	rows, _ := s.MyAchievements(ctx, f.studentID)
	if !hasBadge(rows, "night_owl") {
		t.Errorf("night_owl missing: %+v", rows)
	}
}

func TestAchievements_VarietyAcrossDisciplines(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)

	// Fixture's default class_type has empty discipline. Add a second
	// type with a different discipline, then attend both.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE class_types SET discipline = 'yoga' WHERE id = ?`, f.classTypeID,
	); err != nil {
		t.Fatal(err)
	}
	reformerType := NewID()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO class_types (id, studio_id, name, discipline) VALUES (?, ?, 'Reformer', 'reformer')`,
		reformerType, f.studioID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO entitlement_class_types (entitlement_id, class_type_id) VALUES (?, ?)`,
		ent, reformerType,
	); err != nil {
		t.Fatal(err)
	}

	// One yoga class (already covered by fixture class_type).
	attendPast(t, s, f, ent, 48)

	// One reformer class.
	reformerClass := NewID()
	end := time.Now().UTC().Add(-12 * time.Hour)
	start := end.Add(-1 * time.Hour)
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO classes (id, studio_id, class_type_id, instructor_id, room_id,
		                     title, starts_at, ends_at, capacity, status)
		    VALUES (?, ?, ?, ?, ?, 'Reformer', ?, ?, 10, 'scheduled')`,
		reformerClass, f.studioID, reformerType, f.instructorID, f.roomID,
		start.Format(time.RFC3339), end.Format(time.RFC3339),
	); err != nil {
		t.Fatal(err)
	}
	bid := f.insertBookedSeat(t, s, reformerClass, ent)
	if err := s.MarkAttendance(ctx, "actor-test", bid, "attended", "manual"); err != nil {
		t.Fatal(err)
	}

	rows, _ := s.MyAchievements(ctx, f.studentID)
	if !hasBadge(rows, "variety") {
		t.Errorf("variety missing — yoga + reformer attended: %+v", rows)
	}
}

func TestAchievements_GrantedRowsArePersisted(t *testing.T) {
	// Earning is one-way: once a rule fires, the row exists. Reading
	// again hits the same row without re-INSERTing.
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	ent := f.insertEntitlement(t, s, "unlimited", 0)
	attendPast(t, s, f, ent, 24)

	first := earnedOnly(mustReadAchievements(t, s, f.studentID))
	second := earnedOnly(mustReadAchievements(t, s, f.studentID))

	// Both reads return the same badge with the same earned_at — the
	// second read must not over-write the timestamp.
	if len(first) != 1 || len(second) != 1 {
		t.Fatalf("earned counts: first=%d second=%d", len(first), len(second))
	}
	if !ptrEq(first[0].EarnedAt, second[0].EarnedAt) {
		t.Errorf("earned_at drifted between reads: %v vs %v",
			derefPtr(first[0].EarnedAt), derefPtr(second[0].EarnedAt))
	}
	// Exactly one row in the table.
	var n int
	if err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM achievements WHERE user_id = ?`, f.studentID,
	).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("row count: got %d want 1 (second read should not re-INSERT)", n)
	}
}

func TestLongestConsecutiveWeeks(t *testing.T) {
	cases := []struct {
		name  string
		weeks []isoWeek
		want  int
	}{
		{"empty", nil, 0},
		{"one", []isoWeek{{2026, 10}}, 1},
		{"three in a row", []isoWeek{{2026, 10}, {2026, 11}, {2026, 12}}, 3},
		{"gap breaks streak", []isoWeek{{2026, 10}, {2026, 12}}, 1},
		{"longest of two runs", []isoWeek{{2026, 5}, {2026, 6}, {2026, 12}, {2026, 13}, {2026, 14}, {2026, 15}}, 4},
		{"duplicates count once", []isoWeek{{2026, 10}, {2026, 10}}, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := map[isoWeek]bool{}
			for _, w := range c.weeks {
				m[w] = true
			}
			if got := longestConsecutiveWeeks(m); got != c.want {
				t.Errorf("got %d want %d", got, c.want)
			}
		})
	}
}
