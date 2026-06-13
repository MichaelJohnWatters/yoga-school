// Manager Students — searchable list view.
// Sub line shows "N students · M with an active pass". Row action is
// "View" for students with an active pass, "Grant pass" otherwise.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';
import 'money_dialogs.dart';

final adminStudentsProvider =
    FutureProvider.autoDispose.family<AdminStudentsList, String>((ref, q) async {
  return ref.watch(apiClientProvider).adminListStudents(query: q);
});

class AdminStudentsScreen extends ConsumerStatefulWidget {
  final void Function(String studentId) onView;
  const AdminStudentsScreen({super.key, required this.onView});

  @override
  ConsumerState<AdminStudentsScreen> createState() =>
      _AdminStudentsScreenState();
}

class _AdminStudentsScreenState extends ConsumerState<AdminStudentsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(adminStudentsProvider(_query));
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
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
            // Top "Grant a pass" action removed — the flow needs a student
            // selected first and per-row "Grant pass" already covers it.
            // Re-add via a student picker dialog when one exists.
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SizedBox(
              width: 320,
              child: _SearchPill(
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
          Expanded(
            child: data.when(
              data: (d) => d.students.isEmpty
                  ? _EmptyState(query: _query)
                  : _StudentsTable(
                      rows: d.students,
                      onView: widget.onView,
                      onGrant: (id) => _openGrant(context, ref, id),
                    ),
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (e, _) => Center(
                child: Text(
                  "Can't load students: $e",
                  style: TextStyle(color: context.yoga.muted),
                ),
              ),
            ),
          ),
        ],
      ),
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
  const _StudentsTable({
    required this.rows,
    required this.onView,
    required this.onGrant,
  });

  @override
  Widget build(BuildContext context) {
    return ManagerCard(
      child: Column(
        children: [
          _Head(),
          for (var i = 0; i < rows.length; i++)
            _Row(
              s: rows[i],
              isLast: i == rows.length - 1,
              onView: () => onView(rows[i].id),
              onGrant: () => onGrant(rows[i].id),
            ),
        ],
      ),
    );
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
