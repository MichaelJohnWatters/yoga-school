// Notifications feed.
// Mirrors yoga-student2.jsx YNotificationsScreen.
//
// Three card patterns by type:
//   waitlist_promoted → accent tonal icon + accent unread dot + "Claim spot" CTA
//   booking_confirmed → primary tonal icon
//   system / default  → surface2 tonal icon

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';

final notificationsProvider =
    FutureProvider.autoDispose<List<NotificationItem>>((ref) async {
  return ref.watch(apiClientProvider).notificationsFeed();
});

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final feed = ref.watch(notificationsProvider);
    return Scaffold(
      backgroundColor: y.background,
      body: SafeArea(
        child: feed.when(
          data: (items) => _Body(items: items, onAnyRead: () {
            ref.invalidate(notificationsProvider);
          }),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Text("Can't load feed: $e",
                style: TextStyle(color: y.muted)),
          ),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final List<NotificationItem> items;
  final VoidCallback onAnyRead;
  const _Body({required this.items, required this.onAnyRead});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final hasUnread = items.any((n) => n.unread);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(notificationsProvider),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: y.borderStrong),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.chevron_left, size: 22, color: y.text),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Notifications',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: y.text,
                ),
              ),
              const Spacer(),
              if (hasUnread)
                GestureDetector(
                  onTap: () async {
                    await ref.read(apiClientProvider).markAllNotificationsRead();
                    onAnyRead();
                  },
                  child: Text(
                    'Mark all read',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: y.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const _EmptyState()
          else
            for (final n in items) ...[
              _NotificationCard(
                item: n,
                onTap: () async {
                  if (n.unread) {
                    await ref
                        .read(apiClientProvider)
                        .markNotificationRead(n.id);
                    onAnyRead();
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  final NotificationItem item;
  final VoidCallback onTap;
  const _NotificationCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isWaitlist = item.type == 'waitlist_promoted';
    final isBooking = item.type == 'booking_confirmed';
    final isCancelled = item.type == 'class_cancelled';
    Color iconBg;
    Color iconFg;
    IconData icon;
    if (isWaitlist) {
      iconBg = y.accentSoft;
      iconFg = y.accent;
      icon = Icons.list_alt;
    } else if (isBooking) {
      iconBg = y.primarySoft;
      iconFg = y.primaryStrong;
      icon = Icons.check_circle_outline;
    } else if (isCancelled) {
      iconBg = y.accentSoft;
      iconFg = y.accent;
      icon = Icons.warning_amber_rounded;
    } else {
      iconBg = y.surface2;
      iconFg = y.muted;
      icon = Icons.notifications_none_rounded;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconBg,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: iconFg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: y.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _relTime(item.createdAt),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: y.muted,
                        ),
                      ),
                      if (item.unread) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: y.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (item.body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      item.body,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: y.muted,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (isWaitlist) ...[
                    const SizedBox(height: 10),
                    YButton(
                      label: 'Claim spot',
                      small: true,
                      onTap: onTap,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _relTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inMinutes < 1) return 'now';
    if (delta.inHours < 1) return '${delta.inMinutes}m';
    if (delta.inDays < 1) return '${delta.inHours}h';
    if (delta.inDays < 7) return '${delta.inDays}d';
    return '${(delta.inDays / 7).floor()}w';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: y.surface2,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.notifications_none_rounded,
                size: 26, color: y.muted),
          ),
          const SizedBox(height: 14),
          Text(
            'All quiet for now',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: y.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "We'll let you know when something changes.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
        ],
      ),
    );
  }
}
