// Book screen — Classes tab.
// Mirrors yoga-book.jsx: title + check-in button, segmented control,
// month label, 7-day strip with dot indicators, class rows by time.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/polling.dart';
import '../widgets/yoga_primitives.dart';
import 'booking_sheet.dart';
import 'checkin_sheet.dart';
import 'enrollments_tab.dart';

/// Bumped when something outside BookScreen creates/cancels a booking
/// (e.g. the buy+book auto-booking flow in CheckoutSheet). The carried
/// `day` tells BookScreen which day to refresh — pass the class's local
/// start day so the right row updates even if the user's selection has
/// moved on. `seq` is incremented every bump so listeners fire even when
/// the same day is bumped twice in a row.
typedef ClassesChangedTick = ({int seq, DateTime? day});

final classesChangedTickProvider =
    NotifierProvider<ClassesChangedTickNotifier, ClassesChangedTick>(
        ClassesChangedTickNotifier.new);

class ClassesChangedTickNotifier extends Notifier<ClassesChangedTick> {
  @override
  ClassesChangedTick build() => (seq: 0, day: null);
  void bump({DateTime? day}) =>
      state = (seq: state.seq + 1, day: day);
}

/// Caches the set of days within a given Monday-anchored week that have at
/// least one scheduled class. The day strip uses this to render the activity
/// dot under each day.
final _weekDaysWithClassesProvider = FutureProvider.autoDispose
    .family<Set<DateTime>, DateTime>((ref, monday) async {
  final classes = await ref.watch(apiClientProvider).classesInRange(
        from: monday,
        to: monday.add(const Duration(days: 7)),
      );
  return {
    for (final c in classes)
      DateTime(c.startsAt.toLocal().year, c.startsAt.toLocal().month,
          c.startsAt.toLocal().day)
  };
});

class BookScreen extends ConsumerStatefulWidget {
  final Me me;
  final StudioConfig studio;
  final VoidCallback? onTapProfile;
  const BookScreen({
    super.key,
    required this.me,
    required this.studio,
    this.onTapProfile,
  });

  @override
  ConsumerState<BookScreen> createState() => _BookScreenState();
}

enum _DayView { sections, timeline }

class _BookScreenState extends ConsumerState<BookScreen> {
  late DateTime _selected;
  // Start date of the visible 7-day strip. On first render this is
  // (today - 3) so today sits in the middle column — feels nicer than
  // having Sunday land on the far right. As soon as the user taps a
  // day or chevrons, we snap it to the Monday of the new selection so
  // the strip reads as a normal calendar week from then on.
  late DateTime _windowStart;
  // Per-day result cache. Lets us re-render a previously-viewed day
  // instantly when the user taps back, while a fresh fetch runs in the
  // background — no spinner flash between day taps. DateTime equality
  // is value-based on millisecondsSinceEpoch so day keys collide
  // correctly even across new DateTime() calls.
  final Map<DateTime, List<ClassRow>> _cache = {};
  // Mondays we've already pre-fetched. Saves duplicate range requests
  // when the user pages back to a previously-warmed week.
  final Set<DateTime> _warmedWeeks = {};
  Object? _error; // last error for _selected, if any
  int _tab = 0; // 0 = Classes, 1 = Enrollments
  _DayView _dayView = _DayView.sections;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _selected = DateTime(n.year, n.month, n.day);
    _windowStart = _addDays(_selected, -3);
    // One range request seeds all 7 days of the current week, so every
    // tap on the day strip is instant from first render.
    _warmWeek(_selected);
  }

  // Day-field arithmetic (not Duration) so DST transition days don't
  // drift off midnight — DateTime equality is microsecond-based, so a
  // 23h or 25h "day" would produce a key that misses on lookup.
  static DateTime _addDays(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  static DateTime _mondayOf(DateTime d) {
    final offset = (d.weekday + 6) % 7; // Mon = 0
    return _addDays(d, -offset);
  }

  /// Fetch a whole week in one request and partition by local-date into
  /// `_cache`. Idempotent per Monday — repeat calls no-op. Errors only
  /// surface to the UI if the currently-selected day has no cache hit.
  Future<void> _warmWeek(DateTime anyDayInWeek) async {
    final monday = _mondayOf(anyDayInWeek);
    if (_warmedWeeks.contains(monday)) return;
    _warmedWeeks.add(monday);
    final to = _addDays(monday, 7);
    try {
      final all = await ref
          .read(apiClientProvider)
          .classesInRange(from: monday, to: to);
      if (!mounted) return;
      final byDay = <DateTime, List<ClassRow>>{
        for (var i = 0; i < 7; i++) _addDays(monday, i): <ClassRow>[],
      };
      for (final c in all) {
        final local = c.startsAt.toLocal();
        final key = DateTime(local.year, local.month, local.day);
        (byDay[key] ??= []).add(c);
      }
      // Sort each day's classes by start time — the range API doesn't
      // guarantee per-day ordering and partitioning loses it.
      for (final list in byDay.values) {
        list.sort((a, b) => a.startsAt.compareTo(b.startsAt));
      }
      setState(() {
        _cache.addAll(byDay);
        if (_cache.containsKey(_selected)) _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // If we already have rows for the visible day, hide the error.
      // Otherwise let the user see it and offer retry.
      if (_cache[_selected] == null) {
        _warmedWeeks.remove(monday); // allow retry
        setState(() => _error = e);
      }
    }
  }

  /// Refresh a single day. Used after a booking change to update just
  /// that day's row without re-fetching the whole week.
  Future<void> _refreshDay(DateTime day) async {
    try {
      final rows =
          await ref.read(apiClientProvider).classesForDay(day);
      if (!mounted) return;
      setState(() {
        _cache[day] = rows;
        if (day == _selected) _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (day == _selected) setState(() => _error = e);
    }
  }

  void _pick(DateTime d) {
    if (d == _selected) return;
    setState(() {
      _selected = d;
      // First interaction snaps the strip onto its Monday alignment so
      // every subsequent tap/chevron lives in calendar-week land.
      _windowStart = _mondayOf(d);
    });
    // If the picked day's week isn't yet warmed, fetch it. The day
    // strip lets you chevron to neighbouring weeks; this catches both
    // strip-internal taps (no-op, week already warmed) and cross-week
    // jumps.
    _warmWeek(d);
  }

  void _reload() => _refreshDay(_selected);

  @override
  Widget build(BuildContext context) {
    ref.listen<ClassesChangedTick>(classesChangedTickProvider, (_, next) {
      if (!mounted) return;
      // If the bumper named a day, refresh that one; otherwise fall back
      // to whatever the user is currently looking at.
      _refreshDay(next.day ?? _selected);
    });
    // Live polling — seat counts + waitlist length move every minute in a
    // busy studio. 10s base by default; the manager can dial it from
    // Settings → Advanced like every other surface.
    return PollingRefresh(
      surface: PollingSurface.studentBook,
      onPoll: () => _refreshDay(_selected),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top-bar padding mirrors HomeScreen's ListView padding so the
        // brand row sits at the same vertical offset across tabs.
        const SizedBox(height: 16),
        _BookHeader(
          me: widget.me,
          studio: widget.studio,
          tab: _tab,
          onTab: (i) => setState(() => _tab = i),
          onTapProfile: widget.onTapProfile,
        ),
        if (_tab == 0) ...[
          _DayStrip(
            selected: _selected,
            windowStart: _windowStart,
            onPick: _pick,
          ),
          _DayViewPill(
            view: _dayView,
            onChanged: (v) => setState(() => _dayView = v),
          ),
          Expanded(child: _body()),
        ] else
          const Expanded(child: EnrollmentsTab()),
      ],
      ),
    );
  }

  Widget _body() {
    final rows = _cache[_selected];
    // First-ever view of this day with no cache + still loading → spinner.
    // Once we have any rows for the day, we render them and let subsequent
    // fetches refresh silently underneath.
    if (rows == null) {
      if (_error != null) return _LoadError(error: _error!, onRetry: _reload);
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (rows.isEmpty) return _EmptyDay(day: _selected, onJumpTo: _pick);
    switch (_dayView) {
      case _DayView.sections:
        return _SectionsList(rows: rows, onBookingChanged: _reload);
      case _DayView.timeline:
        return _TimelineList(rows: rows, onBookingChanged: _reload);
    }
  }
}

class _BookHeader extends StatelessWidget {
  final Me me;
  final StudioConfig studio;
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback? onTapProfile;
  const _BookHeader({
    required this.me,
    required this.studio,
    required this.tab,
    required this.onTab,
    this.onTapProfile,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Matches HomeScreen's brand row exactly — logo + studio name on
          // the left, bell + avatar on the right.
          YStudioTopBar(
            studioName: studio.name,
            userFullName: me.fullName,
            userPhotoUrl: me.photoUrl,
            onAvatarTap: onTapProfile,
          ),
          const SizedBox(height: 18),
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
  /// Start date of the 7-day window. On first render the parent passes
  /// `today - 3` so today sits in the centre; once the user picks or
  /// chevrons, the parent snaps it to the Monday of the new selection so
  /// the strip reads as a proper calendar week from then on.
  final DateTime windowStart;
  final ValueChanged<DateTime> onPick;
  const _DayStrip({
    required this.selected,
    required this.windowStart,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Day-field arithmetic (not Duration) so DST transition days don't
    // drift off midnight and break the sameness check below.
    final week = List.generate(7,
        (i) => DateTime(windowStart.year, windowStart.month, windowStart.day + i));
    // Anchor for the activity-dot provider — _DayChip queries which days
    // in `[monday, monday + 7d)` carry at least one scheduled class.
    // Using the actual Monday of the visible week (vs. windowStart, which
    // can drift mid-week on first load) keeps the provider cache key
    // stable as the user navigates within the same week.
    final monday = DateTime(week.first.year, week.first.month,
        week.first.day - ((week.first.weekday + 6) % 7));
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
                // Surfaces a one-tap return to today when the user has
                // chevroned away — only shown when "selected" is on a
                // different day than today, so the control doesn't add
                // visual noise on the default view.
                Builder(builder: (context) {
                  final now = DateTime.now();
                  final isToday = selected.year == now.year &&
                      selected.month == now.month &&
                      selected.day == now.day;
                  if (isToday) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: GestureDetector(
                      onTap: () => onPick(DateTime(now.year, now.month, now.day)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: y.surface,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: y.border),
                        ),
                        child: Text(
                          'Today',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: y.text,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                GestureDetector(
                  onTap: () => onPick(DateTime(windowStart.year,
                      windowStart.month, windowStart.day - 7)),
                  child: Icon(Icons.chevron_left, size: 20, color: y.muted),
                ),
                const SizedBox(width: 14),
                GestureDetector(
                  onTap: () => onPick(DateTime(windowStart.year,
                      windowStart.month, windowStart.day + 7)),
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
                    monday: monday,
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
  final DateTime monday;
  final bool selected;
  final VoidCallback onTap;
  const _DayChip({
    required this.date,
    required this.monday,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final days = ref.watch(_weekDaysWithClassesProvider(monday));
    final hasClasses = days.maybeWhen(
      data: (set) => set.contains(date),
      orElse: () => false,
    );
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

/// View selector pill — Sections vs Timeline. Mirrors the look of the
/// Classes/Enrollments segmented control above it but at a smaller size.
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
                Icon(icon,
                    size: 14,
                    color: active ? y.text : y.muted),
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Container(
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
      ),
    );
  }
}

/// Opens the BookingSheet for [row] and notifies on a booking change.
/// Hoisted out of the row widgets so both list layouts share the same tap
/// path — neither needs its own copy of the showModalBottomSheet boilerplate.
Future<void> _openBookingSheet(
  BuildContext context,
  ClassRow row,
  VoidCallback onBookingChanged,
) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x66100A05),
    builder: (_) => BookingSheet(classRow: row),
  );
  if (result == true) onBookingChanged();
}

/// Time-of-day grouped layout. Morning (<12), Afternoon (12-17), Evening
/// (17+). Section headers only render when their bucket has at least one
/// class — a day with two morning classes shows just "MORNING" + the rows.
class _SectionsList extends StatelessWidget {
  final List<ClassRow> rows;
  final VoidCallback onBookingChanged;
  const _SectionsList({required this.rows, required this.onBookingChanged});

  @override
  Widget build(BuildContext context) {
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

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      itemCount: groups.length,
      itemBuilder: (context, gi) {
        final (label, items) = groups[gi];
        return Padding(
          padding: EdgeInsets.only(bottom: gi == groups.length - 1 ? 0 : 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionHeader(label: label),
              const SizedBox(height: 10),
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _ClassListRow(
                  key: Key('class-row-${items[i].id}'),
                  row: items[i],
                  onTap: () =>
                      _openBookingSheet(context, items[i], onBookingChanged),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
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
  }
}

/// Hour-ruler timeline. Each row is one hour from the earliest class
/// hour to the latest end-hour. Class cards anchor at the hour their
/// class starts; empty hours render as the hour label with no card so
/// the visual gap between morning and evening reads as "nothing happens
/// in here". The vertical rule is painted once underneath via Stack
/// rather than per-row, so widths don't depend on IntrinsicHeight
/// (which previously triggered overflow when the card asked for an
/// intrinsic width that couldn't be satisfied inside an Expanded).
class _TimelineList extends StatelessWidget {
  final List<ClassRow> rows;
  final VoidCallback onBookingChanged;
  const _TimelineList({required this.rows, required this.onBookingChanged});

  static const double _gutterWidth = 44;
  static const double _railOffset = 50; // gutter + ~6 to centre the rail

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

    return Stack(
      children: [
        // The vertical rail under everything — drawn once instead of as
        // a 1px Container in each row (which needed IntrinsicHeight to
        // get a height, which is what was triggering the overflow).
        Positioned(
          top: 14,
          bottom: 14,
          left: 20 + _railOffset,
          width: 1,
          child: Container(color: y.border),
        ),
        ListView.builder(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          itemCount: hours.length,
          itemBuilder: (context, i) {
            final h = hours[i];
            final cards = byHour[h] ?? const <ClassRow>[];
            return Padding(
              padding: EdgeInsets.only(
                  bottom: i == hours.length - 1 ? 0 : 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _gutterWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        hourLabel(h),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: y.muted,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: cards.isEmpty
                        ? const SizedBox(height: 24)
                        : Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.stretch,
                            children: [
                              for (var ci = 0; ci < cards.length; ci++) ...[
                                if (ci > 0) const SizedBox(height: 8),
                                _ClassListRow(
                                  key: Key('class-row-${cards[ci].id}'),
                                  row: cards[ci],
                                  onTap: () => _openBookingSheet(context,
                                      cards[ci], onBookingChanged),
                                ),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Small "+1 friend" chip — flags a booking that includes a plus-one
/// guest. Shown on the Book screen's class card so the student can see
/// at a glance which of today's bookings they're bringing someone to.
class _PlusOneChip extends StatelessWidget {
  const _PlusOneChip();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: y.accentSoft,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_add_alt_1, size: 10, color: y.accent),
          const SizedBox(width: 3),
          Text(
            '+1 friend',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              color: y.accent,
              letterSpacing: 0.3,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "SERIES" tag — flags enrollment sessions in both the calendar
/// and the student day list so a one-off drop-in reads differently from
/// a committed multi-week course session.
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

/// Parse a `#rrggbb` string into a [Color], or null when the input is
/// missing / malformed. Lenient on case + whitespace; the server side
/// validates strictly so anything that lands here SHOULD parse, but
/// defence in depth keeps a typo'd value from crashing the card.
Color? _parseRoomAccent(String? raw) {
  if (raw == null) return null;
  final s = raw.trim().toLowerCase();
  if (!RegExp(r'^#[0-9a-f]{6}$').hasMatch(s)) return null;
  return Color(int.parse(s.substring(1), radix: 16) | 0xFF000000);
}

class _ClassListRow extends StatelessWidget {
  final ClassRow row;
  final VoidCallback onTap;
  const _ClassListRow({super.key, required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final localStart = row.startsAt.toLocal();
    final timeLabel = '${localStart.hour}:${localStart.minute.toString().padLeft(2, '0')}';
    // A class is "past" once it has finished — fade the card so today's
    // already-done classes recede visually and the next-up ones stand
    // out. Past rows are non-interactive: no row tap (can't open the
    // booking sheet for an ended class) and the state column hides any
    // "Book" / "Join waitlist" CTAs.
    final isPast = row.endsAt.toLocal().isBefore(DateTime.now());
    final stripe = _parseRoomAccent(row.roomColor);
    return Opacity(
      opacity: isPast ? 0.55 : 1.0,
      child: GestureDetector(
      onTap: isPast ? null : onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(y.radiusCard),
        child: Stack(
          children: [
            // Card body. Inner padding has an extra 4px on the left so
            // the colour stripe (if any) doesn't overlap the time
            // column — keeps the visual rhythm even when the stripe is
            // absent for rooms without a colour.
            Container(
              padding: const EdgeInsets.fromLTRB(18, 13, 14, 13),
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                            color: y.text,
                          ),
                        ),
                      ),
                      if (row.isEnrollmentSession) ...[
                        const SizedBox(width: 6),
                        const _SeriesTag(),
                      ],
                      // The +1 chip rides next to the title (rather than
                      // down with the instructor row) so it's visible at a
                      // glance even when the card is squeezed and the
                      // sub-row truncates.
                      if (row.bookedWithPlusOne) ...[
                        const SizedBox(width: 6),
                        const _PlusOneChip(),
                      ],
                    ],
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
            _stateColumn(context, isPast: isPast),
          ],
        ),
      ),
            if (stripe != null)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 4,
                child: Container(color: stripe),
              ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _stateColumn(BuildContext context, {required bool isPast}) {
    final y = context.yoga;
    // Past classes never show action CTAs (no Book / Join waitlist).
    // Booked rows keep their chip as a record-of-attendance marker;
    // everything else collapses to nothing so the row reads as inert.
    if (isPast) {
      if (row.bookingState == BookingState.booked) {
        return const YChip(
          kind: YChipKind.booked,
          label: 'Booked',
          leadingCheck: true,
        );
      }
      return const SizedBox.shrink();
    }
    switch (row.bookingState) {
      case BookingState.booked:
        return const YChip(
          kind: YChipKind.booked,
          label: 'Booked',
          leadingCheck: true,
        );
      case BookingState.full:
        // When the caller has already claimed a queue slot for this full
        // class, swap "Join waitlist" for an "On waitlist · #N" affordance
        // so they have visible proof they're in the queue and don't tap
        // through again expecting to join.
        final pos = row.waitlistPosition;
        if (pos != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              YChip(kind: YChipKind.accent, label: 'On waitlist · #$pos'),
              const SizedBox(height: 5),
              Text(
                'Tap to leave',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: y.muted,
                ),
              ),
            ],
          );
        }
        // Public "Full · N waiting" label when the caller isn't on the
        // waitlist themselves — uses the server's waitlist_count so the
        // queue depth is visible to anyone hovering over a packed class.
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
