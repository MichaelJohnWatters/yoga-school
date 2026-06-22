// Token system ported from design_handoff_yoga_school/yoga-theme.jsx.
// Studio sets six semantic tokens; everything else is derived here.

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// The six tokens a studio actually configures.
@immutable
class YogaSemanticTokens {
  final Color primary;
  final Color accent;
  final Color background;
  final Color surface;
  final Color text;
  final Color textMuted;

  const YogaSemanticTokens({
    required this.primary,
    required this.accent,
    required this.background,
    required this.surface,
    required this.text,
    required this.textMuted,
  });

  /// Tolerant of missing / non-string token keys — falls back to a
  /// transparent placeholder colour rather than throwing "Unexpected
  /// null value". A theme row with sparse tokens (e.g. one inserted by
  /// a test fixture as `{"primary":"#000"}`) used to crash the whole
  /// settings screen by triggering this constructor on every build of
  /// the editor's contrast meter, which then cascaded into a layout
  /// failure → render loop → console spam.
  factory YogaSemanticTokens.fromHexMap(Map<String, dynamic> m) {
    String? read(String k) {
      final v = m[k];
      return v is String ? v : null;
    }
    return YogaSemanticTokens(
      primary: _hex(read('primary')),
      accent: _hex(read('accent')),
      background: _hex(read('background')),
      surface: _hex(read('surface')),
      text: _hex(read('text')),
      textMuted: _hex(read('textMuted')),
    );
  }
}

/// Full derived token sheet, attached to ThemeData via ThemeExtension.
/// Read via `Theme.of(context).extension<YogaTokens>()!` or `context.yoga`.
@immutable
class YogaTokens extends ThemeExtension<YogaTokens> {
  final Color primary;
  final Color onPrimary;
  final Color primarySoft;
  final Color primaryStrong;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color background;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color muted;
  final Color border;
  final Color borderStrong;
  final List<BoxShadow> shadow;
  final double radiusCard;
  final double radiusChip;
  final bool isDark;

  const YogaTokens({
    required this.primary,
    required this.onPrimary,
    required this.primarySoft,
    required this.primaryStrong,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.background,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.muted,
    required this.border,
    required this.borderStrong,
    required this.shadow,
    required this.radiusCard,
    required this.radiusChip,
    required this.isDark,
  });

  /// Derive the full token sheet from the six semantic tokens.
  /// Mirrors `yogaVars()` in yoga-theme.jsx — keep these in lockstep.
  factory YogaTokens.derive(
    YogaSemanticTokens t, {
    required bool dark,
    double radius = 16,
  }) {
    final onPrimary = _onColor(t.primary);
    final onAccent = _onColor(t.accent);
    final primarySoft = dark
        ? t.primary.withValues(alpha: 0.16)
        : _mix(t.primary, t.background, 0.88);
    final primaryStrong = dark
        ? _mix(t.primary, const Color(0xFFFFFFFF), 0.12)
        : _mix(t.primary, t.text, 0.18);
    final accentSoft = dark
        ? t.accent.withValues(alpha: 0.16)
        : _mix(t.accent, t.background, 0.86);
    final surface2 = dark
        ? _mix(t.surface, const Color(0xFFFFFFFF), 0.05)
        : _mix(t.surface, t.text, 0.035);
    final border = t.text.withValues(alpha: dark ? 0.14 : 0.10);
    final borderStrong = t.text.withValues(alpha: dark ? 0.24 : 0.18);
    final shadow = dark
        ? const [
            BoxShadow(
              color: Color(0x66000000),
              offset: Offset(0, 4),
              blurRadius: 16,
            ),
          ]
        : [
            BoxShadow(
              color: t.text.withValues(alpha: 0.06),
              offset: const Offset(0, 2),
              blurRadius: 10,
            ),
          ];
    return YogaTokens(
      primary: t.primary,
      onPrimary: onPrimary,
      primarySoft: primarySoft,
      primaryStrong: primaryStrong,
      accent: t.accent,
      onAccent: onAccent,
      accentSoft: accentSoft,
      background: t.background,
      surface: t.surface,
      surface2: surface2,
      text: t.text,
      muted: t.textMuted,
      border: border,
      borderStrong: borderStrong,
      shadow: shadow,
      radiusCard: radius,
      radiusChip: 999,
      isDark: dark,
    );
  }

  /// WCAG relative-luminance contrast ratio. Used by the theme editor to
  /// guard against unreadable studio palettes.
  static double contrastRatio(Color a, Color b) {
    final la = _relativeLuminance(a);
    final lb = _relativeLuminance(b);
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  @override
  YogaTokens copyWith({
    Color? primary,
    Color? onPrimary,
    Color? primarySoft,
    Color? primaryStrong,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? background,
    Color? surface,
    Color? surface2,
    Color? text,
    Color? muted,
    Color? border,
    Color? borderStrong,
    List<BoxShadow>? shadow,
    double? radiusCard,
    double? radiusChip,
    bool? isDark,
  }) =>
      YogaTokens(
        primary: primary ?? this.primary,
        onPrimary: onPrimary ?? this.onPrimary,
        primarySoft: primarySoft ?? this.primarySoft,
        primaryStrong: primaryStrong ?? this.primaryStrong,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        accentSoft: accentSoft ?? this.accentSoft,
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surface2: surface2 ?? this.surface2,
        text: text ?? this.text,
        muted: muted ?? this.muted,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        shadow: shadow ?? this.shadow,
        radiusCard: radiusCard ?? this.radiusCard,
        radiusChip: radiusChip ?? this.radiusChip,
        isDark: isDark ?? this.isDark,
      );

  @override
  YogaTokens lerp(ThemeExtension<YogaTokens>? other, double t) {
    if (other is! YogaTokens) return this;
    return YogaTokens(
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      primarySoft: Color.lerp(primarySoft, other.primarySoft, t)!,
      primaryStrong: Color.lerp(primaryStrong, other.primaryStrong, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      shadow: t < 0.5 ? shadow : other.shadow,
      radiusCard: lerpDouble(radiusCard, other.radiusCard, t)!,
      radiusChip: lerpDouble(radiusChip, other.radiusChip, t)!,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

/// Convenience for screen code: `context.yoga.primary`.
extension YogaContext on BuildContext {
  YogaTokens get yoga => Theme.of(this).extension<YogaTokens>()!;
}

// ---- color math -----------------------------------------------------------
// Mirrors yogaHexRgb / yogaLum / yogaMix / yogaOn in yoga-theme.jsx.

Color _hex(String? hex) {
  if (hex == null || hex.isEmpty) return const Color(0x00000000);
  var h = hex.replaceFirst('#', '');
  if (h.length == 6) h = 'FF$h';
  try {
    return Color(int.parse(h, radix: 16));
  } on FormatException {
    return const Color(0x00000000);
  }
}

double _relativeLuminance(Color c) {
  double channel(double f) =>
      f <= 0.03928 ? f / 12.92 : math.pow((f + 0.055) / 1.055, 2.4) as double;

  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

Color _mix(Color a, Color b, double t) {
  double lerp(double x, double y) => x + (y - x) * t;
  return Color.from(
    alpha: 1.0,
    red: lerp(a.r, b.r),
    green: lerp(a.g, b.g),
    blue: lerp(a.b, b.b),
  );
}

/// Pick black or white text for the given fill, per the contrast guardrail
/// in yoga-theme.jsx (luminance > 0.45 → dark text, else white).
Color _onColor(Color c) =>
    _relativeLuminance(c) > 0.45 ? const Color(0xFF1A1611) : const Color(0xFFFFFFFF);
