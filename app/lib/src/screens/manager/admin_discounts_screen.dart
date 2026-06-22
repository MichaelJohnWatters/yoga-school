// Manager Discounts — list, create, archive.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

final adminDiscountsProvider =
    FutureProvider<List<AdminDiscount>>((ref) async {
  return ref.watch(apiClientProvider).adminListDiscounts(includeArchived: true);
});

const double _kNarrow = 700;

class AdminDiscountsScreen extends ConsumerWidget {
  const AdminDiscountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminDiscountsProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminDiscountsProvider),
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
              title: 'Discounts',
              sub: 'Codes students can enter at checkout',
              actions: [
                YButton(
                  label: '+ New discount',
                  small: true,
                  onTap: () => _openCreateSheet(context, ref),
                ),
              ],
            ),
            Expanded(
              child: data.when(
                data: (rows) => _List(rows: rows, isNarrow: isNarrow),
                loading: () =>
                    const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                error: (e, _) => Center(
                  child: Text(
                    "Can't load discounts: ${ApiError.fromAny(e).message}",
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

  Future<void> _openCreateSheet(BuildContext context, WidgetRef ref) async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateDiscountSheet(),
    );
    if (created == true) ref.invalidate(adminDiscountsProvider);
  }
}

class _List extends ConsumerWidget {
  final List<AdminDiscount> rows;
  final bool isNarrow;
  const _List({required this.rows, required this.isNarrow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = rows.where((d) => !d.isArchived).toList();
    final archived = rows.where((d) => d.isArchived).toList();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ManagerCard(
            title: '${active.length} active discount${active.length == 1 ? '' : 's'}',
            child: active.isEmpty
                ? _EmptyHint()
                : Column(
                    children: [
                      for (var i = 0; i < active.length; i++)
                        _DiscountRow(
                          d: active[i],
                          isLast: i == active.length - 1,
                          onArchive: () => _archive(context, ref, active[i]),
                        ),
                    ],
                  ),
          ),
          if (archived.isNotEmpty) ...[
            const SizedBox(height: 14),
            ManagerCard(
              title: 'Archived',
              child: Column(
                children: [
                  for (var i = 0; i < archived.length; i++)
                    _DiscountRow(
                      d: archived[i],
                      isLast: i == archived.length - 1,
                      onArchive: null,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _archive(BuildContext context, WidgetRef ref, AdminDiscount d) async {
    final y = context.yoga;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: y.surface,
        title: Text('Archive ${d.code ?? "this discount"}?',
            style: TextStyle(color: y.text)),
        content: Text(
          "Students won't be able to apply this code at checkout anymore. "
          "Previous purchases that used it stay linked.",
          style: TextStyle(color: y.text, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).adminArchiveDiscount(d.id);
      ref.invalidate(adminDiscountsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Archive failed: ${ApiError.fromAny(e).message}')),
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
        'No discounts yet — click "+ New discount" to add one.',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.yoga.muted,
        ),
      ),
    );
  }
}

class _DiscountRow extends StatelessWidget {
  final AdminDiscount d;
  final bool isLast;
  final VoidCallback? onArchive;
  const _DiscountRow({
    required this.d,
    required this.isLast,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final used = d.maxUses != null
        ? '${d.timesUsed} / ${d.maxUses} uses'
        : '${d.timesUsed} use${d.timesUsed == 1 ? '' : 's'}';
    final pounds = (d.totalGivenMinor / 100).toStringAsFixed(2);
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
                      d.code ?? '(manager only)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: y.text,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      d.describeRule(),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: y.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$used · £$pounds given'
                  '${d.notes.isNotEmpty ? ' · ${d.notes}' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          if (onArchive != null)
            IconButton(
              onPressed: onArchive,
              icon: Icon(Icons.archive_outlined, size: 18, color: y.muted),
              tooltip: 'Archive',
            ),
        ],
      ),
    );
  }
}

class _CreateDiscountSheet extends ConsumerStatefulWidget {
  const _CreateDiscountSheet();

  @override
  ConsumerState<_CreateDiscountSheet> createState() =>
      _CreateDiscountSheetState();
}

class _CreateDiscountSheetState extends ConsumerState<_CreateDiscountSheet> {
  final _code = TextEditingController();
  final _value = TextEditingController(text: '10');
  final _maxUses = TextEditingController();
  final _maxPerUser = TextEditingController();
  final _notes = TextEditingController();
  String _kind = 'percent';
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _value.dispose();
    _maxUses.dispose();
    _maxPerUser.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
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
                  'New discount',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  enabled: !_submitting,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Code (optional — leave blank for manager-only)',
                    hintText: 'WELCOME10',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _kind,
                        decoration: const InputDecoration(
                          labelText: 'Kind',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 'percent', child: Text('Percent')),
                          DropdownMenuItem(value: 'fixed_minor', child: Text('Fixed amount')),
                          DropdownMenuItem(value: 'comp', child: Text('Comp (100%)')),
                        ],
                        onChanged: _submitting
                            ? null
                            : (v) => setState(() => _kind = v ?? 'percent'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _value,
                        enabled: !_submitting && _kind != 'comp',
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: _kind == 'percent'
                              ? 'Percent (1-100)'
                              : _kind == 'fixed_minor'
                                  ? 'Amount in pence'
                                  : '—',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _maxUses,
                        enabled: !_submitting,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Max uses (blank = unlimited)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _maxPerUser,
                        enabled: !_submitting,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Max per user',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  enabled: !_submitting,
                  decoration: const InputDecoration(
                    labelText: 'Notes (internal)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
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
                  label: _submitting ? 'Saving…' : 'Create discount',
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
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final value = _kind == 'comp' ? 0 : int.tryParse(_value.text.trim()) ?? 0;
      final maxUses = int.tryParse(_maxUses.text.trim());
      final maxPerUser = int.tryParse(_maxPerUser.text.trim());
      await ref.read(apiClientProvider).adminCreateDiscount(
            code: _code.text.trim().isEmpty ? null : _code.text.trim(),
            kind: _kind,
            value: value,
            maxUses: maxUses,
            maxUsesPerUser: maxPerUser,
            notes: _notes.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }
}
