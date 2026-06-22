// New-series dialog — creates a class type + product + enrollment + N classes
// in one atomic call. Reuses small form primitives from class_dialogs (the
// duplicate fits since both stay small and self-contained).
//
// Also exposes Edit series (PATCH /admin/enrollments/{id}) which only allows
// title / description / capacity since the server keeps the rest immutable
// to avoid wrecking already-booked sessions.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'class_dialogs.dart' show adminInstructorsProvider, adminRoomsProvider;

const double _modalWidth = 520.0;
const Color _danger = Color(0xFFA33B2E);

Future<bool?> showNewSeriesDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: _modalWidth,
        child: const _NewSeriesDialog(),
      ),
    ),
  );
}

class _NewSeriesDialog extends ConsumerStatefulWidget {
  const _NewSeriesDialog();

  @override
  ConsumerState<_NewSeriesDialog> createState() => _NewSeriesDialogState();
}

class _NewSeriesDialogState extends ConsumerState<_NewSeriesDialog> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController(text: '60.00');
  String? _instructorId;
  String? _roomId;
  DateTime _startDate = DateTime.now().add(const Duration(days: 14));
  int _hour = 18;
  int _minute = 0;
  int _duration = 60;
  int _capacity = 10;
  int _sessions = 6;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  int get _priceMinor {
    final v = double.tryParse(_priceCtrl.text) ?? 0;
    return (v * 100).round();
  }

  Future<void> _submit() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Title is required.');
      return;
    }
    if (_instructorId == null || _roomId == null) {
      setState(() => _error = 'Instructor and room are required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminCreateSeries({
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'price_minor': _priceMinor,
        'instructor_id': _instructorId,
        'room_id': _roomId,
        'weekday': (_startDate.weekday + 6) % 7,
        'start_hour': _hour,
        'start_minute': _minute,
        'duration_mins': _duration,
        'capacity': _capacity,
        'session_count': _sessions,
        'starts_on': _isoDate(_startDate),
      });
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
    final instructors = ref.watch(adminInstructorsProvider);
    final rooms = ref.watch(adminRoomsProvider);
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
              'New series',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: y.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'One purchase books the student into every session — a class type, a product, the enrollment and N classes are created together.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: y.muted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            _Field(
              label: 'TITLE',
              child: _TextInput(controller: _titleCtrl, hint: "e.g. Beginners' Course · Autumn"),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'DESCRIPTION (optional)',
              child: _TextInput(
                controller: _descCtrl,
                hint: 'Shown on the Enrollments tab',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Field(
                    label: 'INSTRUCTOR',
                    child: instructors.when(
                      data: (list) => _Dropdown<String>(
                        value: _instructorId,
                        items: {for (final i in list) i.id: i.fullName},
                        onChanged: (v) => setState(() => _instructorId = v),
                      ),
                      loading: () => _LoadingMini(),
                      error: (e, _) => Text(ApiError.fromAny(e).message),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Field(
                    label: 'ROOM',
                    child: rooms.when(
                      data: (list) => _Dropdown<String>(
                        value: _roomId,
                        items: {for (final r in list) r.id: r.name},
                        onChanged: (v) => setState(() => _roomId = v),
                      ),
                      loading: () => _LoadingMini(),
                      error: (e, _) => Text(ApiError.fromAny(e).message),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Field(
                    label: 'FIRST SESSION',
                    child: _DateBox(
                      date: _startDate,
                      onPick: (d) => setState(() => _startDate = d),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Field(
                    label: 'TIME',
                    child: _TimeBox(
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
                  child: _Field(
                    label: 'DURATION (MINS)',
                    child: _NumberInput(
                      value: _duration,
                      onChange: (v) => setState(() => _duration = v),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Field(
                    label: 'CAPACITY',
                    child: _NumberInput(
                      value: _capacity,
                      onChange: (v) => setState(() => _capacity = v),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Field(
                    label: 'SESSIONS',
                    child: _NumberInput(
                      value: _sessions,
                      onChange: (v) => setState(() => _sessions = v),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Field(
                    label: 'PRICE (GBP)',
                    child: _TextInput(
                      controller: _priceCtrl,
                      hint: '60.00',
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: y.surface2,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'One payment covers $_sessions sessions. No credits.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: _danger, fontSize: 12.5)),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 9),
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
                YButton(
                  label: _submitting ? 'Creating…' : 'Create $_sessions-session series',
                  small: true,
                  onTap: _submitting ? null : _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

// ============================== EDIT SERIES ==============================

Future<bool?> showEditSeriesDialog({
  required BuildContext context,
  required EnrollmentSummary series,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: 460,
        child: _EditSeriesDialog(series: series),
      ),
    ),
  );
}

class _EditSeriesDialog extends ConsumerStatefulWidget {
  final EnrollmentSummary series;
  const _EditSeriesDialog({required this.series});

  @override
  ConsumerState<_EditSeriesDialog> createState() => _EditSeriesDialogState();
}

class _EditSeriesDialogState extends ConsumerState<_EditSeriesDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;
  late int _capacity;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.series.title);
    _descCtrl = TextEditingController(text: widget.series.description);
    _capacity = widget.series.capacity;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Title is required.');
      return;
    }
    if (_capacity < widget.series.enrolledCount) {
      setState(() => _error = 'Capacity cannot drop below '
          '${widget.series.enrolledCount} (already enrolled).');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminUpdateEnrollment(
            enrollmentId: widget.series.id,
            title: _titleCtrl.text.trim(),
            description: _descCtrl.text.trim(),
            capacity: _capacity,
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
              'Edit series',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: y.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Schedule and pricing stay fixed — only title, description, and capacity can change.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: y.muted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            _Field(
              label: 'TITLE',
              child: _TextInput(controller: _titleCtrl),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'DESCRIPTION',
              child: _TextInput(controller: _descCtrl),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Field(
                    label: 'CAPACITY',
                    child: _NumberInput(
                      value: _capacity,
                      onChange: (v) => setState(() => _capacity = v),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: y.surface2,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${widget.series.enrolledCount} enrolled · '
                      'cannot drop below that.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: _danger, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 9,
                    ),
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
                YButton(
                  label: _submitting ? 'Saving…' : 'Save changes',
                  small: true,
                  onTap: _submitting ? null : _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- inline lightweight form primitives (kept local to avoid coupling) ----

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

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
      ],
    );
  }
}

class _TextInput extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final List<TextInputFormatter>? inputFormatters;
  const _TextInput({
    required this.controller,
    this.hint,
    this.inputFormatters,
  });

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
        inputFormatters: inputFormatters,
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

class _Dropdown<T> extends StatelessWidget {
  final T? value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;
  const _Dropdown({
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
          'Pick…',
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
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _DateBox extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onPick;
  const _DateBox({required this.date, required this.onPick});

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

class _TimeBox extends StatelessWidget {
  final int hour;
  final int minute;
  final void Function(int hour, int minute) onChange;
  const _TimeBox({
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
