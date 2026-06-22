// Purchase success — mirrors yoga-checkout.jsx YPurchaseSuccessScreen.
// Shown via push() after the checkout sheet dismisses. Tapping "Done" or
// "Book your first class" pops back to the tab shell.

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';

class PurchaseSuccessScreen extends StatelessWidget {
  final Product product;
  final PurchaseEntitlement entitlement;
  /// True when the user reached this screen via the "Buy pass and book"
  /// flow on the booking sheet — we already booked the class they wanted,
  /// so the messaging and CTAs change to reflect that.
  final bool autoBooked;

  const PurchaseSuccessScreen({
    super.key,
    required this.product,
    required this.entitlement,
    this.autoBooked = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Scaffold(
      backgroundColor: y.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 80),
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: y.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.check, color: y.onPrimary, size: 36),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  autoBooked ? "You're booked" : "You're all set",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: y.text,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  _subline(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _PassCard(product: product, entitlement: entitlement),
              const SizedBox(height: 22),
              YButton(
                label: autoBooked ? 'Done' : 'Book your first class',
                onTap: () => Navigator.of(context).pop(),
              ),
              if (!autoBooked) ...[
                const SizedBox(height: 14),
                Center(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Text(
                      'Done',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: y.muted,
                      ),
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Center(
                child: Text(
                  _receiptLine(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: y.muted,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  String _subline() {
    if (autoBooked) {
      return 'Your ${entitlement.label} is in your wallet and your spot is confirmed — see you in class.';
    }
    if (entitlement.passKind == 'unlimited') {
      return 'Your ${entitlement.label} is in your wallet — book classes any time until it expires.';
    }
    return 'Your ${entitlement.label} is in your wallet and ready to use.';
  }

  String _receiptLine() {
    final amount = product.formattedPrice();
    return 'Receipt sent · $amount on Visa ···· 4242';
  }
}

class _PassCard extends StatelessWidget {
  final Product product;
  final PurchaseEntitlement entitlement;
  const _PassCard({required this.product, required this.entitlement});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final total = entitlement.creditsTotal ?? 0;
    final isUnlimited = entitlement.passKind == 'unlimited';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: y.primarySoft,
        borderRadius: BorderRadius.circular(y.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entitlement.label,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: y.text,
                  ),
                ),
              ),
              YChip(
                kind: product.gateIsAccent ? YChipKind.accent : YChipKind.booked,
                label: product.gateLabel(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (isUnlimited)
            Container(
              height: 7,
              decoration: BoxDecoration(
                color: y.primary,
                borderRadius: BorderRadius.circular(4),
              ),
            )
          else
            Row(
              children: [
                for (var i = 0; i < total; i++) ...[
                  if (i > 0) const SizedBox(width: 5),
                  Expanded(
                    child: Container(
                      height: 7,
                      decoration: BoxDecoration(
                        color: y.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                    children: [
                      TextSpan(
                        text: isUnlimited
                            ? 'Unlimited classes'
                            : '$total of $total',
                        style: TextStyle(color: y.text, fontWeight: FontWeight.w800),
                      ),
                      TextSpan(text: isUnlimited ? '' : ' credits'),
                    ],
                  ),
                ),
              ),
              Text(
                entitlement.expiresAt != null
                    ? 'Expires ${_d(entitlement.expiresAt!)}'
                    : 'No expiry',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _d(DateTime d) {
    const mons = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final local = d.toLocal();
    return '${local.day} ${mons[local.month - 1]} ${local.year}';
  }
}
