// Buy screen — grouped layout (Memberships block, then Class packs list).
// Mirrors yoga-buy.jsx YBuyGrouped. The studio.buyLayout field will let us
// flip to Grid/List for studios that prefer them; grouped is the default.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'checkout_sheet.dart';

/// Keyed by the optional class-type id. Pass null for the unrestricted list
/// (the default Buy tab); pass a class type when the buyer arrived from a
/// specific class's "no eligible pass" empty state so the picker only shows
/// passes that cover it.
// Session-scoped — Buy is a primary tab; users hit it repeatedly and
// the catalogue rarely changes. The family key is the optional
// coversClassTypeId, so a per-class filtered list survives navigation
// back to that same class's "Buy pass and book" flow.
final productsProvider = FutureProvider
    .family<List<Product>, String?>((ref, coversClassTypeId) async {
  return ref
      .watch(apiClientProvider)
      .listProducts(coversClassTypeId: coversClassTypeId);
});

class BuyScreen extends ConsumerWidget {
  /// When non-null, the list is narrowed to passes that cover this class
  /// type — set by the BookingSheet "Buy a pass" CTA so students don't
  /// see passes that wouldn't unlock the class they wanted.
  final String? coversClassTypeId;

  /// When non-null, the user entered this flow from a class they wanted
  /// to book but couldn't (no eligible pass). After the purchase
  /// completes, CheckoutSheet will auto-book this class with the new
  /// entitlement.
  final String? bookAfterPurchaseClassId;

  /// Local-day of the class above. Carried so BookScreen can refresh
  /// the right day after the auto-book completes.
  final DateTime? bookAfterPurchaseDay;

  /// One of 'grouped' (default), 'grid', 'list'. Set per-studio in the
  /// manager settings; rendered here so each studio can pick the layout
  /// that suits their catalogue.
  final String? buyLayout;

  /// User + studio so the screen can render the shared YStudioTopBar
  /// the same way Home and Book do. Optional — the BookingSheet "Buy
  /// pass and book" push-route still works without them (Scaffold +
  /// SafeArea host) and just renders without the bar.
  final Me? me;
  final StudioConfig? studio;

  /// Wired from RootShell so tapping the avatar in the top bar jumps
  /// to the Profile tab. Null on the push-route variant.
  final VoidCallback? onTapProfile;

  const BuyScreen({
    super.key,
    this.coversClassTypeId,
    this.bookAfterPurchaseClassId,
    this.bookAfterPurchaseDay,
    this.buyLayout,
    this.me,
    this.studio,
    this.onTapProfile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(productsProvider(coversClassTypeId));
    return RefreshOnMount(
      onMount: () => ref.invalidate(productsProvider(coversClassTypeId)),
      child: _BookAfterPurchaseScope(
      classId: bookAfterPurchaseClassId,
      day: bookAfterPurchaseDay,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (me != null && studio != null) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: YStudioTopBar(
                studioName: studio!.name,
                userFullName: me!.fullName,
                userPhotoUrl: me!.photoUrl,
                onAvatarTap: onTapProfile,
              ),
            ),
            const SizedBox(height: 18),
          ],
          const _BuyHeader(),
          Expanded(
            child: products.when(
              data: (list) {
                switch (buyLayout) {
                  case 'grid':
                    return _GridBody(products: list);
                  case 'list':
                    return _ListBody(products: list);
                  default:
                    return _GroupedBody(products: list);
                }
              },
              loading: () =>
                  const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, _) => Center(child: Text("Can't load products: ${ApiError.fromAny(e).message}")),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

/// Threads the "auto-book this class after purchase" intent from BuyScreen
/// down to _openCheckout without plumbing it through every body/card.
class _BookAfterPurchaseScope extends InheritedWidget {
  final String? classId;
  final DateTime? day;
  const _BookAfterPurchaseScope({
    required this.classId,
    required this.day,
    required super.child,
  });

  static _BookAfterPurchaseScope? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_BookAfterPurchaseScope>();

  @override
  bool updateShouldNotify(_BookAfterPurchaseScope old) =>
      classId != old.classId || day != old.day;
}

class _BuyHeader extends StatelessWidget {
  const _BuyHeader();

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
          // Filter chips are visual-only for now; products are seeded with
          // explicit class type coverage. Filter logic comes when there are
          // enough products to warrant it.
          Row(
            children: [
              for (final (i, label) in const [(0, 'All'), (1, 'Yoga'), (2, 'Reformer')].indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _FilterChip(label: label.$2, active: i == 0),
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
  const _FilterChip({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
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

/// Flat list — every product as a _PackRow, no grouping or hero treatment.
/// Useful for studios with one or two passes who don't need the
/// memberships/packs split.
class _ListBody extends StatelessWidget {
  final List<Product> products;
  const _ListBody({required this.products});

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      return const _NoProductsEmpty();
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        for (final p in products) ...[
          _PackRow(product: p),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// Two-column tile layout. Good for catalogues where every pass deserves
/// equal weight — no membership/pack hierarchy.
class _GridBody extends StatelessWidget {
  final List<Product> products;
  const _GridBody({required this.products});

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      return const _NoProductsEmpty();
    }
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      childAspectRatio: 0.85,
      children: [
        for (final p in products) _GridCard(product: p),
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
      key: Key('product-row-${product.id}'),
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: () => _openCheckout(context, product),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _GateChip(label: product.gateLabel(), accent: product.gateIsAccent),
            const SizedBox(height: 8),
            Text(
              product.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                color: y.text,
                height: 1.2,
              ),
            ),
            const Spacer(),
            Text(
              product.formattedPrice(),
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                color: y.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              product.terms(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
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

class _NoProductsEmpty extends StatelessWidget {
  const _NoProductsEmpty();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 30),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: y.surface2,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.shopping_bag_outlined, size: 25, color: y.muted),
            ),
            const SizedBox(height: 12),
            Text(
              'No passes cover this class yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: y.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Check back later or ask the studio.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
              ),
            ),
          ],
        ),
      ),
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
    // IntrinsicHeight gives the Row a finite cross-axis size derived from
    // the tallest card's natural height; without it `stretch` would inherit
    // the unbounded height of the surrounding ListView and throw.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _MembershipCard(product: items[i])),
          ],
        ],
      ),
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
      key: Key('product-row-${product.id}'),
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
            // Spacer only inside the multi-card IntrinsicHeight Row layout,
            // where the parent provides a bounded height. In the single-
            // membership `expand: true` case the Column is mainAxisSize.min
            // and Spacer would assert on unbounded height.
            if (expand) const SizedBox(height: 6) else const Spacer(),
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
                      '/mo',
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
      key: Key('product-row-${product.id}'),
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

Future<void> _openCheckout(BuildContext context, Product product) async {
  final scope = _BookAfterPurchaseScope.of(context);
  await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x66100A05),
    builder: (_) => CheckoutSheet(
      product: product,
      bookAfterPurchaseClassId: scope?.classId,
      bookAfterPurchaseDay: scope?.day,
    ),
  );
}
