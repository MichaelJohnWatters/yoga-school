// Money dialogs — Grant pass / Adjust credits / Void & refund.
// All shown as centered modals (showDialog) at ~460 px, matching the design.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';

const _modalWidth = 460.0;
const _danger = Color(0xFFA33B2E);

// ============================== GRANT PASS ==============================

Future<bool?> showGrantPassDialog({
  required BuildContext context,
  required String studentId,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: _modalWidth,
        child: _GrantPassDialog(studentId: studentId),
      ),
    ),
  );
}

class _GrantPassDialog extends ConsumerStatefulWidget {
  final String studentId;
  const _GrantPassDialog({required this.studentId});

  @override
  ConsumerState<_GrantPassDialog> createState() => _GrantPassDialogState();
}

class _GrantPassDialogState extends ConsumerState<_GrantPassDialog> {
  String? _productId;
  String _paymentMethod = 'cash';
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_productId == null) {
      setState(() => _error = 'Pick a product first.');
      return;
    }
    int? amount;
    if (_amountCtrl.text.trim().isNotEmpty) {
      final v = double.tryParse(_amountCtrl.text);
      if (v != null) amount = (v * 100).round();
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminGrantPass(
            studentId: widget.studentId,
            productId: _productId!,
            paymentMethod: _paymentMethod,
            amountMinor: amount,
            note: _noteCtrl.text.trim(),
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
    final products = ref.watch(adminProductsProviderForGrant);
    final student = ref.watch(adminGetStudentProvider(widget.studentId));
    final isReader = _paymentMethod == 'card_present';
    final amountStr = _amountCtrl.text.trim().isEmpty
        ? '0.00'
        : _amountCtrl.text.trim();
    return _DialogChrome(
      title: 'Grant or sell a pass',
      sub: isReader
          ? "Send the order to the Stripe Terminal at the desk."
          : "Creates a paid-in-cash purchase + entitlement. Receipt is recorded in Reports.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          student.when(
            data: (d) => _StudentRow(name: d.fullName, email: d.email),
            loading: () => _StudentRow.loading(),
            error: (e, _) => _StudentRow(name: '…', email: ApiError.fromAny(e).message),
          ),
          const SizedBox(height: 14),
          products.when(
            data: (list) => _ProductPicker(
              products: list,
              value: _productId,
              onChanged: (v) {
                _productId = v;
                final p = list.firstWhere((p) => p.id == v);
                _amountCtrl.text = (p.priceMinor / 100).toStringAsFixed(2);
                setState(() {});
              },
            ),
            loading: () => const SizedBox(
              height: 40,
              child: Center(child: CircularProgressIndicator(strokeWidth: 1.5)),
            ),
            error: (e, _) => Text("Can't load products: ${ApiError.fromAny(e).message}"),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'PAID VIA',
            child: _PaymentSeg(
              value: _paymentMethod,
              onChanged: (v) => setState(() => _paymentMethod = v),
            ),
          ),
          if (isReader) ...[
            const SizedBox(height: 10),
            _ReaderStatusCard(),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _LabeledField(
                  label: 'AMOUNT',
                  child: _MoneyInput(controller: _amountCtrl),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _LabeledField(
                  label: 'NOTE (optional)',
                  child: _TextInput(controller: _noteCtrl, hint: 'e.g. paid at the desk'),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 16),
          _Footer(
            primaryLabel: _submitting
                ? (isReader ? 'Charging reader…' : 'Granting…')
                : (isReader ? 'Send to reader · £$amountStr' : 'Grant pass'),
            onPrimary: _submitting ? null : _submit,
            onCancel: () => Navigator.of(context).pop(false),
          ),
          if (isReader) ...[
            const SizedBox(height: 10),
            Text(
              'Customer display at the desk will show the order while the card is presented.',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: context.yoga.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReaderStatusCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          // Reader illustration — minimalist.
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: y.text,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.contactless, color: y.background, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Stripe Terminal · Desk',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFF2EAD66),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text(
                      'Connected · 87% battery',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Text(
            'Change',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: y.primary,
            ),
          ),
        ],
      ),
    );
  }
}

final adminProductsProviderForGrant =
    FutureProvider.autoDispose<List<AdminProduct>>((ref) async {
  final list = await ref.watch(apiClientProvider).adminListProducts();
  return list.where((p) => !p.isArchived).toList();
});

final adminGetStudentProvider =
    FutureProvider.autoDispose.family<AdminStudentDetail, String>((ref, id) async {
  return ref.watch(apiClientProvider).adminGetStudent(id);
});

class _ProductPicker extends StatelessWidget {
  final List<AdminProduct> products;
  final String? value;
  final ValueChanged<String> onChanged;
  const _ProductPicker({
    required this.products,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return _LabeledField(
      label: 'PRODUCT',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: y.borderStrong),
          borderRadius: BorderRadius.circular(10),
        ),
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          hint: Text(
            'Pick a product…',
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
            for (final p in products)
              DropdownMenuItem(
                value: p.id,
                child: Text('${p.name} — ${p.formattedPrice()}'),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
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
    const opts = {
      'cash': 'Cash',
      'card_present': 'Card · reader',
      'transfer': 'Transfer',
      'comp': 'Comp',
    };
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final entry in opts.entries)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(entry.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: entry.key == value ? y.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: entry.key == value ? y.border : Colors.transparent,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: entry.key == value ? y.text : y.muted,
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

// ============================== ADJUST CREDITS ==============================

Future<bool?> showAdjustCreditsDialog({
  required BuildContext context,
  required String studentId,
  required WalletEntitlement entitlement,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: _modalWidth,
        child: _AdjustDialog(studentId: studentId, entitlement: entitlement),
      ),
    ),
  );
}

class _AdjustDialog extends ConsumerStatefulWidget {
  final String studentId;
  final WalletEntitlement entitlement;
  const _AdjustDialog({required this.studentId, required this.entitlement});

  @override
  ConsumerState<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends ConsumerState<_AdjustDialog> {
  int _delta = 0;
  final _reasonCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  int get _next => (widget.entitlement.creditsRemaining ?? 0) + _delta;
  int get _total => widget.entitlement.creditsTotal ?? 0;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_delta == 0) {
      setState(() => _error = 'Pick a non-zero adjustment.');
      return;
    }
    if (_reasonCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Reason is required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminAdjustCredits(
            studentId: widget.studentId,
            entitlementId: widget.entitlement.id,
            delta: _delta,
            reason: _reasonCtrl.text.trim(),
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
    final current = widget.entitlement.creditsRemaining ?? 0;
    return _DialogChrome(
      title: 'Adjust credits',
      sub:
          'Change the remaining credits on this pass. Logged with your name.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PassSummary(item: widget.entitlement),
          const SizedBox(height: 16),
          _LabeledField(
            label: 'CHANGE',
            child: Row(
              children: [
                _Stepper(
                  delta: _delta,
                  onMinus: () => setState(() => _delta -= 1),
                  onPlus: () => setState(() => _delta += 1),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: y.muted,
                      ),
                      children: [
                        TextSpan(text: '$current'),
                        TextSpan(
                          text: '  →  ',
                          style: TextStyle(color: y.muted),
                        ),
                        TextSpan(
                          text: '$_next',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: _next < 0 ? _danger : y.text,
                          ),
                        ),
                        TextSpan(text: ' of $_total'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'REASON',
            child: _TextInput(
              controller: _reasonCtrl,
              hint: "Required — e.g. used outside the system",
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 16),
          _Footer(
            primaryLabel: _submitting ? 'Saving…' : 'Save adjustment',
            onPrimary: _submitting ? null : _submit,
            onCancel: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

/// Unified inline stepper pill — `[−|+1|+]` with single outer border and
/// internal dividers. Matches yoga-admin-c.jsx:75-83. Plus button uses
/// primary color; minus button uses muted.
class _Stepper extends StatelessWidget {
  final int delta;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _Stepper({
    required this.delta,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final centerLabel = delta > 0 ? '+$delta' : '$delta';
    Widget tapBox({
      required String glyph,
      required Color color,
      required VoidCallback onTap,
    }) =>
        GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 40,
            child: Center(
              child: Text(
                glyph,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: color,
                  height: 1.0,
                ),
              ),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: y.borderStrong),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            tapBox(glyph: '−', color: y.muted, onTap: onMinus),
            Container(width: 1, height: 40, color: y.border),
            SizedBox(
              width: 56,
              height: 40,
              child: Center(
                child: Text(
                  centerLabel,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                    height: 1.0,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Container(width: 1, height: 40, color: y.border),
            tapBox(glyph: '+', color: y.primary, onTap: onPlus),
          ],
        ),
      ),
    );
  }
}

// ============================== VOID & REFUND ==============================

Future<bool?> showVoidDialog({
  required BuildContext context,
  required WalletEntitlement entitlement,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: SizedBox(
        width: _modalWidth,
        child: _VoidDialog(entitlement: entitlement),
      ),
    ),
  );
}

class _VoidDialog extends ConsumerStatefulWidget {
  final WalletEntitlement entitlement;
  const _VoidDialog({required this.entitlement});

  @override
  ConsumerState<_VoidDialog> createState() => _VoidDialogState();
}

class _VoidDialogState extends ConsumerState<_VoidDialog> {
  String _refund = 'unused';
  final _reasonCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_reasonCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Reason is required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminVoidEntitlement(
            entitlementId: widget.entitlement.id,
            refund: _refund,
            reason: _reasonCtrl.text.trim(),
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
    return _DialogChrome(
      title: 'Void & refund',
      sub: 'Voids the pass and (optionally) refunds the student. '
          'Card payments are returned to the original card via Stripe.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PassSummary(item: widget.entitlement),
          const SizedBox(height: 14),
          _LabeledField(
            label: 'REFUND',
            child: _RefundSeg(
              value: _refund,
              onChanged: (v) => setState(() => _refund = v),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: y.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: y.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Upcoming bookings on this pass will be cancelled.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: y.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'REASON',
            child: _TextInput(
              controller: _reasonCtrl,
              hint: 'Required',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: _danger, fontSize: 12.5)),
          ],
          const SizedBox(height: 16),
          _Footer(
            primaryLabel: _submitting ? 'Voiding…' : 'Void this pass',
            primaryDanger: true,
            onPrimary: _submitting ? null : _submit,
            onCancel: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

class _RefundSeg extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _RefundSeg({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const opts = {
      'unused': 'Unused only',
      'full': 'Full amount',
      'none': 'No refund',
    };
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final entry in opts.entries)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(entry.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: entry.key == value ? y.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: entry.key == value ? y.border : Colors.transparent,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: entry.key == value ? y.text : y.muted,
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

// ============================== SHARED CHROME ==============================

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

class _StudentRow extends StatelessWidget {
  final String name;
  final String email;
  const _StudentRow({required this.name, required this.email});

  factory _StudentRow.loading() => const _StudentRow(name: '…', email: '');

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
          YAvatar(name: name, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                Text(
                  email,
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

class _PassSummary extends StatelessWidget {
  final WalletEntitlement item;
  const _PassSummary({required this.item});

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
                  item.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                Text(
                  item.passKind == 'unlimited'
                      ? 'Unlimited'
                      : '${item.creditsRemaining ?? 0} of ${item.creditsTotal ?? 0} credits',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          YChip(
            kind: item.gateIsAccent ? YChipKind.accent : YChipKind.booked,
            label: item.gateLabel(),
          ),
        ],
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledField({required this.label, required this.child});

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

class _MoneyInput extends StatelessWidget {
  final TextEditingController controller;
  const _MoneyInput({required this.controller});

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
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: y.text,
        ),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 5),
          hintText: '0.00',
        ),
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
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
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
