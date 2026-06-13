// Booking sheet — bottom sheet shown when the user taps a class row.
// Mirrors the class detail / booking sheet pattern from yoga-student2.jsx.
//
// For an available class:
//   1. Fetch eligible entitlements
//   2. If none → show "Buy a new pass…" fallback (Buy flow not yet wired)
//   3. If one or more → preselect best, show "Book this class" button
//
// For a class the user already booked: shows "Cancel booking" with the
// snapshotted cutoff line.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';

class BookingSheet extends ConsumerStatefulWidget {
  final ClassRow classRow;
  const BookingSheet({super.key, required this.classRow});

  @override
  ConsumerState<BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends ConsumerState<BookingSheet> {
  late Future<List<EligibleEntitlement>> _eligible;
  String? _selectedEntitlementId;
  bool _plusOne = false;
  bool _submitting = false;
  String? _conflict;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiClientProvider);
    _eligible = api.eligibleEntitlements(widget.classRow.id);
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final c = widget.classRow;
    final boot = ref.watch(bootstrapProvider).value;
    final plusOneAllowed = boot?.studio.allowStudentPlusOne ?? false;
    final cutoffHours = boot?.studio.freeCancelCutoffHours ?? 12;
    final localStart = c.startsAt.toLocal();
    const dowFull = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dowFull[(localStart.weekday + 6) % 7];
    final timeLabel = '${localStart.hour}:${localStart.minute.toString().padLeft(2, '0')}';
    final dateMeta = '$dow ${localStart.day} · $timeLabel · ${c.roomName}';

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: SafeArea(
          top: false,
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
              const SizedBox(height: 14),
              Text(
                c.title,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: y.text,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    dateMeta,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                  const Spacer(),
                  if (c.bookingState == BookingState.available &&
                      c.spotsLeft > 0 && c.spotsLeft <= 3)
                    YChip(
                      kind: YChipKind.accent,
                      label: '${c.spotsLeft} spots left',
                    )
                  else if (c.bookingState == BookingState.full)
                    const YChip(kind: YChipKind.full, label: 'Full class'),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  YAvatar(name: c.instructorName, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'with ${c.instructorName} · ${c.bookedCount} of ${c.capacity} booked',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (c.bookingState == BookingState.booked)
                _BookedActions(
                  classRow: c,
                  cutoffHours: cutoffHours,
                  onCancelled: () => Navigator.of(context).pop(true),
                )
              else if (c.bookingState == BookingState.full)
                _FullClassActions(
                  classId: c.id,
                  onJoined: () => Navigator.of(context).pop(true),
                )
              else
                _PayWithSection(
                  eligible: _eligible,
                  selected: _selectedEntitlementId,
                  onSelect: (id) => setState(() => _selectedEntitlementId = id),
                ),
              if (c.bookingState == BookingState.available && plusOneAllowed) ...[
                const SizedBox(height: 12),
                _PlusOneToggle(
                  on: _plusOne,
                  onChanged: (v) => setState(() => _plusOne = v),
                ),
              ],
              if (_conflict != null) ...[
                const SizedBox(height: 12),
                Text(
                  _conflict!,
                  style: TextStyle(
                    color: const Color(0xFFA33B2E),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (c.bookingState == BookingState.available) ...[
                const SizedBox(height: 14),
                YButton(
                  label: _submitting ? 'Booking…' : 'Book this class',
                  onTap: _submitting ? null : _book,
                ),
                const SizedBox(height: 8),
                Text(
                  'Free cancellation until $cutoffHours hours before. After that, your credit is used.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _book() async {
    final api = ref.read(apiClientProvider);
    final eligible = await _eligible;
    final id = _selectedEntitlementId ?? (eligible.isNotEmpty ? eligible.first.id : null);
    if (id == null) {
      setState(() => _conflict = 'No eligible pass — buy one first.');
      return;
    }
    setState(() {
      _submitting = true;
      _conflict = null;
    });
    try {
      await api.createBooking(
        classId: widget.classRow.id,
        entitlementId: id,
        plusOne: _plusOne,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on BookingConflict catch (e) {
      setState(() {
        _submitting = false;
        _conflict = e.message;
      });
    } catch (e) {
      setState(() {
        _submitting = false;
        _conflict = 'Something went wrong: $e';
      });
    }
  }
}

class _PlusOneToggle extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onChanged;
  const _PlusOneToggle({required this.on, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bring a +1',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Uses a 2nd credit',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.85,
            child: Switch(
              value: on,
              onChanged: onChanged,
              activeThumbColor: y.onPrimary,
              activeTrackColor: y.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FullClassActions extends ConsumerStatefulWidget {
  final String classId;
  final VoidCallback onJoined;
  const _FullClassActions({required this.classId, required this.onJoined});

  @override
  ConsumerState<_FullClassActions> createState() => _FullClassActionsState();
}

class _FullClassActionsState extends ConsumerState<_FullClassActions> {
  bool _joining = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: y.accentSoft,
            borderRadius: BorderRadius.circular(y.radiusCard),
          ),
          child: Row(
            children: [
              Icon(Icons.list_alt, size: 18, color: y.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "We'll notify you if a spot opens — you'll have 60 minutes to claim it.",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: y.text,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: const TextStyle(
              color: Color(0xFFA33B2E),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 14),
        YButton(
          label: _joining ? 'Joining…' : 'Join waitlist',
          onTap: _joining ? null : _join,
        ),
      ],
    );
  }

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).joinWaitlist(widget.classId);
      widget.onJoined();
    } catch (e) {
      setState(() {
        _joining = false;
        _error = 'Could not join waitlist: $e';
      });
    }
  }
}

class _PayWithSection extends StatelessWidget {
  final Future<List<EligibleEntitlement>> eligible;
  final String? selected;
  final ValueChanged<String> onSelect;
  const _PayWithSection({
    required this.eligible,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'PAY WITH',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<EligibleEntitlement>>(
          future: eligible,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            if (snap.hasError) {
              return Text(
                "Can't load passes: ${snap.error}",
                style: TextStyle(color: y.muted, fontSize: 12),
              );
            }
            final list = snap.data ?? const <EligibleEntitlement>[];
            if (list.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: y.surface2,
                  borderRadius: BorderRadius.circular(y.radiusCard),
                ),
                child: Row(
                  children: [
                    Icon(Icons.shopping_bag_outlined, color: y.muted, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'No eligible pass — buy one first.',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: y.text,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            final preselect = selected ?? list.first.id;
            return Column(
              children: [
                for (final e in list) ...[
                  _EntitlementRow(
                    item: e,
                    selected: e.id == preselect,
                    onTap: () => onSelect(e.id),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _EntitlementRow extends StatelessWidget {
  final EligibleEntitlement item;
  final bool selected;
  final VoidCallback onTap;
  const _EntitlementRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final meta = item.passKind == 'unlimited'
        ? 'Unlimited · expires ${_d(item.expiresAt)}'
        : '${item.creditsRemaining ?? 0} credits left · expires ${_d(item.expiresAt)}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? y.primarySoft : y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(
            color: selected ? y.primary : y.border,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? y.primary : y.borderStrong, width: 1.5),
              ),
              alignment: Alignment.center,
              child: selected
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: y.primary,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              item.passKind == 'unlimited' ? 'Unlimited' : '1 credit',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: y.primaryStrong,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _d(DateTime? d) {
    if (d == null) return '—';
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final local = d.toLocal();
    return '${local.day} ${mons[local.month - 1]}';
  }
}

class _BookedActions extends ConsumerStatefulWidget {
  final ClassRow classRow;
  final int cutoffHours;
  final VoidCallback onCancelled;
  const _BookedActions({
    required this.classRow,
    required this.cutoffHours,
    required this.onCancelled,
  });

  @override
  ConsumerState<_BookedActions> createState() => _BookedActionsState();
}

class _BookedActionsState extends ConsumerState<_BookedActions> {
  bool _cancelling = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const YChip(kind: YChipKind.booked, label: 'You\'re booked', leadingCheck: true),
        const SizedBox(height: 14),
        if (_error != null) ...[
          Text(_error!,
              style: const TextStyle(color: Color(0xFFA33B2E), fontSize: 13)),
          const SizedBox(height: 10),
        ],
        YButton(
          label: _cancelling ? 'Cancelling…' : 'Cancel booking',
          variant: YButtonVariant.outline,
          onTap: _cancelling ? null : _cancel,
        ),
        const SizedBox(height: 8),
        Text(
          'Free cancellation until ${widget.cutoffHours} hours before.',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: y.muted),
        ),
      ],
    );
  }

  Future<void> _cancel() async {
    final api = ref.read(apiClientProvider);
    final id = widget.classRow.bookingId;
    if (id == null) return;
    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      await api.cancelBooking(id);
      widget.onCancelled();
    } catch (e) {
      setState(() {
        _cancelling = false;
        _error = 'Could not cancel: $e';
      });
    }
  }
}
