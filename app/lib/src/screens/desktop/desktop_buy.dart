// Desktop Buy — grouped layout at desktop width.
// Memberships render as 2-up cards; class packs as 2-up rows below.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import '../buy_screen.dart' show productsProvider;
import '../checkout_sheet.dart' show CheckoutSheet;

class DesktopBuy extends ConsumerWidget {
  const DesktopBuy({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final products = ref.watch(productsProvider);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Text(
          'Buy',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            color: y.text,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Passes & memberships',
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
            color: y.muted,
          ),
        ),
        const SizedBox(height: 22),
        products.when(
          data: (list) => _Body(products: list),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          error: (e, _) => Text("Can't load products: $e"),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final List<Product> products;
  const _Body({required this.products});

  @override
  Widget build(BuildContext context) {
    final memberships = products.where((p) => p.isMembership).toList();
    final packs = products.where((p) => !p.isMembership).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (memberships.isNotEmpty) ...[
          const YSectionHead(title: 'Memberships'),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < memberships.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: _MembershipCard(product: memberships[i])),
              ],
            ],
          ),
          const SizedBox(height: 22),
        ],
        if (packs.isNotEmpty) ...[
          const YSectionHead(title: 'Class packs'),
          _Packs2Up(items: packs),
        ],
      ],
    );
  }
}

class _MembershipCard extends StatelessWidget {
  final Product product;
  const _MembershipCard({required this.product});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final fill = product.isHero;
    final bg = fill ? y.primary : y.primarySoft;
    final fg = fill ? y.onPrimary : y.text;
    final muted = fill ? y.onPrimary.withValues(alpha: 0.85) : y.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: () => _openCheckout(context, product),
      child: Container(
        padding: const EdgeInsets.all(18),
        constraints: const BoxConstraints(minHeight: 132),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(y.radiusCard),
          boxShadow: fill ? y.shadow : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.autorenew, size: 14, color: fill ? y.onPrimary : y.primary),
                const SizedBox(width: 6),
                Text(
                  'Membership',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: fill ? y.onPrimary : y.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              product.name,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: fg,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              product.description.isEmpty ? product.terms() : product.description,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  product.formattedPrice(),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                    color: fg,
                  ),
                ),
                if (product.billingType == 'recurring')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, left: 2),
                    child: Text(
                      '/mo',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Packs2Up extends StatelessWidget {
  final List<Product> items;
  const _Packs2Up({required this.items});

  @override
  Widget build(BuildContext context) {
    // 2-up rows: pair items.
    final rows = <List<Product>>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(items.sublist(i, (i + 2).clamp(0, items.length)));
    }
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var k = 0; k < 2; k++) ...[
                if (k > 0) const SizedBox(width: 12),
                Expanded(
                  child: k < rows[i].length
                      ? _PackRow(product: rows[i][k])
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _PackRow extends StatelessWidget {
  final Product product;
  const _PackRow({required this.product});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return InkWell(
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: () => _openCheckout(context, product),
      child: Container(
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
                    product.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    product.terms(),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _GateChip(label: product.gateLabel(), accent: product.gateIsAccent),
            const SizedBox(width: 12),
            Text(
              product.formattedPrice(),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                color: y.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GateChip extends StatelessWidget {
  final String label;
  final bool accent;
  const _GateChip({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final bg = accent ? y.accentSoft : y.surface2;
    final fg = accent ? y.accent : y.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(y.radiusChip),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

Future<void> _openCheckout(BuildContext context, Product product) async {
  // On desktop, render checkout as a centered modal dialog.
  await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Material(
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SingleChildScrollView(
              child: CheckoutSheet(product: product),
            ),
          ),
        ),
      ),
    ),
  );
}
