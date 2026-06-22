package store

import (
	"context"
	"math"
	"testing"
)

func TestContrastRatio_KnownPairs(t *testing.T) {
	cases := []struct {
		fg, bg string
		want   float64
	}{
		// WCAG canonical values.
		{"#000000", "#FFFFFF", 21.0},  // black on white — max possible
		{"#FFFFFF", "#FFFFFF", 1.0},   // identical — minimum
		{"#777777", "#FFFFFF", 4.48},  // grey ~ borderline AA fail
		{"#595959", "#FFFFFF", 7.0},   // AAA threshold (large text 7:1)
	}
	for _, c := range cases {
		got, err := contrastRatio(c.fg, c.bg)
		if err != nil {
			t.Fatalf("contrastRatio(%s,%s): %v", c.fg, c.bg, err)
		}
		if math.Abs(got-c.want) > 0.05 {
			t.Errorf("%s on %s: got %.2f want ~%.2f", c.fg, c.bg, got, c.want)
		}
	}
}

func TestValidateThemeContrast_AcceptsDefaultClayPalette(t *testing.T) {
	// The Warm Clay preset is shipped enabled — it must pass our gate or
	// every new dev would hit "contrast_too_low" on first boot.
	clay := ThemeTokens{
		Primary:    "#B05C3B",
		Accent:     "#C8973F",
		Background: "#FAF5EF",
		Surface:    "#FFFFFF",
		Text:       "#2D2218",
		TextMuted:  "#8F8174",
	}
	if err := validateThemeContrast(clay); err != nil {
		t.Errorf("Warm Clay should pass: %v", err)
	}
}

func TestValidateThemeContrast_RejectsInvisibleText(t *testing.T) {
	bad := ThemeTokens{
		Primary:    "#B05C3B",
		Accent:     "#C8973F",
		Background: "#FFFFFF",
		Surface:    "#FFFFFF",
		Text:       "#EEEEEE", // near-white text on white surface
		TextMuted:  "#888888",
	}
	err := validateThemeContrast(bad)
	if err == nil {
		t.Fatal("expected contrast error, got nil")
	}
	if !IsContrastError(err) {
		t.Errorf("not a ContrastError: %T %v", err, err)
	}
}

func TestValidateThemeContrast_FlagsExactPairThatFails(t *testing.T) {
	// muted text is intentionally subdued (3:1), but going BELOW 3:1
	// against the surface should still trip the gate and call out the
	// muted/surface pair specifically.
	bad := ThemeTokens{
		Primary: "#B05C3B", Accent: "#C8973F",
		Background: "#FAF5EF", Surface: "#FFFFFF",
		Text:      "#2D2218",
		TextMuted: "#E0DDD8", // washed-out muted on white → ~1.2:1
	}
	err := validateThemeContrast(bad)
	if !IsContrastError(err) {
		t.Fatalf("expected ContrastError, got %v", err)
	}
	if !containsCI(err.Error(), "muted") {
		t.Errorf("expected message about muted pair, got %q", err.Error())
	}
}

func TestCreateTheme_RefusesIllegiblePalette(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	_, err := s.CreateTheme(ctx, f.studioID, "actor-test", ThemeInput{
		Name: "Spooky", Mode: "light",
		Tokens: ThemeTokens{
			Primary: "#FFFFFF", Accent: "#FFFFFF",
			Background: "#FFFFFF", Surface: "#FFFFFF",
			Text: "#EEEEEE", TextMuted: "#F0F0F0",
		},
	})
	if !IsContrastError(err) {
		t.Errorf("expected ContrastError, got %v", err)
	}
}

func TestUpdateTheme_RefusesIllegiblePalette(t *testing.T) {
	s := newTestStore(t)
	f := newFixture(t, s)
	ctx := context.Background()

	// Start from a legible theme (the fixture's seeded theme has minimal
	// tokens; install Warm Clay as a fresh row so we have an id to patch).
	clay := ThemeTokens{
		Primary: "#B05C3B", Accent: "#C8973F",
		Background: "#FAF5EF", Surface: "#FFFFFF",
		Text: "#2D2218", TextMuted: "#8F8174",
	}
	id, err := s.CreateTheme(ctx, f.studioID, "actor-test", ThemeInput{
		Name: "Clay", Mode: "light", Tokens: clay,
	})
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	// Now mutate to illegible.
	bad := clay
	bad.Text = "#FFFEFD"
	bad.Surface = "#FFFFFF"
	err = s.UpdateTheme(ctx, f.studioID, "actor-test", id, ThemePatch{Tokens: &bad})
	if !IsContrastError(err) {
		t.Errorf("expected ContrastError, got %v", err)
	}
}

func containsCI(haystack, needle string) bool {
	if needle == "" {
		return true
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		match := true
		for j := 0; j < len(needle); j++ {
			a := haystack[i+j]
			b := needle[j]
			if a >= 'A' && a <= 'Z' {
				a += 32
			}
			if b >= 'A' && b <= 'Z' {
				b += 32
			}
			if a != b {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
