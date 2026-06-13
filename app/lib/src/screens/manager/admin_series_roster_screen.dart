// Manager Series Roster — attendance grid (students × N sessions).
// Cells: present = primary tile w/ check; no_show = text tile w/ ✕;
// upcoming = dashed outline; unmarked = surface2 hint; absent = blank dot.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

final adminSeriesRosterProvider =
    FutureProvider.autoDispose.family<SeriesRoster, String>((ref, id) async {
  return ref.watch(apiClientProvider).adminSeriesRoster(id);
});

class AdminSeriesRosterScreen extends ConsumerWidget {
  final String enrollmentId;
  final VoidCallback onClose;
  const AdminSeriesRosterScreen({
    super.key,
    required this.enrollmentId,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminSeriesRosterProvider(enrollmentId));
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: data.when(
        data: (r) => _Body(roster: r, onClose: onClose),
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Text(
            "Can't load roster: $e",
            style: TextStyle(color: context.yoga.muted),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final SeriesRoster roster;
  final VoidCallback onClose;
  const _Body({required this.roster, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final s = roster.series;
    final attendancePct = _computeAttendancePct(roster);
    return ListView(
      children: [
        ManagerPageHeader(
          title: s.title,
          sub: '${s.sessionCount} sessions · ${roster.students.length} of ${s.capacity} enrolled',
          actions: [
            YButton(
              label: 'Back',
              variant: YButtonVariant.outline,
              small: true,
              onTap: onClose,
            ),
          ],
        ),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ManagerStat(
                  label: 'Enrolled',
                  value: '${roster.students.length} of ${s.capacity}',
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ManagerStat(
                  label: 'Attendance',
                  value: attendancePct == null ? '—' : '$attendancePct%',
                  sub: attendancePct == null ? 'No sessions marked yet' : null,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: ManagerStat(
                  label: 'Current week',
                  value: roster.currentWeekIdx > 0 && roster.currentWeekIdx <= s.sessionCount
                      ? '${roster.currentWeekIdx} of ${s.sessionCount}'
                      : '—',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ManagerCard(
          title: 'Attendance grid',
          child: roster.students.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    "Nobody has enrolled yet — the grid will populate as students sign up.",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.yoga.muted,
                    ),
                  ),
                )
              : _Grid(roster: roster),
        ),
        const SizedBox(height: 12),
        _Legend(),
      ],
    );
  }

  static int? _computeAttendancePct(SeriesRoster r) {
    var marked = 0, present = 0;
    for (final s in r.students) {
      for (final c in s.cells) {
        if (c == 'present' || c == 'no_show') {
          marked++;
          if (c == 'present') present++;
        }
      }
    }
    if (marked == 0) return null;
    return present * 100 ~/ marked;
  }
}

class _Grid extends StatelessWidget {
  final SeriesRoster roster;
  const _Grid({required this.roster});

  @override
  Widget build(BuildContext context) {
    final sessions = roster.sessions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header row: name column + per-session week labels.
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
          child: Row(
            children: [
              const SizedBox(width: 200),
              for (var i = 0; i < sessions.length; i++) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: _SessionHeader(
                    weekIdx: i + 1,
                    date: sessions[i].startsAt.toLocal(),
                    isCurrent: roster.currentWeekIdx == i + 1,
                  ),
                ),
              ],
            ],
          ),
        ),
        for (var i = 0; i < roster.students.length; i++)
          _StudentRow(
            student: roster.students[i],
            isLast: i == roster.students.length - 1,
          ),
      ],
    );
  }
}

class _SessionHeader extends StatelessWidget {
  final int weekIdx;
  final DateTime date;
  final bool isCurrent;
  const _SessionHeader({
    required this.weekIdx,
    required this.date,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return Column(
      children: [
        Text(
          'WK $weekIdx',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.7,
            color: isCurrent ? y.primary : y.muted,
          ),
        ),
        Text(
          '${date.day} ${mons[date.month - 1]}',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: isCurrent ? y.primary : y.text,
          ),
        ),
      ],
    );
  }
}

class _StudentRow extends StatelessWidget {
  final SeriesRosterStudent student;
  final bool isLast;
  const _StudentRow({required this.student, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Row(
              children: [
                YAvatar(name: student.fullName, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    student.fullName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < student.cells.length; i++) ...[
            const SizedBox(width: 6),
            Expanded(child: _Cell(state: student.cells[i])),
          ],
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  final String state;
  const _Cell({required this.state});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget child;
    Decoration deco;
    switch (state) {
      case 'present':
        deco = BoxDecoration(
          color: y.primary,
          borderRadius: BorderRadius.circular(8),
        );
        child = Icon(Icons.check, color: y.onPrimary, size: 16);
        break;
      case 'no_show':
        deco = BoxDecoration(
          color: y.text,
          borderRadius: BorderRadius.circular(8),
        );
        child = Icon(Icons.close, color: y.background, size: 16);
        break;
      case 'upcoming':
        // Dashed outline per yoga-enroll.jsx:143 (`1px dashed var(--border-strong)`).
        return SizedBox(
          height: 36,
          child: YDashedBorder(
            color: y.borderStrong,
            radius: 8,
            child: const SizedBox.expand(),
          ),
        );
      case 'unmarked':
        deco = BoxDecoration(
          color: y.accentSoft,
          borderRadius: BorderRadius.circular(8),
        );
        child = Text(
          '?',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: y.accent,
            height: 1.0,
          ),
        );
        break;
      default:
        deco = BoxDecoration(
          color: y.surface2,
          borderRadius: BorderRadius.circular(8),
        );
        child = const SizedBox.shrink();
    }
    return SizedBox(
      height: 36,
      child: Container(
        decoration: deco,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget swatch(Color bg, IconData? icon, Color? iconColor) => Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
          ),
          alignment: Alignment.center,
          child: icon == null
              ? null
              : Icon(icon, size: 10, color: iconColor),
        );
    Widget item(Widget s, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            s,
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ],
        );
    return Wrap(
      spacing: 18,
      runSpacing: 8,
      children: [
        item(swatch(y.primary, Icons.check, y.onPrimary), 'Present'),
        item(swatch(y.text, Icons.close, y.background), 'No-show'),
        item(swatch(y.accentSoft, null, null), 'Unmarked'),
        item(
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: y.borderStrong, width: 1.5),
            ),
          ),
          'Upcoming',
        ),
        item(swatch(y.surface2, null, null), 'Absent / no booking'),
      ],
    );
  }
}
