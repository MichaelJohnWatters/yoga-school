// Notifications feed.
// Mirrors yoga-student2.jsx YNotificationsScreen.
//
// Three card patterns by type:
//   waitlist_promoted → accent tonal icon + accent unread dot + "Claim spot" CTA
//   booking_confirmed → primary tonal icon
//   system / default  → surface2 tonal icon

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/polling.dart';
import '../widgets/yoga_primitives.dart';
import 'chat_screen.dart';

// Session-scoped — autoDispose was producing a full-screen spinner
// every time the user opened the bell, even though the prior list
// was still perfectly valid. Keeping it alive means a return visit
// renders cached items immediately and Riverpod's default
// skipLoadingOnRefresh keeps data on screen during background
// re-fetches triggered by markRead / invalidate.
final notificationsProvider = FutureProvider<List<NotificationItem>>((
  ref,
) async {
  return ref.watch(apiClientProvider).notificationsFeed();
});

/// Derived count of unread notifications. Returns 0 while the feed is
/// loading or errored so the bell badge stays empty rather than
/// flickering when the user opens the app. Auto-recomputes whenever the
/// feed provider invalidates (mark-read, polling tick, etc.).
final unreadNotificationCountProvider = Provider<int>((ref) {
  final feed = ref.watch(notificationsProvider);
  final list = feed.asData?.value ?? const <NotificationItem>[];
  return list.where((n) => n.unread).length;
});

/// Compact notifications panel for the desktop bell popover. Shows the most
/// recent notifications, "Mark all read", and a "See all" link into the full
/// [NotificationsScreen]. Reuses [_NotificationCard] and the same tap
/// behaviour (mark read; jump into a chat thread for chat notifications).
class NotificationsPopoverPanel extends ConsumerStatefulWidget {
  /// Called to dismiss the popover (e.g. before navigating away).
  final VoidCallback onClose;
  const NotificationsPopoverPanel({super.key, required this.onClose});

  @override
  ConsumerState<NotificationsPopoverPanel> createState() =>
      _NotificationsPopoverPanelState();
}

class _NotificationsPopoverPanelState
    extends ConsumerState<NotificationsPopoverPanel> {
  Future<void> _onTap(NotificationItem n) async {
    if (n.unread) {
      try {
        await ref.read(apiClientProvider).markNotificationRead(n.id);
        ref.invalidate(notificationsProvider);
      } catch (_) {
        // Best-effort; the full screen surfaces errors.
      }
    }
    if (!mounted) return;
    final convId = n.chatConversationId;
    final me = ref.read(bootstrapProvider).asData?.value.me;
    widget.onClose();
    if (convId != null && me != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(conversationId: convId, me: me),
        ),
      );
    }
  }

  Future<void> _markAll() async {
    try {
      await ref.read(apiClientProvider).markAllNotificationsRead();
      ref.invalidate(notificationsProvider);
    } catch (_) {}
  }

  void _seeAll() {
    widget.onClose();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final feed = ref.watch(notificationsProvider);
    final list = feed.asData?.value ?? const <NotificationItem>[];
    final unread = list.where((n) => n.unread).length;
    return Material(
      color: y.surface,
      elevation: 10,
      borderRadius: BorderRadius.circular(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
              child: Row(
                children: [
                  Text(
                    'Notifications',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                  const Spacer(),
                  if (unread > 0)
                    GestureDetector(
                      onTap: _markAll,
                      child: Text(
                        'Mark all read',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: y.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: y.border),
            Flexible(
              child: feed.when(
                data: (items) => items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: Text(
                            'No notifications.',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: y.muted,
                            ),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: items.length > 8 ? 8 : items.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: y.border, indent: 60),
                        itemBuilder: (_, i) => _NotificationCard(
                          item: items[i],
                          onTap: () => _onTap(items[i]),
                        ),
                      ),
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text(
                      "Can't load notifications.",
                      style: TextStyle(color: y.muted),
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: y.border),
            InkWell(
              onTap: _seeAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text(
                    'See all notifications',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: y.primary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final feed = ref.watch(notificationsProvider);
    return PollingRefresh(
      surface: PollingSurface.notifications,
      onPoll: () => ref.invalidate(notificationsProvider),
      child: Scaffold(
        backgroundColor: y.background,
        body: SafeArea(
          child: feed.when(
            data: (items) => _Body(items: items),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Text(
                "Can't load feed: ${ApiError.fromAny(e).message}",
                style: TextStyle(color: y.muted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Splits the feed into an Unread tab (the default — what needs attention)
/// and a Read tab (history). Marking read moves a row across; swipe-to-
/// dismiss deletes a single row; "Clear" on the Read tab wipes read history.
class _Body extends ConsumerStatefulWidget {
  final List<NotificationItem> items;
  const _Body({required this.items});

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {})); // swap the header action per tab

  // Ids removed by swipe-to-dismiss, hidden immediately so the dismissed
  // Dismissible leaves the tree on the very next frame (otherwise Flutter
  // throws "a dismissed Dismissible is still part of the tree"). The server
  // delete + refresh run in the background; didUpdateWidget prunes ids the
  // refreshed feed no longer carries.
  final Set<String> _dismissed = {};

  @override
  void didUpdateWidget(covariant _Body old) {
    super.didUpdateWidget(old);
    if (_dismissed.isNotEmpty) {
      final present = widget.items.map((n) => n.id).toSet();
      _dismissed.retainWhere(present.contains);
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) ref.invalidate(notificationsProvider);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _markAllRead() async {
    try {
      await ref.read(apiClientProvider).markAllNotificationsRead();
    } catch (e) {
      _toast("Couldn't mark all read: ${ApiError.fromAny(e).message}");
    } finally {
      _refresh();
    }
  }

  Future<void> _clearRead() async {
    try {
      await ref.read(apiClientProvider).clearReadNotifications();
    } catch (e) {
      _toast("Couldn't clear: ${ApiError.fromAny(e).message}");
    } finally {
      _refresh();
    }
  }

  /// Swipe-to-dismiss handler. Hides the row synchronously so the dismissed
  /// Dismissible leaves the tree on the next frame, then deletes it
  /// server-side. A failed delete (offline, already gone, or an old server
  /// build missing the route) is swallowed — the row stays hidden until the
  /// next successful refresh reconciles, and the error never escapes.
  void _delete(NotificationItem n) {
    setState(() => _dismissed.add(n.id));
    unawaited(_deleteRemote(n.id));
  }

  Future<void> _deleteRemote(String id) async {
    try {
      await ref.read(apiClientProvider).deleteNotification(id);
    } catch (_) {
      // Intentionally silent — see _delete.
    } finally {
      _refresh();
    }
  }

  Future<void> _onTap(NotificationItem n) async {
    try {
      if (n.unread) {
        await ref.read(apiClientProvider).markNotificationRead(n.id);
        _refresh();
      }
    } catch (e) {
      _toast("Couldn't update: ${ApiError.fromAny(e).message}");
    }
    // chat_message → jump straight into the conversation. The chat thread
    // marks itself read on arrival so the notification row and the
    // conversation's own unread count clear together.
    final convId = n.chatConversationId;
    if (convId != null && mounted) {
      final me = ref.read(bootstrapProvider).asData?.value.me;
      if (me != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatThreadScreen(conversationId: convId, me: me),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final visible = widget.items.where((n) => !_dismissed.contains(n.id));
    final unread = visible.where((n) => n.unread).toList();
    final read = visible.where((n) => !n.unread).toList();
    // Header action follows the active tab: clear unread → Read, or wipe
    // the Read history. Hidden when the active tab is empty.
    final onUnreadTab = _tab.index == 0;
    final String? actionLabel = onUnreadTab
        ? (unread.isNotEmpty ? 'Mark all read' : null)
        : (read.isNotEmpty ? 'Clear' : null);
    final VoidCallback onAction = onUnreadTab ? _markAllRead : _clearRead;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
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
              if (actionLabel != null)
                GestureDetector(
                  onTap: onAction,
                  child: Text(
                    actionLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: y.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        TabBar(
          controller: _tab,
          labelColor: y.text,
          unselectedLabelColor: y.muted,
          indicatorColor: y.primary,
          indicatorWeight: 2,
          tabs: [
            Tab(text: unread.isEmpty ? 'Unread' : 'Unread (${unread.length})'),
            const Tab(text: 'Read'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _NotificationList(
                items: unread,
                onTap: _onTap,
                onDelete: _delete,
                empty: const _EmptyState(
                  title: 'All caught up',
                  subtitle: "You've no unread notifications.",
                ),
              ),
              _NotificationList(
                items: read,
                onTap: _onTap,
                onDelete: _delete,
                empty: const _EmptyState(
                  title: 'Nothing here yet',
                  subtitle: 'Notifications you read will move here.',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One tab's worth of notifications. Each card is swipe-to-dismiss (delete);
/// an empty list shows [empty].
class _NotificationList extends ConsumerWidget {
  final List<NotificationItem> items;
  final Future<void> Function(NotificationItem) onTap;
  final void Function(NotificationItem) onDelete;
  final Widget empty;
  const _NotificationList({
    required this.items,
    required this.onTap,
    required this.onDelete,
    required this.empty,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(notificationsProvider),
      child: items.isEmpty
          ? ListView(
              // A scrollable so pull-to-refresh still works when empty.
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [empty],
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final n = items[i];
                return Dismissible(
                  key: ValueKey(n.id),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) => onDelete(n),
                  background: const _DismissBackground(),
                  child: _NotificationCard(item: n, onTap: () => onTap(n)),
                );
              },
            ),
    );
  }
}

/// Red trailing background revealed as a card is swiped away.
class _DismissBackground extends StatelessWidget {
  const _DismissBackground();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: y.accent,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Icon(Icons.delete_outline, color: y.onPrimary, size: 22),
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
    final isChat = item.type == 'chat_message';
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
    } else if (isChat) {
      iconBg = y.primarySoft;
      iconFg = y.primaryStrong;
      icon = Icons.forum_outlined;
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
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
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
                    YButton(label: 'Claim spot', small: true, onTap: onTap),
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
  final String title;
  final String subtitle;
  const _EmptyState({required this.title, required this.subtitle});

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
            child: Icon(
              Icons.notifications_none_rounded,
              size: 26,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: y.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
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
