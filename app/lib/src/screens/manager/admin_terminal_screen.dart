// Manager Terminal — register/manage in-person card readers, and take a
// "card at the desk" payment. Backend: server/internal/store/terminal.go
// (server-driven Stripe Terminal). The pass is granted by the
// payment_intent.succeeded webhook once the customer taps.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_products_screen.dart' show adminProductsProvider;
import 'manager_shell.dart';

final adminTerminalReadersProvider =
    FutureProvider<List<TerminalReader>>((ref) async {
  return ref.watch(apiClientProvider).adminListTerminalReaders();
});

final _terminalStudentsProvider =
    FutureProvider<List<AdminStudentSummary>>((ref) async {
  return (await ref.watch(apiClientProvider).adminListStudents()).students;
});

const double _kNarrow = 700;

class AdminTerminalScreen extends ConsumerWidget {
  const AdminTerminalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readers = ref.watch(adminTerminalReadersProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminTerminalReadersProvider),
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
                title: 'Terminal',
                sub: 'Take card payments in person at the front desk',
                actions: [
                  YButton(
                    label: '+ Register reader',
                    small: true,
                    variant: YButtonVariant.outline,
                    onTap: () => _registerReader(context, ref),
                  ),
                ],
              ),
              Expanded(
                child: readers.when(
                  data: (rows) => SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ManagerCard(
                          title: 'Take a payment',
                          child: _TakePayment(readers: rows),
                        ),
                        const SizedBox(height: 14),
                        ManagerCard(
                          title:
                              '${rows.length} reader${rows.length == 1 ? '' : 's'}',
                          child: rows.isEmpty
                              ? _EmptyReaders()
                              : Column(
                                  children: [
                                    for (var i = 0; i < rows.length; i++)
                                      _ReaderRow(
                                        reader: rows[i],
                                        isLast: i == rows.length - 1,
                                        onRemove: () =>
                                            _removeReader(context, ref, rows[i]),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                  loading: () => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (e, _) => Center(
                    child: Text(
                      "Can't load readers: ${ApiError.fromAny(e).message}",
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

  Future<void> _registerReader(BuildContext context, WidgetRef ref) async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _RegisterReaderSheet(),
    );
    if (added == true) ref.invalidate(adminTerminalReadersProvider);
  }

  Future<void> _removeReader(
      BuildContext context, WidgetRef ref, TerminalReader r) async {
    final y = context.yoga;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: y.surface,
        title: Text('Remove "${r.displayName}"?',
            style: TextStyle(color: y.text)),
        content: Text(
          "It stays registered in Stripe; this just removes it from the app. "
          "Re-add it any time with its pairing code.",
          style: TextStyle(color: y.text, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).adminRemoveTerminalReader(r.readerId);
      ref.invalidate(adminTerminalReadersProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Remove failed: ${ApiError.fromAny(e).message}')),
        );
      }
    }
  }
}

class _EmptyReaders extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        'No readers yet. Click "Register reader" and enter the pairing code '
        'shown on the device (Settings → Generate pairing code).',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.yoga.muted,
        ),
      ),
    );
  }
}

class _ReaderRow extends StatelessWidget {
  final TerminalReader reader;
  final bool isLast;
  final VoidCallback onRemove;
  const _ReaderRow({
    required this.reader,
    required this.isLast,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.point_of_sale_outlined, size: 20, color: y.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reader.displayName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  reader.readerId,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: Icon(Icons.delete_outline, size: 18, color: y.muted),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}

/// "Take a payment" — opens the card-at-desk sale flow. Disabled until at least
/// one reader is registered.
class _TakePayment extends StatelessWidget {
  final List<TerminalReader> readers;
  const _TakePayment({required this.readers});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    if (readers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Register a reader to take payments at the desk.',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Charge a student for a pass or membership on a card reader.',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: y.muted,
            ),
          ),
        ),
        YButton(
          label: 'New in-person sale',
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => _ChargeSheet(readers: readers),
          ),
        ),
      ],
    );
  }
}

class _RegisterReaderSheet extends ConsumerStatefulWidget {
  const _RegisterReaderSheet();
  @override
  ConsumerState<_RegisterReaderSheet> createState() =>
      _RegisterReaderSheetState();
}

class _RegisterReaderSheetState extends ConsumerState<_RegisterReaderSheet> {
  final _code = TextEditingController();
  final _label = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Register reader',
      children: [
        TextField(
          controller: _code,
          enabled: !_submitting,
          decoration: const InputDecoration(
            labelText: 'Pairing code',
            hintText: 'e.g. simulated-wpe (or the code on the device)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _label,
          enabled: !_submitting,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Label (optional)',
            hintText: 'Front desk',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          _ErrorText(_error!),
        ],
        const SizedBox(height: 16),
        YButton(
          label: _submitting ? 'Registering…' : 'Register',
          onTap: _submitting ? null : _submit,
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'A pairing code is required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminRegisterTerminalReader(
            registrationCode: _code.text.trim(),
            label: _label.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }
}

class _ChargeSheet extends ConsumerStatefulWidget {
  final List<TerminalReader> readers;
  const _ChargeSheet({required this.readers});
  @override
  ConsumerState<_ChargeSheet> createState() => _ChargeSheetState();
}

class _ChargeSheetState extends ConsumerState<_ChargeSheet> {
  final _search = TextEditingController();
  final _discount = TextEditingController();
  AdminStudentSummary? _student;
  String? _productId;
  late String _readerId = widget.readers.first.readerId;
  bool _submitting = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    _discount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) return _sentView();
    final products = ref.watch(adminProductsProvider);
    final students = ref.watch(_terminalStudentsProvider);
    return _SheetScaffold(
      title: 'In-person sale',
      children: [
        // Reader.
        DropdownButtonFormField<String>(
          initialValue: _readerId,
          decoration: const InputDecoration(
            labelText: 'Reader',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final r in widget.readers)
              DropdownMenuItem(value: r.readerId, child: Text(r.displayName)),
          ],
          onChanged: _submitting
              ? null
              : (v) => setState(() => _readerId = v ?? _readerId),
        ),
        const SizedBox(height: 12),
        // Product.
        products.when(
          data: (list) {
            final sellable = list.where((p) => !p.isArchived).toList();
            return DropdownButtonFormField<String>(
              initialValue: _productId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Product',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final p in sellable)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text('${p.name} · ${_price(p)}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged:
                  _submitting ? null : (v) => setState(() => _productId = v),
            );
          },
          loading: () => const LinearProgressIndicator(),
          error: (e, _) =>
              _ErrorText("Can't load products: ${ApiError.fromAny(e).message}"),
        ),
        const SizedBox(height: 12),
        // Student.
        Text('Student', style: _labelStyle(context)),
        const SizedBox(height: 6),
        if (_student != null)
          _SelectedStudent(
            student: _student!,
            onClear: _submitting ? null : () => setState(() => _student = null),
          )
        else ...[
          TextField(
            controller: _search,
            enabled: !_submitting,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Search students',
              prefixIcon: Icon(Icons.search, size: 18),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          students.when(
            data: (all) {
              final q = _search.text.trim().toLowerCase();
              final matches = (q.isEmpty
                      ? all
                      : all.where((s) =>
                          s.fullName.toLowerCase().contains(q) ||
                          s.email.toLowerCase().contains(q)))
                  .take(6)
                  .toList();
              return Column(
                children: [
                  for (final s in matches)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: YAvatar(name: s.fullName, size: 30, photoUrl: s.photoUrl),
                      title: Text(s.fullName, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(s.email, style: const TextStyle(fontSize: 12)),
                      onTap: () => setState(() => _student = s),
                    ),
                ],
              );
            },
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => _ErrorText(
                "Can't load students: ${ApiError.fromAny(e).message}"),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _discount,
          enabled: !_submitting,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Discount code (optional)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          _ErrorText(_error!),
        ],
        const SizedBox(height: 16),
        YButton(
          label: _submitting ? 'Sending to reader…' : 'Charge on reader',
          onTap: _submitting ? null : _submit,
        ),
      ],
    );
  }

  Widget _sentView() {
    final y = context.yoga;
    final readerName = widget.readers
        .firstWhere((r) => r.readerId == _readerId)
        .displayName;
    return _SheetScaffold(
      title: 'Tap to pay',
      children: [
        Row(
          children: [
            Icon(Icons.contactless_outlined, size: 22, color: y.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Ask ${_student?.fullName ?? 'the student'} to tap or insert '
                'their card on "$readerName". The pass is added to their wallet '
                'automatically once the payment succeeds.',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                  color: y.text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        YButton(label: 'Done', onTap: () => Navigator.of(context).pop()),
        const SizedBox(height: 10),
        YButton(
          label: 'Cancel the charge',
          variant: YButtonVariant.outline,
          onTap: _cancel,
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_productId == null) {
      setState(() => _error = 'Pick a product.');
      return;
    }
    if (_student == null) {
      setState(() => _error = 'Pick a student.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).adminTerminalCharge(
            userId: _student!.id,
            productId: _productId!,
            readerId: _readerId,
            discountCode: _discount.text.trim(),
          );
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = ApiError.fromAny(e).message;
      });
    }
  }

  Future<void> _cancel() async {
    try {
      await ref.read(apiClientProvider).adminTerminalCancel(_readerId);
    } catch (_) {
      // best effort
    }
    if (mounted) Navigator.of(context).pop();
  }

  String _price(AdminProduct p) {
    final whole = (p.priceMinor / 100).toStringAsFixed(
        p.priceMinor % 100 == 0 ? 0 : 2);
    final sym = p.currency.toUpperCase() == 'GBP'
        ? '£'
        : p.currency.toUpperCase() == 'USD'
            ? '\$'
            : p.currency.toUpperCase() == 'EUR'
                ? '€'
                : '';
    final per = p.billingType == 'recurring' ? '/mo' : '';
    return '$sym$whole$per';
  }
}

class _SelectedStudent extends StatelessWidget {
  final AdminStudentSummary student;
  final VoidCallback? onClear;
  const _SelectedStudent({required this.student, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.primary),
      ),
      child: Row(
        children: [
          YAvatar(name: student.fullName, size: 30, photoUrl: student.photoUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              student.fullName,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: y.text),
            ),
          ),
          if (onClear != null)
            IconButton(
              onPressed: onClear,
              icon: Icon(Icons.close, size: 16, color: y.muted),
            ),
        ],
      ),
    );
  }
}

TextStyle _labelStyle(BuildContext context) => TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: context.yoga.muted,
    );

class _ErrorText extends StatelessWidget {
  final String message;
  const _ErrorText(this.message);
  @override
  Widget build(BuildContext context) => Text(
        message,
        style: const TextStyle(
          color: Color(0xFFA33B2E),
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      );
}

/// Shared bottom-sheet chrome (grab handle + title + scroll).
class _SheetScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SheetScaffold({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 16),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
