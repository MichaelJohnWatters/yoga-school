// Studio preset palettes + ThemeData builder.
// Preset values mirror YOGA_PRESETS in design_handoff_yoga_school/yoga-theme.jsx.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'yoga_tokens.dart';

class YogaPreset {
  final String key;
  final String name;
  final YogaSemanticTokens light;
  final YogaSemanticTokens dark;
  const YogaPreset(this.key, this.name, this.light, this.dark);
}

const _hexFF = 0xFF000000;
Color _c(int rgb) => Color(_hexFF | rgb);

final yogaPresets = <String, YogaPreset>{
  'clay': YogaPreset(
    'clay',
    'Warm Clay',
    YogaSemanticTokens(
      primary: _c(0xB05C3B),
      accent: _c(0xC8973F),
      background: _c(0xFAF5EF),
      surface: _c(0xFFFFFF),
      text: _c(0x2D2218),
      textMuted: _c(0x8F8174),
    ),
    YogaSemanticTokens(
      primary: _c(0xD08054),
      accent: _c(0xD9AD5F),
      background: _c(0x201A15),
      surface: _c(0x2B231C),
      text: _c(0xF3EDE6),
      textMuted: _c(0xA79784),
    ),
  ),
  'slate': YogaPreset(
    'slate',
    'Cool Slate',
    YogaSemanticTokens(
      primary: _c(0x3A5E7E),
      accent: _c(0x64998F),
      background: _c(0xF4F6F8),
      surface: _c(0xFFFFFF),
      text: _c(0x1E2730),
      textMuted: _c(0x75828E),
    ),
    YogaSemanticTokens(
      primary: _c(0x7BA6C9),
      accent: _c(0x84BCB2),
      background: _c(0x14191F),
      surface: _c(0x1E262E),
      text: _c(0xE9EEF2),
      textMuted: _c(0x93A1AD),
    ),
  ),
  'sage': YogaPreset(
    'sage',
    'Earthy Sage',
    YogaSemanticTokens(
      primary: _c(0x5E7153),
      accent: _c(0xA9744A),
      background: _c(0xF6F5EE),
      surface: _c(0xFFFFFF),
      text: _c(0x272B20),
      textMuted: _c(0x82876F),
    ),
    YogaSemanticTokens(
      primary: _c(0x93AB7F),
      accent: _c(0xC99A6B),
      background: _c(0x191C14),
      surface: _c(0x232719),
      text: _c(0xEEF0E6),
      textMuted: _c(0x9CA28E),
    ),
  ),
  'citrus': YogaPreset(
    'citrus',
    'Bright Citrus',
    YogaSemanticTokens(
      primary: _c(0xD94F24),
      accent: _c(0x17A398),
      background: _c(0xFFFBF5),
      surface: _c(0xFFFFFF),
      text: _c(0x25211E),
      textMuted: _c(0x8B8480),
    ),
    YogaSemanticTokens(
      primary: _c(0xFF7A4D),
      accent: _c(0x2FC4B2),
      background: _c(0x1C1715),
      surface: _c(0x281F1B),
      text: _c(0xF7F1EC),
      textMuted: _c(0xA99F99),
    ),
  ),
};

/// Build a [ThemeData] from the derived tokens.
/// Typography follows the fixed scale in README §Design Tokens.
ThemeData buildYogaTheme(YogaTokens y) {
  final base = y.isDark ? ThemeData.dark() : ThemeData.light();
  final baseText = GoogleFonts.hankenGroteskTextTheme(base.textTheme);

  TextStyle s(double size, FontWeight w, {Color? color, double? letter}) =>
      GoogleFonts.hankenGrotesk(
        fontSize: size,
        fontWeight: w,
        color: color ?? y.text,
        letterSpacing: letter,
        height: 1.2,
      );

  return base.copyWith(
    scaffoldBackgroundColor: y.background,
    canvasColor: y.background,
    colorScheme: ColorScheme(
      brightness: y.isDark ? Brightness.dark : Brightness.light,
      primary: y.primary,
      onPrimary: y.onPrimary,
      secondary: y.accent,
      onSecondary: y.onAccent,
      surface: y.surface,
      onSurface: y.text,
      error: const Color(0xFFA33B2E),
      onError: const Color(0xFFFFFFFF),
    ),
    textTheme: baseText.copyWith(
      displayLarge: s(28, FontWeight.w800, letter: -0.5),  // greeting / page title
      titleLarge: s(19, FontWeight.w800),                  // sheet title
      titleMedium: s(17, FontWeight.w700, letter: -0.2),   // section head
      titleSmall: s(15, FontWeight.w700),                  // card title
      bodyLarge: s(14, FontWeight.w500),
      bodyMedium: s(13, FontWeight.w500, color: y.muted),
      labelLarge: s(12.5, FontWeight.w600, color: y.muted),
      labelMedium: s(11.5, FontWeight.w600),
    ),
    extensions: [y],
  );
}
