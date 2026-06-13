// Manager Student detail — header + active passes + history + actions.
// Shows the same wallet shape as the student-side Wallet, plus manager
// affordances per entitlement: Adjust credits (credit kind only) and Void.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_students_screen.dart';
import 'manager_shell.dart';
import 'money_dialogs.dart';

final adminStudentDetailProvider =
    FutureProvider.autoDispose.family<AdminStudentDetail, String>((ref, id) async {
  return ref.watch(apiClientProvider).adminGetStudent(id);
});

class AdminStudentDetailScreen extends ConsumerWidget {
  final String studentId;
  final VoidCallback onClose;
  const AdminStudentDetailScreen({
    super.key,
    required this.studentId,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(adminStudentDetailProvider(studentId));
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: detail.when(
        data: (d) => _Body(detail: d, onClose: onClose),
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Text(
            "Can't load student: $e",
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
  const _Body({required this.detail, required this.onClose});

  void _afterChange(WidgetRef ref) {
    ref.invalidate(adminStudentDetailProvider(detail.id));
    ref.invalidate(adminStudentsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = detail.entitlements.where((e) => e.isActive).toList();
    final history = detail.entitlements.where((e) => !e.isActive).toList();
    return ListView(
      children: [
        ManagerPageHeader(
          title: detail.fullName,
          sub: '${detail.email} · ${active.length} active pass${active.length == 1 ? '' : 'es'}',
          actions: [
            YButton(
              label: 'Back',
              variant: YButtonVariant.outline,
              small: true,
              onTap: onClose,
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
                                  _UpcomingRow(item: u),
                              ],
                            ),
                    ),
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
  const _ActivePassRow({
    required this.item,
    required this.isLast,
    required this.onAdjust,
    required this.onVoid,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isCredit = item.passKind == 'credit';
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
                  _subline(item),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
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
      ),
    );
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
  const _PurchaseRow({required this.item, required this.isLast});

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
  const _UpcomingRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = item.startsAt.toLocal();
    final hh = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final dow = dows[(local.weekday + 6) % 7];
    return Padding(
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
          const YChip(kind: YChipKind.booked, label: 'Booked', leadingCheck: true),
        ],
      ),
    );
  }
}
