// More tab landing — minimal settings list pattern (not designed in handoff).
// Provides reachable entry points for Notifications, Check-in, and Sign out.
// Future destinations (account / preferences / about / help) plug in here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../auth/auth_state.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/polling.dart';
import '../widgets/yoga_primitives.dart';
import 'chat_screen.dart';
import 'checkin_sheet.dart';
import 'notification_prefs_screen.dart';
import 'notifications_screen.dart';

class MoreScreen extends ConsumerWidget {
  final Me? me;
  final StudioConfig? studio;
  final VoidCallback? onTapProfile;
  const MoreScreen({super.key, this.me, this.studio, this.onTapProfile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final unreadChats = ref.watch(totalUnreadChatProvider);
    // Keep the unread badge fresh while the More tab is open; the chat
    // screens drive their own polling once entered.
    return PollingRefresh(
      surface: PollingSurface.chatList,
      onPoll: () => ref.invalidate(conversationsProvider),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          if (me != null && studio != null) ...[
            const SizedBox(height: 8),
            YStudioTopBar(
              studioName: studio!.name,
              userFullName: me!.fullName,
              userPhotoUrl: me!.photoUrl,
              onAvatarTap: onTapProfile,
            ),
            const SizedBox(height: 18),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: Text(
              'More',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                color: y.text,
              ),
            ),
          ),
          _Group(
            rows: [
              _Row(
                icon: Icons.forum_outlined,
                label: 'Messages',
                badge: unreadChats,
                onTap: me == null
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ChatListScreen(me: me!),
                          ),
                        );
                      },
              ),
              _Row(
                icon: Icons.notifications_none_rounded,
                label: 'Notifications',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NotificationsScreen(),
                    ),
                  );
                },
              ),
              _Row(
                icon: Icons.tune,
                label: 'Notification settings',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NotificationPrefsScreen(),
                    ),
                  );
                },
              ),
              _Row(
                icon: Icons.qr_code_scanner,
                label: 'Check-in code',
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  barrierColor: const Color(0x66100A05),
                  builder: (_) => const CheckInSheet(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Group(
            rows: [
              _Row(
                icon: Icons.help_outline_rounded,
                label: 'Help & support',
                onTap: null, // stub
              ),
              _Row(
                icon: Icons.info_outline_rounded,
                label: 'About Studio 52',
                onTap: null, // stub
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Group(
            rows: [
              _Row(
                icon: Icons.logout,
                label: 'Sign out',
                destructive: true,
                onTap: () async {
                  await ref.read(authServiceProvider).signOut();
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Studio 52 · dev build',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final List<_Row> rows;
  const _Group({required this.rows});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: y.border, indent: 52),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;
  final int badge;
  final VoidCallback? onTap;
  const _Row({
    required this.icon,
    required this.label,
    this.destructive = false,
    this.badge = 0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final fg = destructive
        ? const Color(0xFFA33B2E)
        : (onTap == null ? y.muted : y.text);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: destructive ? const Color(0x1AA33B2E) : y.surface2,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 17, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
            if (badge > 0) ...[
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: y.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: TextStyle(
                    color: y.onPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (!destructive)
              Icon(Icons.chevron_right, size: 18, color: y.muted),
          ],
        ),
      ),
    );
  }
}
