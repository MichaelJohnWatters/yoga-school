// Manager "Payments needing attention" — chargebacks (disputes) + past-due
// memberships, each with the right control (void & revoke a pass, or cancel a
// membership). The list is the manager's single place to act on money problems;
// nothing here is auto-revoked (money ≠ pass), so every action is deliberate.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

final adminPaymentsAttentionProvider =
    FutureProvider<List<PaymentAttentionItem>>((ref) async {
  return ref.watch(apiClientProvider).adminPaymentsAttention();
});

const _danger = Color(0xFFA33B2E);

class AdminPaymentsScreen extends ConsumerWidget {
  const AdminPaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminPaymentsAttentionProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminPaymentsAttentionProvider),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ManagerPageHeader(
              title: 'Payments needing attention',
              sub: 'Chargebacks and unpaid memberships — review and act',
            ),
            Expanded(
              child: data.when(
                data: (rows) => rows.isEmpty
                    ? _Empty()
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _Row(item: rows[i]),
                      ),
                loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2)),
                error: (e, _) => Center(
                  child: Text(
                    "Can't load: ${ApiError.fromAny(e).message}",
                    style: TextStyle(color: context.yoga.muted),
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

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_outlined, size: 40, color: y.muted),
          const SizedBox(height: 10),
          Text('Nothing needs attention',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: y.text)),
          const SizedBox(height: 4),
          Text('No open chargebacks or unpaid memberships.',
              style: TextStyle(fontSize: 12.5, color: y.muted)),
        ],
      ),
    );
  }
}

class _Row extends ConsumerStatefulWidget {
  final PaymentAttentionItem item;
  const _Row({required this.item});

  @override
  ConsumerState<_Row> createState() => _RowState();
}

class _RowState extends ConsumerState<_Row> {
  bool _busy = false;

  String _money(int minor, String ccy) {
    final sym = switch (ccy) {
      'GBP' => '£',
      'USD' => '\$',
      'EUR' => '€',
      _ => '$ccy ',
    };
    return '$sym${(minor / 100).toStringAsFixed(2)}';
  }

  Future<void> _voidPass() async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke pass?'),
        content: const Text(
          'This cancels the student\'s pass and any upcoming bookings on it. '
          'Choose whether to also refund — for a chargeback you usually do NOT '
          'refund (the bank already pulled the funds).',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'none'),
            child: const Text('Revoke, no refund'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'unused'),
            child: const Text('Revoke + refund unused'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).adminVoidEntitlement(
            entitlementId: widget.item.entitlementId!,
            refund: choice,
            reason: 'chargeback / payment dispute',
          );
      ref.invalidate(adminPaymentsAttentionProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text("Couldn't revoke: ${ApiError.fromAny(e).message}")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelMembership() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel membership now?'),
        content: const Text(
          'Cancels the Stripe subscription immediately and revokes access + any '
          'upcoming bookings. Use this when the member has stopped paying or '
          'disputed a charge.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel now'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(apiClientProvider)
          .adminCancelSubscription(widget.item.subscriptionId!, immediate: true);
      ref.invalidate(adminPaymentsAttentionProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text("Couldn't cancel: ${ApiError.fromAny(e).message}")));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final it = widget.item;
    final headline = it.isDispute ? 'Chargeback' : 'Past-due membership';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: _danger.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                it.isDispute
                    ? Icons.gavel_outlined
                    : Icons.autorenew_outlined,
                size: 18,
                color: _danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$headline · ${it.studentName}',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                      letterSpacing: -0.2),
                ),
              ),
              Text(_money(it.amountMinor, it.currency),
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800, color: y.text)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              it.productName,
              if (it.detail.isNotEmpty) it.detail,
              if (it.isDispute) 'status: ${it.status}',
            ].where((s) => s.isNotEmpty).join(' · '),
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600, color: y.muted),
          ),
          if (it.attendedCount > 0 || it.upcomingCount > 0) ...[
            const SizedBox(height: 2),
            Text(
              'On this pass: ${it.attendedCount} attended · ${it.upcomingCount} upcoming',
              style: TextStyle(fontSize: 12, color: y.muted),
            ),
          ],
          if (it.dueAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Evidence due ${_shortDate(it.dueAt!)}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: _danger)),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (it.entitlementId != null)
                TextButton(
                  onPressed: _busy ? null : _voidPass,
                  child: const Text('Void & revoke pass'),
                ),
              if (it.subscriptionId != null)
                TextButton(
                  onPressed: _busy ? null : _cancelMembership,
                  child: const Text('Cancel membership now'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _shortDate(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
      'Oct', 'Nov', 'Dec'];
  return '${d.day} ${mons[d.month - 1]}';
}
