// Manager Memberships — studio-wide list of every subscription with per-row
// manage (cancel at renewal / now / refund / resume). Reuses the cancel dialog
// from the student detail page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_student_detail_screen.dart' show showCancelMembershipDialog;
import 'manager_shell.dart';

final adminMembershipsProvider =
    FutureProvider<List<Subscription>>((ref) async {
  return ref.watch(apiClientProvider).adminListSubscriptions();
});

bool _isLive(Subscription s) => s.status == 'active' || s.status == 'past_due';

class AdminMembershipsScreen extends ConsumerWidget {
  final void Function(String studentId) onOpenStudent;
  const AdminMembershipsScreen({super.key, required this.onOpenStudent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminMembershipsProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminMembershipsProvider),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ManagerPageHeader(
              title: 'Memberships',
              sub: 'Every recurring membership — cancel, refund, or resume',
            ),
            Expanded(
              child: data.when(
                data: (subs) {
                  if (subs.isEmpty) {
                    return Center(
                      child: Text('No memberships yet.',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: context.yoga.muted)),
                    );
                  }
                  final live = subs.where(_isLive).toList();
                  final ended = subs.where((s) => !_isLive(s)).toList();
                  void refresh() => ref.invalidate(adminMembershipsProvider);
                  return ListView(
                    children: [
                      if (live.isNotEmpty)
                        ManagerCard(
                          title: 'Active · ${live.length}',
                          child: Column(
                            children: [
                              for (var i = 0; i < live.length; i++)
                                _Row(
                                  sub: live[i],
                                  isLast: i == live.length - 1,
                                  onOpenStudent: onOpenStudent,
                                  onChanged: refresh,
                                ),
                            ],
                          ),
                        ),
                      if (ended.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        ManagerCard(
                          title: 'Ended · ${ended.length}',
                          child: Column(
                            children: [
                              for (var i = 0; i < ended.length; i++)
                                _Row(
                                  sub: ended[i],
                                  isLast: i == ended.length - 1,
                                  onOpenStudent: onOpenStudent,
                                  onChanged: refresh,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                error: (e, _) => Center(
                  child: Text("Can't load memberships: ${ApiError.fromAny(e).message}",
                      style: TextStyle(color: context.yoga.muted)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final Subscription sub;
  final bool isLast;
  final void Function(String studentId) onOpenStudent;
  final VoidCallback onChanged;
  const _Row({
    required this.sub,
    required this.isLast,
    required this.onOpenStudent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final live = _isLive(sub);
    return Opacity(
      opacity: live ? 1 : 0.6,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: GestureDetector(
                          onTap: sub.userId == null
                              ? null
                              : () => onOpenStudent(sub.userId!),
                          child: Text(
                            sub.userName ?? '—',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: sub.userId == null ? y.text : y.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusChip(sub: sub),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _subline(sub),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: sub.cancelAtPeriodEnd ? y.accent : y.muted,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${sub.formattedAmount()}/mo',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (live) ...[
              const SizedBox(width: 12),
              YButton(
                label: 'Manage',
                variant: YButtonVariant.outline,
                small: true,
                onTap: () async {
                  final changed = await showCancelMembershipDialog(
                    context: context,
                    subscriptionId: sub.id,
                    renewsAt: sub.currentPeriodEndDate,
                    cancelAtPeriodEnd: sub.cancelAtPeriodEnd,
                  );
                  if (changed == true) onChanged();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _subline(Subscription s) {
    final d = s.currentPeriodEndDate?.toLocal();
    String date() {
      const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${d!.day} ${mons[d.month - 1]} ${d.year}';
    }

    final parts = <String>[s.productName];
    if (s.cancelAtPeriodEnd && d != null) {
      parts.add('cancels ${date()}');
    } else if (s.status == 'active' && d != null) {
      parts.add('renews ${date()}');
    } else if (s.status == 'past_due') {
      parts.add('payment past due');
    }
    return parts.join(' · ');
  }
}

class _StatusChip extends StatelessWidget {
  final Subscription sub;
  const _StatusChip({required this.sub});

  @override
  Widget build(BuildContext context) {
    final (kind, label) = switch (sub.status) {
      'active' => (
          sub.cancelAtPeriodEnd ? YChipKind.accent : YChipKind.booked,
          sub.cancelAtPeriodEnd ? 'Ending' : 'Active'
        ),
      'past_due' => (YChipKind.accent, 'Past due'),
      'canceled' => (YChipKind.full, 'Canceled'),
      'pending' => (YChipKind.neutral, 'Pending'),
      _ => (YChipKind.full, sub.status),
    };
    return YChip(kind: kind, label: label);
  }
}
