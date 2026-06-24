// Desktop Book — two-column layout with a persistent right-hand detail panel.
//
// Selecting a class row populates the panel instead of opening a bottom sheet.
// Panel content reuses the booking-sheet UX (PAY WITH, +1 toggle, waitlist,
// cancel) — just embedded in a surface card rather than a sheet.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import '../../api/api_error.dart';
import '../booking_sheet.dart' show BookingSheet;
import '../chat_screen.dart';

class DesktopBook extends ConsumerStatefulWidget {
  const DesktopBook({super.key});

  @override
  ConsumerState<DesktopBook> createState() => _DesktopBookState();
}

enum _DayView { sections, timeline }

class _DesktopBookState extends ConsumerState<DesktopBook> {
  late DateTime _selected;
  int _tab = 0;
  ClassRow? _activeRow;
  late Future<List<ClassRow>> _classes;
  _DayView _view = _DayView.sections;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _selected = DateTime(n.year, n.month, n.day);
    _classes = _fetch(_selected);
  }

  Future<List<ClassRow>> _fetch(DateTime day) {
    return ref.read(apiClientProvider).classesForDay(day);
  }

  void _pick(DateTime d) {
    setState(() {
      _selected = d;
      _classes = _fetch(d);
      _activeRow = null;
    });
  }

  void _reload() {
    setState(() {
      _classes = _fetch(_selected);
      _activeRow = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
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
            SizedBox(
              width: 280,
              child: _DesktopTabs(
                tab: _tab,
                onTab: (i) => setState(() => _tab = i),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Expanded(
          child: _tab == 0
              ? _DesktopBookBody(
                  day: _selected,
                  classes: _classes,
                  active: _activeRow,
                  view: _view,
                  onPickDay: _pick,
                  onPickView: (v) => setState(() => _view = v),
                  onPickRow: (r) => setState(() => _activeRow = r),
                  onReload: _reload,
                )
              : _EnrollmentsHint(),
        ),
      ],
    );
  }
}

class _DesktopTabs extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  const _DesktopTabs({required this.tab, required this.onTab});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget btn(String label, int idx) {
      final on = tab == idx;
      return Expanded(
        child: GestureDetector(
          onTap: () => onTab(idx),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: on ? y.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(y.radiusChip),
              border: Border.all(
                color: on ? y.border : Colors.transparent,
              ),
              boxShadow: on ? y.shadow : null,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: on ? y.text : y.muted,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip),
      ),
      child: Row(
        children: [
          btn('Classes', 0),
          btn('Enrollments', 1),
        ],
      ),
    );
  }
}

class _EnrollmentsHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Text(
        'Enrollments tab is mobile-only for now — try at narrower viewport.',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: y.muted,
        ),
      ),
    );
  }
}

class _DesktopBookBody extends StatelessWidget {
  final DateTime day;
  final Future<List<ClassRow>> classes;
  final ClassRow? active;
  final _DayView view;
  final void Function(DateTime) onPickDay;
  final void Function(_DayView) onPickView;
  final void Function(ClassRow) onPickRow;
  final VoidCallback onReload;
  const _DesktopBookBody({
    required this.day,
    required this.classes,
    required this.active,
    required this.view,
    required this.onPickDay,
    required this.onPickView,
    required this.onPickRow,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ClassRow>>(
      future: classes,
      builder: (context, snap) {
        final rows = snap.data ?? const <ClassRow>[];
        final loading = snap.connectionState != ConnectionState.done;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 16,
              child: _LeftColumn(
                day: day,
                rows: rows,
                active: active,
                loading: loading,
                view: view,
                onPickDay: onPickDay,
                onPickView: onPickView,
                onPickRow: onPickRow,
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              flex: 10,
              child: _DockedDetailPanel(
                active: active,
                onBookingChanged: onReload,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LeftColumn extends StatelessWidget {
  final DateTime day;
  final List<ClassRow> rows;
  final ClassRow? active;
  final bool loading;
  final _DayView view;
  final void Function(DateTime) onPickDay;
  final void Function(_DayView) onPickView;
  final void Function(ClassRow) onPickRow;
  const _LeftColumn({
    required this.day,
    required this.rows,
    required this.active,
    required this.loading,
    required this.view,
    required this.onPickDay,
    required this.onPickView,
    required this.onPickRow,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Use the same shape as the mobile day strip without copy-pasting it.
    final offset = (day.weekday + 6) % 7;
    final monday = DateTime(day.year, day.month, day.day - offset);
    final week = List.generate(7, (i) => monday.add(Duration(days: i)));
    const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    final monthLabel = '${months[day.month - 1]} ${day.year}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
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
                onTap: () => onPickDay(monday.subtract(const Duration(days: 7))),
                child: Icon(Icons.chevron_left, size: 22, color: y.muted),
              ),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: () => onPickDay(monday.add(const Duration(days: 7))),
                child: Icon(Icons.chevron_right, size: 22, color: y.muted),
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
                  selected: _sameDay(week[i], day),
                  onTap: () => onPickDay(week[i]),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        _DayViewPill(view: view, onChanged: onPickView),
        const SizedBox(height: 14),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (rows.isEmpty)
          _EmptyDay(day: day)
        else if (view == _DayView.sections)
          _SectionsLayout(rows: rows, active: active, onPickRow: onPickRow)
        else
          _TimelineLayout(rows: rows, active: active, onPickRow: onPickRow),
      ],
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Small Sections/Timeline pill — twin of the mobile BookScreen control.
class _DayViewPill extends StatelessWidget {
  final _DayView view;
  final ValueChanged<_DayView> onChanged;
  const _DayViewPill({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget seg(_DayView v, IconData icon, String label) {
      final active = v == view;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: active ? y.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(y.radiusChip),
              border: Border.all(
                color: active ? y.border : Colors.transparent,
              ),
              boxShadow: active ? y.shadow : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: active ? y.text : y.muted),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: active ? y.text : y.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip),
      ),
      child: Row(
        children: [
          seg(_DayView.sections, Icons.view_agenda_outlined, 'Sections'),
          const SizedBox(width: 4),
          seg(_DayView.timeline, Icons.schedule_rounded, 'Timeline'),
        ],
      ),
    );
  }
}

/// Time-of-day grouping (Morning <12, Afternoon 12-17, Evening 17+) —
/// only buckets with classes render. Mirrors the mobile layout.
class _SectionsLayout extends StatelessWidget {
  final List<ClassRow> rows;
  final ClassRow? active;
  final void Function(ClassRow) onPickRow;
  const _SectionsLayout({
    required this.rows,
    required this.active,
    required this.onPickRow,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final morning = <ClassRow>[];
    final afternoon = <ClassRow>[];
    final evening = <ClassRow>[];
    for (final r in rows) {
      final h = r.startsAt.toLocal().hour;
      if (h < 12) {
        morning.add(r);
      } else if (h < 17) {
        afternoon.add(r);
      } else {
        evening.add(r);
      }
    }
    final groups = <(String, List<ClassRow>)>[
      ('MORNING', morning),
      ('AFTERNOON', afternoon),
      ('EVENING', evening),
    ].where((g) => g.$2.isNotEmpty).toList();

    Widget head(String label) => Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: y.muted,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Container(height: 1, color: y.border)),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var gi = 0; gi < groups.length; gi++) ...[
          if (gi > 0) const SizedBox(height: 18),
          head(groups[gi].$1),
          const SizedBox(height: 10),
          for (var i = 0; i < groups[gi].$2.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _ClassRow(
              row: groups[gi].$2[i],
              active: active?.id == groups[gi].$2[i].id,
              onTap: () => onPickRow(groups[gi].$2[i]),
            ),
          ],
        ],
      ],
    );
  }
}

/// Hour-ruler layout — Y-axis is the hour, class cards anchored at their
/// start hour, empty hours render as a label + thin divider.
class _TimelineLayout extends StatelessWidget {
  final List<ClassRow> rows;
  final ClassRow? active;
  final void Function(ClassRow) onPickRow;
  const _TimelineLayout({
    required this.rows,
    required this.active,
    required this.onPickRow,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final byHour = <int, List<ClassRow>>{};
    for (final r in rows) {
      final h = r.startsAt.toLocal().hour;
      (byHour[h] ??= []).add(r);
    }
    final firstHour = rows
        .map((r) => r.startsAt.toLocal().hour)
        .reduce((a, b) => a < b ? a : b);
    final lastHour = rows.map((r) {
      final end = r.endsAt.toLocal();
      return end.minute == 0 ? end.hour - 1 : end.hour;
    }).reduce((a, b) => a > b ? a : b);
    final hours = [for (var h = firstHour; h <= lastHour; h++) h];

    String hourLabel(int h) =>
        '${h.toString().padLeft(2, '0')}:00';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < hours.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 48,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      hourLabel(hours[i]),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: y.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                Container(width: 1, color: y.border),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                        bottom: i == hours.length - 1 ? 0 : 12),
                    child: (byHour[hours[i]] == null)
                        ? const SizedBox(height: 28)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var ci = 0;
                                  ci < byHour[hours[i]]!.length;
                                  ci++) ...[
                                if (ci > 0) const SizedBox(height: 8),
                                _ClassRow(
                                  row: byHour[hours[i]]![ci],
                                  active: active?.id ==
                                      byHour[hours[i]]![ci].id,
                                  onTap: () =>
                                      onPickRow(byHour[hours[i]]![ci]),
                                ),
                              ],
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DayChip extends StatelessWidget {
  final DateTime date;
  final bool selected;
  final VoidCallback onTap;
  const _DayChip({
    required this.date,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const dows = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final dow = dows[(date.weekday + 6) % 7];
    final hasClasses = date.weekday != DateTime.sunday;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
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
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: (selected ? y.onPrimary : y.text)
                    .withValues(alpha: selected ? 0.8 : 0.55),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 18,
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

class _ClassRow extends StatelessWidget {
  final ClassRow row;
  final bool active;
  final VoidCallback onTap;
  const _ClassRow({
    required this.row,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = row.startsAt.toLocal();
    final hh = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(
            color: active ? y.primary : y.border,
            width: active ? 1.5 : 1,
          ),
          boxShadow: active ? y.shadow : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 60,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hh,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: y.text,
                    ),
                  ),
                  Text(
                    '${row.durationMinutes} min',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
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
            if (active)
              const YChip(kind: YChipKind.accent, label: 'Selected')
            else
              _StateColumn(row: row),
          ],
        ),
      ),
    );
  }
}

class _StateColumn extends StatelessWidget {
  final ClassRow row;
  const _StateColumn({required this.row});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    switch (row.bookingState) {
      case BookingState.booked:
        return const YChip(
          kind: YChipKind.booked,
          label: 'Booked',
          leadingCheck: true,
        );
      case BookingState.full:
        return YChip(
          kind: YChipKind.full,
          label: 'Full · ${row.bookedCount}/${row.capacity}',
        );
      case BookingState.available:
        return Text(
          '${row.spotsLeft} of ${row.capacity}',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        );
    }
  }
}

class _EmptyDay extends StatelessWidget {
  final DateTime day;
  const _EmptyDay({required this.day});

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
            child: Icon(Icons.access_time_rounded, size: 24, color: y.muted),
          ),
          const SizedBox(height: 14),
          Text(
            'A rest day at the studio',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: y.text,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'No classes scheduled for this day.',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Right-hand persistent detail panel — replaces the mobile booking sheet.
/// Uses the same flows behind the scenes (eligibleEntitlements, createBooking,
/// joinWaitlist, cancelBooking) by reusing the mobile [BookingSheet] widget
/// inside a styled card.
class _DockedDetailPanel extends StatelessWidget {
  final ClassRow? active;
  final VoidCallback onBookingChanged;
  const _DockedDetailPanel({
    required this.active,
    required this.onBookingChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: active == null
          ? _EmptyPanel()
          : _DockedSheetWrapper(
              key: ValueKey(active!.id),
              classRow: active!,
              onChanged: onBookingChanged,
            ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: y.surface2,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.east, size: 22, color: y.muted),
          ),
          const SizedBox(height: 14),
          Text(
            'Pick a class',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: y.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Tap a row on the left and we'll book it from here.",
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

/// Render the mobile BookingSheet inside the docked panel. It pops itself
/// with `Navigator.pop(true)` on success — we intercept by wrapping in a
/// PopScope to feed [onChanged] instead of unmounting.
///
/// When the caller is booked / on the waitlist for the class, the panel
/// switches to a tabbed layout: a "Class" tab carrying the booking sheet
/// and a "Chat" tab embedding the class group chat. Mobile keeps the
/// in-sheet chat row that pushes a separate page; on desktop the tab
/// replaces it (BookingSheet suppresses its inline chat row whenever
/// onClose is non-null, see booking_sheet.dart).
class _DockedSheetWrapper extends ConsumerStatefulWidget {
  final ClassRow classRow;
  final VoidCallback onChanged;
  const _DockedSheetWrapper({
    super.key,
    required this.classRow,
    required this.onChanged,
  });

  @override
  ConsumerState<_DockedSheetWrapper> createState() =>
      _DockedSheetWrapperState();
}

class _DockedSheetWrapperState extends ConsumerState<_DockedSheetWrapper>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  bool get _eligible =>
      widget.classRow.bookingState == BookingState.booked ||
      widget.classRow.waitlistPosition != null;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void didUpdateWidget(covariant _DockedSheetWrapper old) {
    super.didUpdateWidget(old);
    // A book / waitlist mutation flips eligibility on; reset to the Class
    // tab on a class swap so the new selection lands on details, not
    // mid-conversation from the previous class.
    if (old.classRow.id != widget.classRow.id) {
      _tab.index = 0;
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = BookingSheet(
      classRow: widget.classRow,
      onClose: widget.onChanged,
    );
    if (!_eligible) {
      return sheet;
    }
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: _tab,
          labelColor: y.text,
          unselectedLabelColor: y.muted,
          indicatorColor: y.primary,
          indicatorWeight: 2,
          tabs: const [
            Tab(text: 'Class'),
            Tab(text: 'Chat'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              sheet,
              _DockedChatPanel(classId: widget.classRow.id),
            ],
          ),
        ),
      ],
    );
  }
}

/// Resolves (or lazily creates) the class chat then hands off to the
/// standard ChatThreadScreen embedded inside the docked panel. Same
/// pattern as _RosterChatPanel in admin_roster_screen.dart — kept local
/// rather than shared so each screen can tune the empty/loading copy.
class _DockedChatPanel extends ConsumerStatefulWidget {
  final String classId;
  const _DockedChatPanel({required this.classId});

  @override
  ConsumerState<_DockedChatPanel> createState() => _DockedChatPanelState();
}

class _DockedChatPanelState extends ConsumerState<_DockedChatPanel> {
  late Future<Conversation> _conv;

  @override
  void initState() {
    super.initState();
    _conv = ref.read(apiClientProvider).openClassChat(widget.classId);
  }

  @override
  void didUpdateWidget(covariant _DockedChatPanel old) {
    super.didUpdateWidget(old);
    if (old.classId != widget.classId) {
      _conv = ref.read(apiClientProvider).openClassChat(widget.classId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final me = ref.watch(bootstrapProvider).asData?.value.me;
    return FutureBuilder<Conversation>(
      future: _conv,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }
        if (snap.hasError || me == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                snap.hasError
                    ? "Can't open chat: ${ApiError.fromAny(snap.error!).message}"
                    : 'Loading…',
                style: TextStyle(color: y.muted, fontSize: 13),
              ),
            ),
          );
        }
        final conv = snap.data!;
        return ChatThreadScreen(
          conversationId: conv.id,
          initialConversation: conv,
          me: me,
          backgroundColor: y.surface,
        );
      },
    );
  }
}
