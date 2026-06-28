// Desktop shell for the student app — 64 px top bar + centered content column.
// Mirrors yoga-student-web.jsx shell.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'desktop_book.dart';
import 'desktop_buy.dart';
import 'desktop_home.dart';
import '../more_screen.dart';
import '../notifications_screen.dart';
import '../profile_screen.dart';
import '../../widgets/visible_tab.dart' show currentTabProvider;
import 'responsive.dart';

enum DesktopSection { home, book, buy, profile, more }

class DesktopShell extends ConsumerStatefulWidget {
  final Me me;
  final StudioConfig studio;
  const DesktopShell({super.key, required this.me, required this.studio});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  DesktopSection _section = DesktopSection.home;

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Honour external tab navigation (web checkout return → Book). The enum's
    // declaration order matches the mobile tab indices, so the provider's int
    // maps straight onto a section.
    ref.listen<int>(currentTabProvider, (_, next) {
      if (next >= 0 && next < DesktopSection.values.length) {
        final sec = DesktopSection.values[next];
        if (sec != _section && mounted) setState(() => _section = sec);
      }
    });
    return Scaffold(
      backgroundColor: y.background,
      body: Column(
        children: [
          _TopBar(
            studio: widget.studio,
            me: widget.me,
            active: _section,
            onSelect: (s) => setState(() => _section = s),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kDesktopContentMaxWidth,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
                  child: _Body(
                    section: _section,
                    me: widget.me,
                    studio: widget.studio,
                    onNavigate: (s) => setState(() => _section = s),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final StudioConfig studio;
  final Me me;
  final DesktopSection active;
  final ValueChanged<DesktopSection> onSelect;
  const _TopBar({
    required this.studio,
    required this.me,
    required this.active,
    required this.onSelect,
  });

  static const _navItems = [
    (DesktopSection.home, 'Home'),
    (DesktopSection.book, 'Book'),
    (DesktopSection.buy, 'Buy'),
  ];

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: y.surface,
        border: Border(bottom: BorderSide(color: y.border)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kDesktopContentMaxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(
              children: [
                const YLogo(size: 30),
                const SizedBox(width: 12),
                Text(
                  studio.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: y.text,
                  ),
                ),
                const SizedBox(width: 24),
                for (final item in _navItems) ...[
                  _NavPill(
                    label: item.$2,
                    active: item.$1 == active,
                    onTap: () => onSelect(item.$1),
                  ),
                  const SizedBox(width: 4),
                ],
                const Spacer(),
                _BellButton(),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => onSelect(DesktopSection.profile),
                  child: Row(
                    children: [
                      YAvatar(
                        name: me.fullName,
                        photoUrl: me.photoUrl,
                        size: 34,
                        tone: YAvatarTone.accent,
                      ),
                      const SizedBox(width: 9),
                      Text(
                        me.firstName,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: y.text,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _MoreButton(
                  active: active == DesktopSection.more,
                  onTap: () => onSelect(DesktopSection.more),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _NavPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(y.radiusChip),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? y.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(y.radiusChip),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: active ? y.primaryStrong : y.muted,
          ),
        ),
      ),
    );
  }
}

/// Desktop bell — opens a notifications popover anchored under the icon
/// instead of pushing the full-screen mobile view. Tapping outside (or the
/// bell again) dismisses it; "See all" in the panel opens the full screen.
class _BellButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_BellButton> createState() => _BellButtonState();
}

class _BellButtonState extends ConsumerState<_BellButton> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;

  void _toggle() {
    if (_entry != null) {
      _close();
      return;
    }
    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Full-screen dismiss barrier (a second bell tap also lands here).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 8),
            child: NotificationsPopoverPanel(onClose: _close),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final unread = ref.watch(unreadNotificationCountProvider);
    return CompositedTransformTarget(
      link: _link,
      child: InkWell(
        onTap: _toggle,
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: y.borderStrong),
              ),
              child: Icon(
                Icons.notifications_outlined,
                size: 18,
                color: y.text,
              ),
            ),
            if (unread > 0)
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
    );
  }
}

class _MoreButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  const _MoreButton({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: active ? y.primary : y.borderStrong),
        ),
        child: Icon(
          Icons.more_horiz,
          size: 20,
          color: active ? y.primary : y.text,
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final DesktopSection section;
  final Me me;
  final StudioConfig studio;
  final ValueChanged<DesktopSection> onNavigate;
  const _Body({
    required this.section,
    required this.me,
    required this.studio,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    return switch (section) {
      DesktopSection.home => DesktopHome(
        me: me,
        studio: studio,
        onNavigate: onNavigate,
      ),
      DesktopSection.book => const DesktopBook(),
      DesktopSection.buy => const DesktopBuy(),
      DesktopSection.profile => _CenteredMaxWidth(
        maxWidth: 720,
        child: ProfileScreen(me: me),
      ),
      DesktopSection.more => _CenteredMaxWidth(
        maxWidth: 560,
        child: MoreScreen(me: me, studio: studio),
      ),
    };
  }
}

class _CenteredMaxWidth extends StatelessWidget {
  final double maxWidth;
  final Widget child;
  const _CenteredMaxWidth({required this.maxWidth, required this.child});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
