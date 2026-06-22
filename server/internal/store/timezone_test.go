package store

import (
	"context"
	"testing"
	"time"
)

func TestStudioLocation_DefaultIsLondon(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	// The fixture doesn't set a timezone — falls back to the schema
	// default (Europe/London).
	loc := s.StudioLocation(context.Background(), f.studioID)
	if loc.String() != "Europe/London" {
		t.Errorf("default tz: got %s want Europe/London", loc)
	}
}

func TestStudioLocation_HonoursOverride(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	if _, err := s.db.ExecContext(ctx,
		`UPDATE studios SET timezone = 'Australia/Sydney' WHERE id = ?`, f.studioID,
	); err != nil {
		t.Fatal(err)
	}
	InvalidateStudioLocation(f.studioID)
	loc := s.StudioLocation(ctx, f.studioID)
	if loc.String() != "Australia/Sydney" {
		t.Errorf("got %s want Australia/Sydney", loc)
	}
}

func TestStudioLocation_FallsBackOnGarbage(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	if _, err := s.db.ExecContext(ctx,
		`UPDATE studios SET timezone = 'Mars/Olympus_Mons' WHERE id = ?`, f.studioID,
	); err != nil {
		t.Fatal(err)
	}
	InvalidateStudioLocation(f.studioID)
	loc := s.StudioLocation(ctx, f.studioID)
	if loc.String() != "UTC" {
		t.Errorf("garbage tz should fall back to UTC, got %s", loc)
	}
}

func TestStartOfDayIn_HandlesNonUtc(t *testing.T) {
	syd, err := time.LoadLocation("Australia/Sydney")
	if err != nil {
		t.Skip("no tzdata for Australia/Sydney on this box")
	}
	// 2026-06-15 03:00 UTC == 2026-06-15 13:00 Sydney (winter, UTC+10).
	// startOfDayIn should return Sydney's 00:00 on the 15th — which is
	// 2026-06-14 14:00 UTC.
	t1 := time.Date(2026, 6, 15, 3, 0, 0, 0, time.UTC)
	got := startOfDayIn(t1, syd)
	want := time.Date(2026, 6, 15, 0, 0, 0, 0, syd)
	if !got.Equal(want) {
		t.Errorf("startOfDayIn: got %s want %s", got, want)
	}
	// Sanity: this is genuinely a different instant from UTC midnight.
	utcMidnight := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	if got.Equal(utcMidnight) {
		t.Error("Sydney midnight should NOT equal UTC midnight")
	}
}

func TestMondayOfIn_AcrossDateBoundary(t *testing.T) {
	syd, err := time.LoadLocation("Australia/Sydney")
	if err != nil {
		t.Skip("no tzdata")
	}
	// Sun 2026-06-14 23:30 UTC == Mon 2026-06-15 09:30 Sydney. Asking for
	// "Monday of this week" should give Sydney's Monday (15th), not UTC's
	// Monday (which would still be the 8th — last week — from Sunday UTC).
	t1 := time.Date(2026, 6, 14, 23, 30, 0, 0, time.UTC)
	got := mondayOfIn(t1, syd)
	want := time.Date(2026, 6, 15, 0, 0, 0, 0, syd)
	if !got.Equal(want) {
		t.Errorf("mondayOfIn: got %s want %s", got, want)
	}
}

func TestParseStudioDate_InNonUtc(t *testing.T) {
	syd, err := time.LoadLocation("Australia/Sydney")
	if err != nil {
		t.Skip("no tzdata")
	}
	got, err := parseStudioDate("2026-06-15", syd)
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 6, 15, 0, 0, 0, 0, syd)
	if !got.Equal(want) {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestInvalidateStudioLocation_DropsCache(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Prime the cache with the fixture default (London).
	first := s.StudioLocation(ctx, f.studioID)
	if first.String() != "Europe/London" {
		t.Fatalf("primer: got %s", first)
	}
	// Change the DB. Without invalidation the cache still returns London.
	if _, err := s.db.ExecContext(ctx,
		`UPDATE studios SET timezone = 'America/New_York' WHERE id = ?`, f.studioID,
	); err != nil {
		t.Fatal(err)
	}
	if s.StudioLocation(ctx, f.studioID).String() != "Europe/London" {
		t.Error("precondition: cache should still hold London before invalidate")
	}
	InvalidateStudioLocation(f.studioID)
	if got := s.StudioLocation(ctx, f.studioID).String(); got != "America/New_York" {
		t.Errorf("after invalidate: got %s want America/New_York", got)
	}
}

func TestUpdateStudioConfig_TimezoneInvalidatesCache(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Prime the cache.
	_ = s.StudioLocation(ctx, f.studioID)

	tz := "Australia/Sydney"
	if err := s.UpdateStudioConfig(ctx, f.studioID, "actor-test", StudioConfigPatch{Timezone: &tz}); err != nil {
		t.Fatalf("update: %v", err)
	}
	if got := s.StudioLocation(ctx, f.studioID).String(); got != tz {
		t.Errorf("after UpdateStudioConfig: got %s want %s", got, tz)
	}
}

func TestUpdateStudioConfig_RejectsBadTimezone(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()
	bad := "Not/A_Real_Zone"
	err := s.UpdateStudioConfig(ctx, f.studioID, "actor-test", StudioConfigPatch{Timezone: &bad})
	if err == nil {
		t.Error("expected error for unparseable timezone")
	}
}
