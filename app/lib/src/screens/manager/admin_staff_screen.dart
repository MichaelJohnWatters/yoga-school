// Manager Staff — add / edit instructors + managers, and deactivate those who
// leave. Backend: server/internal/store/admin_staff.go (manager-gated, audited).
// A created staff member signs in with Firebase using the SAME email and the
// auth middleware matches them to the row — no pre-made account needed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

final adminStaffProvider = FutureProvider<List<StaffMember>>((ref) async {
  return ref.watch(apiClientProvider).adminListStaff();
});

const double _kNarrow = 700;

class AdminStaffScreen extends ConsumerWidget {
  final Me me;
  const AdminStaffScreen({super.key, required this.me});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminStaffProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminStaffProvider),
      child: LayoutBuilder(builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _kNarrow;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ManagerPageHeader(
                title: 'Staff',
                sub: 'Instructors and managers who can sign in',
                actions: [
                  YButton(
                    label: '+ Add staff',
                    small: true,
                    onTap: () => _openSheet(context, ref, null, roleLocked: false),
                  ),
                ],
              ),
              Expanded(
                child: data.when(
                  data: (rows) => _List(rows: rows, me: me),
                  loading: () => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (e, _) => Center(
                    child: Text(
                      "Can't load staff: ${ApiError.fromAny(e).message}",
                      style: TextStyle(color: context.yoga.muted),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

Future<void> _openSheet(
  BuildContext context,
  WidgetRef ref,
  StaffMember? existing, {
  required bool roleLocked,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _StaffSheet(existing: existing, roleLocked: roleLocked),
  );
  if (saved == true) ref.invalidate(adminStaffProvider);
}

class _List extends ConsumerWidget {
  final List<StaffMember> rows;
  final Me me;
  const _List({required this.rows, required this.me});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = rows.where((m) => m.active).toList();
    final inactive = rows.where((m) => !m.active).toList();
    final activeOwners =
        active.where((m) => m.role == 'owner').length;

    // The deactivate control is hidden for yourself and for the last active
    // owner (the server enforces this too; the UI just avoids a dead button).
    bool canDeactivate(StaffMember m) =>
        m.id != me.id && !(m.role == 'owner' && activeOwners <= 1);
    // The role can't be changed for yourself or the last owner.
    bool roleLocked(StaffMember m) =>
        m.id == me.id || (m.role == 'owner' && activeOwners <= 1);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ManagerCard(
            title: '${active.length} active',
            child: active.isEmpty
                ? _EmptyHint()
                : Column(
                    children: [
                      for (var i = 0; i < active.length; i++)
                        _StaffRow(
                          m: active[i],
                          isLast: i == active.length - 1,
                          onEdit: () => _openSheet(context, ref, active[i],
                              roleLocked: roleLocked(active[i])),
                          onDeactivate: canDeactivate(active[i])
                              ? () => _setActive(context, ref, active[i], false)
                              : null,
                        ),
                    ],
                  ),
          ),
          if (inactive.isNotEmpty) ...[
            const SizedBox(height: 14),
            ManagerCard(
              title: 'Deactivated',
              child: Column(
                children: [
                  for (var i = 0; i < inactive.length; i++)
                    _StaffRow(
                      m: inactive[i],
                      isLast: i == inactive.length - 1,
                      onReactivate: () =>
                          _setActive(context, ref, inactive[i], true),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _setActive(
      BuildContext context, WidgetRef ref, StaffMember m, bool active) async {
    final y = context.yoga;
    if (!active) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: y.surface,
          title: Text('Deactivate ${m.fullName}?',
              style: TextStyle(color: y.text)),
          content: Text(
            "They'll be blocked from signing in and won't appear when "
            "scheduling classes. Their past records stay. You can reactivate "
            "them any time.",
            style: TextStyle(color: y.text, fontSize: 13.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Deactivate'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      final api = ref.read(apiClientProvider);
      if (active) {
        await api.adminReactivateStaff(m.id);
      } else {
        await api.adminDeactivateStaff(m.id);
      }
      ref.invalidate(adminStaffProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${ApiError.fromAny(e).message}')),
        );
      }
    }
  }
}

class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        'No staff yet — click "Add staff" to add an instructor or manager.',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.yoga.muted,
        ),
      ),
    );
  }
}

class _StaffRow extends StatelessWidget {
  final StaffMember m;
  final bool isLast;
  final VoidCallback? onEdit;
  final VoidCallback? onDeactivate;
  final VoidCallback? onReactivate;
  const _StaffRow({
    required this.m,
    required this.isLast,
    this.onEdit,
    this.onDeactivate,
    this.onReactivate,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final dim = !m.active;
    final row = Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: dim ? 0.5 : 1,
            child: YAvatar(name: m.fullName, size: 34, photoUrl: m.photoUrl),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.fullName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: dim ? y.muted : y.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  m.email,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          _roleChip(m.role),
          if (onReactivate != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: YButton(
                label: 'Reactivate',
                small: true,
                variant: YButtonVariant.outline,
                onTap: onReactivate,
              ),
            ),
          if (onDeactivate != null)
            IconButton(
              onPressed: onDeactivate,
              icon: Icon(Icons.block_outlined, size: 18, color: y.muted),
              tooltip: 'Deactivate',
            ),
          if (onEdit != null)
            Icon(Icons.chevron_right, size: 18, color: y.muted),
        ],
      ),
    );
    return onEdit != null ? InkWell(onTap: onEdit, child: row) : row;
  }

  static Widget _roleChip(String role) {
    final (label, kind) = switch (role) {
      'owner' => ('Owner', YChipKind.accent),
      'manager' => ('Manager', YChipKind.booked),
      _ => ('Instructor', YChipKind.neutral),
    };
    return YChip(kind: kind, label: label);
  }
}

class _StaffSheet extends ConsumerStatefulWidget {
  final StaffMember? existing;
  final bool roleLocked;
  const _StaffSheet({required this.existing, required this.roleLocked});

  @override
  ConsumerState<_StaffSheet> createState() => _StaffSheetState();
}

class _StaffSheetState extends ConsumerState<_StaffSheet> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  late String _role;
  bool _submitting = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.fullName ?? '');
    _email = TextEditingController(text: e?.email ?? '');
    _role = e?.role ?? 'instructor';
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: y.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isEdit ? 'Edit staff member' : 'Add staff member',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  enabled: !_submitting,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  enabled: !_submitting,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'instructor', child: Text('Instructor')),
                    DropdownMenuItem(value: 'manager', child: Text('Manager')),
                    DropdownMenuItem(value: 'owner', child: Text('Owner')),
                  ],
                  onChanged: (_submitting || widget.roleLocked)
                      ? null
                      : (v) => setState(() => _role = v ?? _role),
                ),
                if (widget.roleLocked) ...[
                  const SizedBox(height: 6),
                  Text(
                    "You can't change this role (it's your own account or the "
                    'last owner).',
                    style: TextStyle(fontSize: 11.5, color: y.muted, height: 1.4),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  'They sign in with Firebase using this email to get access — '
                  'no separate account needed.',
                  style: TextStyle(fontSize: 11.5, color: y.muted, height: 1.4),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFFA33B2E),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                YButton(
                  label: _submitting
                      ? 'Saving…'
                      : (_isEdit ? 'Save changes' : 'Add staff'),
                  onTap: _submitting ? null : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty || email.isEmpty) {
      setState(() => _error = 'Name and email are required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      if (_isEdit) {
        await api.adminUpdateStaff(
          id: widget.existing!.id,
          role: _role,
          email: email,
          fullName: name,
        );
      } else {
        await api.adminCreateStaff(role: _role, email: email, fullName: name);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }
}
