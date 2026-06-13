package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestCreatePromotion_RoundTrips(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	now := time.Now().UTC()
	starts := now.Add(-1 * time.Hour).Format(time.RFC3339)
	ends := now.Add(48 * time.Hour).Format(time.RFC3339)
	id, err := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{
		Title: "Summer Pass", Body: "20% off", ImageURL: "https://x/y.png",
		StartsAt: &starts, EndsAt: &ends,
	})
	if err != nil {
		t.Fatalf("CreatePromotion: %v", err)
	}

	rows, _ := s.ListAdminPromotions(ctx, f.studioID)
	if len(rows) != 1 || rows[0].ID != id {
		t.Fatalf("admin list: %+v", rows)
	}
	got := rows[0]
	if got.Title != "Summer Pass" || got.Body != "20% off" || got.ImageURL != "https://x/y.png" {
		t.Errorf("stored row: %+v", got)
	}
	if got.StartsAt == nil || got.EndsAt == nil {
		t.Errorf("dates lost: starts=%v ends=%v", got.StartsAt, got.EndsAt)
	}
	if got.IsArchived {
		t.Error("freshly created promo marked archived")
	}
}

func TestCreatePromotion_RejectsEmptyTitle(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{Title: ""}); err == nil {
		t.Error("expected error for blank title")
	}
}

func TestCreatePromotion_RejectsReversedWindow(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	now := time.Now().UTC()
	starts := now.Add(48 * time.Hour).Format(time.RFC3339)
	ends := now.Add(-1 * time.Hour).Format(time.RFC3339)
	_, err := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{
		Title: "Bad window", StartsAt: &starts, EndsAt: &ends,
	})
	if err == nil {
		t.Error("expected error for ends < starts")
	}
}

func TestListActivePromotions_FiltersByWindow(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	now := time.Now().UTC()

	// Active: starts in past, ends in future.
	startedYesterday := now.Add(-24 * time.Hour).Format(time.RFC3339)
	endsTomorrow := now.Add(24 * time.Hour).Format(time.RFC3339)
	active, _ := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{
		Title: "Now", StartsAt: &startedYesterday, EndsAt: &endsTomorrow,
	})

	// Future: starts tomorrow.
	startsTomorrow := now.Add(24 * time.Hour).Format(time.RFC3339)
	endsNextWeek := now.Add(7 * 24 * time.Hour).Format(time.RFC3339)
	future, _ := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{
		Title: "Soon", StartsAt: &startsTomorrow, EndsAt: &endsNextWeek,
	})

	// Past: ended yesterday.
	startedLastWeek := now.Add(-7 * 24 * time.Hour).Format(time.RFC3339)
	endedYesterday := now.Add(-24 * time.Hour).Format(time.RFC3339)
	past, _ := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{
		Title: "Gone", StartsAt: &startedLastWeek, EndsAt: &endedYesterday,
	})

	// Open-ended (no bounds) — should always be active.
	openEnded, _ := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{
		Title: "Forever",
	})

	rows, err := s.ListActivePromotions(ctx, f.studioID)
	if err != nil {
		t.Fatalf("ListActivePromotions: %v", err)
	}
	ids := promotionIds(rows)
	if !contains(ids, active) {
		t.Errorf("active promotion missing: %v", ids)
	}
	if !contains(ids, openEnded) {
		t.Errorf("open-ended promotion missing: %v", ids)
	}
	if contains(ids, future) {
		t.Errorf("future promotion leaked: %v", ids)
	}
	if contains(ids, past) {
		t.Errorf("past promotion leaked: %v", ids)
	}
}

func TestListActivePromotions_HidesArchived(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{Title: "Test"})
	if err := s.ArchivePromotion(ctx, f.studioID, f.instructorID, id); err != nil {
		t.Fatalf("Archive: %v", err)
	}

	rows, _ := s.ListActivePromotions(ctx, f.studioID)
	if contains(promotionIds(rows), id) {
		t.Errorf("archived promotion in active list: %v", rows)
	}

	// Still in admin list, flagged archived.
	adminRows, _ := s.ListAdminPromotions(ctx, f.studioID)
	var found *Promotion
	for i := range adminRows {
		if adminRows[i].ID == id {
			found = &adminRows[i]
		}
	}
	if found == nil {
		t.Fatal("archived promotion missing from admin list")
	}
	if !found.IsArchived {
		t.Errorf("admin row not flagged archived: %+v", *found)
	}
}

func TestUpdatePromotion_NotFoundCrossStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{Title: "Test"})
	err := s.UpdatePromotion(ctx, "other-studio", f.instructorID, id, PromotionInput{Title: "X"})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("cross-studio update: got %v want ErrNotFound", err)
	}
}

func TestArchivePromotion_IsIdempotentOnRowOnly(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, _ := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{Title: "Test"})
	if err := s.ArchivePromotion(ctx, f.studioID, f.instructorID, id); err != nil {
		t.Fatalf("archive 1: %v", err)
	}
	// Re-archiving still hits the row (no `WHERE is_archived = 0`), so it
	// returns nil rather than ErrNotFound. Documenting that contract.
	if err := s.ArchivePromotion(ctx, f.studioID, f.instructorID, id); err != nil {
		t.Errorf("re-archive: got %v want nil", err)
	}
}

func TestListActivePromotions_ScopedByStudio(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreatePromotion(ctx, f.studioID, f.instructorID, PromotionInput{Title: "Mine"}); err != nil {
		t.Fatalf("create: %v", err)
	}
	rows, _ := s.ListActivePromotions(ctx, "other-studio")
	if len(rows) != 0 {
		t.Errorf("cross-studio leak: %v", rows)
	}
}

func promotionIds(rows []Promotion) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.ID
	}
	return out
}
