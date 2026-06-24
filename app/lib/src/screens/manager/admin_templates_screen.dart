// Manager Templates — author a weekly schedule of one or more recurring
// "slots" and generate concrete classes N weeks forward. The whole batch can
// be reverted in one tap (refunds + notifications handled server-side).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_product_editor_screen.dart' show adminClassTypesProvider;
import 'class_dialogs.dart'
    show adminInstructorsProvider, adminRoomsProvider, showUndoTemplateDialog;
import 'manager_shell.dart';

final adminTemplatesProvider =
    FutureProvider<List<ClassTemplate>>((ref) async {
  return ref.watch(apiClientProvider).adminListClassTemplates();
});

const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _danger = Color(0xFFA33B2E);
const double _kNarrow = 700;

class AdminTemplatesScreen extends ConsumerWidget {
  const AdminTemplatesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminTemplatesProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminTemplatesProvider),
      child: LayoutBuilder(
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
                  title: 'Templates',
                  sub:
                      'Repeat a weekly schedule — one or more slots, generated weeks ahead',
                  actions: [
                    YButton(
                      label: '+ New template',
                      small: true,
                      onTap: () async {
                        final created = await showNewTemplateDialog(context);
                        if (created == true) {
                          ref.invalidate(adminTemplatesProvider);
                        }
                      },
                    ),
                  ],
                ),
                Expanded(
                  child: data.when(
                    data: (rows) => rows.isEmpty
                        ? _EmptyState()
                        : ListView.separated(
                            itemCount: rows.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (_, i) => _TemplateCard(
                              template: rows[i],
                              onChanged: () =>
                                  ref.invalidate(adminTemplatesProvider),
                            ),
                          ),
                    loading: () => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    error: (e, _) => Center(
                      child: Text(
                        "Can't load templates: ${ApiError.fromAny(e).message}",
                        style: TextStyle(color: context.yoga.muted),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event_repeat_outlined, size: 40, color: y.muted),
          const SizedBox(height: 12),
          Text(
            'No templates yet.',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: y.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Create one to schedule e.g. "Thu 18:30 + Sat 09:30" for 6 weeks.',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateCard extends ConsumerWidget {
  final ClassTemplate template;
  final VoidCallback onChanged;
  const _TemplateCard({required this.template, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final reverted = template.status == 'reverted';
    final classCount = template.generatedClassIds.length;
    return ManagerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      template.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: reverted ? y.muted : y.text,
                        decoration:
                            reverted ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${template.slots.length} slot${template.slots.length == 1 ? '' : 's'} '
                      '× ${template.weeks} week${template.weeks == 1 ? '' : 's'} '
                      '· $classCount class${classCount == 1 ? '' : 'es'}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (reverted)
                _Pill(label: 'Reverted', color: y.muted)
              else
                GestureDetector(
                  onTap: () async {
                    final undone = await showUndoTemplateDialog(
                      context: context,
                      template: template,
                    );
                    if (undone == true) onChanged();
                  },
                  child: Text(
                    'Undo',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: _danger,
                    ),
                  ),
                ),
            ],
          ),
          if (template.slots.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final s in template.slots) _SlotLine(slot: s),
          ],
        ],
      ),
    );
  }
}

class _SlotLine extends StatelessWidget {
  final ClassTemplateSlot slot;
  const _SlotLine({required this.slot});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final time =
        '${slot.startHour.toString().padLeft(2, '0')}:${slot.startMinute.toString().padLeft(2, '0')}';
    final day = _weekdayLabels[slot.weekday.clamp(0, 6)];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 14, color: y.muted),
          const SizedBox(width: 6),
          Text(
            '$day $time',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: y.text,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${slot.title ?? ''}${slot.title != null ? ' · ' : ''}'
              '${slot.durationMins} min · cap ${slot.capacity}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ============================== NEW TEMPLATE ==============================

/// Returns true when a template was created.
Future<bool?> showNewTemplateDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => const Center(
      child: SizedBox(width: 560, child: _NewTemplateDialog()),
    ),
  );
}

/// Mutable per-slot draft held by the dialog.
class _SlotDraft {
  String? classTypeId;
  String? instructorId;
  String? roomId;
  int weekday = 3; // Thu
  int hour = 18;
  int minute = 30;
  int duration = 60;
  int capacity = 14;
  final TextEditingController titleCtrl = TextEditingController();
}

class _NewTemplateDialog extends ConsumerStatefulWidget {
  const _NewTemplateDialog();

  @override
  ConsumerState<_NewTemplateDialog> createState() => _NewTemplateDialogState();
}

class _NewTemplateDialogState extends ConsumerState<_NewTemplateDialog> {
  final _titleCtrl = TextEditingController();
  DateTime _startDate = DateTime.now().add(const Duration(days: 1));
  int _weeks = 6;
  final List<_SlotDraft> _slots = [_SlotDraft()];
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    for (final s in _slots) {
      s.titleCtrl.dispose();
    }
    super.dispose();
  }

  int get _totalClasses => _weeks * _slots.length;

  Future<void> _submit() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Give the template a name.');
      return;
    }
    for (var i = 0; i < _slots.length; i++) {
      final s = _slots[i];
      if (s.classTypeId == null || s.instructorId == null || s.roomId == null) {
        setState(() =>
            _error = 'Slot ${i + 1}: pick a class type, instructor and room.');
        return;
      }
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminCreateClassTemplate({
        'title': _titleCtrl.text.trim(),
        'weeks': _weeks,
        'starts_on': _isoDate(_startDate),
        'slots': [
          for (final s in _slots)
            {
              'class_type_id': s.classTypeId,
              'instructor_id': s.instructorId,
              'room_id': s.roomId,
              'weekday': s.weekday,
              'start_hour': s.hour,
              'start_minute': s.minute,
              'duration_mins': s.duration,
              'capacity': s.capacity,
              if (s.titleCtrl.text.trim().isNotEmpty)
                'title': s.titleCtrl.text.trim(),
            },
        ],
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
    final types = ref.watch(adminClassTypesProvider);
    final instructors = ref.watch(adminInstructorsProvider);
    final rooms = ref.watch(adminRoomsProvider);

    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 640),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          boxShadow: const [
            BoxShadow(
                color: Color(0x40000000),
                offset: Offset(0, 16),
                blurRadius: 50),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'New template',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: y.text),
            ),
            const SizedBox(height: 4),
            Text(
              'Generates $_totalClasses class${_totalClasses == 1 ? '' : 'es'} '
              '(${_slots.length} slot${_slots.length == 1 ? '' : 's'} × $_weeks weeks).',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500, color: y.muted),
            ),
            const SizedBox(height: 18),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Labeled(
                      label: 'TEMPLATE NAME',
                      child: _Text(controller: _titleCtrl, hint: 'Weekend Flow'),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _Labeled(
                            label: 'STARTS ON',
                            child: _DateField(
                              date: _startDate,
                              onPick: (d) => setState(() => _startDate = d),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 120,
                          child: _Labeled(
                            label: 'WEEKS',
                            child: _Number(
                              value: _weeks,
                              min: 1,
                              max: 52,
                              onChange: (v) => setState(() => _weeks = v),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    for (var i = 0; i < _slots.length; i++)
                      _SlotEditor(
                        index: i,
                        draft: _slots[i],
                        types: types,
                        instructors: instructors,
                        rooms: rooms,
                        canRemove: _slots.length > 1,
                        onRemove: () => setState(() => _slots.removeAt(i)),
                        onChanged: () => setState(() {}),
                      ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            setState(() => _slots.add(_SlotDraft())),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add slot'),
                        style: TextButton.styleFrom(foregroundColor: y.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: _danger, fontSize: 12.5)),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(foregroundColor: y.muted),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                YButton(
                  label: _submitting ? 'Generating…' : 'Generate $_totalClasses classes',
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

class _SlotEditor extends StatelessWidget {
  final int index;
  final _SlotDraft draft;
  final AsyncValue<List<ClassType>> types;
  final AsyncValue<List<AdminInstructor>> instructors;
  final AsyncValue<List<AdminRoom>> rooms;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  const _SlotEditor({
    required this.index,
    required this.draft,
    required this.types,
    required this.instructors,
    required this.rooms,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: y.accentSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Slot ${index + 1}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: y.muted),
              ),
              const Spacer(),
              if (canRemove)
                GestureDetector(
                  onTap: onRemove,
                  child: Icon(Icons.close, size: 16, color: y.muted),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _Labeled(
            label: 'CLASS TYPE',
            child: types.when(
              data: (list) => _Dropdown<String>(
                hint: 'Select…',
                value: draft.classTypeId,
                items: {for (final t in list) t.id: t.name},
                onChanged: (v) {
                  draft.classTypeId = v;
                  onChanged();
                },
              ),
              loading: () => const _LoadingField(),
              error: (_, __) => const _LoadingField(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _Labeled(
                  label: 'INSTRUCTOR',
                  child: instructors.when(
                    data: (list) => _Dropdown<String>(
                      hint: 'Select…',
                      value: draft.instructorId,
                      items: {for (final i in list) i.id: i.fullName},
                      onChanged: (v) {
                        draft.instructorId = v;
                        onChanged();
                      },
                    ),
                    loading: () => const _LoadingField(),
                    error: (_, __) => const _LoadingField(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Labeled(
                  label: 'ROOM',
                  child: rooms.when(
                    data: (list) => _Dropdown<String>(
                      hint: 'Select…',
                      value: draft.roomId,
                      items: {for (final r in list) r.id: r.name},
                      onChanged: (v) {
                        draft.roomId = v;
                        onChanged();
                      },
                    ),
                    loading: () => const _LoadingField(),
                    error: (_, __) => const _LoadingField(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Labeled(
                  label: 'DAY',
                  child: _Dropdown<int>(
                    hint: 'Day',
                    value: draft.weekday,
                    items: {
                      for (var d = 0; d < 7; d++) d: _weekdayLabels[d],
                    },
                    onChanged: (v) {
                      if (v != null) draft.weekday = v;
                      onChanged();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 96,
                child: _Labeled(
                  label: 'TIME',
                  child: _TimeField(
                    hour: draft.hour,
                    minute: draft.minute,
                    onPick: (h, m) {
                      draft.hour = h;
                      draft.minute = m;
                      onChanged();
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _Labeled(
                  label: 'DURATION (MIN)',
                  child: _Number(
                    value: draft.duration,
                    min: 5,
                    max: 600,
                    onChange: (v) {
                      draft.duration = v;
                      onChanged();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Labeled(
                  label: 'CAPACITY',
                  child: _Number(
                    value: draft.capacity,
                    min: 1,
                    max: 500,
                    onChange: (v) {
                      draft.capacity = v;
                      onChanged();
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Labeled(
            label: 'SLOT TITLE (OPTIONAL)',
            child: _Text(
                controller: draft.titleCtrl, hint: 'Defaults to template name'),
          ),
        ],
      ),
    );
  }
}

// ---- small shared inputs (local to this screen) ----

class _Labeled extends StatelessWidget {
  final String label;
  final Widget child;
  const _Labeled({required this.label, required this.child});

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

class _BoxedField extends StatelessWidget {
  final Widget child;
  const _BoxedField({required this.child});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: y.surface,
        border: Border.all(color: y.borderStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
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
    return _BoxedField(
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        hint: Text(hint,
            style: TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w600, color: y.muted)),
        style: TextStyle(
            fontSize: 13.5, fontWeight: FontWeight.w600, color: y.text),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _LoadingField extends StatelessWidget {
  const _LoadingField();
  @override
  Widget build(BuildContext context) => const _BoxedField(
        child: SizedBox(
          height: 28,
          child: Center(
            child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
      );
}

class _Text extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  const _Text({required this.controller, this.hint});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return _BoxedField(
      child: TextField(
        controller: controller,
        style: TextStyle(
            fontSize: 13.5, fontWeight: FontWeight.w600, color: y.text),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 7),
          hintText: hint,
        ),
      ),
    );
  }
}

class _Number extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChange;
  const _Number({
    required this.value,
    required this.onChange,
    this.min = 0,
    this.max = 9999,
  });

  @override
  State<_Number> createState() => _NumberState();
}

class _NumberState extends State<_Number> {
  late final TextEditingController _ctrl =
      TextEditingController(text: '${widget.value}');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _commit(String raw) {
    final n = int.tryParse(raw);
    if (n == null) return;
    final clamped = n.clamp(widget.min, widget.max);
    widget.onChange(clamped);
    if (clamped != n) _ctrl.text = '$clamped';
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return _BoxedField(
      child: TextField(
        controller: _ctrl,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: TextStyle(
            fontSize: 13.5, fontWeight: FontWeight.w600, color: y.text),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 7),
        ),
        onChanged: _commit,
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onPick;
  const _DateField({required this.date, required this.onPick});

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
      child: _BoxedField(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Text(
            '${date.day} ${mons[date.month - 1]} ${date.year}',
            style: TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w600, color: y.text),
          ),
        ),
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  final int hour;
  final int minute;
  final void Function(int hour, int minute) onPick;
  const _TimeField(
      {required this.hour, required this.minute, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final label =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: hour, minute: minute),
        );
        if (picked != null) onPick(picked.hour, picked.minute);
      },
      child: _BoxedField(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Text(
            label,
            style: TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w600, color: y.text),
          ),
        ),
      ),
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
