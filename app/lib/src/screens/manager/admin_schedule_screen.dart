// Manager Schedule — Week view.
// Mirrors yoga-admin-a.jsx KSchedule. 7-column grid of compact class blocks,
// primarySoft for yoga / accentSoft for reformer & courses, with a 3 px
// left border in the solid color.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/polling.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart';
import 'manager_shell.dart';

/// Parse a `#rrggbb` room colour into a [Color], or null when the input
/// is missing / malformed. Mirrors the helper in book_screen.dart —
/// kept duplicated rather than promoted because the schedule screen is
/// the only manager-side consumer and a shared utils file isn't worth
/// the indirection yet.
Color? _parseRoomAccent(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (!RegExp(r'^#[0-9a-f]{6}$').hasMatch(s)) return null;
  return Color(int.parse(s.substring(1), radix: 16) | 0xFF000000);
}

class AdminScheduleScreen extends ConsumerStatefulWidget {
  final void Function(String classId)? onOpenRoster;
  const AdminScheduleScreen({super.key, this.onOpenRoster});

  @override
  ConsumerState<AdminScheduleScreen> createState() =>
      _AdminScheduleScreenState();
}

const double _kNarrow = 700;

enum _ScheduleView { week, day, sections, timeline }

/// Cache key for the schedule fetch. We can't use a raw DateTime because
/// Riverpod family keys are compared by `==` and DateTime equality is
/// microsecond-exact — two `DateTime.now()`-derived "today" values
/// rarely match, blowing the cache on every rebuild. The string form
/// `YYYY-MM-DD:scope` collapses to one entry per unique day+scope.
String _scheduleKey(DateTime start, bool multiDay) {
  final yyyy = start.year.toString().padLeft(4, '0');
  final mm = start.month.toString().padLeft(2, '0');
  final dd = start.day.toString().padLeft(2, '0');
  return '${multiDay ? 'wk' : 'day'}:$yyyy-$mm-$dd';
}

/// Session-scoped schedule cache — non-autoDispose so sidebar tab swaps
/// don't blow it away. Each (window-start, scope) combo gets its own
/// entry, paged in as the manager chevrons forward/back. Combined with
/// the postFrame invalidate in initState, navigation back to Schedule
/// renders the cached classes instantly and refreshes silently behind
/// the scenes.
final adminScheduleProvider =
    FutureProvider.family<List<ClassRow>, String>((ref, key) async {
  // Key format: "wk:YYYY-MM-DD" or "day:YYYY-MM-DD".
  final parts = key.split(':');
  final multiDay = parts[0] == 'wk';
  final date = DateTime.parse(parts[1]);
  final api = ref.watch(apiClientProvider);
  if (multiDay) {
    return api.adminClasses(from: date, to: date.add(const Duration(days: 7)));
  }
  return api.adminClasses(from: date, to: date.add(const Duration(days: 1)));
});

class _AdminScheduleScreenState extends ConsumerState<AdminScheduleScreen> {
  /// First day rendered in the Week grid. The 7-column strip is
  /// `[_weekStart … _weekStart + 6 days]`. On first load we pin it to
  /// (today − 1) so today sits in column 2 — yesterday on the left for
  /// context, the next six days to the right. Chevrons then page the
  /// window by 7 days at a time without re-snapping to a Mon-Sun
  /// alignment, matching the rolling-window pattern the student Book
  /// screen uses.
  late DateTime _weekStart;
  late DateTime _day;
  _ScheduleView _view = _ScheduleView.week;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _weekStart = _addDays(today, -1);
    _day = today;
    // Initial silent refresh handled by the PollingRefresh wrapper in
    // build — kept here as a fallback for the very first frame in case
    // the wrapper hasn't mounted yet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(adminScheduleProvider(_currentKey()));
    });
  }

  /// True for views that span 7 days (everything except Day/Rooms). The
  /// fetch range + the date pager step both branch on this — multi-day
  /// views move the 7-day window, the single-day view moves one day.
  bool get _isMultiDay => _view != _ScheduleView.day;

  String _currentKey() =>
      _scheduleKey(_isMultiDay ? _weekStart : _day, _isMultiDay);

  void _setView(_ScheduleView v) {
    setState(() => _view = v);
  }

  void _pageWeeks(int delta) {
    setState(() {
      if (_isMultiDay) {
        _weekStart = _addDays(_weekStart, 7 * delta);
      } else {
        // Only the single-day Rooms view pages by one day at a time.
        _day = _addDays(_day, delta);
      }
    });
  }

  void _goToday() {
    setState(() {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      _weekStart = _addDays(today, -1);
      _day = today;
    });
  }

  // Day-field arithmetic — DST transitions can make Duration(days: 1)
  // land on 23:00 the previous day, which then breaks `isSameDay`
  // comparisons further down. Building the date from year/month/day+N
  // sidesteps the issue.
  static DateTime _addDays(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _kNarrow;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;
        // On mobile the multi-day calendar grids (Week/Sections/Timeline)
        // can't fit 7 columns side-by-side; force the single-day Rooms
        // view. The user can still switch back to a multi-day mode on a
        // wider window.
        if (isNarrow && _isMultiDay) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _setView(_ScheduleView.day);
          });
        }
        final showsMultiDay = _isMultiDay && !isNarrow;
        final weekEnd = _addDays(_weekStart, 6);
        final label = showsMultiDay
            ? '${_short(_weekStart)} – ${_short(weekEnd)}'
            : _longDay(_day);
        final classes = ref.watch(adminScheduleProvider(_currentKey()));
        return PollingRefresh(
          surface: PollingSurface.schedule,
          onPoll: () =>
              ref.invalidate(adminScheduleProvider(_currentKey())),
          child: Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: Builder(
            builder: (context) {
              final rows = classes.asData?.value ?? const <ClassRow>[];
              final rooms = <String>{for (final r in rows) r.roomName};
              final classCount = rows.length;
              final roomCount = rooms.length;
              // Week view reads "X classes across N rooms" — the "across"
              // phrasing tracks the design spec for a multi-day summary.
              // Single-day views (Day / Rooms) use the simpler "·"
              // separator since the layout already groups by room.
              final subText = rows.isEmpty
                  ? label
                  : showsMultiDay
                      ? '$label · $classCount class${classCount == 1 ? '' : 'es'}'
                          ' across $roomCount room${roomCount == 1 ? '' : 's'}'
                      : '$label · $classCount class${classCount == 1 ? '' : 'es'}'
                          ' · $roomCount room${roomCount == 1 ? '' : 's'}';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ManagerPageHeader(
                    title: 'Schedule',
                    sub: subText,
                    actions: [
                      // Only "+ New class" lives in the page header now —
                      // it's the one creation action and doesn't pair with
                      // the per-view controls below.
                      YButton(
                        label: isNarrow ? '+ New' : '+ New class',
                        small: true,
                        onTap: () async {
                          final newId = await showNewClassDialog(context);
                          if (newId != null && mounted) {
                            ref.invalidate(
                                adminScheduleProvider(_currentKey()));
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Same-row controls: layout picker left, navigation
                  // right. Pairing them makes the visual relationship
                  // explicit — both are "how am I looking at the
                  // schedule right now?" controls, so they share a row.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _LayoutPicker(
                          view: _view,
                          onChange: _setView,
                          allowMultiDay: !isNarrow,
                        ),
                      ),
                      const SizedBox(width: 16),
                      YButton(
                        label: 'Prev',
                        variant: YButtonVariant.outline,
                        small: true,
                        onTap: () => _pageWeeks(-1),
                      ),
                      const SizedBox(width: 6),
                      YButton(
                        label: 'Next',
                        variant: YButtonVariant.outline,
                        small: true,
                        onTap: () => _pageWeeks(1),
                      ),
                      const SizedBox(width: 6),
                      YButton(
                        label: 'Today',
                        variant: YButtonVariant.outline,
                        small: true,
                        onTap: _goToday,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Builder(
                      builder: (_) {
                        // First-ever load with no cache → spinner.
                        // Subsequent re-fetches keep the cached rows
                        // visible (asData?.value pattern above) and
                        // skip the spinner.
                        if (classes.isLoading && rows.isEmpty) {
                          return const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                        }
                        if (classes.hasError && rows.isEmpty) {
                          return Center(
                            child: Text(
                              "Can't load schedule: ${classes.error}",
                              style: TextStyle(color: y.muted),
                            ),
                          );
                        }
                        Future<void> onBlockTap(ClassRow row) async {
                          await showClassActionsSheet(
                            context: context,
                            classRow: row,
                            onOpenRoster: () {
                              widget.onOpenRoster?.call(row.id);
                            },
                          );
                          if (mounted) {
                            ref.invalidate(
                                adminScheduleProvider(_currentKey()));
                          }
                        }
                        if (isNarrow && _view == _ScheduleView.day) {
                          // On mobile the per-room lanes view is too
                          // wide; fall back to a chronological list.
                          return _MobileDayList(
                            day: _day,
                            rows: rows,
                            onTap: onBlockTap,
                          );
                        }
                        Widget body;
                        switch (_view) {
                          case _ScheduleView.week:
                            body = _WeekGrid(
                              weekStart: _weekStart,
                              rows: rows,
                              onTap: onBlockTap,
                            );
                            break;
                          case _ScheduleView.day:
                            body = _DayLanes(
                              day: _day,
                              rows: rows,
                              onTap: onBlockTap,
                            );
                            break;
                          case _ScheduleView.sections:
                            body = _SectionsWeek(
                              weekStart: _weekStart,
                              rows: rows,
                              onTap: onBlockTap,
                            );
                            break;
                          case _ScheduleView.timeline:
                            body = _TimelineWeek(
                              weekStart: _weekStart,
                              rows: rows,
                              onTap: onBlockTap,
                            );
                            break;
                        }
                        return ManagerCard(
                          padding: const EdgeInsets.all(14),
                          fill: true,
                          child: body,
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        );
      },
    );
  }

  static String _longDay(DateTime d) {
    const dow = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dow[(d.weekday + 6) % 7]} ${d.day} ${mons[d.month - 1]}';
  }

  // _mondayOf was used when the week strip auto-snapped to Mon–Sun;
  // the new rolling-window pattern (init = today − 1, chevrons step 7)
  // doesn't need it. Kept as a static helper in case a future "Snap to
  // calendar week" affordance wants it back.
  // ignore: unused_element
  static DateTime _mondayOf(DateTime now) {
    final d = DateTime(now.year, now.month, now.day);
    final offset = (d.weekday + 6) % 7; // Mon=0
    return d.subtract(Duration(days: offset));
  }

  static String _short(DateTime d) {
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                   'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${mons[d.month - 1]}';
  }
}

/// Layout picker — distinct from the date pager. Lives on its own row
/// under the page header with a "LAYOUT" label + an icon for each
/// segment so the row visually reads as "pick a way to render the
/// schedule" rather than "navigate the schedule". Multi-day layouts
/// share the same 7-day window; the single-day "Rooms" view is the
/// outlier (renders one day with per-room lanes).
class _LayoutPicker extends StatelessWidget {
  final _ScheduleView view;
  final ValueChanged<_ScheduleView> onChange;
  /// Mobile drops the multi-day layouts — 7 columns can't fit a phone.
  final bool allowMultiDay;
  const _LayoutPicker({
    required this.view,
    required this.onChange,
    this.allowMultiDay = true,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget btn(String label, IconData icon, _ScheduleView v) {
      final on = view == v;
      return GestureDetector(
        onTap: () => onChange(v),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
          decoration: BoxDecoration(
            color: on ? y.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: on ? y.border : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: on ? y.text : y.muted),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: on ? y.text : y.muted,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        Text(
          'LAYOUT',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
            color: y.muted,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: y.surface2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  if (allowMultiDay) ...[
                    btn('Calendar', Icons.calendar_view_week_rounded,
                        _ScheduleView.week),
                    const SizedBox(width: 4),
                    btn('Sections', Icons.view_agenda_outlined,
                        _ScheduleView.sections),
                    const SizedBox(width: 4),
                    btn('Timeline', Icons.schedule_rounded,
                        _ScheduleView.timeline),
                    const SizedBox(width: 4),
                  ],
                  btn('Rooms', Icons.view_column_outlined,
                      _ScheduleView.day),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================== DAY LANES ==============================

const double _dayStartHour = 7.0;
const double _dayEndHour = 21.0;
// Pixels per hour in the day-lane (Rooms) view. Bumped from 56→64 so a
// 60-min class block has enough room to carry title + meta + the
// occupancy bar without LayoutBuilder having to drop pieces. Trade-off
// is the day's vertical scroll area grows by ~14%, which is fine — the
// view already scrolls.
const double _hourHeight = 64.0;
const double _gutterWidth = 52.0;

class _DayLanes extends StatelessWidget {
  final DateTime day;
  final List<ClassRow> rows;
  final void Function(ClassRow)? onTap;
  const _DayLanes({required this.day, required this.rows, this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Order rooms by first appearance — stable per day.
    final rooms = <String>[];
    for (final r in rows) {
      if (!rooms.contains(r.roomName)) rooms.add(r.roomName);
    }
    if (rooms.isEmpty) {
      return Center(
        child: Text(
          'No classes scheduled for this day.',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      );
    }
    final laneHeight = (_dayEndHour - _dayStartHour) * _hourHeight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Room header row.
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              const SizedBox(width: _gutterWidth),
              for (final room in rooms) ...[
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      room.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: y.muted,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Lane grid — scrollable vertically.
        Expanded(
          child: SingleChildScrollView(
            child: SizedBox(
              height: laneHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: _gutterWidth,
                    child: _TimeGutter(),
                  ),
                  for (var i = 0; i < rooms.length; i++)
                    Expanded(
                      child: _RoomLane(
                        rows: rows.where((r) => r.roomName == rooms[i]).toList(),
                        showLeftBorder: true,
                        onTap: onTap,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TimeGutter extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Stack(
      children: [
        for (var h = _dayStartHour.toInt(); h <= _dayEndHour.toInt(); h++)
          Positioned(
            top: (h - _dayStartHour) * _hourHeight - 7,
            left: 0,
            right: 0,
            child: Text(
              '$h:00',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: y.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }
}

class _RoomLane extends StatelessWidget {
  final List<ClassRow> rows;
  final bool showLeftBorder;
  final void Function(ClassRow)? onTap;
  const _RoomLane({
    required this.rows,
    required this.showLeftBorder,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: showLeftBorder ? y.border : Colors.transparent),
        ),
      ),
      child: Stack(
        children: [
          // Hour gridlines.
          for (var h = _dayStartHour.toInt(); h <= _dayEndHour.toInt(); h++)
            Positioned(
              top: (h - _dayStartHour) * _hourHeight,
              left: 0,
              right: 0,
              child: Container(
                height: 1,
                color: y.border.withValues(alpha: 0.55),
              ),
            ),
          // Class blocks.
          for (final r in rows)
            _DayBlock(row: r, onTap: onTap == null ? null : () => onTap!(r)),
        ],
      ),
    );
  }
}

class _DayBlock extends StatelessWidget {
  final ClassRow row;
  final VoidCallback? onTap;
  const _DayBlock({required this.row, this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final start = row.startsAt.toLocal();
    final end = row.endsAt.toLocal();
    final from = start.hour + start.minute / 60.0;
    final to = end.hour + end.minute / 60.0;
    final top = (from - _dayStartHour) * _hourHeight;
    final height = ((to - from) * _hourHeight - 5).clamp(20.0, 1000.0);
    final isReformer = row.discipline == 'reformer';
    final bg = isReformer ? y.accentSoft : y.primarySoft;
    final edge = isReformer ? y.accent : y.primary;
    final isFull = row.bookingState == BookingState.full;
    final hh = '${start.hour}:${start.minute.toString().padLeft(2, '0')}';
    final endHH = '${end.hour}:${end.minute.toString().padLeft(2, '0')}';
    return Positioned(
      top: top,
      left: 4,
      right: 4,
      height: height,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border(left: BorderSide(color: edge, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.title,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                      height: 1.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isFull)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: y.borderStrong),
                    ),
                    child: Text(
                      'FULL',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        color: y.muted,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '$hh – $endHH · ${row.instructorName}',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        ),
      ),
    );
  }
}


/// Time-anchored week calendar. Each day column is a fixed-height canvas
/// (one row per hour); class blocks are absolutely positioned by their
/// start time and sized by their duration — same shape as Apple Calendar
/// / Google Calendar week views. A shared time gutter on the left labels
/// the hours so the eye can read every column at once.
class _WeekGrid extends StatelessWidget {
  /// Start of the visible 7-day window. Used to be Monday-aligned; under
  /// the rolling-window scheme it's today − 1 on init then steps by 7
  /// from the user's chevrons, so the name is just "first column".
  final DateTime weekStart;
  final List<ClassRow> rows;
  final void Function(ClassRow)? onTap;
  const _WeekGrid({required this.weekStart, required this.rows, this.onTap});

  // 56 px per hour reads well on desktop without making a typical 8-21
  // schedule require excessive vertical scrolling. The class block keeps
  // a minimum so a tiny 30-min class doesn't shrink below tap-comfort.
  // Matches _hourHeight in the day-lane view above so both grids use
  // the same scale. See that comment for the bump rationale.
  static const double _hourPx = 64;
  static const double _minBlockPx = 36;
  // Padding inside each day column so blocks don't kiss the day divider.
  static const double _colInnerPad = 4;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final byDay = <int, List<ClassRow>>{};
    for (final r in rows) {
      final local = r.startsAt.toLocal();
      // Day-field arithmetic against the window start so DST transition
      // weeks don't bucket a Sunday class into Monday.
      final classDay = DateTime(local.year, local.month, local.day);
      final base = DateTime(weekStart.year, weekStart.month, weekStart.day);
      final idx = classDay.difference(base).inDays;
      if (idx < 0 || idx > 6) continue;
      byDay.putIfAbsent(idx, () => []).add(r);
    }

    // Compute the visible hour range — clamp to a sane studio default
    // even on empty weeks so the grid doesn't collapse into nothing.
    int firstHour = 24;
    int lastHour = 0;
    for (final r in rows) {
      final s = r.startsAt.toLocal();
      final e = r.endsAt.toLocal();
      if (s.hour < firstHour) firstHour = s.hour;
      final endRow = (e.minute == 0) ? e.hour - 1 : e.hour;
      if (endRow > lastHour) lastHour = endRow;
    }
    if (rows.isEmpty) {
      firstHour = 8;
      lastHour = 20;
    }
    // Pad one hour above/below for breathing room.
    firstHour = (firstHour - 1).clamp(0, 23);
    lastHour = (lastHour + 1).clamp(firstHour, 23);
    final hours = [for (var h = firstHour; h <= lastHour; h++) h];
    final totalHeight = hours.length * _hourPx;

    return SingleChildScrollView(
      child: SizedBox(
        height: totalHeight + 30, // + day-header strip
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _HourGutter(hours: hours, hourPx: _hourPx, topInset: 30),
            for (var i = 0; i < 7; i++)
              Expanded(
                child: _DayColumn(
                  date: DateTime(weekStart.year, weekStart.month,
                      weekStart.day + i),
                  isToday: _sameDay(
                      DateTime(weekStart.year, weekStart.month,
                          weekStart.day + i),
                      today),
                  classes: byDay[i] ?? const [],
                  firstHour: firstHour,
                  hourPx: _hourPx,
                  minBlockPx: _minBlockPx,
                  innerPad: _colInnerPad,
                  onTap: onTap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _HourGutter extends StatelessWidget {
  final List<int> hours;
  final double hourPx;
  final double topInset;
  const _HourGutter({
    required this.hours,
    required this.hourPx,
    required this.topInset,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return SizedBox(
      width: 44,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: Stack(
          children: [
            for (var i = 0; i < hours.length; i++)
              Positioned(
                left: 0,
                right: 4,
                // Subtract a few px so the label sits just below the
                // hour line rather than centred awkwardly within the slot.
                top: i * hourPx - 6,
                child: Text(
                  '${hours[i].toString().padLeft(2, '0')}:00',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: y.muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  final DateTime date;
  final bool isToday;
  final List<ClassRow> classes;
  final int firstHour;
  final double hourPx;
  final double minBlockPx;
  final double innerPad;
  final void Function(ClassRow)? onTap;
  const _DayColumn({
    required this.date,
    required this.isToday,
    required this.classes,
    required this.firstHour,
    required this.hourPx,
    required this.minBlockPx,
    required this.innerPad,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const dows = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final dow = dows[(date.weekday + 6) % 7];
    return Container(
      // Faint background tint on today's column — same surface2 we use
      // for sectioned UI elsewhere — makes "where am I in the week"
      // obvious without competing with the class cards' own colors.
      decoration: BoxDecoration(
        color: isToday ? y.primarySoft.withValues(alpha: 0.35) : null,
        border: Border(left: BorderSide(color: y.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 30px header strip — matches the SizedBox topInset above so
          // the first hour line aligns with the top of each column body.
          SizedBox(
            height: 30,
            child: Padding(
              padding: EdgeInsets.only(left: innerPad + 6, top: 6),
              child: Text(
                '$dow ${date.day}',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: isToday ? y.primary : y.muted,
                ),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                // Faint horizontal hour lines for visual time scanning.
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HourLinesPainter(
                      color: y.border,
                      hourPx: hourPx,
                    ),
                  ),
                ),
                if (classes.isEmpty)
                  Positioned(
                    left: innerPad + 6,
                    top: 8,
                    child: Text(
                      'Rest day',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: y.muted.withValues(alpha: 0.55),
                      ),
                    ),
                  )
                else
                  for (final c in classes)
                    _positionedBlock(c, context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _positionedBlock(ClassRow c, BuildContext context) {
    final start = c.startsAt.toLocal();
    final end = c.endsAt.toLocal();
    final startMinFromTop =
        ((start.hour - firstHour) * 60 + start.minute).toDouble();
    final durationMin = end.difference(start).inMinutes.toDouble();
    final top = startMinFromTop * (hourPx / 60);
    final height = (durationMin * (hourPx / 60)).clamp(minBlockPx, 999.0);
    return Positioned(
      left: innerPad,
      right: innerPad,
      top: top,
      height: height,
      child: _ClassBlock(
        row: c,
        onTap: onTap == null ? null : () => onTap!(c),
      ),
    );
  }
}

class _HourLinesPainter extends CustomPainter {
  final Color color;
  final double hourPx;
  _HourLinesPainter({required this.color, required this.hourPx});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var y = 0.0; y <= size.height + 0.5; y += hourPx) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HourLinesPainter old) =>
      old.color != color || old.hourPx != hourPx;
}

class _ClassBlock extends StatelessWidget {
  final ClassRow row;
  final VoidCallback? onTap;
  const _ClassBlock({required this.row, this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isReformer = row.discipline == 'reformer';
    final isSeries = row.isEnrollmentSession;
    final isPast = row.endsAt.toLocal().isBefore(DateTime.now());
    // Room colour drives both the left-edge accent AND a low-alpha
    // wash on the card background. When the room has no colour set we
    // fall back to the discipline-based defaults (primarySoft for yoga,
    // accentSoft for reformer, plain surface for series) so the
    // existing visual language for theme-only studios is preserved.
    final roomTint = isPast ? null : _parseRoomAccent(row.roomColor);
    final bg = roomTint != null
        // alphaBlend over the theme surface so the wash composes
        // correctly in both light + dark mode without the colour going
        // sour. 0.18 is around the threshold where the hue reads as
        // intentional without making 11.5pt text struggle.
        ? Color.alphaBlend(roomTint.withValues(alpha: 0.18), y.surface)
        : (isSeries
            ? y.surface
            : (isReformer ? y.accentSoft : y.primarySoft));
    final edge = roomTint ??
        (isSeries ? y.text : (isReformer ? y.accent : y.primary));
    final local = row.startsAt.toLocal();
    final hh = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    final roomShort = _shortRoom(row.roomName);
    // Past classes fade to a neutral grey so the eye skims past them and
    // lands on what's still upcoming. Still clickable (manager may need
    // to open the roster after the fact), just visually deprioritised.
    //
    // LayoutBuilder lets us gracefully degrade in cramped calendar cells:
    // a 50-min Reformer block at 56px/hr = 47px tall can't carry both
    // the meta line and the occupancy bar without spilling. We drop the
    // bottom-most pieces as height shrinks rather than letting the card
    // throw a `RenderFlex overflowed by N pixels` yellow stripe.
    final block = LayoutBuilder(
      builder: (context, c) {
        final h = c.maxHeight;
        // Tiered thresholds — measured against the actual rendered
        // stack height (title ~14 + meta ~12 + bar ~11 + padding 6 +
        // gaps 2 ≈ 45px). Tight enough to fit a 50-min Reformer block
        // (47px tall at 56px/hr) which is the shortest common class
        // length; anything below that genuinely doesn't have room for
        // three text lines.
        final showMeta = h >= 36;
        final showOccupancy = h >= 47;
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: isPast ? y.surface2 : bg,
              borderRadius: BorderRadius.circular(10),
              border: Border(
                left: BorderSide(
                    color: isPast ? y.border : edge, width: 3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (isSeries) ...[
                      const _SeriesTag(),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: y.text,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
                if (showMeta) ...[
                  const SizedBox(height: 1),
                  Text(
                    '$hh · ${row.instructorName.split(' ').first} · $roomShort',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
                ],
                if (showOccupancy) ...[
                  const SizedBox(height: 1),
                  // Occupancy — booked seats vs capacity. For past
                  // classes BookedCount drops as people get marked
                  // attended/no_show, so a 0/14 reading there means
                  // everyone was processed (not "nobody came"). Future
                  // classes show live demand.
                  _OccupancyBar(
                    booked: row.bookedCount,
                    capacity: row.capacity,
                    muted: isPast,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
    return isPast ? Opacity(opacity: 0.55, child: block) : block;
  }

  static String _shortRoom(String name) {
    if (name.startsWith('Room ')) {
      final n = name.substring(5);
      final cut = n.indexOf(' ');
      return 'R${cut == -1 ? n : n.substring(0, cut)}';
    }
    return name;
  }
}

/// Compact occupancy chip: "8/14" + a thin progress bar. The bar tints
/// stronger as the class fills (primary at <70%, accent at 70-99%, hot
/// at full) so the eye picks up "this class is selling out" without
/// having to parse the number.
class _OccupancyBar extends StatelessWidget {
  final int booked;
  final int capacity;
  final bool muted;
  const _OccupancyBar({
    required this.booked,
    required this.capacity,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final ratio = capacity > 0
        ? (booked / capacity).clamp(0.0, 1.0)
        : 0.0;
    Color fill;
    if (muted) {
      fill = y.muted;
    } else if (ratio >= 1.0) {
      fill = const Color(0xFFA33B2E); // full → warm-red signal
    } else if (ratio >= 0.7) {
      fill = y.accent;
    } else {
      fill = y.primary;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          '$booked/$capacity',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: y.muted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              color: y.border,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: ratio,
                child: Container(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Small inline tag — "SERIES" — that flags an enrollment session in the
/// calendar grid. Same visual weight as the OVERFLOW chip in the spec.
class _SeriesTag extends StatelessWidget {
  const _SeriesTag();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: y.text,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'SERIES',
        style: TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          color: y.background,
          letterSpacing: 0.6,
          height: 1.0,
        ),
      ),
    );
  }
}

/// 7-day Sections view: one column per day, each column groups its
/// classes under MORNING / AFTERNOON / EVENING sub-headers. The same
/// 7-day window the Week calendar uses, just re-arranged so each day's
/// time-of-day rhythm reads as the primary structure.
class _SectionsWeek extends StatelessWidget {
  final DateTime weekStart;
  final List<ClassRow> rows;
  final void Function(ClassRow)? onTap;
  const _SectionsWeek({
    required this.weekStart,
    required this.rows,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final today = DateTime.now();
    final byDay = <int, List<ClassRow>>{};
    for (final r in rows) {
      final local = r.startsAt.toLocal();
      final classDay = DateTime(local.year, local.month, local.day);
      final base =
          DateTime(weekStart.year, weekStart.month, weekStart.day);
      final idx = classDay.difference(base).inDays;
      if (idx < 0 || idx > 6) continue;
      byDay.putIfAbsent(idx, () => []).add(r);
    }
    const dows = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return SingleChildScrollView(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 7; i++) ...[
            if (i > 0) Container(width: 1, color: y.border),
            Expanded(
              child: _SectionsDayColumn(
                date: DateTime(weekStart.year, weekStart.month,
                    weekStart.day + i),
                dow: dows[(DateTime(weekStart.year, weekStart.month,
                                weekStart.day + i)
                            .weekday +
                        6) %
                    7],
                classes: byDay[i] ?? const [],
                isToday: _sameDay(
                    DateTime(weekStart.year, weekStart.month,
                        weekStart.day + i),
                    today),
                onTap: onTap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _SectionsDayColumn extends StatelessWidget {
  final DateTime date;
  final String dow;
  final List<ClassRow> classes;
  final bool isToday;
  final void Function(ClassRow)? onTap;
  const _SectionsDayColumn({
    required this.date,
    required this.dow,
    required this.classes,
    required this.isToday,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final morning = <ClassRow>[];
    final afternoon = <ClassRow>[];
    final evening = <ClassRow>[];
    for (final r in classes) {
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

    return Container(
      decoration: BoxDecoration(
        color: isToday ? y.primarySoft.withValues(alpha: 0.35) : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10, top: 4),
            child: Text(
              '$dow ${date.day}',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: isToday ? y.primary : y.muted,
              ),
            ),
          ),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Rest day',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted.withValues(alpha: 0.6),
                ),
              ),
            )
          else
            for (var gi = 0; gi < groups.length; gi++) ...[
              if (gi > 0) const SizedBox(height: 12),
              Text(
                groups[gi].$1,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                  color: y.muted,
                ),
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < groups[gi].$2.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                _ClassBlock(
                  row: groups[gi].$2[i],
                  onTap: onTap == null
                      ? null
                      : () => onTap!(groups[gi].$2[i]),
                ),
              ],
            ],
        ],
      ),
    );
  }
}

/// 7-day Timeline view: a single chronological feed of all classes in
/// the window, sorted by start time, with a sticky day separator
/// between days. Best for "what's coming up this week" scanning — the
/// hour ruler in the Calendar/Week view is denser, this is leaner.
class _TimelineWeek extends StatelessWidget {
  final DateTime weekStart;
  final List<ClassRow> rows;
  final void Function(ClassRow)? onTap;
  const _TimelineWeek({
    required this.weekStart,
    required this.rows,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final today = DateTime.now();
    final byDay = <int, List<ClassRow>>{};
    for (final r in rows) {
      final local = r.startsAt.toLocal();
      final classDay = DateTime(local.year, local.month, local.day);
      final base =
          DateTime(weekStart.year, weekStart.month, weekStart.day);
      final idx = classDay.difference(base).inDays;
      if (idx < 0 || idx > 6) continue;
      byDay.putIfAbsent(idx, () => []).add(r);
    }
    const dowLong = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    const mons = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < 7; i++) ...[
            Builder(builder: (_) {
              final date = DateTime(weekStart.year, weekStart.month,
                  weekStart.day + i);
              final classes = byDay[i] ?? const [];
              final isToday = date.year == today.year &&
                  date.month == today.month &&
                  date.day == today.day;
              final dayLabel =
                  '${dowLong[(date.weekday + 6) % 7]} '
                  '${date.day} ${mons[date.month - 1]}';
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isToday ? y.primarySoft : y.surface2,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Text(
                            dayLabel,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: isToday ? y.primaryStrong : y.text,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            classes.isEmpty
                                ? '—'
                                : '${classes.length} class'
                                    '${classes.length == 1 ? '' : 'es'}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: y.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (classes.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 10, top: 2),
                        child: Text(
                          'Rest day',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: y.muted.withValues(alpha: 0.6),
                          ),
                        ),
                      )
                    else
                      for (var ci = 0; ci < classes.length; ci++) ...[
                        if (ci > 0) const SizedBox(height: 6),
                        _ClassBlock(
                          row: classes[ci],
                          onTap: onTap == null
                              ? null
                              : () => onTap!(classes[ci]),
                        ),
                      ],
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

/// Single-column chronological list for narrow widths. Each class is the
/// full _ClassBlock chip the desktop view already uses — picking that
/// reuses the discipline coloring and tap target shape for free.
class _MobileDayList extends StatelessWidget {
  final DateTime day;
  final List<ClassRow> rows;
  final void Function(ClassRow)? onTap;
  const _MobileDayList({
    required this.day,
    required this.rows,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    if (rows.isEmpty) {
      return ManagerCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              'No classes scheduled for this day.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
        ),
      );
    }
    final sorted = [...rows]
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    return ManagerCard(
      padding: const EdgeInsets.all(12),
      fill: true,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: sorted.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _ClassBlock(
          row: sorted[i],
          onTap: onTap == null ? null : () => onTap!(sorted[i]),
        ),
      ),
    );
  }
}
