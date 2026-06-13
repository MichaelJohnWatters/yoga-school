// Manager Series — list view with per-row "View roster" entry point.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';
import 'series_dialogs.dart';

final adminEnrollmentsProvider =
    FutureProvider.autoDispose<List<AdminEnrollmentSummary>>((ref) async {
  return ref.watch(apiClientProvider).adminListEnrollments();
});

class AdminSeriesScreen extends ConsumerWidget {
  final void Function(String enrollmentId) onView;
  const AdminSeriesScreen({super.key, required this.onView});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminEnrollmentsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ManagerPageHeader(
            title: 'Series',
            sub: 'Multi-session courses — one payment, every session booked',
            actions: [
              YButton(
                label: '+ New series',
                small: true,
                onTap: () async {
                  final created = await showNewSeriesDialog(context);
                  if (created == true) ref.invalidate(adminEnrollmentsProvider);
                },
              ),
            ],
          ),
          Expanded(
            child: data.when(
              data: (rows) => rows.isEmpty
                  ? Center(
                      child: Text(
                        'No series scheduled yet.',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.yoga.muted,
                        ),
                      ),
                    )
                  : ManagerCard(
                      child: Column(
                        children: [
                          _Head(),
                          for (var i = 0; i < rows.length; i++)
                            _Row(
                              item: rows[i],
                              isLast: i == rows.length - 1,
                              onView: () => onView(rows[i].summary.id),
                              onEdit: () async {
                                final edited = await showEditSeriesDialog(
                                  context: context,
                                  series: rows[i].summary,
                                );
                                if (edited == true) {
                                  ref.invalidate(adminEnrollmentsProvider);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (e, _) => Center(
                child: Text(
                  "Can't load series: $e",
                  style: TextStyle(color: context.yoga.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Head extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final s = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: y.muted,
      letterSpacing: 0.6,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Expanded(flex: 18, child: Text('SERIES', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: Text('ENROLLED', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: Text('REVENUE', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: Text('ATTENDANCE', style: s)),
          const SizedBox(width: 12),
          const SizedBox(width: 140),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final AdminEnrollmentSummary item;
  final bool isLast;
  final VoidCallback onView;
  final VoidCallback onEdit;
  const _Row({
    required this.item,
    required this.isLast,
    required this.onView,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final s = item.summary;
    final dates = s.startsAt != null && s.endsAt != null
        ? '${_short(s.startsAt!)} – ${_short(s.endsAt!)}'
        : '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 18,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                Text(
                  '${s.sessionCount} sessions · $dates',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Text(
              '${s.enrolledCount} / ${s.capacity}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Text(
              '£${(item.revenueMinor / 100).toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Text(
              item.attendancePct > 0 ? '${item.attendancePct}%' : '—',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: onEdit,
                  child: Text(
                    'Edit',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: y.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                GestureDetector(
                  onTap: onView,
                  child: Text(
                    'View roster',
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
        ],
      ),
    );
  }

  static String _short(DateTime d) {
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${mons[l.month - 1]}';
  }
}
