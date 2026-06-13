// Manager Schedule — Week view.
// Mirrors yoga-admin-a.jsx KSchedule. 7-column grid of compact class blocks,
// primarySoft for yoga / accentSoft for reformer & courses, with a 3 px
// left border in the solid color.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart';
import 'manager_shell.dart';

class AdminScheduleScreen extends ConsumerStatefulWidget {
  final void Function(String classId)? onOpenRoster;
  const AdminScheduleScreen({super.key, this.onOpenRoster});

  @override
  ConsumerState<AdminScheduleScreen> createState() =>
      _AdminScheduleScreenState();
}

enum _ScheduleView { week, day }

class _AdminScheduleScreenState extends ConsumerState<AdminScheduleScreen> {
  late DateTime _monday;
  late DateTime _day;
  _ScheduleView _view = _ScheduleView.week;
  late Future<List<ClassRow>> _classes;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _monday = _mondayOf(now);
    _day = DateTime(now.year, now.month, now.day);
    _classes = _fetch();
  }

  Future<List<ClassRow>> _fetch() {
    if (_view == _ScheduleView.week) {
      return ref.read(apiClientProvider).adminClasses(
            from: _monday,
            to: _monday.add(const Duration(days: 7)),
          );
    }
    return ref.read(apiClientProvider).adminClasses(
          from: _day,
          to: _day.add(const Duration(days: 1)),
        );
  }

  void _setView(_ScheduleView v) {
    setState(() {
      _view = v;
      _classes = _fetch();
    });
  }

  void _pageWeeks(int delta) {
    setState(() {
      if (_view == _ScheduleView.week) {
        _monday = _monday.add(Duration(days: 7 * delta));
      } else {
        _day = _day.add(Duration(days: delta));
      }
      _classes = _fetch();
    });
  }

  void _goToday() {
    setState(() {
      final now = DateTime.now();
      _monday = _mondayOf(now);
      _day = DateTime(now.year, now.month, now.day);
      _classes = _fetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isWeek = _view == _ScheduleView.week;
    final weekEnd = _monday.add(const Duration(days: 6));
    final label = isWeek
        ? '${_short(_monday)} – ${_short(weekEnd)}'
        : _longDay(_day);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: FutureBuilder<List<ClassRow>>(
        future: _classes,
        builder: (context, snap) {
          final rows = snap.data ?? const <ClassRow>[];
          final rooms = <String>{for (final r in rows) r.roomName};
          final subText = rows.isEmpty
              ? label
              : '$label · ${rows.length} class${rows.length == 1 ? '' : 'es'}'
                  '${isWeek ? '' : ' · ${rooms.length} room${rooms.length == 1 ? '' : 's'}'}';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ManagerPageHeader(
                title: 'Schedule',
                sub: subText,
                actions: [
                  SizedBox(
                    width: 140,
                    child: _ViewToggle(
                      view: _view,
                      onChange: _setView,
                    ),
                  ),
                  _WeekNav(
                    onPrev: () => _pageWeeks(-1),
                    onNext: () => _pageWeeks(1),
                  ),
                  YButton(
                    label: 'Today',
                    variant: YButtonVariant.outline,
                    small: true,
                    onTap: _goToday,
                  ),
                  YButton(
                    label: '+ New class',
                    small: true,
                    onTap: () async {
                      final newId = await showNewClassDialog(context);
                      if (newId != null && mounted) {
                        setState(() => _classes = _fetch());
                      }
                    },
                  ),
                ],
              ),
              Expanded(
                child: Builder(
                  builder: (_) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Text(
                          "Can't load schedule: ${snap.error}",
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
                        setState(() => _classes = _fetch());
                      }
                    }
                    return ManagerCard(
                      padding: const EdgeInsets.all(14),
                      child: isWeek
                          ? SizedBox(
                              height: double.infinity,
                              child: _WeekGrid(
                                monday: _monday,
                                rows: rows,
                                onTap: onBlockTap,
                              ),
                            )
                          : _DayLanes(
                              day: _day,
                              rows: rows,
                              onTap: onBlockTap,
                            ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _longDay(DateTime d) {
    const dow = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dow[(d.weekday + 6) % 7]} ${d.day} ${mons[d.month - 1]}';
  }

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

class _ViewToggle extends StatelessWidget {
  final _ScheduleView view;
  final ValueChanged<_ScheduleView> onChange;
  const _ViewToggle({required this.view, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget btn(String label, _ScheduleView v) {
      final on = view == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChange(v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: on ? y.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: on ? y.border : Colors.transparent,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
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
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          btn('Week', _ScheduleView.week),
          btn('Day', _ScheduleView.day),
        ],
      ),
    );
  }
}

// ============================== DAY LANES ==============================

const double _dayStartHour = 7.0;
const double _dayEndHour = 21.0;
const double _hourHeight = 56.0;
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

class _WeekNav extends StatelessWidget {
  final VoidCallback onPrev;
  final VoidCallback onNext;
  const _WeekNav({required this.onPrev, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget btn(IconData icon, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: y.borderStrong),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 16, color: y.text),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.chevron_left, onPrev),
        const SizedBox(width: 6),
        btn(Icons.chevron_right, onNext),
      ],
    );
  }
}

class _WeekGrid extends StatelessWidget {
  final DateTime monday;
  final List<ClassRow> rows;
  final void Function(ClassRow)? onTap;
  const _WeekGrid({required this.monday, required this.rows, this.onTap});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final byDay = <int, List<ClassRow>>{};
    for (final r in rows) {
      final local = r.startsAt.toLocal();
      final idx = local.difference(monday).inDays;
      if (idx < 0 || idx > 6) continue;
      byDay.putIfAbsent(idx, () => []).add(r);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < 7; i++) ...[
          Expanded(
            child: _DayColumn(
              date: monday.add(Duration(days: i)),
              isFirst: i == 0,
              isToday: _sameDay(monday.add(Duration(days: i)), today),
              classes: byDay[i] ?? const [],
              onTap: onTap,
            ),
          ),
        ],
      ],
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayColumn extends StatelessWidget {
  final DateTime date;
  final bool isFirst;
  final bool isToday;
  final List<ClassRow> classes;
  final void Function(ClassRow)? onTap;
  const _DayColumn({
    required this.date,
    required this.isFirst,
    required this.isToday,
    required this.classes,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const dows = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final dow = dows[(date.weekday + 6) % 7];
    return Container(
      padding: EdgeInsets.only(left: isFirst ? 0 : 10),
      decoration: BoxDecoration(
        border: isFirst
            ? null
            : Border(left: BorderSide(color: y.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
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
          if (classes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'No classes — rest day',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted.withValues(alpha: 0.6),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final c in classes) ...[
                    _ClassBlock(
                      row: c,
                      onTap: onTap == null ? null : () => onTap!(c),
                    ),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ClassBlock extends StatelessWidget {
  final ClassRow row;
  final VoidCallback? onTap;
  const _ClassBlock({required this.row, this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isReformer = row.discipline == 'reformer';
    final bg = isReformer ? y.accentSoft : y.primarySoft;
    final edge = isReformer ? y.accent : y.primary;
    final local = row.startsAt.toLocal();
    final hh = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    final roomShort = _shortRoom(row.roomName);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border(left: BorderSide(color: edge, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              row.title,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: y.text,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '$hh · ${row.instructorName.split(' ').first} · $roomShort',
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
    );
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
