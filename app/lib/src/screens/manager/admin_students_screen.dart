// Manager Students — searchable list view.
// Sub line shows "N students · M with an active pass". Row action is
// "View" for students with an active pass, "Grant pass" otherwise.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/polling.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';
import 'money_dialogs.dart';

// NOT autoDispose by design — the silent-refresh pattern in _StudentsBody
// only helps if the previous payload survives a sidebar tab swap. With
// autoDispose, the cache was torn down the moment the user left the
// Students screen, so coming back fell through to the first-load spinner
// every time. Keeping the family alive for the session is cheap (one
// list of student summaries per query) and matches what the UI promises.
final adminStudentsProvider =
    FutureProvider.family<AdminStudentsList, String>((ref, q) async {
  return ref.watch(apiClientProvider).adminListStudents(query: q);
});

class AdminStudentsScreen extends ConsumerStatefulWidget {
  final void Function(String studentId) onView;
  const AdminStudentsScreen({super.key, required this.onView});

  @override
  ConsumerState<AdminStudentsScreen> createState() =>
      _AdminStudentsScreenState();
}

const double _kNarrow = 700;

class _AdminStudentsScreenState extends ConsumerState<AdminStudentsScreen> {
  String _query = '';

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Silent refresh on visit + slow background poll at the students
    // cadence — student list moves rarely but the manager often leaves
    // this tab open while triaging support questions.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _restartPoll();
    });
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(adminStudentsProvider(_query));
  }

  void _restartPoll() {
    _pollTimer?.cancel();
    final prefs = ref.read(pollingPrefsProvider);
    final i = prefs.intervalFor(PollingSurface.students);
    if (i == null) return;
    _pollTimer = Timer.periodic(i, (_) => _refresh());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(adminStudentsProvider(_query));
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _kNarrow;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ManagerPageHeader(
                title: 'Students',
                sub: data.maybeWhen(
                  data: (d) =>
                      '${d.total} student${d.total == 1 ? '' : 's'} · ${d.withActivePass} with an active pass',
                  orElse: () => '',
                ),
                actions: [
                  YButton(
                    label: '+ Grant a pass',
                    small: true,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Pick a student row first.'),
                        ),
                      );
                    },
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: SizedBox(
                  // Full-width search on mobile; capped width on desktop.
                  width: isNarrow ? double.infinity : 320,
                  child: _SearchPill(
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              ),
              Expanded(
                child: _StudentsBody(
                  data: data,
                  query: _query,
                  isNarrow: isNarrow,
                  onView: widget.onView,
                  onGrant: (id) => _openGrant(context, ref, id),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _openGrant(
    BuildContext context, WidgetRef ref, String studentId) async {
  final saved = await showGrantPassDialog(context: context, studentId: studentId);
  if (saved == true) {
    ref.invalidate(adminStudentsProvider);
  }
}

/// Renders the students table with a silent-refresh pattern: when a
/// re-fetch is in flight but we already have cached data (e.g. typing
/// in the search field, or refreshing after a pass grant), we keep
/// the old table on screen and overlay a small refresh chip. Only
/// the *first ever* load with no cached data falls back to a
/// full-screen spinner.
class _StudentsBody extends StatelessWidget {
  final AsyncValue<AdminStudentsList> data;
  final String query;
  final bool isNarrow;
  final void Function(String) onView;
  final void Function(String) onGrant;
  const _StudentsBody({
    required this.data,
    required this.query,
    required this.isNarrow,
    required this.onView,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final cached = data.asData?.value;
    // True for invalidations / query swaps where the previous payload
    // is still useful. The user keeps seeing rows while we re-fetch
    // instead of flashing to a spinner.
    final refreshing = data.isLoading && cached != null;

    if (cached == null) {
      // First-ever load on this query — no previous data to keep
      // around, so a real loading state is appropriate.
      return data.when(
        data: (_) => const SizedBox.shrink(), // covered by cached path
        loading: () => const Center(
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (e, _) => Center(
          child: Text(
            "Can't load students: ${ApiError.fromAny(e).message}",
            style: TextStyle(color: y.muted),
          ),
        ),
      );
    }

    final table = cached.students.isEmpty
        ? _EmptyState(query: query)
        : _StudentsTable(
            rows: cached.students,
            onView: onView,
            onGrant: onGrant,
            isNarrow: isNarrow,
          );

    return Stack(
      children: [
        Positioned.fill(child: table),
        if (refreshing)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: y.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: y.border),
                boxShadow: y.shadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: y.muted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Refreshing…',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
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
                hintText: 'Search name or email…',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentsTable extends StatelessWidget {
  final List<AdminStudentSummary> rows;
  final void Function(String id) onView;
  final void Function(String id) onGrant;
  final bool isNarrow;
  const _StudentsTable({
    required this.rows,
    required this.onView,
    required this.onGrant,
    required this.isNarrow,
  });

  @override
  Widget build(BuildContext context) {
    // fill:true gives the card's child a bounded height (the card sits inside
    // an Expanded up the tree). _Head stays pinned; rows scroll inside the
    // remaining space so any number of students fits without overflow.
    return ManagerCard(
      fill: true,
      child: Column(
        children: [
          if (!isNarrow) _Head(),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: rows.length,
              itemBuilder: (ctx, i) => isNarrow
                  ? _MobileRow(
                      s: rows[i],
                      isLast: i == rows.length - 1,
                      onView: () => onView(rows[i].id),
                      onGrant: () => onGrant(rows[i].id),
                    )
                  : _Row(
                      s: rows[i],
                      isLast: i == rows.length - 1,
                      onView: () => onView(rows[i].id),
                      onGrant: () => onGrant(rows[i].id),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mobile shape — name + email block on top, pass label below it, action
/// link aligned to the right edge. Whole row is tappable.
class _MobileRow extends StatelessWidget {
  final AdminStudentSummary s;
  final bool isLast;
  final VoidCallback onView;
  final VoidCallback onGrant;
  const _MobileRow({
    required this.s,
    required this.isLast,
    required this.onView,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final tap = s.hasActivePass ? onView : onGrant;
    final actionLabel = s.hasActivePass ? 'View ›' : 'Grant ›';
    return InkWell(
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            YAvatar(name: s.fullName, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.fullName,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                  Text(
                    s.email,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.hasActivePass
                        ? '${s.activePassLabel}'
                            '${s.activePassDetail.isEmpty ? '' : ' · ${s.activePassDetail}'}'
                        : 'No active pass',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: s.hasActivePass ? y.text : y.muted,
                    ),
                  ),
                  Text(
                    'Last visit · ${_last(s.lastVisit)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              actionLabel,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: y.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _last(DateTime? d) {
    if (d == null) return 'never';
    final delta = DateTime.now().difference(d);
    if (delta.inDays < 1) return 'today';
    if (delta.inDays < 7) return '${delta.inDays} d ago';
    if (delta.inDays < 30) return '${(delta.inDays / 7).floor()} wk ago';
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${mons[l.month - 1]}';
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
          Expanded(flex: 18, child: Text('STUDENT', style: s)),
          const SizedBox(width: 12),
          Expanded(flex: 14, child: Text('ACTIVE PASS', style: s)),
          const SizedBox(width: 12),
          Expanded(flex: 14, child: Text('REMAINING', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: Text('LAST VISIT', style: s)),
          const SizedBox(width: 12),
          const SizedBox(width: 88),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final AdminStudentSummary s;
  final bool isLast;
  final VoidCallback onView;
  final VoidCallback onGrant;
  const _Row({
    required this.s,
    required this.isLast,
    required this.onView,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 18,
            child: Row(
              children: [
                YAvatar(name: s.fullName, size: 26),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.fullName,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: y.text,
                        ),
                      ),
                      Text(
                        s.email,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: y.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 14,
            child: s.hasActivePass
                ? Text(
                    s.activePassLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                  )
                : Text(
                    '—',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 14,
            child: Text(
              s.activePassDetail.isEmpty ? '—' : s.activePassDetail,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Text(
              _last(s.lastVisit),
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 88,
            child: s.hasActivePass
                ? GestureDetector(
                    onTap: onView,
                    child: Text(
                      'View',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: y.primary,
                      ),
                    ),
                  )
                : GestureDetector(
                    onTap: onGrant,
                    child: Text(
                      'Grant pass',
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

  static String _last(DateTime? d) {
    if (d == null) return 'never';
    final delta = DateTime.now().difference(d);
    if (delta.inDays < 1) return 'today';
    if (delta.inDays < 7) return '${delta.inDays} d ago';
    if (delta.inDays < 30) return '${(delta.inDays / 7).floor()} wk ago';
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${mons[l.month - 1]}';
  }
}

class _EmptyState extends StatelessWidget {
  final String query;
  const _EmptyState({required this.query});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            query.isEmpty
                ? 'No students yet.'
                : 'No matching students.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: y.text,
            ),
          ),
        ],
      ),
    );
  }
}
