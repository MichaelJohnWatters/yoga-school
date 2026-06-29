// Buy screen — three layouts (Grid / List / Grouped) per studio.buyLayout.
// Mirrors yoga-buy.jsx YBuyGrid / YBuyList / YBuyGrouped.
//
// The studio's choice in Settings determines which body renders. Each body
// shares the same _BuyHeader, _MembershipCard, _PackRow + _GateChip widgets;
// only the arrangement differs.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'checkout_sheet.dart';
import 'profile_screen.dart' show subscriptionsProvider, entitlementsProvider;

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

/// The membership product ids the student already holds (active or past_due).
/// Used to render those cards as "Current plan" rather than buyable, matching
/// the server's duplicate-subscription guard. A pending (abandoned checkout)
/// subscription is deliberately excluded so they can still retry.
// Derived from subscriptionsProvider so it refreshes whenever that does (e.g.
// RootShell's app-resume refresh after a membership purchase completes).
final activeMembershipProductIdsProvider = Provider<Set<String>>((ref) {
  final subs = ref.watch(subscriptionsProvider).asData?.value ?? const [];
  return subs
      .where((s) => s.status == 'active' || s.status == 'past_due')
      .map((s) => s.productId)
      .toSet();
});

/// Product ids the student already holds a *usable* pass for (active, not
/// expired, credits left). Drives the per-product duplicate_policy hints/gating
/// on the buy cards. Derived from entitlementsProvider so it tracks the wallet.
final heldUsablePassProductIdsProvider = Provider<Set<String>>((ref) {
  final ents = ref.watch(entitlementsProvider).asData?.value ?? const [];
  final now = DateTime.now();
  return ents
      .where((e) {
        if (e.status != 'active') return false;
        if (e.expiresAt != null && !e.expiresAt!.isAfter(now)) return false;
        if (e.passKind == 'credit') return (e.creditsRemaining ?? 0) > 0;
        return true;
      })
      .map((e) => e.sourceProductId)
      .whereType<String>()
      .toSet();
});

/// What a pass product's duplicate_policy means for a student who already holds
/// a usable one: whether to block the buy, and an optional hint to show.
({bool gated, String? note}) passDuplicateState(Product p, Set<String> held) {
  if (!held.contains(p.id)) return (gated: false, note: null);
  switch (p.duplicatePolicy) {
    case 'prevent':
      return (gated: true, note: 'Already owned');
    case 'topup':
      return (gated: false, note: 'Tops up your existing pass');
    default: // allow — no nag
      return (gated: false, note: null);
  }
}

/// Buy filter — student's chosen discipline. `all` shows everything;
/// specific filters keep only products whose discipline set contains the
/// selected value (or is empty = covers everything).
enum _BuyFilter { all, yoga, reformer }

class BuyScreen extends ConsumerStatefulWidget {
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

  /// Overrides the studio's configured layout. Null = read the layout
  /// off the bootstrap. The CheckoutSheet push-route passes a specific
  /// value when it wants a particular shape.
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
  ConsumerState<BuyScreen> createState() => _BuyScreenState();
}

class _BuyScreenState extends ConsumerState<BuyScreen> {
  _BuyFilter _filter = _BuyFilter.all;

  @override
  Widget build(BuildContext context) {
    final products =
        ref.watch(productsProvider(widget.coversClassTypeId));
    // Layout precedence: explicit override (push-route) → studio's
    // configured default → 'grouped' fallback. Reading the bootstrap
    // for the studio side keeps the manager's setting live without
    // requiring every caller to plumb it through.
    final boot = ref.watch(bootstrapProvider);
    final String layout = widget.buyLayout ??
        boot.maybeWhen<String>(
          data: (b) => b.studio.buyLayout,
          orElse: () => 'grouped',
        );
    return RefreshOnMount(
      onMount: () =>
          ref.invalidate(productsProvider(widget.coversClassTypeId)),
      child: _BookAfterPurchaseScope(
        classId: widget.bookAfterPurchaseClassId,
        day: widget.bookAfterPurchaseDay,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.me != null && widget.studio != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: YStudioTopBar(
                  studioName: widget.studio!.name,
                  userFullName: widget.me!.fullName,
                  userPhotoUrl: widget.me!.photoUrl,
                  onAvatarTap: widget.onTapProfile,
                ),
              ),
              const SizedBox(height: 18),
            ],
            _BuyHeader(
              filter: _filter,
              onFilter: (f) => setState(() => _filter = f),
            ),
            Expanded(
              child: products.when(
                data: (list) => _bodyFor(layout, _applyFilter(list)),
                loading: () => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (e, _) => Center(
                  child: Text(
                    "Can't load products: ${ApiError.fromAny(e).message}",
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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

class _GridCard extends ConsumerWidget {
  final Product product;
  const _GridCard({required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final dup =
        passDuplicateState(product, ref.watch(heldUsablePassProductIdsProvider));
    final card = Container(
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
              dup.note ?? product.terms(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: dup.note != null ? y.accent : y.muted,
              ),
            ),
          ],
        ),
      );
    return InkWell(
      key: Key('product-row-${product.id}'),
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: dup.gated
          ? () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('You already have this pass.')),
              )
          : () => _openCheckout(context, product),
      child: dup.gated ? Opacity(opacity: 0.6, child: card) : card,
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

class _MembershipCard extends ConsumerWidget {
  final Product product;
  final bool expand;
  const _MembershipCard({required this.product, this.expand = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final fill = product.isHero;
    final bg = fill ? y.primary : y.primarySoft;
    final fg = fill ? y.onPrimary : y.text;
    final muted = fill ? y.onPrimary.withValues(alpha: 0.85) : y.muted;
    // Already on this membership? Render it as the current plan, not buyable —
    // the server would reject a duplicate sign-up anyway (already_subscribed).
    // Default to buyable while the subscriptions list is loading.
    final owned =
        ref.watch(activeMembershipProductIdsProvider).contains(product.id);
    final card = Container(
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
            _MembershipTag(onFill: fill, currentPlan: owned),
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
                      product.billingInterval == 'year' ? '/year' : '/month',
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
      );

    if (!owned) {
      return InkWell(
        key: Key('product-row-${product.id}'),
        borderRadius: BorderRadius.circular(y.radiusCard),
        onTap: () => _openCheckout(context, product),
        child: card,
      );
    }
    // Already the current plan → not buyable; a tap explains why.
    return InkWell(
      key: Key('product-row-${product.id}'),
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're already on this plan.")),
      ),
      child: Opacity(opacity: 0.85, child: card),
    );
  }
}

class _MembershipTag extends StatelessWidget {
  final bool onFill;
  final bool currentPlan;
  const _MembershipTag({required this.onFill, this.currentPlan = false});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final color = onFill ? y.onPrimary : y.primary;
    if (currentPlan) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            'CURRENT PLAN',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: color,
            ),
          ),
        ],
      );
    }
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

class _PackRow extends ConsumerWidget {
  final Product product;
  const _PackRow({required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final dup =
        passDuplicateState(product, ref.watch(heldUsablePassProductIdsProvider));
    final row = Container(
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
                  if (dup.note != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      dup.note!,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: y.accent,
                      ),
                    ),
                  ],
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
      );
    return InkWell(
      key: Key('product-row-${product.id}'),
      borderRadius: BorderRadius.circular(y.radiusCard),
      onTap: dup.gated
          ? () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('You already have this pass.')),
              )
          : () => _openCheckout(context, product),
      child: dup.gated ? Opacity(opacity: 0.6, child: row) : row,
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
