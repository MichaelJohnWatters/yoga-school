// Manager Product Editor — single form + live student preview.
// Mirrors yoga-admin-a.jsx KProductBuilder.
//
// Two columns (3fr / 2fr):
//   Left  — Name, Price, Billing seg, Pass kind seg, Credits + Validity
//           (gated on kind), Eligible class types as check chips, surface2
//           footer about "future purchases only"
//   Right — "Student sees" live preview + plain-language terms sentence,
//           "In use" stats card

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_products_screen.dart';
import 'manager_shell.dart';

final adminClassTypesProvider =
    FutureProvider.autoDispose<List<ClassType>>((ref) async {
  return ref.watch(apiClientProvider).adminListClassTypes();
});

class AdminProductEditorScreen extends ConsumerStatefulWidget {
  /// Null when creating a new product, otherwise the existing product id.
  final String? productId;
  final VoidCallback onClose;
  const AdminProductEditorScreen({
    super.key,
    required this.productId,
    required this.onClose,
  });

  @override
  ConsumerState<AdminProductEditorScreen> createState() =>
      _AdminProductEditorScreenState();
}

class _AdminProductEditorScreenState
    extends ConsumerState<AdminProductEditorScreen> {
  // Form state. Sourced from the loaded product when editing, or defaults
  // when creating.
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _priceCents = TextEditingController();
  final _credits = TextEditingController();
  final _validity = TextEditingController();
  String _billing = 'one_time';
  String _interval = 'month'; // billing interval when _billing == 'recurring'
  String _passKind = 'credit';
  String _duplicatePolicy = 'allow'; // allow | prevent | topup
  Set<String> _classTypeIds = {};
  AdminProduct? _original;
  AdminProductUsage? _usage;
  String _currency = 'GBP';
  bool _saving = false;
  bool _archiving = false;

  bool get _isCreate => widget.productId == null;

  /// Public hook so sibling widgets (which hold a reference to this State)
  /// can request a rebuild without poking at the protected setState.
  void rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    if (_isCreate) {
      _priceCents.text = '0.00';
      _credits.text = '1';
      _validity.text = '30';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _priceCents.dispose();
    _credits.dispose();
    _validity.dispose();
    super.dispose();
  }

  void _populate(AdminProduct p) {
    if (_original?.id == p.id) return;
    _original = p;
    _usage = p.usage;
    _currency = p.currency;
    _name.text = p.name;
    _description.text = p.description;
    _priceCents.text = (p.priceMinor / 100).toStringAsFixed(2);
    _billing = p.billingType;
    _interval = p.billingInterval ?? 'month';
    _passKind = p.passKind;
    _duplicatePolicy = p.duplicatePolicy;
    _credits.text = '${p.credits ?? 1}';
    _validity.text = '${p.validityDays ?? 30}';
    _classTypeIds = Set.from(p.classTypeIds);
  }

  int get _priceMinor {
    final v = double.tryParse(_priceCents.text) ?? 0;
    return (v * 100).round();
  }

  Map<String, dynamic> _buildPayload({bool isCreate = false}) {
    final out = <String, dynamic>{
      'name': _name.text.trim(),
      'description': _description.text.trim(),
      'price_minor': _priceMinor,
      'billing_type': _billing,
      if (_billing == 'recurring') 'billing_interval': _interval,
      'pass_kind': _passKind,
      'duplicate_policy': _duplicatePolicy,
      'class_type_ids': _classTypeIds.toList(),
    };
    if (_passKind == 'credit') {
      out['credits'] = int.tryParse(_credits.text) ?? 1;
    }
    final validity = int.tryParse(_validity.text);
    if (validity != null) {
      out['validity_days'] = validity;
    }
    return out;
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _toast('Name is required.');
      return;
    }
    setState(() => _saving = true);
    try {
      final api = ref.read(apiClientProvider);
      if (_isCreate) {
        await api.adminCreateProduct(_buildPayload(isCreate: true));
      } else {
        await api.adminUpdateProduct(widget.productId!, _buildPayload());
      }
      ref.invalidate(adminProductsProvider);
      _toast(_isCreate ? 'Product created.' : 'Saved.');
      widget.onClose();
    } catch (e) {
      _toast('Save failed: ${ApiError.fromAny(e).message}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _archive() async {
    if (_isCreate || _original == null) return;
    setState(() => _archiving = true);
    try {
      await ref.read(apiClientProvider).adminArchiveProduct(_original!.id);
      ref.invalidate(adminProductsProvider);
      _toast('Product archived.');
      widget.onClose();
    } catch (e) {
      _toast('Archive failed: ${ApiError.fromAny(e).message}');
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_isCreate) {
      return _buildScaffold(null);
    }
    final list = ref.watch(adminProductsProvider);
    return list.when(
      data: (products) {
        final p = products.firstWhere(
          (e) => e.id == widget.productId,
          orElse: () => products.isNotEmpty
              ? products.first
              : throw StateError('product not found'),
        );
        _populate(p);
        return _buildScaffold(p);
      },
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => Center(child: Text("Can't load product: ${ApiError.fromAny(e).message}")),
    );
  }

  Widget _buildScaffold(AdminProduct? p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: ListView(
        children: [
          ManagerPageHeader(
            title: _isCreate ? 'New product' : 'Edit product',
            sub: _isCreate
                ? 'Goes live for students once saved.'
                : 'Products / ${p?.name ?? '…'}',
            actions: [
              YButton(
                label: 'Cancel',
                variant: YButtonVariant.outline,
                small: true,
                onTap: widget.onClose,
              ),
              if (!_isCreate)
                YButton(
                  label: _archiving ? 'Archiving…' : 'Archive',
                  variant: YButtonVariant.outline,
                  small: true,
                  onTap: _archiving ? null : _archive,
                ),
              YButton(
                label: _saving
                    ? 'Saving…'
                    : (_isCreate ? 'Create product' : 'Save changes'),
                small: true,
                onTap: _saving ? null : _save,
              ),
            ],
          ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: _LeftCard(state: this)),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: _RightColumn(state: this)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================ LEFT (form) ============================

class _LeftCard extends StatelessWidget {
  final _AdminProductEditorScreenState state;
  const _LeftCard({required this.state});

  @override
  Widget build(BuildContext context) {
    return ManagerCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _twoColRow(
            left: _FieldGroup(
              label: 'NAME',
              child: _BorderInput(controller: state._name, onChanged: (_) {
                state.rebuild();
              }),
            ),
            right: _FieldGroup(
              label: 'PRICE',
              child: _BorderInput(
                controller: state._priceCents,
                onChanged: (_) => state.rebuild(),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                suffix: state._currency,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _twoColRow(
            left: _FieldGroup(
              label: 'BILLING',
              child: _Seg(
                value: state._billing,
                options: const {
                  'one_time': 'One-time',
                  'recurring': 'Recurring',
                },
                onChanged: (v) {
                state._billing = v;
                state.rebuild();
              },
              ),
            ),
            right: _FieldGroup(
              label: 'PASS KIND',
              hint:
                  'Credit packs count down; unlimited checks only the validity window.',
              child: _Seg(
                value: state._passKind,
                options: const {
                  'credit': 'Credits',
                  'unlimited': 'Unlimited',
                },
                onChanged: (v) {
                state._passKind = v;
                state.rebuild();
              },
              ),
            ),
          ),
          if (state._billing == 'recurring') ...[
            const SizedBox(height: 18),
            _FieldGroup(
              label: 'BILLS EVERY',
              hint:
                  'Recurring memberships auto-renew via Stripe. A recurring '
                  'Price is created in your Stripe account on save — needs '
                  'Stripe configured in Settings.',
              child: _Seg(
                value: state._interval,
                options: const {'month': 'Month', 'year': 'Year'},
                onChanged: (v) {
                  state._interval = v;
                  state.rebuild();
                },
              ),
            ),
          ],
          const SizedBox(height: 18),
          _twoColRow(
            left: _FieldGroup(
              label: 'CREDITS',
              hint: state._passKind == 'unlimited'
                  ? 'Disabled for unlimited passes.'
                  : null,
              child: _BorderInput(
                controller: state._credits,
                onChanged: (_) => state.rebuild(),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                enabled: state._passKind == 'credit',
                width: 130,
              ),
            ),
            right: _FieldGroup(
              label: 'VALID FOR',
              hint: 'From purchase date.',
              child: _BorderInput(
                controller: state._validity,
                onChanged: (_) => state.rebuild(),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                suffix: 'days',
                width: 160,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _FieldGroup(
            label: 'REPEAT PURCHASES',
            hint: switch (state._duplicatePolicy) {
              'prevent' =>
                'Block buying this while they still hold a usable one.',
              'topup' =>
                'Buying again adds onto their existing pass (credits + validity) '
                    'instead of creating a separate one.',
              _ => 'Each purchase creates a separate pass (credits stack).',
            },
            child: _Seg(
              value: state._duplicatePolicy,
              options: const {
                'allow': 'Allow',
                'prevent': 'Prevent',
                'topup': 'Top-up',
              },
              onChanged: (v) {
                state._duplicatePolicy = v;
                state.rebuild();
              },
            ),
          ),
          const SizedBox(height: 18),
          _FieldGroup(
            label: 'DESCRIPTION',
            hint: 'Short blurb shown on the Buy row.',
            child: _BorderInput(
              controller: state._description,
              onChanged: (_) => state.rebuild(),
            ),
          ),
          const SizedBox(height: 20),
          _ClassTypeChips(state: state),
          const SizedBox(height: 20),
          _FutureOnlyNote(),
        ],
      ),
    );
  }

  Widget _twoColRow({required Widget left, required Widget right}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 18),
        Expanded(child: right),
      ],
    );
  }
}

class _FieldGroup extends StatelessWidget {
  final String label;
  final String? hint;
  final Widget child;
  const _FieldGroup({required this.label, this.hint, required this.child});

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
          const SizedBox(height: 6),
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

class _BorderInput extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final String? suffix;
  final bool enabled;
  final double? width;
  const _BorderInput({
    required this.controller,
    required this.onChanged,
    this.inputFormatters,
    this.suffix,
    this.enabled = true,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: y.borderStrong),
          borderRadius: BorderRadius.circular(10),
          color: enabled ? y.surface : y.surface2,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                enabled: enabled,
                inputFormatters: inputFormatters,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: enabled ? y.text : y.muted,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 5),
                ),
              ),
            ),
            if (suffix != null) ...[
              const SizedBox(width: 6),
              Text(
                suffix!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;
  const _Seg({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final keys = options.keys.toList();
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final k in keys)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(k),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: k == value ? y.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: k == value ? y.border : Colors.transparent,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    options[k]!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: k == value ? y.text : y.muted,
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

class _ClassTypeChips extends ConsumerWidget {
  final _AdminProductEditorScreenState state;
  const _ClassTypeChips({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final types = ref.watch(adminClassTypesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ELIGIBLE CLASS TYPES',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        types.when(
          data: (list) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in list)
                _CheckChip(
                  label: t.name,
                  on: state._classTypeIds.contains(t.id),
                  onTap: () {
                    if (state._classTypeIds.contains(t.id)) {
                      state._classTypeIds.remove(t.id);
                    } else {
                      state._classTypeIds.add(t.id);
                    }
                    state.rebuild();
                  },
                ),
            ],
          ),
          loading: () => const SizedBox(
            height: 24,
            child: Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          ),
          error: (e, _) => Text("Can't load types: ${ApiError.fromAny(e).message}"),
        ),
      ],
    );
  }
}

class _CheckChip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _CheckChip({
    required this.label,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? y.primarySoft : y.surface,
          borderRadius: BorderRadius.circular(y.radiusChip),
          border: Border.all(
            color: on ? Colors.transparent : y.borderStrong,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (on) ...[
              Icon(Icons.check, size: 11, color: y.primaryStrong),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: on ? y.primaryStrong : y.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FutureOnlyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: y.muted,
            height: 1.5,
          ),
          children: [
            const TextSpan(text: 'Changes apply to '),
            TextSpan(
              text: 'future purchases only',
              style: TextStyle(color: y.text, fontWeight: FontWeight.w800),
            ),
            const TextSpan(
              text:
                  " — passes already sold keep the terms they were bought with.",
            ),
          ],
        ),
      ),
    );
  }
}

// ============================ RIGHT column ============================

class _RightColumn extends ConsumerWidget {
  final _AdminProductEditorScreenState state;
  const _RightColumn({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(adminClassTypesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ManagerCard(
          title: 'Student sees',
          child: types.when(
            data: (list) => _StudentSeesPreview(state: state, types: list),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ),
            ),
            error: (e, _) => const SizedBox.shrink(),
          ),
        ),
        const SizedBox(height: 12),
        ManagerCard(
          title: 'In use',
          child: _InUseCard(state: state),
        ),
      ],
    );
  }
}

class _StudentSeesPreview extends StatelessWidget {
  final _AdminProductEditorScreenState state;
  final List<ClassType> types;
  const _StudentSeesPreview({required this.state, required this.types});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final disciplines = <String>{};
    for (final id in state._classTypeIds) {
      final ct = types.firstWhere((t) => t.id == id,
          orElse: () => ClassType(id: '', name: '', discipline: ''));
      if (ct.discipline.isNotEmpty) disciplines.add(ct.discipline);
    }
    final gate = _gateLabel(disciplines);
    final accentGate = disciplines.length == 1 && !disciplines.contains('yoga');
    final price = state._priceMinor;
    final priceStr = _fmt(price, state._currency);
    final terms = _terms(state, disciplines);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: y.surface,
            borderRadius: BorderRadius.circular(y.radiusCard),
            border: Border.all(color: y.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state._name.text.trim().isEmpty
                          ? 'Product name'
                          : state._name.text.trim(),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: y.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      terms,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (gate.isNotEmpty) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentGate ? y.accentSoft : y.surface2,
                    borderRadius: BorderRadius.circular(y.radiusChip),
                  ),
                  child: Text(
                    gate,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: accentGate ? y.accent : y.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                priceStr,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: y.text,
                ),
              ),
              if (state._billing == 'recurring')
                Text(
                  '/mo',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _plain(state, types),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: y.muted,
            height: 1.55,
          ),
        ),
      ],
    );
  }

  String _gateLabel(Set<String> disciplines) {
    if (disciplines.length >= 2) return 'All disciplines';
    if (disciplines.length == 1) {
      final d = disciplines.first;
      if (d == 'yoga') return 'All yoga';
      return '${d[0].toUpperCase()}${d.substring(1)} only';
    }
    return '';
  }

  String _fmt(int minor, String currency) {
    final symbol = switch (currency) {
      'GBP' => '£',
      'USD' => '\$',
      'EUR' => '€',
      _ => '$currency ',
    };
    final whole = minor ~/ 100;
    final cents = minor % 100;
    final body =
        cents == 0 ? '$whole' : '$whole.${cents.toString().padLeft(2, '0')}';
    return '$symbol$body';
  }

  String _terms(_AdminProductEditorScreenState s, Set<String> disciplines) {
    final parts = <String>[];
    if (s._passKind == 'credit') {
      final c = int.tryParse(s._credits.text) ?? 0;
      parts.add('$c credit${c == 1 ? '' : 's'}');
    } else {
      parts.add('Unlimited');
    }
    final v = int.tryParse(s._validity.text);
    if (v != null) parts.add('valid $v days');
    return parts.join(' · ');
  }

  String _plain(_AdminProductEditorScreenState s, List<ClassType> types) {
    final names = types
        .where((t) => s._classTypeIds.contains(t.id))
        .map((t) => t.name)
        .toList();
    final namesStr = names.isEmpty ? 'no classes selected yet' : names.join(', ');
    if (s._passKind == 'unlimited') {
      final v = int.tryParse(s._validity.text);
      return 'In plain terms: every $namesStr class, '
          '${v == null ? 'unlimited' : 'for $v days from purchase'}.';
    }
    final c = int.tryParse(s._credits.text) ?? 0;
    final v = int.tryParse(s._validity.text);
    return 'In plain terms: $c class${c == 1 ? '' : 'es'} of $namesStr, '
        'used within ${v == null ? 'any time' : '$v days'} of purchase.';
  }
}

class _InUseCard extends StatelessWidget {
  final _AdminProductEditorScreenState state;
  const _InUseCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final u = state._usage;
    if (u == null) {
      return Text(
        'Stats appear here once the product has been sold.',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: y.muted,
        ),
      );
    }
    final rev = (u.revenueMinor / 100).toStringAsFixed(
      u.revenueMinor % 100 == 0 ? 0 : 2,
    );
    final last = u.lastSale == null
        ? 'no sales yet'
        : 'last sale ${_relTime(u.lastSale!)} ago';
    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: y.muted,
          height: 1.6,
        ),
        children: [
          TextSpan(
            text: '${u.activePasses} active pass${u.activePasses == 1 ? '' : 'es'}',
            style: TextStyle(color: y.text, fontWeight: FontWeight.w800),
          ),
          const TextSpan(text: ' from this product.\n'),
          TextSpan(
            text: '£$rev',
            style: TextStyle(color: y.text, fontWeight: FontWeight.w800),
          ),
          TextSpan(text: ' revenue · $last.'),
        ],
      ),
    );
  }

  static String _relTime(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inMinutes < 1) return 'moments';
    if (delta.inHours < 1) return '${delta.inMinutes} min';
    if (delta.inDays < 1) return '${delta.inHours} h';
    if (delta.inDays < 7) return '${delta.inDays} d';
    return '${(delta.inDays / 7).floor()} wk';
  }
}
