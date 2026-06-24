// Mobile primitives ported from design_handoff_yoga_school/yoga-ui.jsx.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/notifications_screen.dart';
import '../theme/yoga_tokens.dart';

/// Resolves a studio-configured image source to an [ImageProvider]. A value
/// beginning with `asset:` refers to a bundled built-in image (e.g. the
/// splash photos in `assets/splash/`); anything else is treated as a network
/// URL. Keeps the splash render sites from each re-implementing the split.
///
/// Network URLs use [CachedNetworkImageProvider], which persists to disk via
/// flutter_cache_manager — so the splash/studio image loads instantly from
/// disk on later launches instead of re-downloading (a plain NetworkImage
/// only caches in memory, which is cleared on restart).
ImageProvider studioImageProvider(String src) {
  const assetScheme = 'asset:';
  if (src.startsWith(assetScheme)) {
    return AssetImage(src.substring(assetScheme.length));
  }
  return CachedNetworkImageProvider(src);
}

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

/// Shared top utility row for the student-facing shells (home, book,
/// profile etc.). Keeps the brand row visually consistent: studio logo
/// + name on the left, notifications bell + user avatar on the right.
/// Each consuming screen wraps it in its own padding so it can sit
/// inside a ListView or other scrollable.
/// Fires [onMount] once, on the frame after this widget is first
/// inserted into the tree. Used to schedule a silent provider refresh
/// when the user navigates to a screen — paired with non-autoDispose
/// providers, the cache renders immediately and the in-flight refetch
/// updates the UI quietly when it lands (Riverpod's default
/// skipLoadingOnRefresh keeps the data callback firing with the
/// previous value while loading).
///
/// Plain `StatefulWidget` rather than ConsumerStatefulWidget — the
/// callback is just a void function so the caller can capture `ref`
/// from its enclosing scope.
class RefreshOnMount extends StatefulWidget {
  final VoidCallback onMount;
  final Widget child;
  const RefreshOnMount({super.key, required this.onMount, required this.child});

  @override
  State<RefreshOnMount> createState() => _RefreshOnMountState();
}

class _RefreshOnMountState extends State<RefreshOnMount> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onMount();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class YStudioTopBar extends ConsumerWidget {
  final String studioName;
  final String userFullName;
  final String? userPhotoUrl;

  /// Tapping the avatar fires this — RootShell wires it to "switch to
  /// the Profile tab". Null on the Profile tab itself so the avatar is
  /// just a visual identity marker there (no self-navigation).
  final VoidCallback? onAvatarTap;
  const YStudioTopBar({
    super.key,
    required this.studioName,
    required this.userFullName,
    this.userPhotoUrl,
    this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    // Live unread count drives both the dot and the screen-reader label,
    // so the bell badge tracks the actual feed instead of the old
    // hardcoded `true`.
    final unread = ref.watch(unreadNotificationCountProvider);
    // Fixed children (logo + bell + avatar + spacing) take ~130px on their
    // own. Below that the Row would overflow no matter how aggressively the
    // studio-name Expanded shrinks, so drop the label then the bell as the
    // surrounding container narrows. The avatar is the identity anchor and
    // stays visible at every width.
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final showStudioName = w >= 200;
        final showBell = w >= 150;
        return Row(
          children: [
            const YLogo(),
            const SizedBox(width: 10),
            if (showStudioName)
              Expanded(
                child: Text(
                  studioName.toUpperCase(),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                    color: y.muted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            if (showBell) ...[
              _BellButton(
                unread: unread > 0,
                count: unread,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NotificationsScreen(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAvatarTap,
              child: YAvatar(
                name: userFullName,
                size: 38,
                tone: YAvatarTone.accent,
                photoUrl: userPhotoUrl,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BellButton extends StatelessWidget {
  final bool unread;
  final int count;
  final VoidCallback onTap;
  const _BellButton({
    required this.unread,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Material+InkWell so the bell gets the same hover/splash treatment
    // as other tappable surfaces. Tooltip exposes the unread count for
    // screen readers and as a hover hint on desktop.
    return Tooltip(
      message: unread
          ? (count == 1
                ? '1 unread notification'
                : '$count unread notifications')
          : 'Notifications',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: y.borderStrong),
                ),
                child: Icon(
                  Icons.notifications_none_rounded,
                  size: 20,
                  color: y.text,
                ),
              ),
              if (unread)
                Positioned(
                  top: 7,
                  right: 8,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: y.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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
    late final Color hover;
    late final Color splash;
    Border? border;
    switch (variant) {
      case YButtonVariant.primary:
        bg = y.primary;
        fg = y.onPrimary;
        // White overlay reads as a subtle lighten over the brand colour;
        // pure black would muddy the warm primary.
        hover = Colors.white.withValues(alpha: 0.10);
        splash = Colors.white.withValues(alpha: 0.18);
        break;
      case YButtonVariant.soft:
        bg = y.primarySoft;
        fg = y.primaryStrong;
        hover = y.primary.withValues(alpha: 0.10);
        splash = y.primary.withValues(alpha: 0.18);
        break;
      case YButtonVariant.outline:
        bg = Colors.transparent;
        fg = y.text;
        border = Border.all(color: y.borderStrong);
        hover = y.primary.withValues(alpha: 0.06);
        splash = y.primary.withValues(alpha: 0.12);
        break;
    }
    final radius = BorderRadius.circular(y.radiusChip);
    final disabled = onTap == null;
    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 14 : 20,
        vertical: small ? 7 : 13,
      ),
      decoration: border == null
          ? null
          : BoxDecoration(borderRadius: radius, border: border),
      constraints: const BoxConstraints(minHeight: 32),
      // Center the label. With a bounded width (full-width buttons in a
      // stretched Column / Expanded) the Container expands to fill and the
      // text sits centered; under unbounded width (an inline button in a
      // Row) it shrink-wraps to the label as before. Without this the
      // Container hugged the text at the Material's left edge, so a
      // stretched button looked left-aligned despite textAlign.center.
      alignment: Alignment.center,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: disabled ? fg.withValues(alpha: 0.55) : fg,
          fontWeight: FontWeight.w700,
          fontSize: small ? 13 : 15,
          height: 1.0,
        ),
      ),
    );
    // Material owns the fill + borderRadius so the InkWell's hover/splash
    // overlay paints between the fill and the label. Wrapping the inner
    // Container in InkWell alone (the previous shape) put the fill on top
    // of the overlay layer, so hover never showed on web/desktop.
    return Material(
      color: bg,
      borderRadius: radius,
      type: MaterialType.button,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        hoverColor: hover,
        splashColor: splash,
        highlightColor: splash,
        // Wider cursor target on web: the system pointer flips to a hand
        // automatically when onTap is non-null, but stays default when null
        // — i.e. disabled — which is the behaviour we want.
        child: content,
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

/// Paints a rounded-rect dashed border around a child. The design uses this
/// for the Home milestones strip and the Series roster "upcoming" cells.
class YDashedBorder extends StatelessWidget {
  final Color color;
  final double radius;
  final double dashLength;
  final double gapLength;
  final double strokeWidth;
  final Widget child;
  const YDashedBorder({
    super.key,
    required this.color,
    required this.radius,
    this.dashLength = 4,
    this.gapLength = 3,
    this.strokeWidth = 1,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRectPainter(
        color: color,
        radius: radius,
        dashLength: dashLength,
        gapLength: gapLength,
        strokeWidth: strokeWidth,
      ),
      child: child,
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double dashLength;
  final double gapLength;
  final double strokeWidth;
  _DashedRectPainter({
    required this.color,
    required this.radius,
    required this.dashLength,
    required this.gapLength,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(radius),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final path = Path()..addRRect(rrect);
    final dashed = Path();
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dashLength).clamp(0.0, metric.length);
        dashed.addPath(metric.extractPath(distance, next), Offset.zero);
        distance = next + gapLength;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.dashLength != dashLength ||
      old.gapLength != gapLength ||
      old.strokeWidth != strokeWidth;
}
