// Desktop shell for the student app — 64 px top bar + centered content column.
// Mirrors yoga-student-web.jsx shell.

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'desktop_book.dart';
import 'desktop_buy.dart';
import 'desktop_home.dart';
import '../more_screen.dart';
import '../profile_screen.dart';
import 'responsive.dart';

enum DesktopSection { home, book, buy, profile, more }

class DesktopShell extends StatefulWidget {
  final Me me;
  final StudioConfig studio;
  const DesktopShell({super.key, required this.me, required this.studio});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  DesktopSection _section = DesktopSection.home;

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
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
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => onSelect(DesktopSection.profile),
                  child: YAvatar(
                    name: me.fullName,
                    size: 36,
                    tone: YAvatarTone.accent,
                  ),
                ),
                const SizedBox(width: 10),
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

class _BellButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: y.borderStrong),
          ),
          child: Icon(Icons.notifications_none_rounded, size: 18, color: y.text),
        ),
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
  const _Body({
    required this.section,
    required this.me,
    required this.studio,
  });

  @override
  Widget build(BuildContext context) {
    return switch (section) {
      DesktopSection.home => DesktopHome(me: me, studio: studio),
      DesktopSection.book => const DesktopBook(),
      DesktopSection.buy => const DesktopBuy(),
      DesktopSection.profile => _CenteredMaxWidth(
          maxWidth: 720,
          child: ProfileScreen(me: me),
        ),
      DesktopSection.more => _CenteredMaxWidth(
          maxWidth: 560,
          child: const MoreScreen(),
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
