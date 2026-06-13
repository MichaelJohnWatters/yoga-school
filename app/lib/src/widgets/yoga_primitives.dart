// Mobile primitives ported from design_handoff_yoga_school/yoga-ui.jsx.

import 'package:flutter/material.dart';

import '../theme/yoga_tokens.dart';

/// Studio monogram tile. Real logo replaces "52" later.
///
/// The `onImage` variant flips the tile to white with the primary token as
/// the monogram color — used when the logo sits over a studio splash image
/// or other dark backdrop (per the design's note).
class YLogo extends StatelessWidget {
  final double size;
  final bool onImage;
  const YLogo({super.key, this.size = 34, this.onImage = false});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final bg = onImage ? Colors.white : y.primary;
    final fg = onImage ? y.primary : y.onPrimary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: onImage
            ? const [
                BoxShadow(
                  color: Color(0x33000000),
                  offset: Offset(0, 4),
                  blurRadius: 14,
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        '52',
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.44,
          letterSpacing: -0.5,
          height: 1.0,
        ),
      ),
    );
  }
}

enum YAvatarTone { primary, accent }

class YAvatar extends StatelessWidget {
  final String name;
  final double size;
  final YAvatarTone tone;
  final String? photoUrl;
  const YAvatar({
    super.key,
    required this.name,
    this.size = 32,
    this.tone = YAvatarTone.primary,
    this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isAccent = tone == YAvatarTone.accent;
    final bg = isAccent ? y.accentSoft : y.primarySoft;
    final fg = isAccent ? y.accent : y.primaryStrong;
    final initials = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0])
        .take(2)
        .join();

    final initialsPainted = Container(
      color: bg,
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
          letterSpacing: 0.3,
          height: 1.0,
        ),
      ),
    );

    Widget content;
    if (photoUrl == null || photoUrl!.isEmpty) {
      content = initialsPainted;
    } else {
      content = Image.network(
        photoUrl!,
        fit: BoxFit.cover,
        width: size,
        height: size,
        loadingBuilder: (context, child, loading) {
          if (loading == null) return child;
          return initialsPainted;
        },
        errorBuilder: (_, __, ___) => initialsPainted,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: y.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}

enum YChipKind { booked, full, accent, neutral }

class YChip extends StatelessWidget {
  final YChipKind kind;
  final String label;
  final bool leadingCheck;
  const YChip({
    super.key,
    this.kind = YChipKind.neutral,
    required this.label,
    this.leadingCheck = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    late final Color bg;
    late final Color fg;
    Border? border;
    switch (kind) {
      case YChipKind.booked:
        bg = y.primarySoft;
        fg = y.primaryStrong;
        break;
      case YChipKind.full:
        bg = Colors.transparent;
        fg = y.muted;
        border = Border.all(color: y.borderStrong);
        break;
      case YChipKind.accent:
        bg = y.accentSoft;
        fg = y.accent;
        break;
      case YChipKind.neutral:
        bg = y.surface2;
        fg = y.muted;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(y.radiusChip),
        border: border,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leadingCheck) ...[
            Icon(Icons.check, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

enum YButtonVariant { primary, soft, outline }

class YButton extends StatelessWidget {
  final String label;
  final YButtonVariant variant;
  final bool small;
  final VoidCallback? onTap;
  const YButton({
    super.key,
    required this.label,
    this.variant = YButtonVariant.primary,
    this.small = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    late final Color bg;
    late final Color fg;
    Border? border;
    switch (variant) {
      case YButtonVariant.primary:
        bg = y.primary;
        fg = y.onPrimary;
        break;
      case YButtonVariant.soft:
        bg = y.primarySoft;
        fg = y.primaryStrong;
        break;
      case YButtonVariant.outline:
        bg = Colors.transparent;
        fg = y.text;
        border = Border.all(color: y.borderStrong);
        break;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(y.radiusChip),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: small ? 14 : 20,
          vertical: small ? 7 : 13,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(y.radiusChip),
          border: border,
        ),
        // Min 44 px touch target per spec.
        constraints: const BoxConstraints(minHeight: 32),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
            fontSize: small ? 13 : 15,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

class YSectionHead extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const YSectionHead({
    super.key,
    required this.title,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                height: 1.2,
              ),
            ),
          ),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(
                action!,
                style: TextStyle(
                  color: y.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 52×56 date tile shown next to the hero booking card on Home.
class YDateTile extends StatelessWidget {
  final String dow; // e.g. "FRI"
  final String day; // e.g. "12"
  const YDateTile({super.key, required this.dow, required this.day});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      width: 52,
      height: 56,
      decoration: BoxDecoration(
        color: y.primarySoft,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            dow,
            style: TextStyle(
              color: y.primaryStrong,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            day,
            style: TextStyle(
              color: y.primaryStrong,
              fontSize: 21,
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
        ],
      ),
    );
  }
}
