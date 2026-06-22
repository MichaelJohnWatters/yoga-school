// Notification preferences — the screen behind More → Notification settings.
// A short list of category toggles. Empty/loading/error states all handled
// without leaving the screen so a single failed PATCH doesn't strand the
// user without a way to retry.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';

final notificationPrefsProvider =
    FutureProvider<NotificationPrefs>((ref) async {
  return ref.watch(apiClientProvider).notificationPrefs();
});

class NotificationPrefsScreen extends ConsumerWidget {
  const NotificationPrefsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final prefs = ref.watch(notificationPrefsProvider);
    return Scaffold(
      backgroundColor: y.background,
      appBar: AppBar(
        backgroundColor: y.background,
        elevation: 0,
        iconTheme: IconThemeData(color: y.text),
        title: Text(
          'Notification settings',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: y.text,
          ),
        ),
      ),
      body: prefs.when(
        data: (p) => _Loaded(initial: p),
        loading: () => const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(20),
          child: Text("Can't load preferences: ${ApiError.fromAny(e).message}",
              style: TextStyle(color: y.muted)),
        ),
      ),
    );
  }
}

class _Loaded extends ConsumerStatefulWidget {
  final NotificationPrefs initial;
  const _Loaded({required this.initial});

  @override
  ConsumerState<_Loaded> createState() => _LoadedState();
}

class _LoadedState extends ConsumerState<_Loaded> {
  late NotificationPrefs _current;
  String? _error;
  // While a PATCH is in-flight for a category, that row's switch shows a
  // tiny spinner instead of an enabled toggle.
  String? _pendingField;

  @override
  void initState() {
    super.initState();
    _current = widget.initial;
  }

  Future<void> _set(String field, bool value) async {
    setState(() {
      _pendingField = field;
      _error = null;
    });
    try {
      final updated = await ref
          .read(apiClientProvider)
          .updateNotificationPrefs({field: value});
      // Refresh the cached provider so other screens see the new state.
      ref.invalidate(notificationPrefsProvider);
      setState(() => _current = updated);
    } catch (e) {
      setState(() => _error = ApiError.fromAny(e).message);
    } finally {
      if (mounted) setState(() => _pendingField = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            'Choose which messages land in your feed. Class cancellations '
            'always reach you on the day-of, regardless.',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
              height: 1.45,
            ),
          ),
        ),
        _Group(
          rows: [
            _Toggle(
              key: const Key('notif-toggle-booking_confirmed'),
              label: 'Booking confirmations',
              sub: '"You\'re booked into …" when you reserve a class.',
              value: _current.bookingConfirmed,
              pending: _pendingField == 'booking_confirmed',
              onChanged: (v) => _set('booking_confirmed', v),
            ),
            _Toggle(
              key: const Key('notif-toggle-class_cancelled'),
              label: 'Class cancellations',
              sub: 'When the studio cancels a class you were booked into.',
              value: _current.classCancelled,
              pending: _pendingField == 'class_cancelled',
              onChanged: (v) => _set('class_cancelled', v),
            ),
            _Toggle(
              key: const Key('notif-toggle-waitlist_promoted'),
              label: 'Waitlist offers',
              sub: 'When a spot opens up and we held one for you.',
              value: _current.waitlistPromoted,
              pending: _pendingField == 'waitlist_promoted',
              onChanged: (v) => _set('waitlist_promoted', v),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Group(
          rows: [
            _Toggle(
              label: 'Promotions & offers',
              sub: 'Memberships, seasonal deals, and announcements.',
              value: _current.promotions,
              pending: _pendingField == 'promotions',
              onChanged: (v) => _set('promotions', v),
            ),
            _Toggle(
              label: 'Account messages',
              sub: 'Welcome notes and other studio-wide system messages.',
              value: _current.systemMsgs,
              pending: _pendingField == 'system_msgs',
              onChanged: (v) => _set('system_msgs', v),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x1AA33B2E),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              "Couldn't save: $_error",
              style: const TextStyle(
                color: Color(0xFFA33B2E),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Group extends StatelessWidget {
  final List<_Toggle> rows;
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
            if (i > 0) Divider(height: 1, color: y.border, indent: 16),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final String label;
  final String sub;
  final bool value;
  final bool pending;
  final ValueChanged<bool> onChanged;
  const _Toggle({
    super.key,
    required this.label,
    required this.sub,
    required this.value,
    required this.pending,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (pending)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: y.primary,
            ),
        ],
      ),
    );
  }
}
