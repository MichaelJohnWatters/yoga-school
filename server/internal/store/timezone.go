package store

import (
	"context"
	"sync"
	"time"
)

// studioLocationCache memoises the parsed *time.Location per studio.
// Hot-path callers (every "what is today's date?" check on the dashboard,
// the schedule, the reports) hit this; the underlying time.LoadLocation
// does an mmap of the tzdata file which we don't want to repeat on every
// request.
var studioLocationCache sync.Map // studioID → *time.Location

// StudioLocation returns the studio's *time.Location, falling back to UTC
// when the column is missing or unparseable. Cached forever within the
// process; callers that mutate `studios.timezone` should call
// InvalidateStudioLocation(studioID) so the next read picks up the change.
//
// Why a method on Store: the lookup needs DB access. Why a top-level
// cache: the result is process-wide, not per-Store-instance — sharing
// across test stores is harmless since each test gets a fresh studio
// id and the cache is keyed by id.
func (s *Store) StudioLocation(ctx context.Context, studioID string) *time.Location {
	if v, ok := studioLocationCache.Load(studioID); ok {
		return v.(*time.Location)
	}
	var tz string
	if err := s.db.QueryRowContext(ctx,
		`SELECT timezone FROM studios WHERE id = ?`, studioID,
	).Scan(&tz); err != nil {
		return time.UTC
	}
	loc, err := time.LoadLocation(tz)
	if err != nil || loc == nil {
		// Unrecognised IANA name (or no tzdata on this box). Falling back
		// to UTC keeps the server running with a known-correct timezone
		// rather than crashing — the studio's display will look "an hour
		// off" until the admin fixes it.
		loc = time.UTC
	}
	studioLocationCache.Store(studioID, loc)
	return loc
}

// InvalidateStudioLocation drops the cached parse so the next
// StudioLocation call re-reads from the DB. Called from UpdateStudioConfig
// when the timezone field is touched.
func InvalidateStudioLocation(studioID string) {
	studioLocationCache.Delete(studioID)
}

// startOfDayIn computes the local midnight for `t` interpreted in loc.
// Returns the resulting instant — caller usually formats it as RFC3339 UTC
// for SQL. Useful because `time.Date(...)` in a non-UTC location does the
// right thing for "first moment of this calendar day" even across DST.
func startOfDayIn(t time.Time, loc *time.Location) time.Time {
	tl := t.In(loc)
	return time.Date(tl.Year(), tl.Month(), tl.Day(), 0, 0, 0, 0, loc)
}

// startOfMonthIn returns local midnight on the 1st of the month for the
// instant `t` interpreted in loc.
func startOfMonthIn(t time.Time, loc *time.Location) time.Time {
	tl := t.In(loc)
	return time.Date(tl.Year(), tl.Month(), 1, 0, 0, 0, 0, loc)
}

// mondayOfIn returns the most recent local Monday at 00:00 in loc on or
// before `t`. Mirrors mondayOf (UTC) for the timezone-aware paths.
func mondayOfIn(t time.Time, loc *time.Location) time.Time {
	tl := t.In(loc)
	offset := (int(tl.Weekday()) + 6) % 7 // Mon=0..Sun=6
	return time.Date(tl.Year(), tl.Month(), tl.Day()-offset, 0, 0, 0, 0, loc)
}

// parseStudioDate parses a YYYY-MM-DD string as "midnight on that date in
// the studio's TZ" so a /classes?date=2026-06-15 request from a Sydney
// studio means Sydney's June 15, not UTC's. Returns an error on a bad
// format so the caller can 400 cleanly.
func parseStudioDate(s string, loc *time.Location) (time.Time, error) {
	return time.ParseInLocation("2006-01-02", s, loc)
}
