// Manager Roster — per-class attendance & waitlist.
// Mirrors yoga-admin-b.jsx KRoster: left card (booked + filter chips +
// per-row Present/No-show segmented toggle), right card (waitlist with
// Promote buttons + claim-window note).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import '../chat_screen.dart';
import 'class_dialogs.dart';
import 'manager_shell.dart';
import 'scan_checkin_sheet.dart';

const double _kNarrow = 700;

enum _Filter { all, unmarked, present, noShow, lateCancel }

class AdminRosterScreen extends ConsumerStatefulWidget {
  final String classId;
  const AdminRosterScreen({super.key, required this.classId});

  @override
  ConsumerState<AdminRosterScreen> createState() => _AdminRosterScreenState();
}

class _AdminRosterScreenState extends ConsumerState<AdminRosterScreen> {
  // Stale-while-revalidate: we hold the last loaded roster and keep it on
  // screen while a refetch is in flight, so marking attendance (or any
  // other mutation that calls _reload) refreshes the data in place instead
  // of blanking the whole page back to a spinner on every tap.
  Roster? _data;
  Object? _error;
  _Filter _filter = _Filter.all;
  String _query = '';
  final _busy = <String>{}; // booking_ids currently being mutated

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final r = await ref.read(apiClientProvider).adminRoster(widget.classId);
      if (!mounted) return;
      setState(() {
        _data = r;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // Keep any previously loaded data on screen; only surface the error
      // when we have nothing to show.
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _kNarrow;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;
        // First load with nothing yet — spinner. Once we have data we keep
        // showing it across reloads (no full-page spinner on each mark).
        if (_data == null && _error != null) {
          return Padding(
            padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
            child: Center(
              child: Text(
                "Can't load roster: $_error",
                style: TextStyle(color: y.muted),
              ),
            ),
          );
        }
        if (_data == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: Builder(
            builder: (context) {
              final r = _data!;
              final booked = _BookedCard(
                roster: r,
                filter: _filter,
                query: _query,
                busy: _busy,
                isNarrow: isNarrow,
                onFilter: (f) => setState(() => _filter = f),
                onQuery: (q) => setState(() => _query = q),
                onMark: _mark,
                onMarkAllPresent: _markAllPresent,
                onAddStudent: _addStudent,
                onRemove: _remove,
              );
              final waitlist = _WaitlistCard(
                roster: r,
                onPromote: _promote,
                isNarrow: isNarrow,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ManagerPageHeader(
                    title: r.klass.title,
                    sub: _subline(r.klass),
                    actions: [
                      // Cancel class lives here as well as in Schedule;
                      // useful when a manager is already on the roster
                      // and realises the class can't run.
                      YButton(
                        label: 'Cancel class',
                        variant: YButtonVariant.outline,
                        small: true,
                        onTap: () async {
                          final cancelled = await showCancelClassDialog(
                            context: context,
                            classId: r.klass.id,
                            classTitle: r.klass.title,
                            bookedCount: r.counts.booked,
                            startsAt: r.klass.startsAt,
                          );
                          if (cancelled == true) _reload();
                        },
                      ),
                      YButton(
                        label: 'Scan check-in',
                        small: true,
                        onTap: () async {
                          final any = await showScanCheckinSheet(context);
                          if (any == true && mounted) _reload();
                        },
                      ),
                      // Mobile-only entry to the chat — desktop embeds
                      // the thread inline (see right column below) so
                      // the button would be redundant there.
                      if (isNarrow)
                        YButton(
                          label: 'Group chat',
                          small: true,
                          variant: YButtonVariant.outline,
                          onTap: () => _openClassChat(r.klass.id),
                        ),
                    ],
                  ),
                  Expanded(
                    child: isNarrow
                        // Stack the cards on mobile and scroll the page so
                        // long rosters + the waitlist both stay reachable.
                        // Mobile keeps the group-chat header button — the
                        // viewport's too tight to embed the thread inline.
                        ? ListView(
                            padding: EdgeInsets.zero,
                            children: [
                              booked,
                              const SizedBox(height: 12),
                              waitlist,
                            ],
                          )
                        // Desktop: booked on the left, then a vertical
                        // split on the right with waitlist on top and the
                        // group chat embedded below it — no extra
                        // navigation for the manager.
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 7, child: booked),
                              const SizedBox(width: 16),
                              Expanded(
                                flex: 5,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(child: waitlist),
                                    const SizedBox(height: 12),
                                    Expanded(
                                      child: _RosterChatPanel(
                                        classId: r.klass.id,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _mark(RosterBookingRow row, String status) async {
    setState(() => _busy.add(row.bookingId));
    try {
      await ref
          .read(apiClientProvider)
          .markAttendance(bookingId: row.bookingId, status: status);
      await _reload();
    } catch (e) {
      _toast('Could not mark: ${ApiError.fromAny(e).message}');
    } finally {
      setState(() => _busy.remove(row.bookingId));
    }
  }

  Future<void> _markAllPresent(List<RosterBookingRow> rows) async {
    // Optimistically: fire all in parallel.
    final api = ref.read(apiClientProvider);
    final unmarked = rows.where((r) => r.status == 'booked').toList();
    setState(() => _busy.addAll(unmarked.map((r) => r.bookingId)));
    try {
      await Future.wait(
        unmarked.map(
          (r) => api.markAttendance(bookingId: r.bookingId, status: 'present'),
        ),
      );
      await _reload();
    } catch (e) {
      _toast('Some rows failed: ${ApiError.fromAny(e).message}');
    } finally {
      setState(() => _busy.removeAll(unmarked.map((r) => r.bookingId)));
    }
  }

  Future<void> _promote() async {
    try {
      final r = await ref
          .read(apiClientProvider)
          .promoteWaitlist(widget.classId);
      _toast('${r.promotedName} promoted off the waitlist');
      _reload();
    } catch (e) {
      _toast('Promote failed: ${ApiError.fromAny(e).message}');
    }
  }

  Future<void> _addStudent(String classTitle) async {
    final booked = await showAddStudentToClassDialog(
      context: context,
      classId: widget.classId,
      classTitle: classTitle,
    );
    if (booked == true && mounted) {
      _toast('Student added to class');
      _reload();
    }
  }

  Future<void> _remove(RosterBookingRow row, String classTitle) async {
    // For a +1 cancel the visible label is the friend (the parent row
    // owns the pass), but the booking id we send is the row clicked.
    final shown = row.isPlusOne
        ? (row.plusOneName.isEmpty ? 'Guest' : row.plusOneName)
        : row.fullName;
    final removed = await showRemoveFromClassDialog(
      context: context,
      bookingId: row.bookingId,
      studentName: shown,
      classTitle: classTitle,
      passKind: row.passKind,
    );
    if (removed == true && mounted) {
      _toast('Booking removed');
      _reload();
    }
  }

  Future<void> _openClassChat(String classId) async {
    try {
      final conv = await ref.read(apiClientProvider).openClassChat(classId);
      final me = ref.read(bootstrapProvider).asData?.value.me;
      if (!mounted || me == null) return;
      ref.invalidate(conversationsProvider);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
            conversationId: conv.id,
            initialConversation: conv,
            me: me,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _toast("Couldn't open chat: ${ApiError.fromAny(e).message}");
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _subline(RosterClassHeader k) {
    final start = k.startsAt.toLocal();
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dows[(start.weekday + 6) % 7];
    final hh = '${start.hour}:${start.minute.toString().padLeft(2, '0')}';
    return '$dow ${start.day} · $hh · ${k.instructorName} · ${k.roomName}';
  }
}

class _BookedCard extends StatelessWidget {
  final Roster roster;
  final _Filter filter;
  final String query;
  final Set<String> busy;
  final bool isNarrow;
  final ValueChanged<_Filter> onFilter;
  final ValueChanged<String> onQuery;
  final Future<void> Function(RosterBookingRow, String) onMark;
  final Future<void> Function(List<RosterBookingRow>) onMarkAllPresent;
  final Future<void> Function(String classTitle) onAddStudent;
  final Future<void> Function(RosterBookingRow, String classTitle) onRemove;
  const _BookedCard({
    required this.roster,
    required this.filter,
    required this.query,
    required this.busy,
    required this.isNarrow,
    required this.onFilter,
    required this.onQuery,
    required this.onMark,
    required this.onMarkAllPresent,
    required this.onAddStudent,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final c = roster.counts;
    final filtered = _filterRows(roster.booked);
    // "All" includes the late-cancelled rows so managers can see them in
    // context — the count below adds them back in.
    final allCount = c.booked + c.lateCancelled;
    final filterPills = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _FilterPill(
          label: 'All $allCount',
          active: filter == _Filter.all,
          onTap: () => onFilter(_Filter.all),
        ),
        _FilterPill(
          label: 'Unmarked ${c.unmarked}',
          active: filter == _Filter.unmarked,
          onTap: () => onFilter(_Filter.unmarked),
        ),
        _FilterPill(
          label: 'Present ${c.present}',
          active: filter == _Filter.present,
          onTap: () => onFilter(_Filter.present),
        ),
        _FilterPill(
          label: 'No-show ${c.noShow}',
          active: filter == _Filter.noShow,
          onTap: () => onFilter(_Filter.noShow),
        ),
        if (c.lateCancelled > 0)
          _FilterPill(
            label: 'Late cancel ${c.lateCancelled}',
            active: filter == _Filter.lateCancel,
            onTap: () => onFilter(_Filter.lateCancel),
          ),
      ],
    );
    final searchPill = _SearchPill(onChanged: onQuery);
    final actionsRow = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        YButton(
          label: 'Add student',
          variant: YButtonVariant.outline,
          small: true,
          onTap: () => onAddStudent(roster.klass.title),
        ),
        const SizedBox(width: 8),
        YButton(
          label: 'Mark all present',
          variant: YButtonVariant.soft,
          small: true,
          onTap: () => onMarkAllPresent(roster.booked),
        ),
      ],
    );
    // The booked rows themselves. Built once, then rendered either inline
    // (mobile — the whole roster scrolls in the page's outer ListView) or
    // inside a scroll view that fills the card (desktop — bounded height,
    // so a long roster scrolls instead of overflowing).
    final Widget rowsList = filtered.isEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'No matching students.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.yoga.muted,
              ),
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Render each primary booker, then any +1 guests they brought
              // nested underneath. The +1 row has its own booking + status so
              // managers can mark the guest separately from the member.
              for (var i = 0; i < filtered.length; i++) ...[
                () {
                  final primary = filtered[i];
                  final children = _plusOnesOf(primary);
                  final blockIsLast = i == filtered.length - 1;
                  return Column(
                    children: [
                      _StudentRow(
                        row: primary,
                        // If there are children, the primary itself never owns
                        // the bottom border — the last child does.
                        isLast: blockIsLast && children.isEmpty,
                        busy: busy.contains(primary.bookingId),
                        isNarrow: isNarrow,
                        onMark: (status) => onMark(primary, status),
                        onRemove: () => onRemove(primary, roster.klass.title),
                      ),
                      for (var j = 0; j < children.length; j++)
                        _PlusOneSubRow(
                          parent: primary,
                          row: children[j],
                          isLast: blockIsLast && j == children.length - 1,
                          busy: busy.contains(children[j].bookingId),
                          isNarrow: isNarrow,
                          onMark: (status) => onMark(children[j], status),
                          onRemove: () =>
                              onRemove(children[j], roster.klass.title),
                        ),
                    ],
                  );
                }(),
              ],
            ],
          );
    return ManagerCard(
      // Fill + inner scroll only on desktop, where the card sits in a bounded
      // Expanded. On mobile the card is inside the page's ListView (unbounded
      // height), so an Expanded/scroll-in-scroll would be invalid — the outer
      // ListView handles scrolling there.
      fill: !isNarrow,
      title: 'Booked · ${c.booked} of ${roster.klass.capacity}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: actionsRow,
          ),
          if (isNarrow) ...[
            // Stack on mobile: pills first, then full-width search.
            filterPills,
            const SizedBox(height: 10),
            searchPill,
          ] else
            Row(
              children: [
                Expanded(child: filterPills),
                const SizedBox(width: 12),
                SizedBox(width: 200, child: searchPill),
              ],
            ),
          const SizedBox(height: 14),
          if (isNarrow)
            rowsList
          else
            Expanded(child: SingleChildScrollView(child: rowsList)),
        ],
      ),
    );
  }

  /// +1 children for a given primary booking — match on parent_booking_id.
  /// Returns rows in their original insertion order (which is creation
  /// order, since the roster query orders by created_at).
  List<RosterBookingRow> _plusOnesOf(RosterBookingRow primary) {
    return roster.booked
        .where((r) => r.isPlusOne && r.parentBookingId == primary.bookingId)
        .toList();
  }

  List<RosterBookingRow> _filterRows(List<RosterBookingRow> rows) {
    // +1 rows always render nested under their primary — exclude them from
    // the top-level list so they don't appear twice.
    Iterable<RosterBookingRow> it = rows.where((r) => !r.isPlusOne);
    switch (filter) {
      case _Filter.all:
        break;
      case _Filter.unmarked:
        it = it.where((r) => r.status == 'booked');
        break;
      case _Filter.present:
        it = it.where((r) => r.status == 'attended');
        break;
      case _Filter.noShow:
        it = it.where((r) => r.status == 'no_show');
        break;
      case _Filter.lateCancel:
        it = it.where((r) => r.status == 'late_cancelled');
        break;
    }
    if (query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      it = it.where((r) => r.fullName.toLowerCase().contains(q));
    }
    return it.toList();
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? y.text : y.surface,
          borderRadius: BorderRadius.circular(y.radiusChip),
          border: Border.all(color: active ? Colors.transparent : y.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: active ? y.background : y.muted,
          ),
        ),
      ),
    );
  }
}

class _SearchPill extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchPill({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusChip),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: y.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              onChanged: onChanged,
              style: TextStyle(fontSize: 13, color: y.text),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Find a name…',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentRow extends StatelessWidget {
  final RosterBookingRow row;
  final bool isLast;
  final bool busy;
  final bool isNarrow;
  final Future<void> Function(String status) onMark;
  final VoidCallback onRemove;
  const _StudentRow({
    required this.row,
    required this.isLast,
    required this.busy,
    required this.isNarrow,
    required this.onMark,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isLateCancel = row.status == 'late_cancelled';
    final isNoShow = row.status == 'no_show';
    final passConsumedNote = isLateCancel
        ? 'Cancelled late · pass still consumed'
        : isNoShow
        ? 'No-show · pass still consumed'
        : null;
    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                row.fullName,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: isLateCancel ? y.muted : y.text,
                  decoration: isLateCancel ? TextDecoration.lineThrough : null,
                  decorationColor: y.muted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (row.attendanceVia == 'scan') ...[
              const SizedBox(width: 8),
              Text(
                '· scanned',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: y.accent,
                ),
              ),
            ],
            if (row.isPlusOne) ...[
              const SizedBox(width: 8),
              const YChip(kind: YChipKind.neutral, label: '+1'),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          row.passLabel,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: y.muted,
          ),
        ),
        if (passConsumedNote != null) ...[
          const SizedBox(height: 3),
          Text(
            passConsumedNote,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: y.accent,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ],
    );
    final trailing = isLateCancel
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Cancelled late',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: y.muted,
                letterSpacing: 0.4,
              ),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AttendanceToggle(status: row.status, busy: busy, onMark: onMark),
              const SizedBox(width: 6),
              _RowRemoveButton(busy: busy, onTap: onRemove),
            ],
          );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: isNarrow
          // On mobile, attendance toggle moves to its own row below the
          // name — the segmented control is too wide to share an inline
          // row with a name + chips.
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Opacity(
                      opacity: isLateCancel ? 0.55 : 1.0,
                      child: YAvatar(name: row.fullName, size: 26),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: nameBlock),
                  ],
                ),
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ],
            )
          : Row(
              children: [
                Opacity(
                  opacity: isLateCancel ? 0.55 : 1.0,
                  child: YAvatar(name: row.fullName, size: 26),
                ),
                const SizedBox(width: 10),
                Expanded(child: nameBlock),
                trailing,
              ],
            ),
    );
  }
}

/// Compact nested row for a +1 guest under their primary booker.
/// Indented, smaller avatar, friend's name front and centre with a
/// "Guest of [member]" caption. Has its own attendance toggle since the
/// +1 is a separate physical body in the studio and may attend / no-show
/// independently of the member who brought them.
class _PlusOneSubRow extends StatelessWidget {
  final RosterBookingRow parent;
  final RosterBookingRow row;
  final bool isLast;
  final bool busy;
  final bool isNarrow;
  final Future<void> Function(String status) onMark;
  final VoidCallback onRemove;
  const _PlusOneSubRow({
    required this.parent,
    required this.row,
    required this.isLast,
    required this.busy,
    required this.isNarrow,
    required this.onMark,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final friend = row.plusOneName.isEmpty ? 'Unnamed guest' : row.plusOneName;
    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                friend,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: y.text,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            const YChip(kind: YChipKind.neutral, label: '+1'),
          ],
        ),
        const SizedBox(height: 1),
        Text(
          'Guest of ${parent.fullName}',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: y.muted,
          ),
        ),
      ],
    );
    final toggle = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AttendanceToggle(status: row.status, busy: busy, onMark: onMark),
        const SizedBox(width: 6),
        _RowRemoveButton(busy: busy, onTap: onRemove),
      ],
    );
    // Indent + thinner separator + ↳ marker make the row read as a
    // visual child of the primary above it.
    return Container(
      padding: const EdgeInsets.fromLTRB(34, 9, 0, 9),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: isNarrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right,
                      size: 14,
                      color: y.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: nameBlock),
                  ],
                ),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: toggle),
              ],
            )
          : Row(
              children: [
                Icon(Icons.subdirectory_arrow_right, size: 14, color: y.muted),
                const SizedBox(width: 6),
                Expanded(child: nameBlock),
                toggle,
              ],
            ),
    );
  }
}

class _AttendanceToggle extends StatelessWidget {
  final String status;
  final bool busy;
  final Future<void> Function(String status) onMark;
  const _AttendanceToggle({
    required this.status,
    required this.busy,
    required this.onMark,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isPresent = status == 'attended';
    final isNoShow = status == 'no_show';
    return Opacity(
      opacity: busy ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: y.surface2,
          borderRadius: BorderRadius.circular(y.radiusChip),
          border: Border.all(color: y.border),
        ),
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SegBtn(
              label: 'Present',
              active: isPresent,
              activeBg: y.primary,
              activeFg: y.onPrimary,
              onTap: busy
                  ? null
                  : () => onMark(isPresent ? 'booked' : 'present'),
            ),
            _SegBtn(
              label: 'No-show',
              active: isNoShow,
              activeBg: y.text,
              activeFg: y.background,
              onTap: busy
                  ? null
                  : () => onMark(isNoShow ? 'booked' : 'no_show'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small icon button rendered alongside the attendance toggle. Opens
/// the remove-from-class modal where the manager picks refund vs
/// consume. Disabled while a sibling mutation is in flight so the
/// row state stays coherent.
class _RowRemoveButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _RowRemoveButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Opacity(
      opacity: busy ? 0.4 : 1.0,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(y.radiusChip),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: y.surface2,
            borderRadius: BorderRadius.circular(y.radiusChip),
            border: Border.all(color: y.border),
          ),
          child: Icon(Icons.person_remove_outlined, size: 16, color: y.muted),
        ),
      ),
    );
  }
}

class _SegBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color activeBg;
  final Color activeFg;
  final VoidCallback? onTap;
  const _SegBtn({
    required this.label,
    required this.active,
    required this.activeBg,
    required this.activeFg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? activeBg : Colors.transparent,
          borderRadius: BorderRadius.circular(y.radiusChip),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: active ? activeFg : y.muted,
          ),
        ),
      ),
    );
  }
}

class _WaitlistCard extends StatelessWidget {
  final Roster roster;
  final VoidCallback onPromote;
  final bool isNarrow;
  const _WaitlistCard({
    required this.roster,
    required this.onPromote,
    required this.isNarrow,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Rows built once, then scrolled inside the card on desktop (bounded
    // Expanded) or rendered inline on mobile (the page ListView scrolls).
    final Widget rows = roster.waitlist.isEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Nobody is waiting.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < roster.waitlist.length; i++)
                _WaitlistRow(
                  row: roster.waitlist[i],
                  isLast: i == roster.waitlist.length - 1,
                  isHead: i == 0,
                  onPromote: onPromote,
                ),
            ],
          );
    return ManagerCard(
      fill: !isNarrow,
      title: 'Waitlist · ${roster.waitlist.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The note below stays pinned at the card bottom; the rows scroll.
          if (isNarrow)
            rows
          else
            Expanded(child: SingleChildScrollView(child: rows)),
          if (roster.waitlist.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: y.surface2,
                borderRadius: BorderRadius.circular(y.radiusCard),
              ),
              child: Text(
                'Promoting notifies the student — their spot holds for 60 minutes before passing on.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: y.muted,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WaitlistRow extends StatelessWidget {
  final RosterWaitlistRow row;
  final bool isLast;
  final bool isHead;
  final VoidCallback onPromote;
  const _WaitlistRow({
    required this.row,
    required this.isLast,
    required this.isHead,
    required this.onPromote,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: y.surface2,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '${row.position}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: y.text,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              row.fullName,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: y.text,
              ),
            ),
          ),
          YButton(
            label: 'Promote',
            variant: YButtonVariant.soft,
            small: true,
            onTap: isHead ? onPromote : null,
          ),
        ],
      ),
    );
  }
}

/// Embeds the class group chat into the desktop roster's right column.
/// Resolves the conversation lazily via `openClassChat` then hands off to
/// the standard ChatThreadScreen so the polling / send / edit / member-
/// sheet behaviour is identical to the full-screen variant. The wrapper
/// adds a Material card so the embedded Scaffold matches the surrounding
/// ManagerCards visually.
class _RosterChatPanel extends ConsumerStatefulWidget {
  final String classId;
  const _RosterChatPanel({required this.classId});

  @override
  ConsumerState<_RosterChatPanel> createState() => _RosterChatPanelState();
}

class _RosterChatPanelState extends ConsumerState<_RosterChatPanel> {
  late Future<Conversation> _conv;

  @override
  void initState() {
    super.initState();
    _conv = ref.read(apiClientProvider).openClassChat(widget.classId);
  }

  @override
  void didUpdateWidget(covariant _RosterChatPanel old) {
    super.didUpdateWidget(old);
    // Manager navigated to a different class instance — reload.
    if (old.classId != widget.classId) {
      _conv = ref.read(apiClientProvider).openClassChat(widget.classId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final me = ref.watch(bootstrapProvider).asData?.value.me;
    return Container(
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<Conversation>(
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
      ),
    );
  }
}
