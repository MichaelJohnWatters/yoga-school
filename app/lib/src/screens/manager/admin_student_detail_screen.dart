// Manager Student detail — header + active passes + history + actions.
// Shows the same wallet shape as the student-side Wallet, plus manager
// affordances per entitlement: Adjust credits (credit kind only) and Void.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../export/csv_download.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_students_screen.dart';
import 'manager_shell.dart';
import 'money_dialogs.dart';
import 'student_notes_card.dart';

final adminStudentDetailProvider =
    FutureProvider.autoDispose.family<AdminStudentDetail, String>((ref, id) async {
  return ref.watch(apiClientProvider).adminGetStudent(id);
});

class AdminStudentDetailScreen extends ConsumerWidget {
  final String studentId;
  final VoidCallback onClose;
  final void Function(String classId) onOpenClass;
  const AdminStudentDetailScreen({
    super.key,
    required this.studentId,
    required this.onClose,
    required this.onOpenClass,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(adminStudentDetailProvider(studentId));
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: detail.when(
        data: (d) => _Body(detail: d, onClose: onClose, onOpenClass: onOpenClass),
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Text(
            "Can't load student: ${ApiError.fromAny(e).message}",
            style: TextStyle(color: context.yoga.muted),
          ),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final AdminStudentDetail detail;
  final VoidCallback onClose;
  final void Function(String classId) onOpenClass;
  const _Body({
    required this.detail,
    required this.onClose,
    required this.onOpenClass,
  });

  void _afterChange(WidgetRef ref) {
    ref.invalidate(adminStudentDetailProvider(detail.id));
    ref.invalidate(adminStudentsProvider);
  }

  // UK GDPR Art. 15/20: download everything we hold on this student as JSON.
  Future<void> _exportData(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final data = await ref.read(apiClientProvider).adminExportStudent(detail.id);
      final pretty = const JsonEncoder.withIndent('  ').convert(data);
      await downloadCsv('student-${detail.id}-data.json', utf8.encode(pretty));
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Export failed: ${ApiError.fromAny(e).message}')),
      );
    }
  }

  // UK GDPR Art. 17: pseudonymise the student after a typed-name confirmation.
  // Irreversible, so we make the manager type the name to proceed.
  Future<void> _eraseData(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x80100A05),
      builder: (_) => _EraseConfirmDialog(
        studentName: detail.fullName,
        studentId: detail.id,
      ),
    );
    if (confirmed != true) return;
    ref.invalidate(adminStudentsProvider);
    onClose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = detail.entitlements.where((e) => e.isActive).toList();
    final history = detail.entitlements.where((e) => !e.isActive).toList();
    // Current user id from bootstrap — the Notes card uses it to gate
    // the per-row edit/delete affordances to the note's author. Server
    // enforces the same rule independently, so a stale value here only
    // hides a button that wouldn't have worked anyway.
    final currentUserId = ref.watch(bootstrapProvider).asData?.value.me.id ?? '';
    return ListView(
      children: [
        ManagerPageHeader(
          title: detail.fullName,
          sub: '${detail.email} · ${active.length} active pass${active.length == 1 ? '' : 'es'}'
              '${detail.plusOneCount > 0 ? ' · ${detail.plusOneCount} +1 guest${detail.plusOneCount == 1 ? '' : 's'} brought' : ''}',
          actions: [
            YButton(
              label: 'Back',
              variant: YButtonVariant.outline,
              small: true,
              onTap: onClose,
            ),
            YButton(
              label: 'Export data',
              variant: YButtonVariant.outline,
              small: true,
              onTap: () => _exportData(context, ref),
            ),
            YButton(
              label: 'Erase…',
              variant: YButtonVariant.outline,
              small: true,
              onTap: () => _eraseData(context, ref),
            ),
            YButton(
              label: '+ Grant pass',
              small: true,
              onTap: () async {
                final saved = await showGrantPassDialog(
                  context: context,
                  studentId: detail.id,
                );
                if (saved == true) _afterChange(ref);
              },
            ),
          ],
        ),
        // Notes hero — full width above the wallet/bookings columns so
        // injury info, preferences, and front-desk-relevant context are
        // the first thing a staff member sees on opening the record.
        StudentNotesCard(
          studentId: detail.id,
          currentUserId: currentUserId,
        ),
        const SizedBox(height: 16),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    ManagerCard(
                      title: 'Active passes',
                      child: active.isEmpty
                          ? _Empty(
                              label:
                                  'No active passes — Grant pass at the top.',
                            )
                          : Column(
                              children: [
                                for (var i = 0; i < active.length; i++)
                                  _ActivePassRow(
                                    item: active[i],
                                    isLast: i == active.length - 1,
                                    onAdjust: () async {
                                      final saved = await showAdjustCreditsDialog(
                                        context: context,
                                        studentId: detail.id,
                                        entitlement: active[i],
                                      );
                                      if (saved == true) _afterChange(ref);
                                    },
                                    onVoid: () async {
                                      final saved = await showVoidDialog(
                                        context: context,
                                        entitlement: active[i],
                                      );
                                      if (saved == true) _afterChange(ref);
                                    },
                                    onCancelMembership: () async {
                                      final changed =
                                          await showCancelMembershipDialog(
                                        context: context,
                                        subscriptionId:
                                            active[i].subscriptionId!,
                                        renewsAt: active[i].renewsAt,
                                        cancelAtPeriodEnd:
                                            active[i].cancelAtPeriodEnd,
                                      );
                                      if (changed == true) _afterChange(ref);
                                    },
                                  ),
                              ],
                            ),
                    ),
                    if (history.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ManagerCard(
                        title: 'History',
                        child: Column(
                          children: [
                            for (var i = 0; i < history.length; i++)
                              _HistoryRow(
                                item: history[i],
                                isLast: i == history.length - 1,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    ManagerCard(
                      title: 'Purchase history',
                      child: detail.purchases.isEmpty
                          ? _Empty(label: 'No purchases yet.')
                          : Column(
                              children: [
                                for (var i = 0; i < detail.purchases.length; i++)
                                  _PurchaseRow(
                                    item: detail.purchases[i],
                                    isLast: i == detail.purchases.length - 1,
                                    onRefund: () async {
                                      final done = await showRefundPurchaseDialog(
                                        context: context,
                                        purchase: detail.purchases[i],
                                      );
                                      if (done == true) _afterChange(ref);
                                    },
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),
                    ManagerCard(
                      title: 'Upcoming bookings',
                      child: detail.upcoming.isEmpty
                          ? _Empty(label: 'Nothing booked yet.')
                          : Column(
                              children: [
                                for (final u in detail.upcoming)
                                  _UpcomingRow(
                                    item: u,
                                    onTap: () => onOpenClass(u.classId),
                                  ),
                              ],
                            ),
                    ),
                    if (detail.plusOneHistory.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ManagerCard(
                        title: '+1 guests · ${detail.plusOneCount}',
                        child: Column(
                          children: [
                            for (var i = 0; i < detail.plusOneHistory.length; i++)
                              _PlusOneRow(
                                visit: detail.plusOneHistory[i],
                                isLast:
                                    i == detail.plusOneHistory.length - 1,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String label;
  const _Empty({required this.label});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: y.muted,
        ),
      ),
    );
  }
}

class _ActivePassRow extends StatelessWidget {
  final WalletEntitlement item;
  final bool isLast;
  final VoidCallback onAdjust;
  final VoidCallback onVoid;
  final VoidCallback onCancelMembership;
  const _ActivePassRow({
    required this.item,
    required this.isLast,
    required this.onAdjust,
    required this.onVoid,
    required this.onCancelMembership,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isCredit = item.passKind == 'credit';
    final isMembership = item.isMembership;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    YChip(
                      kind: item.gateIsAccent
                          ? YChipKind.accent
                          : YChipKind.booked,
                      label: item.gateLabel(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isMembership ? _membershipSubline(item) : _subline(item),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: item.cancelAtPeriodEnd ? y.accent : y.muted,
                  ),
                ),
              ],
            ),
          ),
          if (isMembership) ...[
            // A membership must be cancelled (stops Stripe billing), not voided
            // (which would kill the pass but keep charging).
            YButton(
              label: 'Cancel',
              variant: YButtonVariant.outline,
              small: true,
              onTap: onCancelMembership,
            ),
          ] else ...[
            if (isCredit) ...[
              YButton(
                label: 'Adjust',
                variant: YButtonVariant.outline,
                small: true,
                onTap: onAdjust,
              ),
              const SizedBox(width: 8),
            ],
            YButton(
              label: 'Void',
              variant: YButtonVariant.outline,
              small: true,
              onTap: onVoid,
            ),
          ],
        ],
      ),
    );
  }

  static String _membershipSubline(WalletEntitlement e) {
    String date(DateTime d) {
      const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final l = d.toLocal();
      return '${l.day} ${mons[l.month - 1]} ${l.year}';
    }

    if (e.cancelAtPeriodEnd) {
      return e.renewsAt != null
          ? 'Membership · cancels ${date(e.renewsAt!)}'
          : 'Membership · cancellation scheduled';
    }
    final base = e.subscriptionStatus == 'past_due'
        ? 'Membership · payment past due'
        : 'Membership';
    return e.renewsAt != null ? '$base · renews ${date(e.renewsAt!)}' : base;
  }

  static String _subline(WalletEntitlement e) {
    final parts = <String>[];
    if (e.passKind == 'credit') {
      parts.add('${e.creditsRemaining ?? 0} of ${e.creditsTotal ?? 0} credits');
    } else {
      parts.add('Unlimited');
    }
    if (e.expiresAt != null) {
      const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final l = e.expiresAt!.toLocal();
      parts.add('expires ${l.day} ${mons[l.month - 1]}');
    }
    return parts.join(' · ');
  }
}

class _HistoryRow extends StatelessWidget {
  final WalletEntitlement item;
  final bool isLast;
  const _HistoryRow({required this.item, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Opacity(
      opacity: 0.75,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: y.muted,
                ),
              ),
            ),
            YChip(
              kind: YChipKind.full,
              label: item.status[0].toUpperCase() + item.status.substring(1),
            ),
          ],
        ),
      ),
    );
  }
}

class _PurchaseRow extends StatelessWidget {
  final WalletPurchase item;
  final bool isLast;
  final VoidCallback onRefund;
  const _PurchaseRow({
    required this.item,
    required this.isLast,
    required this.onRefund,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.productName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                Text(
                  '${_fmtDate(item.createdAt)} · ${_method(item.paymentMethod)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          Text(
            item.formattedPrice(),
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: y.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          // Money-only refund (doesn't void the pass — that's the Void action
          // on the pass row). Only on completed sales.
          if (item.status == 'completed') ...[
            const SizedBox(width: 10),
            YButton(
              label: 'Refund',
              small: true,
              variant: YButtonVariant.outline,
              onTap: onRefund,
            ),
          ] else if (item.status == 'refunded') ...[
            const SizedBox(width: 10),
            const YChip(kind: YChipKind.full, label: 'Refunded'),
          ],
        ],
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${mons[l.month - 1]}';
  }

  static String _method(String m) => switch (m) {
        'cash' => 'Cash, at the desk',
        'card_present' => 'Card · terminal',
        'card' => 'Card',
        'transfer' => 'Transfer',
        'comp' => 'Complimentary',
        _ => m,
      };
}

class _UpcomingRow extends StatelessWidget {
  final UpcomingBooking item;
  final VoidCallback onTap;
  const _UpcomingRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = item.startsAt.toLocal();
    final hh = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dows[(local.weekday + 6) % 7];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: y.text,
                    ),
                  ),
                  Text(
                    '$dow ${local.day} · $hh · ${item.instructorName}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            const YChip(
                kind: YChipKind.booked, label: 'Booked', leadingCheck: true),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: y.muted),
          ],
        ),
      ),
    );
  }
}

/// One row in the +1 guests card — friend's name + when + which class +
/// the booking's final status (so cancelled +1s show up greyed-out).
class _PlusOneRow extends StatelessWidget {
  final PlusOneVisit visit;
  final bool isLast;
  const _PlusOneRow({required this.visit, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isCancelled = visit.status == 'cancelled';
    final local = visit.startsAt.toLocal();
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final dateLabel = '${local.day} ${mons[local.month - 1]}';
    final statusLabel = switch (visit.status) {
      'attended' => 'attended',
      'no_show' => 'no-show',
      'cancelled' => 'cancelled',
      _ => 'booked',
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  visit.friendName.isEmpty ? 'Unnamed guest' : visit.friendName,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: isCancelled ? y.muted : y.text,
                    decoration:
                        isCancelled ? TextDecoration.lineThrough : null,
                    decorationColor: y.muted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$dateLabel · ${visit.classTitle} · $statusLabel',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
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

// _EraseConfirmDialog gates the irreversible UK GDPR Art. 17 erasure behind a
// typed-name confirmation. On success it performs the erase and pops(true).
class _EraseConfirmDialog extends ConsumerStatefulWidget {
  final String studentName;
  final String studentId;
  const _EraseConfirmDialog({
    required this.studentName,
    required this.studentId,
  });

  @override
  ConsumerState<_EraseConfirmDialog> createState() =>
      _EraseConfirmDialogState();
}

class _EraseConfirmDialogState extends ConsumerState<_EraseConfirmDialog> {
  final _confirmCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  static const _danger = Color(0xFFB3261E);

  @override
  void dispose() {
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool get _matches =>
      _confirmCtrl.text.trim().toLowerCase() ==
      widget.studentName.trim().toLowerCase();

  Future<void> _submit() async {
    if (!_matches) {
      setState(() => _error = "Type the student's name to confirm.");
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminEraseStudent(widget.studentId);
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
    return Center(
      child: SizedBox(
        width: 460,
        child: Material(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Erase ${widget.studentName}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Right to erasure (UK GDPR Art. 17). This permanently '
                  'pseudonymises the student: profile, chat messages, +1 guest '
                  'names and contact details are scrubbed and their sign-in is '
                  'removed. Payment and audit records are retained (legally '
                  'required) but no longer identify them. This cannot be undone.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: y.muted,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Type the name to confirm',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: y.muted,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _confirmCtrl,
                  autofocus: true,
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: (_) => _submit(),
                  style: TextStyle(color: y.text),
                  decoration: InputDecoration(
                    hintText: widget.studentName,
                    hintStyle: TextStyle(color: y.muted),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: y.border),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: _danger),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(fontSize: 12, color: _danger),
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
                      onTap: _submitting
                          ? null
                          : () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: 10),
                    Opacity(
                      opacity: (_matches && !_submitting) ? 1 : 0.5,
                      child: Material(
                        color: _danger,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: (_matches && !_submitting) ? _submit : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            child: Text(
                              _submitting ? 'Erasing…' : 'Erase permanently',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cancel a membership the right way: stop the Stripe subscription. "At
/// renewal" keeps access until the paid period ends; "Now" revokes access and
/// releases future bookings immediately. Returns true if anything changed.
Future<bool?> showCancelMembershipDialog({
  required BuildContext context,
  required String subscriptionId,
  required DateTime? renewsAt,
  required bool cancelAtPeriodEnd,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => _CancelMembershipDialog(
      subscriptionId: subscriptionId,
      renewsAt: renewsAt,
      cancelAtPeriodEnd: cancelAtPeriodEnd,
    ),
  );
}

class _CancelMembershipDialog extends ConsumerStatefulWidget {
  final String subscriptionId;
  final DateTime? renewsAt;
  final bool cancelAtPeriodEnd;
  const _CancelMembershipDialog({
    required this.subscriptionId,
    required this.renewsAt,
    required this.cancelAtPeriodEnd,
  });

  @override
  ConsumerState<_CancelMembershipDialog> createState() =>
      _CancelMembershipDialogState();
}

class _CancelMembershipDialogState
    extends ConsumerState<_CancelMembershipDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function(ApiClient api, String subId) op) async {
    final subId = widget.subscriptionId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await op(ref.read(apiClientProvider), subId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  Future<void> _cancel({required bool immediate}) =>
      _run((api, subId) => api.adminCancelSubscription(subId, immediate: immediate));

  Future<void> _refund() => _run((api, subId) => api.adminRefundSubscription(subId));

  Future<void> _resume() => _run((api, subId) => api.adminResumeSubscription(subId));

  String _renewLabel() {
    final d = widget.renewsAt?.toLocal();
    if (d == null) return 'the end of the paid period';
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${mons[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final alreadyScheduled = widget.cancelAtPeriodEnd;
    return Center(
      child: SizedBox(
        width: 460,
        child: Material(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Cancel membership',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  alreadyScheduled
                      ? 'Already set to cancel on ${_renewLabel()}. You can end it '
                          'immediately instead.'
                      : 'Stops the auto-renewing Stripe subscription. Choose when '
                          'access ends.',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                if (alreadyScheduled)
                  _CancelOption(
                    title: 'Resume membership',
                    sub: 'Clears the scheduled cancellation; billing continues.',
                    onTap: _busy ? null : _resume,
                  ),
                if (!alreadyScheduled)
                  _CancelOption(
                    title: 'Cancel at renewal',
                    sub: 'Keeps access until ${_renewLabel()}; no further charges.',
                    onTap: _busy ? null : () => _cancel(immediate: false),
                  ),
                const SizedBox(height: 10),
                _CancelOption(
                  title: 'Cancel now',
                  sub: 'Revokes access immediately and frees their booked seats.',
                  danger: true,
                  onTap: _busy ? null : () => _cancel(immediate: true),
                ),
                const SizedBox(height: 10),
                _CancelOption(
                  title: 'Refund & cancel',
                  sub: 'Refunds the latest payment, then cancels now (revokes '
                      'access + frees their booked seats).',
                  danger: true,
                  onTap: _busy ? null : _refund,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                        color: Color(0xFFA33B2E), fontSize: 12.5),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: YButton(
                    label: 'Keep membership',
                    variant: YButtonVariant.outline,
                    small: true,
                    onTap: _busy ? null : () => Navigator.of(context).pop(false),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CancelOption extends StatelessWidget {
  final String title;
  final String sub;
  final bool danger;
  final VoidCallback? onTap;
  const _CancelOption({
    required this.title,
    required this.sub,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final accent = danger ? const Color(0xFFA33B2E) : y.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: y.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: y.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 2),
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
            Icon(Icons.chevron_right, size: 18, color: y.muted),
          ],
        ),
      ),
    );
  }
}

/// Money-only refund of a completed purchase (full or partial). Does NOT void
/// the pass — managers use the pass-row Void for that. Returns true on success.
Future<bool?> showRefundPurchaseDialog({
  required BuildContext context,
  required WalletPurchase purchase,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => _RefundPurchaseDialog(purchase: purchase),
  );
}

class _RefundPurchaseDialog extends ConsumerStatefulWidget {
  final WalletPurchase purchase;
  const _RefundPurchaseDialog({required this.purchase});

  @override
  ConsumerState<_RefundPurchaseDialog> createState() =>
      _RefundPurchaseDialogState();
}

class _RefundPurchaseDialogState extends ConsumerState<_RefundPurchaseDialog> {
  late final TextEditingController _amount;
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(
        text: (widget.purchase.amountMinor / 100).toStringAsFixed(2));
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final v = double.tryParse(_amount.text.trim());
    if (v == null || v <= 0) {
      setState(() => _error = 'Enter a valid amount.');
      return;
    }
    final minor = (v * 100).round();
    if (minor > widget.purchase.amountMinor) {
      setState(() => _error = "Can't refund more than the sale.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminRefundPurchase(
            purchaseId: widget.purchase.id,
            refundAmountMinor: minor,
            note: _note.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: SizedBox(
        width: 420,
        child: Material(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Refund ${widget.purchase.productName}',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Refunds the money via Stripe (card sales) and records it. The '
                  'pass itself stays active — use Void to revoke access.',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'AMOUNT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: y.muted,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(fontSize: 14, color: y.text),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixText: '£ ',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: y.borderStrong),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _note,
                  style: TextStyle(fontSize: 14, color: y.text),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Note (optional)',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: y.borderStrong),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: const TextStyle(
                          color: Color(0xFFA33B2E), fontSize: 12.5)),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    YButton(
                      label: 'Cancel',
                      variant: YButtonVariant.outline,
                      small: true,
                      onTap: _busy ? null : () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: 10),
                    YButton(
                      label: _busy ? 'Refunding…' : 'Refund',
                      small: true,
                      onTap: _busy ? null : _submit,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
