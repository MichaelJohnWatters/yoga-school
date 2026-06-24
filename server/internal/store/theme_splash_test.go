package store

import (
	"context"
	"testing"
)

// legibleClay is a palette that passes the contrast gate, so these tests can
// focus on splash behaviour without tripping validateThemeContrast.
var legibleClay = ThemeTokens{
	Primary: "#B05C3B", Accent: "#C8973F",
	Background: "#FAF5EF", Surface: "#FFFFFF",
	Text: "#2D2218", TextMuted: "#8F8174",
}

func splashOf(t *testing.T, s *Store, studioID, themeID string) *string {
	t.Helper()
	rows, err := s.ListThemes(context.Background(), studioID)
	if err != nil {
		t.Fatalf("ListThemes: %v", err)
	}
	for _, r := range rows {
		if r.ID == themeID {
			return r.SplashImageURL
		}
	}
	t.Fatalf("theme %s not found in ListThemes", themeID)
	return nil
}

func TestUpdateTheme_SetsAndClearsSplashImage(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, err := s.CreateTheme(ctx, f.studioID, "actor-test", ThemeInput{
		Name: "Clay", Mode: "light", Tokens: legibleClay,
	})
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Fresh theme has no splash.
	if got := splashOf(t, s, f.studioID, id); got != nil {
		t.Fatalf("new theme should have no splash, got %q", *got)
	}

	// Set a bundled asset reference.
	const asset = "asset:assets/splash/studio_class.webp"
	v := asset
	if err := s.UpdateTheme(ctx, f.studioID, "actor-test", id, ThemePatch{SplashImageURL: &v}); err != nil {
		t.Fatalf("set splash: %v", err)
	}
	if got := splashOf(t, s, f.studioID, id); got == nil || *got != asset {
		t.Fatalf("splash after set: got %v want %q", got, asset)
	}

	// Clearing with an empty string returns it to nil (stored NULL).
	empty := ""
	if err := s.UpdateTheme(ctx, f.studioID, "actor-test", id, ThemePatch{SplashImageURL: &empty}); err != nil {
		t.Fatalf("clear splash: %v", err)
	}
	if got := splashOf(t, s, f.studioID, id); got != nil {
		t.Fatalf("splash after clear: want nil, got %q", *got)
	}
}

func TestUpdateTheme_RejectsBadSplashURL(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	id, err := s.CreateTheme(ctx, f.studioID, "actor-test", ThemeInput{
		Name: "Clay", Mode: "light", Tokens: legibleClay,
	})
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	bad := "ftp://example.com/pic.png"
	err = s.UpdateTheme(ctx, f.studioID, "actor-test", id, ThemePatch{SplashImageURL: &bad})
	if err == nil {
		t.Fatal("expected rejection of non-http/asset splash url, got nil")
	}
	// The bad value must not have been persisted.
	if got := splashOf(t, s, f.studioID, id); got != nil {
		t.Fatalf("rejected splash should not persist, got %q", *got)
	}
}
