// Manager Dashboard — alert banner, 3 stats, today's classes table.
// Mirrors yoga-admin-a.jsx KDashboard.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/polling.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart';
import 'manager_shell.dart';

// Session-scoped — dashboard is the manager's landing tab. Spinner-on-
// every-visit reads as "the app is reloading" even when nothing
// changed. Caching + silent refresh matches user expectation.
final adminDashboardProvider =
    FutureProvider<AdminDashboard>((ref) async {
  return ref.watch(apiClientProvider).adminDashboard();
});

/// Below this width inner tables wrap and stat tiles stack — the page
/// switches to its mobile shape.
const double _kNarrow = 700;

class AdminDashboardScreen extends ConsumerWidget {
  final Me me;
  final void Function(String classId)? onOpenRoster;
  const AdminDashboardScreen({super.key, required this.me, this.onOpenRoster});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminDashboardProvider);
    return PollingRefresh(
      surface: PollingSurface.dashboard,
      onPoll: () => ref.invalidate(adminDashboardProvider),
      child: LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _kNarrow;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: data.when(
            data: (d) => _DashboardBody(
              data: d,
              me: me,
              onOpenRoster: onOpenRoster,
              isNarrow: isNarrow,
            ),
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => _ErrorView(error: e, onRetry: () {
              ref.invalidate(adminDashboardProvider);
            }),
          ),
        );
      },
    ),
    );
  }
}

class _DashboardBody extends ConsumerWidget {
  final AdminDashboard data;
  final Me me;
  final void Function(String classId)? onOpenRoster;
  final bool isNarrow;
  const _DashboardBody({
    required this.data,
    required this.me,
    required this.isNarrow,
    this.onOpenRoster,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classCount = data.classesToday.length;
    final firstName = me.firstName;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ManagerPageHeader(
          title: 'Good morning, $firstName',
          sub: '${_weekdayLong(DateTime.now())} · '
              '$classCount class${classCount == 1 ? '' : 'es'} today',
          actions: [
            YButton(
              label: '+ New class',
              small: true,
              onTap: () async {
                final id = await showNewClassDialog(context);
                if (id != null) ref.invalidate(adminDashboardProvider);
              },
            ),
          ],
        ),
        if (data.unmarkedAttendance > 0) ...[
          _UnmarkedBanner(count: data.unmarkedAttendance),
          const SizedBox(height: 16),
        ],
        _StatsRow(data: data, isNarrow: isNarrow),
        const SizedBox(height: 16),
        _TodayClassesCard(
          rows: data.classesToday,
          onOpenRoster: onOpenRoster,
          isNarrow: isNarrow,
        ),
      ],
    );
  }

  static String _weekdayLong(DateTime d) {
    const dow = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mon = ['January', 'February', 'March', 'April', 'May', 'June',
                  'July', 'August', 'September', 'October', 'November', 'December'];
    return '${dow[d.weekday - 1]} ${d.day} ${mon[d.month - 1]}';
  }
}

class _UnmarkedBanner extends StatelessWidget {
  final int count;
  const _UnmarkedBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: y.accentSoft,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: y.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count class${count == 1 ? '' : 'es'} from yesterday still have unmarked attendance',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: y.text,
              ),
            ),
          ),
          Text(
            'Review →',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: y.accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final AdminDashboard data;
  final bool isNarrow;
  const _StatsRow({required this.data, required this.isNarrow});

  @override
  Widget build(BuildContext context) {
    final occ = data.occupancyToday;
    final rev = data.revenueToday;
    final tiles = <Widget>[
      ManagerStat(
        label: 'Occupancy today',
        value: '${occ.percent}%',
        sub: '${occ.bookedSeats} of ${occ.totalCapacity} spots booked',
      ),
      ManagerStat(
        label: 'Revenue today',
        value: rev.fmt(rev.totalMinor),
        sub: rev.discountMinor > 0
            ? '${rev.fmt(rev.cardMinor)} card · ${rev.fmt(rev.cashMinor)} cash\n'
                '${rev.fmt(rev.discountMinor)} in discounts (gross ${rev.fmt(rev.grossMinor)})'
            : '${rev.fmt(rev.cardMinor)} card · ${rev.fmt(rev.cashMinor)} cash',
      ),
      ManagerStat(
        label: 'New bookings',
        value: '${data.newBookingsToday}',
        sub: data.newBookingsToday == 0 ? 'No bookings yet' : 'Today',
      ),
    ];
    if (isNarrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            tiles[i],
          ],
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );
  }
}

class _TodayClassesCard extends StatelessWidget {
  final List<ClassRow> rows;
  final void Function(String classId)? onOpenRoster;
  final bool isNarrow;
  const _TodayClassesCard({
    required this.rows,
    required this.isNarrow,
    this.onOpenRoster,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return ManagerCard(
      title: "Today's classes",
      action: 'Open schedule',
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No classes scheduled today.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            )
          : Column(
              children: [
                if (!isNarrow) _TableHeader(),
                for (var i = 0; i < rows.length; i++)
                  if (isNarrow)
                    _MobileClassRow(
                      row: rows[i],
                      isLast: i == rows.length - 1,
                      onOpenRoster: onOpenRoster,
                    )
                  else
                    _TableRow(
                      row: rows[i],
                      isLast: i == rows.length - 1,
                      onOpenRoster: onOpenRoster,
                    ),
              ],
            ),
    );
  }
}

/// Mobile shape for today's classes — time + status badge across the top,
/// class title + instructor block, occupancy meter, then a tap-to-open
/// roster row. No fixed-width columns so it fits a phone.
class _MobileClassRow extends StatelessWidget {
  final ClassRow row;
  final bool isLast;
  final void Function(String classId)? onOpenRoster;
  const _MobileClassRow({
    required this.row,
    required this.isLast,
    this.onOpenRoster,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final pct = row.capacity == 0
        ? 0
        : (row.bookedCount * 100 / row.capacity).round();
    final local = row.startsAt.toLocal();
    final timeLabel =
        '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap:
          onOpenRoster == null ? null : () => onOpenRoster!(row.id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  timeLabel,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    row.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _StatusChip(row: row),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                YAvatar(
                  name: row.instructorName,
                  photoUrl: row.instructorPhotoUrl,
                  size: 22,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    row.instructorName,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onOpenRoster != null)
                  Text(
                    'Roster ›',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: y.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ManagerMeter(
              percent: pct,
              label: '${row.bookedCount} / ${row.capacity}',
            ),
          ],
        ),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
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
          SizedBox(width: 64, child: Text('TIME', style: s)),
          const SizedBox(width: 12),
          Expanded(flex: 14, child: Text('CLASS', style: s)),
          const SizedBox(width: 12),
          Expanded(flex: 10, child: Text('INSTRUCTOR', style: s)),
          const SizedBox(width: 12),
          Expanded(flex: 16, child: Text('OCCUPANCY', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 130, child: Text('STATUS', style: s)),
          const SizedBox(width: 12),
          const SizedBox(width: 70),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  final ClassRow row;
  final bool isLast;
  final void Function(String classId)? onOpenRoster;
  const _TableRow({
    required this.row,
    required this.isLast,
    this.onOpenRoster,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final pct = row.capacity == 0 ? 0 : (row.bookedCount * 100 / row.capacity).round();
    final local = row.startsAt.toLocal();
    final timeLabel = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              timeLabel,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 14,
            child: Text(
              row.title,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: y.text,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 10,
            child: Row(
              children: [
                YAvatar(name: row.instructorName, photoUrl: row.instructorPhotoUrl, size: 22),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    row.instructorName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 16,
            child: ManagerMeter(
              percent: pct,
              label: '${row.bookedCount} / ${row.capacity}',
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 130,
            child: _StatusChip(row: row),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: GestureDetector(
              onTap: onOpenRoster == null ? null : () => onOpenRoster!(row.id),
              child: Text(
                'Roster',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: y.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final ClassRow row;
  const _StatusChip({required this.row});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = row.startsAt.toLocal();
    final end = row.endsAt.toLocal();
    if (row.bookingState == BookingState.full) {
      final label = row.waitlistCount > 0
          ? 'Full · ${row.waitlistCount} waiting'
          : 'Full';
      return YChip(kind: YChipKind.full, label: label);
    }
    if (now.isAfter(end)) {
      return const YChip(kind: YChipKind.neutral, label: 'Done');
    }
    if (now.isAfter(start)) {
      return const YChip(kind: YChipKind.accent, label: 'In progress');
    }
    return const YChip(kind: YChipKind.booked, label: 'Open');
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Can't load dashboard",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: y.text,
            ),
          ),
          const SizedBox(height: 6),
          Text('$error', style: TextStyle(color: y.muted)),
          const SizedBox(height: 16),
          YButton(label: 'Retry', small: true, onTap: onRetry),
        ],
      ),
    );
  }
}
