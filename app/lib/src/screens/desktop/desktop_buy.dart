// Desktop Buy — honors the studio's buyLayout (grid / list / grouped), the
// same setting the mobile Buy screen switches on, with desktop-width
// treatments for each:
//   grouped — memberships (cards) + class packs (rows), each two-per-row;
//   grid    — a responsive multi-column card grid (2–4 across);
//   list    — full-width rows down the content column.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart' show bootstrapProvider;
import '../../api/models.dart';
import '../../api/api_error.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import '../buy_screen.dart' show productsProvider;
import '../checkout_sheet.dart' show CheckoutSheet;

class DesktopBuy extends ConsumerWidget {
  const DesktopBuy({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final products = ref.watch(productsProvider(null));
    // Same source the mobile Buy screen uses; 'grouped' until config lands.
    final layout = ref
        .watch(bootstrapProvider)
        .maybeWhen(data: (b) => b.studio.buyLayout, orElse: () => 'grouped');
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
          data: (list) => _Body(products: list, layout: layout),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          error: (e, _) =>
              Text("Can't load products: ${ApiError.fromAny(e).message}"),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final List<Product> products;
  final String layout;
  const _Body({required this.products, required this.layout});

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) return const _EmptyBuy();
    return switch (layout) {
      'grid' => _GridBody(products: products),
      'list' => _ListBody(products: products),
      _ => _GroupedBody(products: products),
    };
  }
}

/// Memberships (cards) + class packs (rows), each flowing two-per-row.
class _GroupedBody extends StatelessWidget {
  final List<Product> products;
  const _GroupedBody({required this.products});

  @override
  Widget build(BuildContext context) {
    final memberships = products.where((p) => p.isMembership).toList();
    final packs = products.where((p) => !p.isMembership).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (memberships.isNotEmpty) ...[
          const YSectionHead(title: 'Memberships'),
          _TwoUp(
            children: [
              for (final m in memberships) _MembershipCard(product: m),
            ],
          ),
          const SizedBox(height: 22),
        ],
        if (packs.isNotEmpty) ...[
          const YSectionHead(title: 'Class packs'),
          _TwoUp(children: [for (final p in packs) _PackRow(product: p)]),
        ],
      ],
    );
  }
}

/// Flat full-width rows — no grouping or hero treatment.
class _ListBody extends StatelessWidget {
  final List<Product> products;
  const _ListBody({required this.products});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in products) ...[
          _PackRow(product: p),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// Responsive card grid. Fixed-width cards in a Wrap flow to fill the row at
/// any width — no nested scrollable, which is what was rendering the page
/// blank (a GridView inside the page ListView).
class _GridBody extends StatelessWidget {
  final List<Product> products;
  const _GridBody({required this.products});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final p in products)
          SizedBox(width: 220, child: _GridCard(product: p)),
      ],
    );
  }
}

class _GridCard extends StatelessWidget {
  final Product product;
  const _GridCard({required this.product});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return InkWell(
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: () => _openCheckout(context, product),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _GateChip(label: product.gateLabel(), accent: product.gateIsAccent),
            const SizedBox(height: 10),
            Text(
              product.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                height: 1.2,
                color: y.text,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              product.formattedPrice(),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: y.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              product.terms(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyBuy extends StatelessWidget {
  const _EmptyBuy();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          'No passes available right now.',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: y.muted,
          ),
        ),
      ),
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
                Icon(
                  Icons.autorenew,
                  size: 14,
                  color: fill ? y.onPrimary : y.primary,
                ),
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
              product.description.isEmpty
                  ? product.terms()
                  : product.description,
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
                      product.billingInterval == 'year' ? '/yr' : '/mo',
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

/// Lays children out two-per-row at desktop width. Cards in a row stretch to
/// equal height; a lone trailing child spans the full width rather than
/// sitting half-empty — so a section looks balanced at any count (1 → full,
/// 2 → side-by-side, 3 → pair + full, 4 → 2×2, …).
class _TwoUp extends StatelessWidget {
  final List<Widget> children;
  const _TwoUp({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < children.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: i + 1 < children.length
                ? [
                    Expanded(child: children[i]),
                    const SizedBox(width: 12),
                    Expanded(child: children[i + 1]),
                  ]
                : [Expanded(child: children[i])],
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
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
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
