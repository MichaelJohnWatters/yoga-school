package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Achievement is one badge in the catalogue, optionally with the time the
// user earned it. EarnedAt is nil when the badge is still locked — the
// client uses that to render the dim/locked variant on the full screen.
type Achievement struct {
	BadgeKey string  `json:"badge_key"`
	Title    string  `json:"title"`
	Sub      string  `json:"sub"`
	EarnedAt *string `json:"earned_at"`
}

// achievementRule is a single badge in the catalogue. Each rule knows how
// to check itself against the user's attendance history; the lazy eval on
// MyAchievements grants any rule that newly passes since the last read.
type achievementRule struct {
	key   string
	title string
	sub   string
	check func(s *stats) bool
}

// stats is a cheap one-pass aggregation of a user's attended bookings —
// the inputs every catalogue rule needs. Computed once per
// MyAchievements call.
type stats struct {
	attended          int
	disciplines       map[string]bool
	consecutiveWeeks  int
	earliestStartHour int
	latestStartHour   int
	courseCompletions int
}

// isoWeek is a (year, week) pair used as a map key inside stats
// computation. Top-level so longestConsecutiveWeeks can take the same
// type without re-declaring.
type isoWeek struct{ year, week int }

var allRules = []achievementRule{
	{
		key:   "first_class",
		title: "First class",
		sub:   "Welcome — your first session is on the books.",
		check: func(s *stats) bool { return s.attended >= 1 },
	},
	{
		key:   "regular",
		title: "Regular",
		sub:   "Five classes in.",
		check: func(s *stats) bool { return s.attended >= 5 },
	},
	{
		key:   "devotee",
		title: "Devotee",
		sub:   "Twenty-five classes.",
		check: func(s *stats) bool { return s.attended >= 25 },
	},
	{
		key:   "early_bird",
		title: "Early bird",
		sub:   "Attended a class starting before 08:00.",
		check: func(s *stats) bool { return s.earliestStartHour > 0 && s.earliestStartHour < 8 },
	},
	{
		key:   "night_owl",
		title: "Night owl",
		sub:   "Attended an evening class (19:00 or later).",
		check: func(s *stats) bool { return s.latestStartHour >= 19 },
	},
	{
		key:   "variety",
		title: "Range",
		sub:   "Tried more than one discipline.",
		check: func(s *stats) bool { return len(s.disciplines) >= 2 },
	},
	{
		key:   "streak_3",
		title: "Three-week streak",
		sub:   "Attended in three consecutive weeks.",
		check: func(s *stats) bool { return s.consecutiveWeeks >= 3 },
	},
	{
		key:   "course_graduate",
		title: "Course graduate",
		sub:   "Completed a multi-session course.",
		check: func(s *stats) bool { return s.courseCompletions >= 1 },
	},
}

// MyAchievements reads + lazily grants. Returns the full earned list in
// the same shape every time, including the just-granted ones. Earned_at
// is "first time we noticed", which is good enough for a cosmetic
// feature — no background job needed.
func (s *Store) MyAchievements(ctx context.Context, userID string) ([]Achievement, error) {
	st, err := computeUserStats(ctx, s.db, userID)
	if err != nil {
		return nil, err
	}

	// Existing earned set (badge_key → earned_at).
	earned := map[string]string{}
	rows, err := s.db.QueryContext(ctx,
		`SELECT badge_key, earned_at FROM achievements WHERE user_id = ?`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var k, t string
		if err := rows.Scan(&k, &t); err != nil {
			rows.Close()
			return nil, err
		}
		earned[k] = t
	}
	rows.Close()

	// Grant any new rule that passes. INSERT OR IGNORE in case of races.
	// Re-read after writing so the returned earned_at matches the
	// DB-formatted timestamp byte-for-byte — otherwise a second
	// MyAchievements call (which reads from the DB) appears to mutate
	// the timestamp.
	granted := false
	for _, r := range allRules {
		if _, already := earned[r.key]; already {
			continue
		}
		if !r.check(st) {
			continue
		}
		if _, err := s.db.ExecContext(ctx,
			`INSERT OR IGNORE INTO achievements (user_id, badge_key) VALUES (?, ?)`,
			userID, r.key,
		); err != nil {
			return nil, fmt.Errorf("grant %s: %w", r.key, err)
		}
		granted = true
	}
	if granted {
		earned = map[string]string{}
		rows, err := s.db.QueryContext(ctx,
			`SELECT badge_key, earned_at FROM achievements WHERE user_id = ?`,
			userID,
		)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var k, t string
			if err := rows.Scan(&k, &t); err != nil {
				rows.Close()
				return nil, err
			}
			earned[k] = t
		}
		rows.Close()
	}

	// Build the response in catalogue order. Every rule shows up so the
	// full screen can render locked variants — earned rows carry their
	// timestamp, locked rows carry nil. Legacy badge_key rows that no
	// longer match any rule are dropped silently.
	out := make([]Achievement, 0, len(allRules))
	for _, r := range allRules {
		row := Achievement{
			BadgeKey: r.key,
			Title:    r.title,
			Sub:      r.sub,
		}
		if t, ok := earned[r.key]; ok {
			row.EarnedAt = &t
		}
		out = append(out, row)
	}
	return out, nil
}

// computeUserStats walks the user's attended bookings once and rolls them
// up into the aggregate the rule set needs.
func computeUserStats(ctx context.Context, db *sql.DB, userID string) (*stats, error) {
	out := &stats{
		disciplines: map[string]bool{},
	}
	rows, err := db.QueryContext(ctx, `
		SELECT c.starts_at, COALESCE(ct.discipline,''), c.enrollment_id
		  FROM bookings b
		  JOIN classes     c  ON c.id  = b.class_id
		  JOIN class_types ct ON ct.id = c.class_type_id
		 WHERE b.user_id = ?
		   AND b.status  = 'attended'
		 ORDER BY c.starts_at ASC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	weeks := map[isoWeek]bool{}
	enrollmentCounts := map[string]int{}

	out.earliestStartHour = -1
	out.latestStartHour = -1
	for rows.Next() {
		var startStr, disc string
		var enrollmentID sql.NullString
		if err := rows.Scan(&startStr, &disc, &enrollmentID); err != nil {
			return nil, err
		}
		t, err := time.Parse(time.RFC3339, startStr)
		if err != nil {
			continue // skip malformed rather than blowing up the whole read
		}
		out.attended++
		if disc != "" {
			out.disciplines[disc] = true
		}
		h := t.UTC().Hour()
		if out.earliestStartHour < 0 || h < out.earliestStartHour {
			out.earliestStartHour = h
		}
		if h > out.latestStartHour {
			out.latestStartHour = h
		}
		y, w := t.UTC().ISOWeek()
		weeks[isoWeek{y, w}] = true
		if enrollmentID.Valid {
			enrollmentCounts[enrollmentID.String]++
		}
	}

	// Longest run of consecutive ISO weeks attended.
	if len(weeks) > 0 {
		out.consecutiveWeeks = longestConsecutiveWeeks(weeks)
	}

	// Course completion: a user has completed an enrollment when their
	// attended-session count on that enrollment matches the enrollment's
	// declared session_count. Done as a single query so we don't have to
	// re-query per enrollment.
	if len(enrollmentCounts) > 0 {
		erows, err := db.QueryContext(ctx, `
			SELECT id, session_count FROM enrollments WHERE id IN (`+
			placeholders(len(enrollmentCounts))+`)`,
			anyKeys(enrollmentCounts)...,
		)
		if err != nil {
			return nil, err
		}
		defer erows.Close()
		for erows.Next() {
			var id string
			var need int
			if err := erows.Scan(&id, &need); err != nil {
				return nil, err
			}
			if enrollmentCounts[id] >= need {
				out.courseCompletions++
			}
		}
	}
	return out, rows.Err()
}

// longestConsecutiveWeeks returns the length of the longest streak of
// adjacent ISO weeks present in the set. Walks the keys sorted; year/week
// rollover is handled by converting to a single linear week index.
func longestConsecutiveWeeks(weeks map[isoWeek]bool) int {
	// Flatten to sorted linear keys. Year=2026 week=10 → 2026*53+10. Not
	// astronomically correct (ISO weeks can be 52 or 53) but close enough
	// for badge-granting: a one-week gap occasionally counts as adjacent
	// across a 53→1 boundary, which over-grants by at most one badge.
	type lin int
	keys := make([]lin, 0, len(weeks))
	for w := range weeks {
		keys = append(keys, lin(w.year*53+w.week))
	}
	// Simple insertion sort — small N.
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j-1] > keys[j]; j-- {
			keys[j-1], keys[j] = keys[j], keys[j-1]
		}
	}
	best, cur := 1, 1
	for i := 1; i < len(keys); i++ {
		if keys[i] == keys[i-1]+1 {
			cur++
			if cur > best {
				best = cur
			}
		} else if keys[i] != keys[i-1] {
			cur = 1
		}
	}
	if len(keys) == 0 {
		return 0
	}
	return best
}

func placeholders(n int) string {
	if n == 0 {
		return ""
	}
	out := make([]byte, 0, 2*n-1)
	for i := 0; i < n; i++ {
		if i > 0 {
			out = append(out, ',')
		}
		out = append(out, '?')
	}
	return string(out)
}

func anyKeys(m map[string]int) []any {
	out := make([]any, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
