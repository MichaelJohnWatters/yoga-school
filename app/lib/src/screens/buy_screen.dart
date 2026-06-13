// Buy screen — three layouts (Grid / List / Grouped) per studio.buyLayout.
// Mirrors yoga-buy.jsx YBuyGrid / YBuyList / YBuyGrouped.
//
// The studio's choice in Settings determines which body renders. Each body
// shares the same _BuyHeader, _MembershipCard, _PackRow + _GateChip widgets;
// only the arrangement differs.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'checkout_sheet.dart';

final productsProvider = FutureProvider.autoDispose<List<Product>>((ref) async {
  return ref.watch(apiClientProvider).listProducts();
});

/// Buy filter — student's chosen discipline. `all` shows everything;
/// specific filters keep only products whose discipline set contains the
/// selected value (or is empty = covers everything).
enum _BuyFilter { all, yoga, reformer }

class BuyScreen extends ConsumerStatefulWidget {
  const BuyScreen({super.key});

  @override
  ConsumerState<BuyScreen> createState() => _BuyScreenState();
}

class _BuyScreenState extends ConsumerState<BuyScreen> {
  _BuyFilter _filter = _BuyFilter.all;

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider);
    final boot = ref.watch(bootstrapProvider);
    final layout = boot.maybeWhen(
      data: (b) => b.studio.buyLayout,
      orElse: () => 'grouped',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BuyHeader(
          filter: _filter,
          onFilter: (f) => setState(() => _filter = f),
        ),
        Expanded(
          child: products.when(
            data: (list) => _bodyFor(layout, _applyFilter(list)),
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text("Can't load products: $e")),
          ),
        ),
      ],
    );
  }

  List<Product> _applyFilter(List<Product> all) {
    if (_filter == _BuyFilter.all) return all;
    final target = _filter == _BuyFilter.yoga ? 'yoga' : 'reformer';
    return all.where((p) {
      // Products with no declared disciplines (or with 'all') cover everything.
      if (p.disciplines.isEmpty) return true;
      return p.disciplines.contains(target);
    }).toList();
  }

  Widget _bodyFor(String layout, List<Product> products) => switch (layout) {
        'grid' => _GridBody(products: products),
        'list' => _ListBody(products: products),
        _ => _GroupedBody(products: products),
      };
}

class _BuyHeader extends StatelessWidget {
  final _BuyFilter filter;
  final ValueChanged<_BuyFilter> onFilter;
  const _BuyHeader({required this.filter, required this.onFilter});

  static const _options = [
    (_BuyFilter.all, 'All'),
    (_BuyFilter.yoga, 'Yoga'),
    (_BuyFilter.reformer, 'Reformer'),
  ];

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          const SizedBox(height: 2),
          Text(
            'Passes & memberships',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final (value, label) in _options)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _FilterChip(
                    label: label,
                    active: value == filter,
                    onTap: () => onFilter(value),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: active ? y.text : y.surface,
          borderRadius: BorderRadius.circular(y.radiusChip),
          border: Border.all(color: active ? Colors.transparent : y.borderStrong),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: active ? y.background : y.muted,
          ),
        ),
      ),
    );
  }
}

class _GroupedBody extends StatelessWidget {
  final List<Product> products;
  const _GroupedBody({required this.products});

  @override
  Widget build(BuildContext context) {
    final memberships = products.where((p) => p.isMembership).toList();
    final packs = products.where((p) => !p.isMembership).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        if (memberships.isNotEmpty) ...[
          const YSectionHead(title: 'Memberships'),
          _MembershipsGrid(items: memberships),
          const SizedBox(height: 18),
        ],
        if (packs.isNotEmpty) ...[
          const YSectionHead(title: 'Class packs'),
          for (final p in packs) ...[
            _PackRow(product: p),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}

class _MembershipsGrid extends StatelessWidget {
  final List<Product> items;
  const _MembershipsGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.length == 1) {
      return _MembershipCard(product: items.first, expand: true);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _MembershipCard(product: items[i])),
        ],
      ],
    );
  }
}

class _MembershipCard extends StatelessWidget {
  final Product product;
  final bool expand;
  const _MembershipCard({required this.product, this.expand = false});

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
        constraints: const BoxConstraints(minHeight: 108),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(y.radiusCard),
          boxShadow: fill ? y.shadow : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: expand ? MainAxisSize.min : MainAxisSize.max,
          children: [
            _MembershipTag(onFill: fill),
            const SizedBox(height: 6),
            Text(
              product.name,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                height: 1.2,
                color: fg,
              ),
            ),
            const SizedBox(height: 6),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  product.formattedPrice(),
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: fg,
                  ),
                ),
                if (product.billingType == 'recurring')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 1),
                    child: Text(
                      '/month',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              product.description.isNotEmpty ? product.description : product.terms(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: muted,
                height: 1.35,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _MembershipTag extends StatelessWidget {
  final bool onFill;
  const _MembershipTag({required this.onFill});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final color = onFill ? y.onPrimary : y.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.autorenew, size: 12, color: color),
        const SizedBox(width: 5),
        Text(
          'Membership',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: color,
            height: 1.0,
          ),
        ),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: y.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    product.terms(),
                    style: TextStyle(
                      fontSize: 12,
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
                fontSize: 17,
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
          height: 1.2,
        ),
      ),
    );
  }
}

/// Grid body: 2-up card grid mixing memberships + packs. Mirrors YBuyGrid
/// from yoga-buy.jsx. Hero memberships fill primary; other memberships sit
/// on primary-soft; packs stay on surface with a border.
class _GridBody extends StatelessWidget {
  final List<Product> products;
  const _GridBody({required this.products});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            mainAxisExtent: 138,
          ),
          itemCount: products.length,
          itemBuilder: (_, i) => _GridCard(product: products[i]),
        ),
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
    final isMembership = product.isMembership;
    final fill = product.isHero;
    final bg = fill ? y.primary : (isMembership ? y.primarySoft : y.surface);
    final fg = fill ? y.onPrimary : y.text;
    final muted = fill ? y.onPrimary.withValues(alpha: 0.85) : y.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: () => _openCheckout(context, product),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: (isMembership || fill)
              ? null
              : Border.all(color: y.border),
          boxShadow: fill ? y.shadow : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            isMembership
                ? _MembershipTag(onFill: fill)
                : _GateChip(label: product.gateLabel(), accent: product.gateIsAccent),
            const SizedBox(height: 6),
            Text(
              product.name,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                height: 1.2,
                color: fg,
              ),
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  product.formattedPrice(),
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: fg,
                  ),
                ),
                if (product.billingType == 'recurring')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 1),
                    child: Text(
                      '/month',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              product.terms(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: muted,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// List body: full-width rows for every product. Mirrors YBuyList.
class _ListBody extends StatelessWidget {
  final List<Product> products;
  const _ListBody({required this.products});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemCount: products.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _ListRow(product: products[i]),
    );
  }
}

class _ListRow extends StatelessWidget {
  final Product product;
  const _ListRow({required this.product});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final isMembership = product.isMembership;
    final fill = product.isHero;
    final bg = fill ? y.primary : (isMembership ? y.primarySoft : y.surface);
    final fg = fill ? y.onPrimary : y.text;
    final muted = fill ? y.onPrimary.withValues(alpha: 0.85) : y.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: () => _openCheckout(context, product),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: (isMembership || fill) ? null : Border.all(color: y.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          product.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                            color: fg,
                          ),
                        ),
                      ),
                      if (isMembership) ...[
                        const SizedBox(width: 8),
                        _MembershipTag(onFill: fill),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    product.terms(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
            if (!isMembership) ...[
              const SizedBox(width: 8),
              _GateChip(label: product.gateLabel(), accent: product.gateIsAccent),
            ],
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  product.formattedPrice(),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: fg,
                  ),
                ),
                if (product.billingType == 'recurring')
                  Text(
                    '/month',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: muted,
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

Future<void> _openCheckout(BuildContext context, Product product) async {
  await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x66100A05),
    builder: (_) => CheckoutSheet(product: product),
  );
}
