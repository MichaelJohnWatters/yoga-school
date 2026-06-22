// Class management dialogs — New class (single + template) + Cancel class.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_product_editor_screen.dart' show adminClassTypesProvider;
import 'money_dialogs.dart' show showGrantPassDialog;

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
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Give the class a title.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final start = DateTime.utc(
        _startDate.year,
        _startDate.month,
        _startDate.day,
        _startHour,
        _startMinute,
      );
      if (_recurring) {
        // Materialize via the recurrence model so generated classes back-link
        // to a recurrence_rule_id. That's what makes the scope picker (this /
        // future / all) show up when the manager later edits a single
        // session in the series.
        final res = await api.adminCreateClass({
          'class_type_id': _classTypeId,
          'instructor_id': _instructorId,
          'room_id': _roomId,
          'title': _titleCtrl.text.trim(),
          'starts_at': start.toIso8601String(),
          'duration_minutes': _duration,
          'capacity': _capacity,
          'recurrence': {
            'frequency': 'weekly',
            'interval': 1,
            'weekdays': [(_startDate.weekday + 6) % 7],
            'starts_on': _isoDate(_startDate),
            'occurrences': _weeks,
          },
        });
        // Server returns either {id: ...} for one-off or {rule_id, generated_class_ids: [...]}
        // for recurrence — pop the first generated id so the schedule grid can
        // focus the freshly-created series.
        final firstId = (res['generated_class_ids'] as List?)?.firstOrNull as String?
            ?? res['rule_id'] as String?
            ?? '';
        if (mounted) Navigator.of(context).pop(firstId);
      } else {
        final res = await api.adminCreateClass({
          'class_type_id': _classTypeId,
          'instructor_id': _instructorId,
          'room_id': _roomId,
          'title': _titleCtrl.text.trim(),
          'starts_at': start.toIso8601String(),
          'duration_minutes': _duration,
          'capacity': _capacity,
        });
        if (mounted) Navigator.of(context).pop(res['id'] as String?);
      }
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
                    error: (e, _) => Text(ApiError.fromAny(e).message),
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
                    error: (e, _) => Text(ApiError.fromAny(e).message),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LabeledField(
                  label: 'TITLE',
                  child: _TextInput(
                    controller: _titleCtrl,
                    hint: 'e.g. Slow Flow',
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
  /// Set when the class is rule-backed — surfaces the scope picker
  /// (this / future) so the manager can cancel the rest of the series too.
  bool isRecurring = false,
  /// Local-time start of the class. Used to detect past-class cancels and
  /// force the type-to-confirm gate. Null = treat as not-past.
  DateTime? startsAt,
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
          isRecurring: isRecurring,
          startsAt: startsAt,
        ),
      ),
    ),
  );
}

class _CancelClassDialog extends ConsumerStatefulWidget {
  final String classId;
  final String classTitle;
  final int bookedCount;
  final bool isRecurring;
  final DateTime? startsAt;
  const _CancelClassDialog({
    required this.classId,
    required this.classTitle,
    required this.bookedCount,
    required this.isRecurring,
    required this.startsAt,
  });

  @override
  ConsumerState<_CancelClassDialog> createState() => _CancelClassDialogState();
}

// Phrase the manager must type to confirm a past-class cancel. Kept lower
// case to keep the typing low-friction once they've decided.
const _kPastClassConfirmPhrase = 'yes cancel past class';

class _CancelClassDialogState extends ConsumerState<_CancelClassDialog> {
  bool _submitting = false;
  String? _error;
  // Default to "this" so a single tap on Cancel for a series row still does
  // the conservative thing.
  String _scope = 'this';
  // Past-class gate: when [startsAt] is in the past we hide the primary
  // action behind a typed-confirm step. _gateAck flips to true on
  // "Continue" and the text field then has to match _kPastClassConfirmPhrase.
  bool _gateAck = false;
  final _confirmCtrl = TextEditingController();

  bool get _isPast {
    final s = widget.startsAt;
    if (s == null) return false;
    return s.isBefore(DateTime.now());
  }

  @override
  void initState() {
    super.initState();
    _confirmCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiClientProvider).adminCancelClass(
            widget.classId,
            scope: widget.isRecurring ? _scope : null,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      final tail = r.classesCancelled > 1
          ? '${r.classesCancelled} classes · ${r.bookingsCancelled} bookings released'
          : '${r.bookingsCancelled} bookings released';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Cancelled · $tail'
          '${r.creditsReturned > 0 ? ', ${r.creditsReturned} credits returned' : ''}.',
        ),
      ));
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
    final has = widget.bookedCount > 0;
    final past = _isPast;
    // The user has to clear two gates for a past class: acknowledge the
    // warning, then type the phrase exactly. _submit stays disabled until
    // both are satisfied (and we're not mid-flight).
    final phraseOk =
        _confirmCtrl.text.trim().toLowerCase() == _kPastClassConfirmPhrase;
    final canSubmit = !_submitting && (!past || (_gateAck && phraseOk));
    return _DialogChrome(
      title: past ? 'Cancel a past class?' : 'Cancel this class?',
      sub: past
          ? "This class already started or has ended. Cancelling it now is "
              "unusual — it's mostly used to clean up bad data or correct a "
              "no-show record. Bookings will still be released."
          : has
              ? '${widget.bookedCount} student${widget.bookedCount == 1 ? '' : 's'} will be notified and credit-pack credits will be returned.'
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
          if (widget.isRecurring) ...[
            const SizedBox(height: 14),
            _ScopePicker(
              value: _scope,
              onChanged: (v) => setState(() => _scope = v),
              allowAll: false, // cancelling "all" is rarely wanted — start conservative
              destructive: true,
            ),
          ],
          if (past) ...[
            const SizedBox(height: 14),
            _PastClassGate(
              acknowledged: _gateAck,
              onAcknowledge: () => setState(() => _gateAck = true),
              confirmController: _confirmCtrl,
              phrase: _kPastClassConfirmPhrase,
              phraseOk: phraseOk,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 18),
          _Footer(
            primaryLabel: _submitting ? 'Cancelling…' : 'Cancel class',
            primaryDanger: true,
            onPrimary: canSubmit ? _submit : null,
            onCancel: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

/// Two-stage gate that fronts a past-class cancel. Step 1 is a single
/// "I understand, continue" tap — keeps a misclick on a yesterday-row from
/// silently submitting. Step 2 reveals a text field that has to match the
/// phrase exactly before the dialog's primary action re-enables.
class _PastClassGate extends StatelessWidget {
  final bool acknowledged;
  final VoidCallback onAcknowledge;
  final TextEditingController confirmController;
  final String phrase;
  final bool phraseOk;
  const _PastClassGate({
    required this.acknowledged,
    required this.onAcknowledge,
    required this.confirmController,
    required this.phrase,
    required this.phraseOk,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: y.borderStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_toggle_off, size: 16, color: y.text),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Past-class safety check',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "Most past-class cancellations are accidents. Confirm twice "
            "to continue.",
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              height: 1.45,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 12),
          if (!acknowledged)
            Align(
              alignment: Alignment.centerLeft,
              child: YButton(
                label: 'I understand, continue',
                variant: YButtonVariant.outline,
                small: true,
                onTap: onAcknowledge,
              ),
            )
          else ...[
            Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: y.text,
                ),
                children: [
                  const TextSpan(text: 'Type '),
                  TextSpan(
                    text: phrase,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const TextSpan(text: ' to confirm.'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: confirmController,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                hintText: phrase,
                hintStyle: TextStyle(color: y.muted),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: y.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: phraseOk ? y.primary : y.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                      color: phraseOk ? y.primary : y.borderStrong, width: 1.4),
                ),
              ),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: y.text,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact radio-style picker for the recurrence scope on edit/cancel. Used
/// only when the class is rule-backed.
class _ScopePicker extends StatelessWidget {
  final String value; // 'this' | 'future' | 'all'
  final ValueChanged<String> onChanged;
  final bool allowAll;
  final bool destructive;
  const _ScopePicker({
    required this.value,
    required this.onChanged,
    this.allowAll = true,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final entries = <(String, String, String)>[
      ('this', 'This class only', 'Leave the rest of the series untouched.'),
      ('future', 'This and future', 'Apply to every session from this one onwards.'),
      if (allowAll)
        ('all', 'All in series', 'Apply to every non-detached session, past + future.'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in entries)
            InkWell(
              onTap: () => onChanged(e.$1),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    Icon(
                      value == e.$1
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: value == e.$1
                          ? (destructive ? _danger : y.primary)
                          : y.muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.$2,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: y.text,
                            ),
                          ),
                          Text(
                            e.$3,
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
                isRecurring: classRow.isRecurring,
                startsAt: classRow.startsAt,
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
  // Only meaningful when the class is rule-backed. Defaults to "this" so a
  // single-class edit on a series row stays conservative.
  String _scope = 'this';

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
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Give the class a title.');
      return;
    }
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
      // Server enforces: starts_at only patchable at scope=this. For bulk
      // scopes we strip it client-side to avoid the 400 trip-up.
      final isBulk = widget.classRow.isRecurring && _scope != 'this';
      final body = <String, dynamic>{
        'title': _titleCtrl.text.trim(),
        if (!isBulk) 'starts_at': start.toIso8601String(),
        'duration_minutes': _duration,
        'capacity': _capacity,
        if (_instructorId != null) 'instructor_id': _instructorId,
        if (_roomId != null) 'room_id': _roomId,
      };
      final api = ref.read(apiClientProvider);
      await api.adminPatchClass(
        widget.classRow.id,
        body,
        scope: widget.classRow.isRecurring ? _scope : null,
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
                    error: (e, _) => Text(ApiError.fromAny(e).message),
                  ),
                ),
              ),
            ],
          ),
          if (widget.classRow.isRecurring) ...[
            const SizedBox(height: 14),
            _ScopePicker(
              value: _scope,
              onChanged: (v) => setState(() => _scope = v),
            ),
            if (_scope != 'this') ...[
              const SizedBox(height: 6),
              Text(
                'Date / time can only change on a single class. The other '
                'fields will apply to ${_scope == 'all' ? 'every non-detached session' : 'every session from this one onward'}.',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: context.yoga.muted,
                  height: 1.4,
                ),
              ),
            ],
          ],
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
        _error = ApiError.fromAny(e).message;
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
  const _LoadingMini();
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
  /// Nullable so callers can disable Cancel while a submit is in flight —
  /// matches onPrimary's shape so both buttons follow the same disabled-
  /// during-submit pattern.
  final VoidCallback? onCancel;
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

// ============================== ADD STUDENT TO CLASS ==============================

/// Manager-side "Add to class" picker. Two-step:
///   1. Search/pick a student.
///   2. Pick one of their eligible passes (+ optional +1).
///
/// Returns `true` on a successful book so the caller can refresh the
/// roster. Returns `null` on cancel.
///
/// When the chosen student has no eligible pass we surface a clear
/// empty-state with a "Grant a pass first" callout — the server would
/// refuse the request anyway, but it's friendlier to block the manager
/// before they fill the form.
Future<bool?> showAddStudentToClassDialog({
  required BuildContext context,
  required String classId,
  required String classTitle,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (_) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _modalWidth),
        child: _AddStudentDialog(classId: classId, classTitle: classTitle),
      ),
    ),
  );
}

class _AddStudentDialog extends ConsumerStatefulWidget {
  final String classId;
  final String classTitle;
  const _AddStudentDialog({required this.classId, required this.classTitle});

  @override
  ConsumerState<_AddStudentDialog> createState() => _AddStudentDialogState();
}

class _AddStudentDialogState extends ConsumerState<_AddStudentDialog> {
  String _query = '';
  AdminStudentSummary? _picked;
  Future<List<EligibleEntitlement>>? _passes;
  String? _passId;
  bool _plusOne = false;
  final _plusOneNameCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _plusOneNameCtrl.dispose();
    super.dispose();
  }

  void _selectStudent(AdminStudentSummary s) {
    setState(() {
      _picked = s;
      _passId = null;
      _plusOne = false;
      _plusOneNameCtrl.clear();
      _error = null;
      _passes = ref
          .read(apiClientProvider)
          .adminEligibleEntitlements(classId: widget.classId, userId: s.id);
    });
  }

  /// Opens the existing grant-pass dialog for the currently-picked
  /// student, and on success re-fetches their eligible passes so the
  /// new pass appears in the picker without the manager having to
  /// re-search for the student.
  Future<void> _grantPassForPicked() async {
    final picked = _picked;
    if (picked == null) return;
    final granted = await showGrantPassDialog(
      context: context,
      studentId: picked.id,
    );
    if (granted == true && mounted) {
      _selectStudent(picked);
    }
  }

  Future<void> _submit() async {
    final picked = _picked;
    final passId = _passId;
    if (picked == null || passId == null) return;
    if (_plusOne && _plusOneNameCtrl.text.trim().isEmpty) {
      setState(() => _error = "Add the friend's name for the +1.");
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminCreateBooking(
            classId: widget.classId,
            userId: picked.id,
            entitlementId: passId,
            plusOne: _plusOne,
            plusOneName: _plusOne ? _plusOneNameCtrl.text.trim() : null,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogChrome(
      title: 'Add student to class',
      sub: widget.classTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _LabeledField(
            label: 'STUDENT',
            child: _StudentPicker(
              query: _query,
              picked: _picked,
              onQuery: (q) => setState(() => _query = q),
              onPick: _selectStudent,
            ),
          ),
          if (_picked != null) ...[
            const SizedBox(height: 16),
            FutureBuilder<List<EligibleEntitlement>>(
              future: _passes,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _LoadingMini();
                }
                if (snap.hasError) {
                  return Text(
                    "Could not load passes: ${ApiError.fromAny(snap.error ?? Exception('unknown')).message}",
                    style: TextStyle(
                      fontSize: 12.5,
                      color: context.yoga.muted,
                    ),
                  );
                }
                final passes = snap.data ?? const [];
                if (passes.isEmpty) {
                  return _NoEligiblePassesCallout(
                    student: _picked!,
                    onGrantPass: () => _grantPassForPicked(),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _LabeledField(
                      label: 'PAY WITH',
                      child: _PassPicker(
                        passes: passes,
                        value: _passId,
                        onChanged: (id) => setState(() => _passId = id),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _PlusOneToggle(
                      enabled: _passId != null &&
                          passes
                                  .firstWhere((p) => p.id == _passId,
                                      orElse: () => passes.first)
                                  .passKind ==
                              'credit',
                      enabledHint:
                          '+1 requires a credit pass · uses 2 credits',
                      disabledHint:
                          '+1 is not allowed on an unlimited pass — pick a credit pass to enable.',
                      value: _plusOne,
                      onChanged: (v) => setState(() {
                        _plusOne = v;
                        if (!v) _plusOneNameCtrl.clear();
                      }),
                    ),
                    if (_plusOne) ...[
                      const SizedBox(height: 12),
                      _LabeledField(
                        label: 'FRIEND’S NAME',
                        child: _TextInput(
                          controller: _plusOneNameCtrl,
                          hint: 'e.g. Lara Patel',
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _danger,
              ),
            ),
          ],
          const SizedBox(height: 20),
          _Footer(
            primaryLabel: _submitting ? 'Booking…' : 'Book',
            primaryDanger: false,
            onCancel: _submitting ? null : () => Navigator.of(context).pop(),
            onPrimary: (_submitting || _picked == null || _passId == null)
                ? null
                : _submit,
          ),
        ],
      ),
    );
  }
}

class _StudentPicker extends ConsumerStatefulWidget {
  final String query;
  final AdminStudentSummary? picked;
  final ValueChanged<String> onQuery;
  final ValueChanged<AdminStudentSummary> onPick;
  const _StudentPicker({
    required this.query,
    required this.picked,
    required this.onQuery,
    required this.onPick,
  });

  @override
  ConsumerState<_StudentPicker> createState() => _StudentPickerState();
}

class _StudentPickerState extends ConsumerState<_StudentPicker> {
  late Future<AdminStudentsList> _future;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _future = ref.read(apiClientProvider).adminListStudents();
  }

  void _refreshIfQueryChanged() {
    if (widget.query.trim() == _lastQuery) return;
    _lastQuery = widget.query.trim();
    _future = ref
        .read(apiClientProvider)
        .adminListStudents(query: _lastQuery.isEmpty ? null : _lastQuery);
  }

  @override
  Widget build(BuildContext context) {
    _refreshIfQueryChanged();
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search box.
        Container(
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
                  onChanged: widget.onQuery,
                  style: TextStyle(fontSize: 13, color: y.text),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Find a student…',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Results list. Capped height so the dialog doesn't overflow on
        // a studio with hundreds of students.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: FutureBuilder<AdminStudentsList>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const _LoadingMini();
              }
              if (snap.hasError) {
                return Text(
                  "Could not load students: ${ApiError.fromAny(snap.error ?? Exception('unknown')).message}",
                  style: TextStyle(color: y.muted, fontSize: 12.5),
                );
              }
              final all = snap.data?.students ?? const [];
              if (all.isEmpty) {
                return Text(
                  'No students match.',
                  style: TextStyle(color: y.muted, fontSize: 12.5),
                );
              }
              return ListView.builder(
                itemCount: all.length,
                itemBuilder: (context, i) {
                  final s = all[i];
                  final picked = widget.picked?.id == s.id;
                  return InkWell(
                    onTap: () => widget.onPick(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: picked ? y.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          YAvatar(name: s.fullName, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.fullName,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
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
                          if (picked)
                            Icon(Icons.check, color: y.primary, size: 18),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PassPicker extends StatelessWidget {
  final List<EligibleEntitlement> passes;
  final String? value;
  final ValueChanged<String> onChanged;
  const _PassPicker({
    required this.passes,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in passes)
          InkWell(
            onTap: () => onChanged(p.id),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: value == p.id ? y.accentSoft : y.surface,
                borderRadius: BorderRadius.circular(y.radiusChip),
                border: Border.all(
                  color: value == p.id ? y.primary : y.border,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    p.passKind == 'unlimited'
                        ? Icons.all_inclusive
                        : Icons.confirmation_number_outlined,
                    size: 16,
                    color: y.muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      p.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: y.text,
                      ),
                    ),
                  ),
                  Text(
                    p.passKind == 'credit'
                        ? '${p.creditsRemaining ?? 0} left'
                        : 'unlimited',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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

class _PlusOneToggle extends StatelessWidget {
  final bool enabled;
  final bool value;
  final String enabledHint;
  final String disabledHint;
  final ValueChanged<bool> onChanged;
  const _PlusOneToggle({
    required this.enabled,
    required this.value,
    required this.enabledHint,
    required this.disabledHint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Row(
        children: [
          Switch(
            value: enabled && value,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: y.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bring a +1 guest',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                Text(
                  enabled ? enabledHint : disabledHint,
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
    );
  }
}

class _NoEligiblePassesCallout extends StatelessWidget {
  final AdminStudentSummary student;
  /// Called when the manager taps the inline "Grant a pass" action.
  /// Parent opens the existing grant-pass dialog and, on success,
  /// re-fetches eligible passes so the picker fills in without the
  /// manager having to navigate away.
  final VoidCallback onGrantPass;
  const _NoEligiblePassesCallout({
    required this.student,
    required this.onGrantPass,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: y.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${student.fullName} has no eligible pass',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'No active pass covers this class type. Grant one now and '
            'it will appear in the picker.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: y.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: YButton(
              label: 'Grant a pass',
              small: true,
              onTap: onGrantPass,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================== REMOVE FROM CLASS ==============================

/// Returns `true` on a successful cancel so the caller can refresh.
/// Returns `null` on dismiss.
Future<bool?> showRemoveFromClassDialog({
  required BuildContext context,
  required String bookingId,
  required String studentName,
  required String classTitle,
  required String passKind,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x66000000),
    builder: (_) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _modalWidth),
        child: _RemoveFromClassDialog(
          bookingId: bookingId,
          studentName: studentName,
          classTitle: classTitle,
          passKind: passKind,
        ),
      ),
    ),
  );
}

class _RemoveFromClassDialog extends ConsumerStatefulWidget {
  final String bookingId;
  final String studentName;
  final String classTitle;
  final String passKind;
  const _RemoveFromClassDialog({
    required this.bookingId,
    required this.studentName,
    required this.classTitle,
    required this.passKind,
  });

  @override
  ConsumerState<_RemoveFromClassDialog> createState() =>
      _RemoveFromClassDialogState();
}

class _RemoveFromClassDialogState
    extends ConsumerState<_RemoveFromClassDialog> {
  // Default to refunding — it's the studio taking the seat back, so
  // returning the credit is the friendly default. Manager flips for
  // courtesy / no-show-after-the-fact cases.
  bool _refund = true;
  final _reasonCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminCancelBooking(
            bookingId: widget.bookingId,
            refundCredit: _refund,
            reason: _reasonCtrl.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Unlimited passes: the refund toggle is meaningless (nothing to
    // refund), so hide it and always send refund=true so the audit row
    // reads cleanly.
    final showRefundChoice = widget.passKind == 'credit';
    return _DialogChrome(
      title: 'Remove from class',
      sub: '${widget.studentName} · ${widget.classTitle}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showRefundChoice) ...[
            _RefundChoiceTile(
              label: 'Return the credit',
              sub: 'Default — student gets their credit back.',
              icon: Icons.replay,
              selected: _refund,
              onTap: () => setState(() => _refund = true),
            ),
            const SizedBox(height: 8),
            _RefundChoiceTile(
              label: 'Consume the credit',
              sub: 'No-show / courtesy cancel — credit stays burned.',
              icon: Icons.local_fire_department_outlined,
              selected: !_refund,
              onTap: () => setState(() => _refund = false),
            ),
            const SizedBox(height: 14),
          ] else
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                'This booking used an unlimited pass — nothing to refund. '
                'The seat will be released.',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: context.yoga.muted,
                  height: 1.4,
                ),
              ),
            ),
          _LabeledField(
            label: 'REASON (OPTIONAL)',
            child: _TextInput(
              controller: _reasonCtrl,
              hint: 'e.g. studio called to confirm cancel',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _danger,
              ),
            ),
          ],
          const SizedBox(height: 20),
          _Footer(
            primaryLabel: _submitting ? 'Removing…' : 'Remove',
            primaryDanger: true,
            onCancel: _submitting ? null : () => Navigator.of(context).pop(),
            onPrimary: _submitting ? null : _submit,
          ),
        ],
      ),
    );
  }
}

class _RefundChoiceTile extends StatelessWidget {
  final String label;
  final String sub;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _RefundChoiceTile({
    required this.label,
    required this.sub,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(y.radiusCard),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? y.accentSoft : y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: selected ? y.primary : y.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? y.primary : y.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    sub,
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
    );
  }
}
