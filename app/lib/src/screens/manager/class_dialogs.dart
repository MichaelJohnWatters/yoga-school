// Class management dialogs — New class (single + template) + Cancel class.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_product_editor_screen.dart' show adminClassTypesProvider;

const _modalWidth = 520.0;
const _danger = Color(0xFFA33B2E);

final adminInstructorsProvider =
    FutureProvider.autoDispose<List<AdminInstructor>>((ref) async {
  return ref.watch(apiClientProvider).adminListInstructors();
});

final adminRoomsProvider =
    FutureProvider.autoDispose<List<AdminRoom>>((ref) async {
  return ref.watch(apiClientProvider).adminListRooms();
});

// ============================== NEW CLASS ==============================

/// Returns the new class id (or template id) on success, null on cancel.
Future<String?> showNewClassDialog(BuildContext context) {
  return showDialog<String?>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: _modalWidth,
        child: const _NewClassDialog(),
      ),
    ),
  );
}

class _NewClassDialog extends ConsumerStatefulWidget {
  const _NewClassDialog();

  @override
  ConsumerState<_NewClassDialog> createState() => _NewClassDialogState();
}

class _NewClassDialogState extends ConsumerState<_NewClassDialog> {
  bool _recurring = false;
  String? _classTypeId;
  String? _instructorId;
  String? _roomId;
  final _titleCtrl = TextEditingController();
  DateTime _startDate = DateTime.now().add(const Duration(days: 1));
  int _startHour = 9;
  int _startMinute = 0;
  int _duration = 60;
  int _capacity = 14;
  int _weeks = 6;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_classTypeId == null || _instructorId == null || _roomId == null) {
      setState(() => _error = 'Class type, instructor and room are required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      if (_recurring) {
        final t = await api.adminCreateClassTemplate({
          'title': _titleCtrl.text.trim().isEmpty
              ? 'Class'
              : _titleCtrl.text.trim(),
          'class_type_id': _classTypeId,
          'instructor_id': _instructorId,
          'room_id': _roomId,
          'weekday': (_startDate.weekday + 6) % 7,
          'start_hour': _startHour,
          'start_minute': _startMinute,
          'duration_mins': _duration,
          'capacity': _capacity,
          'weeks': _weeks,
          'starts_on': _isoDate(_startDate),
        });
        if (mounted) Navigator.of(context).pop(t.id);
      } else {
        final start = DateTime.utc(
          _startDate.year,
          _startDate.month,
          _startDate.day,
          _startHour,
          _startMinute,
        );
        final id = await api.adminCreateClass({
          'class_type_id': _classTypeId,
          'instructor_id': _instructorId,
          'room_id': _roomId,
          'title': _titleCtrl.text.trim(),
          'starts_at': start.toIso8601String(),
          'duration_minutes': _duration,
          'capacity': _capacity,
        });
        if (mounted) Navigator.of(context).pop(id);
      }
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final types = ref.watch(adminClassTypesProvider);
    final instructors = ref.watch(adminInstructorsProvider);
    final rooms = ref.watch(adminRoomsProvider);
    return _DialogChrome(
      title: _recurring ? 'New recurring class' : 'New class',
      sub: _recurring
          ? 'Generates a class for the chosen weekday across the next N weeks.'
          : 'A single class on a single date.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ModeToggle(
            recurring: _recurring,
            onChanged: (v) => setState(() => _recurring = v),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: 'CLASS TYPE',
                  child: types.when(
                    data: (list) => _Dropdown<String>(
                      hint: 'Pick…',
                      value: _classTypeId,
                      items: {for (final t in list) t.id: t.name},
                      onChanged: (v) => setState(() => _classTypeId = v),
                    ),
                    loading: () => _LoadingMini(),
                    error: (e, _) => Text('$e'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'INSTRUCTOR',
                  child: instructors.when(
                    data: (list) => _Dropdown<String>(
                      hint: 'Pick…',
                      value: _instructorId,
                      items: {for (final i in list) i.id: i.fullName},
                      onChanged: (v) => setState(() => _instructorId = v),
                    ),
                    loading: () => _LoadingMini(),
                    error: (e, _) => Text('$e'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: 'ROOM',
                  child: rooms.when(
                    data: (list) => _Dropdown<String>(
                      hint: 'Pick…',
                      value: _roomId,
                      items: {for (final r in list) r.id: r.name},
                      onChanged: (v) => setState(() => _roomId = v),
                    ),
                    loading: () => _LoadingMini(),
                    error: (e, _) => Text('$e'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'TITLE (optional)',
                  child: _TextInput(
                    controller: _titleCtrl,
                    hint: 'Defaults to class type',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: _recurring ? 'FIRST SESSION' : 'DATE',
                  child: _DatePickerBox(
                    date: _startDate,
                    onPick: (d) => setState(() => _startDate = d),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'TIME',
                  child: _TimePickerBox(
                    hour: _startHour,
                    minute: _startMinute,
                    onChange: (h, m) => setState(() {
                      _startHour = h;
                      _startMinute = m;
                    }),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: 'DURATION (MINS)',
                  child: _NumberInput(
                    value: _duration,
                    onChange: (v) => setState(() => _duration = v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'CAPACITY',
                  child: _NumberInput(
                    value: _capacity,
                    onChange: (v) => setState(() => _capacity = v),
                  ),
                ),
              ),
              if (_recurring) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: _LabeledField(
                    label: 'WEEKS',
                    hint: 'How many weeks to schedule',
                    child: _NumberInput(
                      value: _weeks,
                      onChange: (v) => setState(() => _weeks = v),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          if (_recurring) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: y.surface2,
                borderRadius: BorderRadius.circular(10),
              ),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                    height: 1.5,
                  ),
                  children: [
                    const TextSpan(text: 'After creation you can '),
                    TextSpan(
                      text: 'undo the whole batch',
                      style: TextStyle(
                        color: y.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const TextSpan(
                      text:
                          ' — Activity log will offer an Undo for the next 30 days. Cancellations notify enrolled students.',
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _Footer(
            primaryLabel: _submitting
                ? (_recurring ? 'Generating…' : 'Creating…')
                : (_recurring ? 'Generate $_weeks weeks' : 'Create class'),
            onPrimary: _submitting ? null : _submit,
            onCancel: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

class _ModeToggle extends StatelessWidget {
  final bool recurring;
  final ValueChanged<bool> onChanged;
  const _ModeToggle({required this.recurring, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    Widget btn(String label, bool isRecurring) {
      final on = recurring == isRecurring;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(isRecurring),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
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
                fontSize: 13,
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
          btn('Single class', false),
          btn('Recurring template', true),
        ],
      ),
    );
  }
}

// ============================== CANCEL CLASS ==============================

Future<bool?> showCancelClassDialog({
  required BuildContext context,
  required String classId,
  required String classTitle,
  required int bookedCount,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: 460,
        child: _CancelClassDialog(
          classId: classId,
          classTitle: classTitle,
          bookedCount: bookedCount,
        ),
      ),
    ),
  );
}

class _CancelClassDialog extends ConsumerStatefulWidget {
  final String classId;
  final String classTitle;
  final int bookedCount;
  const _CancelClassDialog({
    required this.classId,
    required this.classTitle,
    required this.bookedCount,
  });

  @override
  ConsumerState<_CancelClassDialog> createState() => _CancelClassDialogState();
}

class _CancelClassDialogState extends ConsumerState<_CancelClassDialog> {
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiClientProvider).adminCancelClass(widget.classId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Class cancelled · ${r.bookingsCancelled} bookings released'
          '${r.creditsReturned > 0 ? ', ${r.creditsReturned} credits returned' : ''}.',
        ),
      ));
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final has = widget.bookedCount > 0;
    return _DialogChrome(
      title: 'Cancel this class?',
      sub: has
          ? '$widget.bookedCount student${widget.bookedCount == 1 ? '' : 's'} will be notified and credit-pack credits will be returned.'
          : 'No students are booked yet — the slot just disappears.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: y.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: y.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.classTitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                ),
                if (has)
                  Text(
                    '${widget.bookedCount} booked',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: y.accent,
                    ),
                  ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 18),
          _Footer(
            primaryLabel: _submitting ? 'Cancelling…' : 'Cancel class',
            primaryDanger: true,
            onPrimary: _submitting ? null : _submit,
            onCancel: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

// ============================== CLASS ACTIONS ==============================

/// Shows a small actions modal for a class block tap.
/// Returns true if the underlying schedule should reload.
Future<bool?> showClassActionsSheet({
  required BuildContext context,
  required ClassRow classRow,
  required VoidCallback onOpenRoster,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: 420,
        child: _ClassActionsSheet(classRow: classRow, onOpenRoster: onOpenRoster),
      ),
    ),
  );
}

class _ClassActionsSheet extends StatelessWidget {
  final ClassRow classRow;
  final VoidCallback onOpenRoster;
  const _ClassActionsSheet({
    required this.classRow,
    required this.onOpenRoster,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = classRow.startsAt.toLocal();
    final hh = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dows[(local.weekday + 6) % 7];
    return _DialogChrome(
      title: classRow.title,
      sub: '$dow ${local.day} · $hh · ${classRow.instructorName} · ${classRow.roomName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Capacity meter.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: y.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    classRow.bookingState == BookingState.full
                        ? 'Full — ${classRow.bookedCount} of ${classRow.capacity}'
                        : '${classRow.bookedCount} of ${classRow.capacity} booked',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                  ),
                ),
                Text(
                  '${classRow.durationMinutes} min',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _ActionRow(
            icon: Icons.fact_check_outlined,
            label: 'Open roster',
            sub: 'Attendance, waitlist, scan check-in',
            onTap: () {
              Navigator.of(context).pop(false);
              onOpenRoster();
            },
          ),
          _ActionRow(
            icon: Icons.edit_outlined,
            label: 'Edit class',
            sub: 'Move time / change instructor / capacity',
            onTap: () async {
              Navigator.of(context).pop(false);
              final saved = await showEditClassDialog(
                context: context,
                classRow: classRow,
              );
              if (saved == true) {
                // bubble reload up after the next frame
                Future.microtask(() {
                  // no-op: caller invalidates via its own listener
                });
              }
            },
          ),
          _ActionRow(
            icon: Icons.close,
            label: 'Cancel class',
            sub: classRow.bookedCount == 0
                ? 'No students booked yet — quiet cancellation.'
                : '${classRow.bookedCount} student${classRow.bookedCount == 1 ? '' : 's'} will be notified.',
            destructive: true,
            onTap: () async {
              Navigator.of(context).pop(false);
              await showCancelClassDialog(
                context: context,
                classId: classRow.id,
                classTitle: classRow.title,
                bookedCount: classRow.bookedCount,
              );
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(
                  'Close',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: y.muted,
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

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final bool destructive;
  final VoidCallback onTap;
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final color = destructive ? _danger : y.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: destructive ? const Color(0x1AA33B2E) : y.surface2,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  Text(
                    sub,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (!destructive)
              Icon(Icons.chevron_right, size: 18, color: y.muted),
          ],
        ),
      ),
    );
  }
}

// ============================== EDIT CLASS ==============================

Future<bool?> showEditClassDialog({
  required BuildContext context,
  required ClassRow classRow,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: _modalWidth,
        child: _EditClassDialog(classRow: classRow),
      ),
    ),
  );
}

class _EditClassDialog extends ConsumerStatefulWidget {
  final ClassRow classRow;
  const _EditClassDialog({required this.classRow});

  @override
  ConsumerState<_EditClassDialog> createState() => _EditClassDialogState();
}

class _EditClassDialogState extends ConsumerState<_EditClassDialog> {
  late String? _instructorId;
  late String? _roomId;
  late final TextEditingController _titleCtrl;
  late DateTime _date;
  late int _hour;
  late int _minute;
  late int _duration;
  late int _capacity;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final local = widget.classRow.startsAt.toLocal();
    _instructorId = widget.classRow.instructorId;
    _roomId = null; // resolved lazily once rooms load (name match)
    _titleCtrl = TextEditingController(text: widget.classRow.title);
    _date = DateTime(local.year, local.month, local.day);
    _hour = local.hour;
    _minute = local.minute;
    _duration = widget.classRow.durationMinutes;
    _capacity = widget.classRow.capacity;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final start = DateTime.utc(
        _date.year,
        _date.month,
        _date.day,
        _hour,
        _minute,
      );
      final body = <String, dynamic>{
        'title': _titleCtrl.text.trim(),
        'starts_at': start.toIso8601String(),
        'duration_minutes': _duration,
        'capacity': _capacity,
        if (_instructorId != null) 'instructor_id': _instructorId,
        if (_roomId != null) 'room_id': _roomId,
      };
      final api = ref.read(apiClientProvider);
      await api.raw.patch<void>('/admin/classes/${widget.classRow.id}', data: body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final instructors = ref.watch(adminInstructorsProvider);
    final rooms = ref.watch(adminRoomsProvider);
    return _DialogChrome(
      title: 'Edit class',
      sub: 'Changes do not retroactively cancel bookings — just move them.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: 'TITLE',
                  child: _TextInput(controller: _titleCtrl),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'INSTRUCTOR',
                  child: instructors.when(
                    data: (list) => _Dropdown<String>(
                      hint: 'Pick…',
                      value: _instructorId,
                      items: {for (final i in list) i.id: i.fullName},
                      onChanged: (v) => setState(() => _instructorId = v),
                    ),
                    loading: () => _LoadingMini(),
                    error: (e, _) => Text('$e'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: 'DATE',
                  child: _DatePickerBox(
                    date: _date,
                    onPick: (d) => setState(() => _date = d),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'TIME',
                  child: _TimePickerBox(
                    hour: _hour,
                    minute: _minute,
                    onChange: (h, m) => setState(() {
                      _hour = h;
                      _minute = m;
                    }),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: 'DURATION (MINS)',
                  child: _NumberInput(
                    value: _duration,
                    onChange: (v) => setState(() => _duration = v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'CAPACITY',
                  child: _NumberInput(
                    value: _capacity,
                    onChange: (v) => setState(() => _capacity = v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'ROOM',
                  child: rooms.when(
                    data: (list) {
                      // Resolve current room id from the original name if not picked.
                      _roomId ??= list
                          .firstWhere(
                            (r) => r.name == widget.classRow.roomName,
                            orElse: () => list.first,
                          )
                          .id;
                      return _Dropdown<String>(
                        hint: 'Pick…',
                        value: _roomId,
                        items: {for (final r in list) r.id: r.name},
                        onChanged: (v) => setState(() => _roomId = v),
                      );
                    },
                    loading: () => _LoadingMini(),
                    error: (e, _) => Text('$e'),
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 16),
          _Footer(
            primaryLabel: _submitting ? 'Saving…' : 'Save changes',
            onPrimary: _submitting ? null : _submit,
            onCancel: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

// ============================== UNDO TEMPLATE ==============================

Future<bool?> showUndoTemplateDialog({
  required BuildContext context,
  required ClassTemplate template,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: 460,
        child: _UndoTemplateDialog(template: template),
      ),
    ),
  );
}

class _UndoTemplateDialog extends ConsumerStatefulWidget {
  final ClassTemplate template;
  const _UndoTemplateDialog({required this.template});

  @override
  ConsumerState<_UndoTemplateDialog> createState() => _UndoTemplateDialogState();
}

class _UndoTemplateDialogState extends ConsumerState<_UndoTemplateDialog> {
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiClientProvider).adminUndoClassTemplate(widget.template.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      final s = r.summary;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Undone · ${r.totalClasses} class${r.totalClasses == 1 ? '' : 'es'} cancelled'
          '${s.bookingsCancelled > 0 ? ', ${s.bookingsCancelled} bookings released' : ''}'
          '${s.creditsReturned > 0 ? ', ${s.creditsReturned} credits returned' : ''}.',
        ),
      ));
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return _DialogChrome(
      title: 'Undo this template?',
      sub:
          'Each generated class will be cancelled · students refunded · notifications fired.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: y.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.history, size: 16, color: y.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.template.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                ),
                Text(
                  '${widget.template.generatedClassIds.length} classes',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: y.accent,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 18),
          _Footer(
            primaryLabel: _submitting ? 'Reverting…' : 'Undo template',
            primaryDanger: true,
            onPrimary: _submitting ? null : _submit,
            onCancel: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

// ============================== SHARED ==============================

class _DialogChrome extends StatelessWidget {
  final String title;
  final String sub;
  final Widget child;
  const _DialogChrome({
    required this.title,
    required this.sub,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              offset: Offset(0, 16),
              blurRadius: 50,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: y.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              sub,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: y.muted,
              ),
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final String? hint;
  final Widget child;
  const _LabeledField({required this.label, this.hint, required this.child});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 6),
        child,
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint!,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final String hint;
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;
  const _Dropdown({
    required this.hint,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: y.borderStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        hint: Text(
          hint,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: y.text,
        ),
        items: [
          for (final entry in items.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  const _TextInput({required this.controller, this.hint});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: y.borderStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextField(
        controller: controller,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: y.text,
        ),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 5),
          hintText: hint,
        ),
      ),
    );
  }
}

class _NumberInput extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChange;
  const _NumberInput({required this.value, required this.onChange});

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.value}');
  }

  @override
  void didUpdateWidget(_NumberInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && '${widget.value}' != _ctrl.text) {
      _ctrl.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: y.borderStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextField(
        controller: _ctrl,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null) widget.onChange(n);
        },
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: y.text,
        ),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 5),
        ),
      ),
    );
  }
}

class _DatePickerBox extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onPick;
  const _DatePickerBox({required this.date, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime.now().subtract(const Duration(days: 1)),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (picked != null) onPick(picked);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: y.borderStrong),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today_outlined, size: 14, color: y.muted),
            const SizedBox(width: 8),
            Text(
              '${date.day} ${mons[date.month - 1]} ${date.year}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: y.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimePickerBox extends StatelessWidget {
  final int hour;
  final int minute;
  final void Function(int hour, int minute) onChange;
  const _TimePickerBox({
    required this.hour,
    required this.minute,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final label = '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: hour, minute: minute),
        );
        if (picked != null) onChange(picked.hour, picked.minute);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: y.borderStrong),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.schedule, size: 14, color: y.muted),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingMini extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 40,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
}

class _Footer extends StatelessWidget {
  final String primaryLabel;
  final VoidCallback? onPrimary;
  final VoidCallback onCancel;
  final bool primaryDanger;
  const _Footer({
    required this.primaryLabel,
    required this.onPrimary,
    required this.onCancel,
    this.primaryDanger = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        GestureDetector(
          onTap: onCancel,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(
              'Cancel',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: y.muted,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        if (primaryDanger)
          InkWell(
            onTap: onPrimary,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              decoration: BoxDecoration(
                color: _danger,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                primaryLabel,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          )
        else
          YButton(label: primaryLabel, small: true, onTap: onPrimary),
      ],
    );
  }
}
