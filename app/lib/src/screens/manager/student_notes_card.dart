// Student notes card — staff-visible free-text context attached to a
// student. Lives on admin_student_detail_screen.dart as a hero section
// above the wallet / bookings columns: injury info, preferences, and
// other "what the next instructor needs to know" facts belong front and
// centre, not buried.
//
// Per-row author + relative time + an "edited" marker. The original
// author of a note can edit / delete it; anyone else just reads. The
// server enforces author-only mutations independently — the UI gate is
// purely a "don't show buttons that won't work" hint.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

/// Session-scoped — visiting the detail page repeatedly during triage
/// shouldn't re-fetch every time. Mutations invalidate this family
/// keyed by the student id.
final studentNotesProvider =
    FutureProvider.family<List<StudentNote>, String>((ref, studentId) async {
  return ref.watch(apiClientProvider).adminListStudentNotes(studentId);
});

class StudentNotesCard extends ConsumerWidget {
  final String studentId;
  /// The signed-in staff member's id — used to gate the edit/delete
  /// affordances. Pulled from the bootstrap by the parent so this
  /// widget stays presentational.
  final String currentUserId;
  const StudentNotesCard({
    super.key,
    required this.studentId,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final notes = ref.watch(studentNotesProvider(studentId));
    return ManagerCard(
      title: 'Notes',
      child: notes.when(
        data: (list) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 0),
                child: Text(
                  'No notes yet — add anything the next instructor or '
                  'front-desk colleague should know about this student.',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                    height: 1.45,
                  ),
                ),
              )
            else
              for (var i = 0; i < list.length; i++)
                _NoteRow(
                  note: list[i],
                  isLast: i == list.length - 1,
                  canMutate: list[i].authorId == currentUserId,
                  studentId: studentId,
                ),
            const SizedBox(height: 10),
            _AddNoteRow(studentId: studentId),
          ],
        ),
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (e, _) => Text(
          "Can't load notes: ${ApiError.fromAny(e).message}",
          style: TextStyle(color: y.muted, fontSize: 12.5),
        ),
      ),
    );
  }
}

/// Inline "add a note" affordance — a single-line field that grows to
/// multi-line as the user types. Submit on Cmd/Ctrl+Enter OR the Save
/// button. Empty body is silently ignored on blur (matches the store's
/// "empty body refused" rule).
class _AddNoteRow extends ConsumerStatefulWidget {
  final String studentId;
  const _AddNoteRow({required this.studentId});

  @override
  ConsumerState<_AddNoteRow> createState() => _AddNoteRowState();
}

class _AddNoteRowState extends ConsumerState<_AddNoteRow> {
  final _ctrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final body = _ctrl.text.trim();
    if (body.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).adminCreateStudentNote(
            studentId: widget.studentId,
            body: body,
          );
      _ctrl.clear();
      ref.invalidate(studentNotesProvider(widget.studentId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't save: ${ApiError.fromAny(e).message}")),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: y.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Add a note — visible to all staff',
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: y.border),
                ),
              ),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: y.text,
              ),
            ),
          ),
          const SizedBox(width: 8),
          YButton(
            label: _saving ? 'Saving…' : 'Add',
            small: true,
            onTap: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

class _NoteRow extends ConsumerStatefulWidget {
  final StudentNote note;
  final bool isLast;
  final bool canMutate;
  final String studentId;
  const _NoteRow({
    required this.note,
    required this.isLast,
    required this.canMutate,
    required this.studentId,
  });

  @override
  ConsumerState<_NoteRow> createState() => _NoteRowState();
}

class _NoteRowState extends ConsumerState<_NoteRow> {
  bool _editing = false;
  late TextEditingController _ctrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.note.body);
  }

  @override
  void didUpdateWidget(_NoteRow old) {
    super.didUpdateWidget(old);
    // Server-driven update — keep the field in sync when not editing.
    if (!_editing && old.note.body != widget.note.body) {
      _ctrl.text = widget.note.body;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _commitEdit() async {
    final next = _ctrl.text.trim();
    if (next == widget.note.body) {
      setState(() => _editing = false);
      return;
    }
    if (next.isEmpty) {
      _ctrl.text = widget.note.body;
      setState(() => _editing = false);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).adminUpdateStudentNote(
            noteId: widget.note.id,
            body: next,
          );
      ref.invalidate(studentNotesProvider(widget.studentId));
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      _ctrl.text = widget.note.body;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't update: ${ApiError.fromAny(e).message}")),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text(
          "This can't be undone — but the audit log keeps a copy with "
          "the note body, so support can still answer 'what did the "
          "note say' after deletion.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).adminDeleteStudentNote(widget.note.id);
      ref.invalidate(studentNotesProvider(widget.studentId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't delete: ${ApiError.fromAny(e).message}")),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final n = widget.note;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: widget.isLast
            ? null
            : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_editing)
            TextField(
              controller: _ctrl,
              minLines: 1,
              maxLines: 8,
              autofocus: true,
              onSubmitted: (_) => _commitEdit(),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: y.border),
                ),
              ),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: y.text,
                height: 1.45,
              ),
            )
          else
            Text(
              n.body,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: y.text,
                height: 1.45,
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _footer(n),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ),
              if (_busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (widget.canMutate && !_editing) ...[
                _IconAction(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit',
                  onTap: () => setState(() => _editing = true),
                ),
                const SizedBox(width: 10),
                _IconAction(
                  icon: Icons.delete_outline,
                  tooltip: 'Delete',
                  onTap: _delete,
                ),
              ] else if (widget.canMutate && _editing) ...[
                _IconAction(
                  icon: Icons.check,
                  tooltip: 'Save edit',
                  onTap: _commitEdit,
                ),
                const SizedBox(width: 10),
                _IconAction(
                  icon: Icons.close,
                  tooltip: 'Cancel edit',
                  onTap: () {
                    _ctrl.text = widget.note.body;
                    setState(() => _editing = false);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _footer(StudentNote n) {
    final base = '${n.authorName} · ${_relTime(n.createdAt)}';
    return n.wasEdited ? '$base · edited' : base;
  }

  static String _relTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inDays < 1) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    if (delta.inDays < 30) return '${(delta.inDays / 7).floor()}w ago';
    // For older notes the absolute date is more useful than "8mo ago".
    return '${t.day} ${_mon(t.month)} ${t.year}';
  }

  static String _mon(int m) {
    const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                   'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return names[m - 1];
  }
}

/// Tiny icon-only button with hover/splash + tooltip — used for the
/// per-row edit/delete affordances. Inline because they're trivial and
/// only used here.
class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 17, color: y.muted),
        ),
      ),
    );
  }
}
