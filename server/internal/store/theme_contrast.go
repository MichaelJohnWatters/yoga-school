package store

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
)

// ContrastError is returned by validateThemeContrast when a token palette
// would ship illegible text. The Pair / Ratio fields let the API and the
// Flutter theme editor highlight the exact offending colour pair inline.
type ContrastError struct {
	Pair   string  // e.g. "text on surface"
	Ratio  float64 // computed ratio (e.g. 1.83)
	Wanted float64 // minimum acceptable (4.5 for normal text, 3.0 for muted)
}

func (e *ContrastError) Error() string {
	return fmt.Sprintf("contrast too low: %s is %.2f:1, need at least %.1f:1",
		e.Pair, e.Ratio, e.Wanted)
}

// IsContrastError lets API handlers fan out 400 + a typed code without
// reaching for errors.As on every call site.
func IsContrastError(err error) bool {
	var ce *ContrastError
	return errors.As(err, &ce)
}

// validateThemeContrast enforces the spec's contrast guardrail: the
// configured text and surface tokens must pass WCAG AA (4.5:1) for normal
// text, and the muted token must hit at least 3:1 — because muted text is
// allowed to be lower-contrast, but not invisible.
//
// We check text against background + surface only. Text on primary buttons
// uses the YogaTokens-derived `onPrimary` (white-or-text picked by
// luminance), not the raw `text` token — checking it here would falsely
// reject palettes where the primary itself is mid-tone (which is half of
// the shipped presets, including Warm Clay).
func validateThemeContrast(t ThemeTokens) error {
	type pair struct {
		fg, bg string
		label  string
		min    float64
	}
	checks := []pair{
		{t.Text, t.Background, "text on background", 4.5},
		{t.Text, t.Surface, "text on surface", 4.5},
		// text_muted is intentionally subdued — 3:1 is the WCAG AA bar for
		// "large text", which matches the design intent (captions/labels
		// over surface).
		{t.TextMuted, t.Surface, "muted text on surface", 3.0},
	}
	for _, c := range checks {
		ratio, err := contrastRatio(c.fg, c.bg)
		if err != nil {
			return err
		}
		if ratio+1e-6 < c.min {
			return &ContrastError{Pair: c.label, Ratio: ratio, Wanted: c.min}
		}
	}
	return nil
}

// contrastRatio implements the WCAG 2.0 relative-luminance formula. Inputs
// are 6-digit hex strings ("#RRGGBB" or "RRGGBB"). The "+0.05" gutters keep
// the ratio finite for pure black; ratios run from 1:1 (identical) up to
// 21:1 (black on white).
func contrastRatio(a, b string) (float64, error) {
	la, err := relativeLuminance(a)
	if err != nil {
		return 0, fmt.Errorf("token %q: %w", a, err)
	}
	lb, err := relativeLuminance(b)
	if err != nil {
		return 0, fmt.Errorf("token %q: %w", b, err)
	}
	if lb > la {
		la, lb = lb, la
	}
	return (la + 0.05) / (lb + 0.05), nil
}

func relativeLuminance(hex string) (float64, error) {
	r, g, b, err := parseHex(hex)
	if err != nil {
		return 0, err
	}
	rl := linearize(float64(r) / 255.0)
	gl := linearize(float64(g) / 255.0)
	bl := linearize(float64(b) / 255.0)
	return 0.2126*rl + 0.7152*gl + 0.0722*bl, nil
}

func linearize(c float64) float64 {
	if c <= 0.03928 {
		return c / 12.92
	}
	return math.Pow((c+0.055)/1.055, 2.4)
}

func parseHex(s string) (r, g, b int, err error) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "#")
	if len(s) != 6 {
		return 0, 0, 0, fmt.Errorf("expected #RRGGBB, got %q", s)
	}
	rv, err := strconv.ParseUint(s[0:2], 16, 8)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("bad red: %w", err)
	}
	gv, err := strconv.ParseUint(s[2:4], 16, 8)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("bad green: %w", err)
	}
	bv, err := strconv.ParseUint(s[4:6], 16, 8)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("bad blue: %w", err)
	}
	return int(rv), int(gv), int(bv), nil
}
