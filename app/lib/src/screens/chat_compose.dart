// Staff-only "start a conversation" flow.
//
// [startNewConversation] pops an action sheet — New group / New direct
// message — then routes to a picker. Both pickers reuse the admin students
// directory (the only people staff can currently start a thread with) and,
// on success, replace themselves with the freshly-opened [ChatThreadScreen].
//
// Creation is gated server-side by requireStaff; these entry points only
// render for staff, so a student never reaches them.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'chat_screen.dart';

void startNewConversation(BuildContext context, WidgetRef ref, Me me) {
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('New group'),
            subtitle: const Text('A named room with several students'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => _NewGroupScreen(me: me)),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Direct message'),
            subtitle: const Text('A private 1:1 with a student'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => _NewDmScreen(me: me)));
            },
          ),
        ],
      ),
    ),
  );
}

/// Loads the studio's students once per picker, filtered by a live query.
final _studentSearchProvider = FutureProvider.autoDispose
    .family<List<AdminStudentSummary>, String>((ref, query) async {
      return ref
          .watch(apiClientProvider)
          .chatableStudents(query: query.trim().isEmpty ? null : query.trim());
    });

class _NewDmScreen extends ConsumerStatefulWidget {
  final Me me;
  const _NewDmScreen({required this.me});

  @override
  ConsumerState<_NewDmScreen> createState() => _NewDmScreenState();
}

class _NewDmScreenState extends ConsumerState<_NewDmScreen> {
  String _query = '';
  bool _opening = false;

  Future<void> _open(AdminStudentSummary s) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final conv = await ref.read(apiClientProvider).openDm(s.id);
      if (!mounted) return;
      ref.invalidate(conversationsProvider);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
            conversationId: conv.id,
            initialConversation: conv,
            me: widget.me,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _opening = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't open: ${ApiError.fromAny(e).message}"),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final students = ref.watch(_studentSearchProvider(_query));
    return Scaffold(
      backgroundColor: y.background,
      appBar: AppBar(
        backgroundColor: y.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: y.text,
        title: const Text(
          'New message',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _SearchField(onChanged: (v) => setState(() => _query = v)),
            Expanded(
              child: students.when(
                data: (list) => _StudentList(
                  students: list,
                  trailing: (_) => _opening
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.chevron_right, color: y.muted),
                  onTap: _open,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Text(
                    "Can't load students: ${ApiError.fromAny(e).message}",
                    style: TextStyle(color: y.muted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewGroupScreen extends ConsumerStatefulWidget {
  final Me me;
  const _NewGroupScreen({required this.me});

  @override
  ConsumerState<_NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<_NewGroupScreen> {
  final _name = TextEditingController();
  final _selected = <String>{};
  String _query = '';
  bool _creating = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _name.text.trim();
    if (title.isEmpty || _creating) return;
    setState(() => _creating = true);
    try {
      final conv = await ref
          .read(apiClientProvider)
          .createGroup(title: title, memberIds: _selected.toList());
      if (!mounted) return;
      ref.invalidate(conversationsProvider);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
            conversationId: conv.id,
            initialConversation: conv,
            me: widget.me,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't create: ${ApiError.fromAny(e).message}"),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final students = ref.watch(_studentSearchProvider(_query));
    final canCreate = _name.text.trim().isNotEmpty && !_creating;
    return Scaffold(
      backgroundColor: y.background,
      appBar: AppBar(
        backgroundColor: y.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: y.text,
        title: const Text(
          'New group',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          TextButton(
            onPressed: canCreate ? _create : null,
            child: Text(
              'Create',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: canCreate ? y.primary : y.muted,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _name,
                onChanged: (_) => setState(() {}),
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Group name',
                  filled: true,
                  fillColor: y.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: y.border),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _selected.isEmpty
                      ? 'Add members'
                      : '${_selected.length} selected',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: y.muted,
                  ),
                ),
              ),
            ),
            _SearchField(onChanged: (v) => setState(() => _query = v)),
            Expanded(
              child: students.when(
                data: (list) => _StudentList(
                  students: list,
                  trailing: (s) => Checkbox(
                    value: _selected.contains(s.id),
                    onChanged: (_) => setState(() {
                      if (!_selected.add(s.id)) _selected.remove(s.id);
                    }),
                  ),
                  onTap: (s) => setState(() {
                    if (!_selected.add(s.id)) _selected.remove(s.id);
                  }),
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Text(
                    "Can't load students: ${ApiError.fromAny(e).message}",
                    style: TextStyle(color: y.muted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchField({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Search students…',
          prefixIcon: Icon(Icons.search, color: y.muted, size: 20),
          filled: true,
          fillColor: y.surface,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: y.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: y.border),
          ),
        ),
      ),
    );
  }
}

class _StudentList extends StatelessWidget {
  final List<AdminStudentSummary> students;
  final Widget Function(AdminStudentSummary) trailing;
  final void Function(AdminStudentSummary) onTap;
  const _StudentList({
    required this.students,
    required this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    if (students.isEmpty) {
      return Center(
        child: Text('No students found', style: TextStyle(color: y.muted)),
      );
    }
    return ListView.separated(
      itemCount: students.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: y.border, indent: 70),
      itemBuilder: (_, i) {
        final s = students[i];
        return ListTile(
          leading: YAvatar(name: s.fullName, photoUrl: s.photoUrl, size: 40),
          title: Text(
            s.fullName,
            style: TextStyle(fontWeight: FontWeight.w700, color: y.text),
          ),
          subtitle: Text(
            s.email,
            style: TextStyle(color: y.muted, fontSize: 12),
          ),
          trailing: trailing(s),
          onTap: () => onTap(s),
        );
      },
    );
  }
}
