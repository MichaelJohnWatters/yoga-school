// Manager Roster — per-class attendance & waitlist.
// Mirrors yoga-admin-b.jsx KRoster: left card (booked + filter chips +
// per-row Present/No-show segmented toggle), right card (waitlist with
// Promote buttons + claim-window note).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart';
import 'manager_shell.dart';

enum _Filter { all, unmarked, present, noShow }

class AdminRosterScreen extends ConsumerStatefulWidget {
  final String classId;
  const AdminRosterScreen({super.key, required this.classId});

  @override
  ConsumerState<AdminRosterScreen> createState() => _AdminRosterScreenState();
}

class _AdminRosterScreenState extends ConsumerState<AdminRosterScreen> {
  late Future<Roster> _roster;
  _Filter _filter = _Filter.all;
  String _query = '';
  final _busy = <String>{}; // booking_ids currently being mutated

  @override
  void initState() {
    super.initState();
    _roster = _fetch();
  }

  Future<Roster> _fetch() {
    return ref.read(apiClientProvider).adminRoster(widget.classId);
  }

  void _reload() {
    setState(() => _roster = _fetch());
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: FutureBuilder<Roster>(
        future: _roster,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                "Can't load roster: ${snap.error}",
                style: TextStyle(color: y.muted),
              ),
            );
          }
          final r = snap.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ManagerPageHeader(
                title: r.klass.title,
                sub: _subline(r.klass),
                actions: [
                  // Cancel class lives here as well as in Schedule; useful
                  // when a manager is already looking at the roster and
                  // realizes the class can't run.
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
                      );
                      if (cancelled == true) _reload();
                    },
                  ),
                  const YButton(label: 'Scan check-in', small: true),
                ],
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: _BookedCard(
                        roster: r,
                        filter: _filter,
                        query: _query,
                        busy: _busy,
                        onFilter: (f) => setState(() => _filter = f),
                        onQuery: (q) => setState(() => _query = q),
                        onMark: _mark,
                        onMarkAllPresent: _markAllPresent,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 4,
                      child: _WaitlistCard(
                        roster: r,
                        onPromote: _promote,
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
  }

  Future<void> _mark(RosterBookingRow row, String status) async {
    setState(() => _busy.add(row.bookingId));
    try {
      await ref.read(apiClientProvider).markAttendance(
            bookingId: row.bookingId,
            status: status,
          );
      _reload();
    } catch (e) {
      _toast('Could not mark: $e');
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
      await Future.wait(unmarked.map(
        (r) => api.markAttendance(bookingId: r.bookingId, status: 'present'),
      ));
      _reload();
    } catch (e) {
      _toast('Some rows failed: $e');
    } finally {
      setState(() => _busy.removeAll(unmarked.map((r) => r.bookingId)));
    }
  }

  Future<void> _promote() async {
    try {
      final r = await ref.read(apiClientProvider).promoteWaitlist(widget.classId);
      _toast('${r.promotedName} promoted off the waitlist');
      _reload();
    } catch (e) {
      _toast('Promote failed: $e');
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
  final ValueChanged<_Filter> onFilter;
  final ValueChanged<String> onQuery;
  final Future<void> Function(RosterBookingRow, String) onMark;
  final Future<void> Function(List<RosterBookingRow>) onMarkAllPresent;
  const _BookedCard({
    required this.roster,
    required this.filter,
    required this.query,
    required this.busy,
    required this.onFilter,
    required this.onQuery,
    required this.onMark,
    required this.onMarkAllPresent,
  });

  @override
  Widget build(BuildContext context) {
    final c = roster.counts;
    final filtered = _filterRows(roster.booked);
    return ManagerCard(
      title: 'Booked · ${c.booked} of ${roster.klass.capacity}',
      action: 'Mark all present',
      onAction: () => onMarkAllPresent(roster.booked),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _FilterPill(label: 'All ${c.booked}', active: filter == _Filter.all, onTap: () => onFilter(_Filter.all)),
                    _FilterPill(label: 'Unmarked ${c.unmarked}', active: filter == _Filter.unmarked, onTap: () => onFilter(_Filter.unmarked)),
                    _FilterPill(label: 'Present ${c.present}', active: filter == _Filter.present, onTap: () => onFilter(_Filter.present)),
                    _FilterPill(label: 'No-show ${c.noShow}', active: filter == _Filter.noShow, onTap: () => onFilter(_Filter.noShow)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 200,
                child: _SearchPill(onChanged: onQuery),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (filtered.isEmpty)
            Padding(
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
          else
            for (var i = 0; i < filtered.length; i++)
              _StudentRow(
                row: filtered[i],
                isLast: i == filtered.length - 1,
                busy: busy.contains(filtered[i].bookingId),
                onMark: (status) => onMark(filtered[i], status),
              ),
        ],
      ),
    );
  }

  List<RosterBookingRow> _filterRows(List<RosterBookingRow> rows) {
    Iterable<RosterBookingRow> it = rows;
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
  final Future<void> Function(String status) onMark;
  const _StudentRow({
    required this.row,
    required this.isLast,
    required this.busy,
    required this.onMark,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          YAvatar(name: row.fullName, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      row.fullName,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: y.text,
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
              ],
            ),
          ),
          _AttendanceToggle(
            status: row.status,
            busy: busy,
            onMark: onMark,
          ),
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
  const _WaitlistCard({required this.roster, required this.onPromote});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return ManagerCard(
      title: 'Waitlist · ${roster.waitlist.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (roster.waitlist.isEmpty)
            Padding(
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
          else
            for (var i = 0; i < roster.waitlist.length; i++) ...[
              _WaitlistRow(
                row: roster.waitlist[i],
                isLast: i == roster.waitlist.length - 1,
                isHead: i == 0,
                onPromote: onPromote,
              ),
            ],
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
