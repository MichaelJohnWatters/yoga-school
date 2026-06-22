// Manager Products — list view, with a navigate-to-editor entry per row.
// Mirrors the "Products" tab from the design at a list-summary level.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'manager_shell.dart';

final adminProductsProvider =
    FutureProvider<List<AdminProduct>>((ref) async {
  return ref.watch(apiClientProvider).adminListProducts();
});

const double _kNarrow = 700;

class AdminProductsScreen extends ConsumerWidget {
  final VoidCallback onNew;
  final void Function(String productId) onEdit;
  const AdminProductsScreen({
    super.key,
    required this.onNew,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(adminProductsProvider);
    return RefreshOnMount(
      onMount: () => ref.invalidate(adminProductsProvider),
      child: LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _kNarrow;
        final padH = isNarrow ? 14.0 : 30.0;
        final padV = isNarrow ? 18.0 : 26.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ManagerPageHeader(
                title: 'Products',
                sub: 'Passes & memberships available to students',
                actions: [
                  YButton(label: '+ New product', small: true, onTap: onNew),
                ],
              ),
              Expanded(
                child: data.when(
                  data: (rows) =>
                      _ProductList(rows: rows, onEdit: onEdit, isNarrow: isNarrow),
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (e, _) => Center(
                    child: Text(
                      "Can't load products: ${ApiError.fromAny(e).message}",
                      style: TextStyle(color: context.yoga.muted),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
    );
  }
}

class _ProductList extends StatelessWidget {
  final List<AdminProduct> rows;
  final void Function(String productId) onEdit;
  final bool isNarrow;
  const _ProductList({
    required this.rows,
    required this.onEdit,
    required this.isNarrow,
  });

  @override
  Widget build(BuildContext context) {
    return ManagerCard(
      title: '${rows.length} product${rows.length == 1 ? '' : 's'}',
      child: rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No products yet — click "+ New product" to add one.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.yoga.muted,
                ),
              ),
            )
          : Column(
              children: [
                if (!isNarrow) _Head(),
                for (var i = 0; i < rows.length; i++)
                  if (isNarrow)
                    _MobileRow(
                      p: rows[i],
                      isLast: i == rows.length - 1,
                      onEdit: () => onEdit(rows[i].id),
                    )
                  else
                    _Row(
                      p: rows[i],
                      isLast: i == rows.length - 1,
                      onEdit: () => onEdit(rows[i].id),
                    ),
              ],
            ),
    );
  }
}

/// Mobile shape — name + badges on top with price aligned right,
/// pass type and metrics underneath, Edit link bottom-right.
class _MobileRow extends StatelessWidget {
  final AdminProduct p;
  final bool isLast;
  final VoidCallback onEdit;
  const _MobileRow({
    required this.p,
    required this.isLast,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final passSummary = p.passKind == 'unlimited'
        ? 'Unlimited'
        : '${p.credits ?? 0} credit${(p.credits ?? 0) == 1 ? '' : 's'}';
    final billing = p.billingType == 'recurring' ? '/month' : '';
    return InkWell(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: y.text,
                        ),
                      ),
                      if (p.isHero) _SmallBadge(label: 'Hero', accent: false),
                      if (p.isArchived)
                        _SmallBadge(label: 'Archived', accent: true),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text.rich(
                  TextSpan(
                    text: p.formattedPrice(),
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    children: [
                      TextSpan(
                        text: billing,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: y.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '$passSummary · ${p.usage.activePasses} active · '
              '${p.formattedPriceFromMinor(p.usage.revenueMinor)} revenue',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Edit ›',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: y.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final s = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: y.muted,
      letterSpacing: 0.6,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Expanded(flex: 14, child: Text('PRODUCT', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 100, child: Text('PRICE', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 100, child: Text('PASS', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: Text('ACTIVE', style: s)),
          const SizedBox(width: 12),
          SizedBox(width: 110, child: Text('REVENUE', style: s)),
          const SizedBox(width: 12),
          const SizedBox(width: 56),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final AdminProduct p;
  final bool isLast;
  final VoidCallback onEdit;
  const _Row({required this.p, required this.isLast, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final passSummary = p.passKind == 'unlimited'
        ? 'Unlimited'
        : '${p.credits ?? 0} credit${(p.credits ?? 0) == 1 ? '' : 's'}';
    final billing = p.billingType == 'recurring' ? '/month' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: y.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 14,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    p.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                ),
                if (p.isHero) ...[
                  const SizedBox(width: 8),
                  _SmallBadge(label: 'Hero', accent: false),
                ],
                if (p.isArchived) ...[
                  const SizedBox(width: 8),
                  _SmallBadge(label: 'Archived', accent: true),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 100,
            child: Row(
              children: [
                Text(
                  p.formattedPrice(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  billing,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 100,
            child: Text(
              passSummary,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Text(
              '${p.usage.activePasses}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: y.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Text(
              p.formattedPriceFromMinor(p.usage.revenueMinor),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: y.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 56,
            child: GestureDetector(
              onTap: onEdit,
              child: Text(
                'Edit',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: y.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension on AdminProduct {
  String formattedPriceFromMinor(int minor) {
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
}

class _SmallBadge extends StatelessWidget {
  final String label;
  final bool accent;
  const _SmallBadge({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent ? y.accentSoft : y.surface2,
        borderRadius: BorderRadius.circular(y.radiusChip),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: accent ? y.accent : y.muted,
        ),
      ),
    );
  }
}
