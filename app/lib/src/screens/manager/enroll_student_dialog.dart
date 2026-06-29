// Manager "enroll a student into this series" dialog — desk sign-ups
// (comp / cash / card / transfer). Search a student, pick how they paid, enrol.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_students_screen.dart' show adminStudentsProvider;

/// Returns true if a student was enrolled.
Future<bool?> showEnrollStudentDialog({
  required BuildContext context,
  required String enrollmentId,
  required int seatsLeft,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: 460,
        child: _EnrollStudentDialog(
          enrollmentId: enrollmentId,
          seatsLeft: seatsLeft,
        ),
      ),
    ),
  );
}

const _payMethods = <String, String>{
  'comp': 'Comp',
  'cash': 'Cash',
  'card': 'Card',
  'transfer': 'Transfer',
};

class _EnrollStudentDialog extends ConsumerStatefulWidget {
  final String enrollmentId;
  final int seatsLeft;
  const _EnrollStudentDialog({
    required this.enrollmentId,
    required this.seatsLeft,
  });

  @override
  ConsumerState<_EnrollStudentDialog> createState() =>
      _EnrollStudentDialogState();
}

class _EnrollStudentDialogState extends ConsumerState<_EnrollStudentDialog> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  AdminStudentSummary? _selected;
  String _paymentMethod = 'comp';
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_selected == null) {
      setState(() => _error = 'Pick a student first.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminEnrollStudent(
            enrollmentId: widget.enrollmentId,
            userId: _selected!.id,
            paymentMethod: _paymentMethod,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final full = widget.seatsLeft <= 0;
    return Material(
      color: y.surface,
      borderRadius: BorderRadius.circular(y.radiusCard),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Enroll a student',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: y.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              full
                  ? 'This series is full — enrolling now will be refused.'
                  : '${widget.seatsLeft} seat${widget.seatsLeft == 1 ? '' : 's'} left · '
                      'books them into every remaining session.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: full ? const Color(0xFFA33B2E) : y.muted,
              ),
            ),
            const SizedBox(height: 14),
            if (_selected == null) ...[
              _SearchField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
              const SizedBox(height: 10),
              SizedBox(height: 220, child: _Results(
                query: _query,
                onPick: (s) => setState(() {
                  _selected = s;
                  _error = null;
                }),
              )),
            ] else ...[
              _SelectedRow(
                student: _selected!,
                onClear: () => setState(() => _selected = null),
              ),
              const SizedBox(height: 14),
              Text(
                'PAID VIA',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: y.muted,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 6),
              _PaymentSeg(
                value: _paymentMethod,
                onChanged: (v) => setState(() => _paymentMethod = v),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFA33B2E), fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                YButton(
                  label: 'Cancel',
                  variant: YButtonVariant.outline,
                  small: true,
                  onTap: () => Navigator.of(context).pop(false),
                ),
                const SizedBox(width: 10),
                YButton(
                  label: _submitting ? 'Enrolling…' : 'Enroll',
                  small: true,
                  onTap: _submitting || _selected == null ? null : _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: true,
      style: TextStyle(fontSize: 14, color: y.text),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search students by name or email',
        prefixIcon: Icon(Icons.search, size: 18, color: y.muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: y.borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: y.border),
        ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  final String query;
  final ValueChanged<AdminStudentSummary> onPick;
  const _Results({required this.query, required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final data = ref.watch(adminStudentsProvider(query));
    return data.when(
      data: (list) {
        if (list.students.isEmpty) {
          return Center(
            child: Text(
              query.isEmpty ? 'Start typing to find a student.' : 'No matches.',
              style: TextStyle(color: y.muted, fontSize: 13),
            ),
          );
        }
        return ListView.separated(
          itemCount: list.students.length,
          separatorBuilder: (_, __) => Divider(height: 1, color: y.border),
          itemBuilder: (_, i) {
            final s = list.students[i];
            return ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(
                s.fullName,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: y.text,
                ),
              ),
              subtitle: Text(
                s.email,
                style: TextStyle(fontSize: 11.5, color: y.muted),
              ),
              trailing: s.hasActivePass
                  ? YChip(kind: YChipKind.neutral, label: 'has pass')
                  : null,
              onTap: () => onPick(s),
            );
          },
        );
      },
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 1.5)),
      error: (e, _) => Center(
        child: Text(
          "Can't load students: ${ApiError.fromAny(e).message}",
          style: TextStyle(color: y.muted, fontSize: 12.5),
        ),
      ),
    );
  }
}

class _SelectedRow extends StatelessWidget {
  final AdminStudentSummary student;
  final VoidCallback onClear;
  const _SelectedRow({required this.student, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  student.fullName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                Text(
                  student.email,
                  style: TextStyle(fontSize: 11.5, color: y.muted),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onClear,
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }
}

class _PaymentSeg extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _PaymentSeg({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Wrap(
      spacing: 8,
      children: [
        for (final e in _payMethods.entries)
          GestureDetector(
            onTap: () => onChanged(e.key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: value == e.key ? y.primarySoft : y.surface2,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: value == e.key ? y.primary : y.border,
                ),
              ),
              child: Text(
                e.value,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: value == e.key ? y.primaryStrong : y.muted,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
