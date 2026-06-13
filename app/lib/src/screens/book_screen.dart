// Book screen — Classes tab.
// Mirrors yoga-book.jsx: title + check-in button, segmented control,
// month label, 7-day strip with dot indicators, class rows by time.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'booking_sheet.dart';
import 'checkin_sheet.dart';
import 'enrollments_tab.dart';

class BookScreen extends ConsumerStatefulWidget {
  const BookScreen({super.key});

  @override
  ConsumerState<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends ConsumerState<BookScreen> {
  late DateTime _selected;
  late Future<List<ClassRow>> _classes;
  int _tab = 0; // 0 = Classes, 1 = Enrollments

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _selected = DateTime(n.year, n.month, n.day);
    _classes = ref.read(apiClientProvider).classesForDay(_selected);
  }

  void _pick(DateTime d) {
    setState(() {
      _selected = d;
      _classes = ref.read(apiClientProvider).classesForDay(d);
    });
  }

  void _reload() {
    setState(() {
      _classes = ref.read(apiClientProvider).classesForDay(_selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BookHeader(
          tab: _tab,
          onTab: (i) => setState(() => _tab = i),
        ),
        if (_tab == 0) ...[
          _DayStrip(selected: _selected, onPick: _pick),
          Expanded(
            child: FutureBuilder<List<ClassRow>>(
              future: _classes,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                if (snap.hasError) {
                  return _LoadError(error: snap.error!, onRetry: _reload);
                }
                final rows = snap.data ?? const <ClassRow>[];
                if (rows.isEmpty) return _EmptyDay(day: _selected, onJumpTo: _pick);
                return _ClassList(rows: rows, onBookingChanged: _reload);
              },
            ),
          ),
        ] else
          const Expanded(child: EnrollmentsTab()),
      ],
    );
  }
}

class _BookHeader extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  const _BookHeader({required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Book',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  color: y.text,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  barrierColor: const Color(0x66100A05),
                  builder: (_) => const CheckInSheet(),
                ),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: y.borderStrong),
                  ),
                  child: Icon(Icons.qr_code_scanner, size: 18, color: y.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _Segmented(
            segments: const ['Classes', 'Enrollments'],
            active: tab,
            onTap: onTab,
          ),
        ],
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  final List<String> segments;
  final int active;
  final ValueChanged<int> onTap;
  const _Segmented({required this.segments, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip),
      ),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onTap(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == active ? y.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(y.radiusChip),
                    border: Border.all(
                      color: i == active ? y.border : Colors.transparent,
                    ),
                    boxShadow: i == active ? y.shadow : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    segments[i],
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: i == active ? y.text : y.muted,
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

class _DayStrip extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onPick;
  const _DayStrip({required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Show 7 days starting from the Monday of the selected week.
    final offset = (selected.weekday + 6) % 7; // Mon=0
    final monday = DateTime(selected.year, selected.month, selected.day - offset);
    final week = List.generate(7, (i) => monday.add(Duration(days: i)));
    const monthNames = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    final monthLabel = '${monthNames[selected.month - 1]} ${selected.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
            child: Row(
              children: [
                Text(
                  monthLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: y.muted,
                    letterSpacing: 0.4,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => onPick(monday.subtract(const Duration(days: 7))),
                  child: Icon(Icons.chevron_left, size: 20, color: y.muted),
                ),
                const SizedBox(width: 14),
                GestureDetector(
                  onTap: () => onPick(monday.add(const Duration(days: 7))),
                  child: Icon(Icons.chevron_right, size: 20, color: y.muted),
                ),
              ],
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < week.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: _DayChip(
                    date: week[i],
                    selected: _sameDay(week[i], selected),
                    onTap: () => onPick(week[i]),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayChip extends ConsumerWidget {
  final DateTime date;
  final bool selected;
  final VoidCallback onTap;
  const _DayChip({required this.date, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    // Dot logic: ask the API if this day has classes. To avoid a flood of
    // requests, we just show a dot for every day except Sunday in the seeded
    // schedule. A future iteration can fetch a month-level summary.
    final hasClasses = date.weekday != DateTime.sunday;
    const dows = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final dow = dows[(date.weekday + 6) % 7];

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(0, 9, 0, 7),
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          color: selected ? y.primary : y.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Colors.transparent : y.border,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              dow,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: (selected ? y.onPrimary : y.text)
                    .withValues(alpha: selected ? 0.8 : 0.55),
                height: 1.0,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: selected ? y.onPrimary : y.text,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: hasClasses
                    ? (selected ? y.onPrimary : y.primary)
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClassList extends StatelessWidget {
  final List<ClassRow> rows;
  final VoidCallback onBookingChanged;
  const _ClassList({required this.rows, required this.onBookingChanged});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _ClassListRow(
        row: rows[i],
        onTap: () async {
          final result = await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            barrierColor: const Color(0x66100A05),
            builder: (_) => BookingSheet(classRow: rows[i]),
          );
          if (result == true) onBookingChanged();
        },
      ),
    );
  }
}

class _ClassListRow extends StatelessWidget {
  final ClassRow row;
  final VoidCallback onTap;
  const _ClassListRow({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final localStart = row.startsAt.toLocal();
    final timeLabel = '${localStart.hour}:${localStart.minute.toString().padLeft(2, '0')}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    timeLabel,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: y.text,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${row.durationMinutes} min',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                      height: 1.0,
                    ),
                  ),
                ],
              ),
            ),
            Container(width: 1, height: 40, color: y.border),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      YAvatar(name: row.instructorName, photoUrl: row.instructorPhotoUrl, size: 20),
                      const SizedBox(width: 6),
                      Flexible(
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
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _stateColumn(context),
          ],
        ),
      ),
    );
  }

  Widget _stateColumn(BuildContext context) {
    final y = context.yoga;
    switch (row.bookingState) {
      case BookingState.booked:
        return const YChip(
          kind: YChipKind.booked,
          label: 'Booked',
          leadingCheck: true,
        );
      case BookingState.full:
        final fullLabel = row.waitlistCount > 0
            ? 'Full · ${row.waitlistCount} waiting'
            : 'Full';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            YChip(kind: YChipKind.full, label: fullLabel),
            const SizedBox(height: 5),
            Text(
              'Join waitlist',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: y.primary,
              ),
            ),
          ],
        );
      case BookingState.available:
        final spots = row.spotsLeft;
        final showHint = spots > 0 && spots <= 3;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            YButton(label: 'Book', small: true, onTap: onTap),
            if (showHint) ...[
              const SizedBox(height: 5),
              Text(
                '$spots spots left',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            ],
          ],
        );
    }
  }
}

class _EmptyDay extends StatelessWidget {
  final DateTime day;
  final ValueChanged<DateTime>? onJumpTo;
  const _EmptyDay({required this.day, this.onJumpTo});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const dowFull = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final label = '${dowFull[(day.weekday + 6) % 7]} ${day.day}';
    final nextDay = day.add(const Duration(days: 1));
    const dowShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final nextLabel =
        '${dowShort[(nextDay.weekday + 6) % 7]} ${nextDay.day}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
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
            child: Icon(Icons.access_time_rounded, size: 24, color: y.muted),
          ),
          const SizedBox(height: 14),
          Text(
            'A rest day at the studio',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: y.text,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'No classes scheduled for $label.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          YButton(
            label: 'Next classes · $nextLabel →',
            variant: YButtonVariant.soft,
            small: true,
            onTap: onJumpTo == null ? null : () => onJumpTo!(nextDay),
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _LoadError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text("Can't load classes",
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: y.text)),
          const SizedBox(height: 6),
          Text('$error',
              textAlign: TextAlign.center,
              style: TextStyle(color: y.muted, fontSize: 12.5)),
          const SizedBox(height: 16),
          YButton(label: 'Retry', small: true, onTap: onRetry),
        ],
      ),
    );
  }
}
