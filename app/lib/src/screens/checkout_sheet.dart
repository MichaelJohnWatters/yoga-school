// Checkout bottom sheet shown over Buy.
// Mirrors yoga-checkout.jsx YCheckoutScreen.
//
// Stripe is deferred — POST /purchases?payment_method=dev_stub instantly
// completes the purchase and returns the resulting entitlement. The Apple Pay
// and Google Pay rows are visually present but tap as "dev stub" too.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'buy_screen.dart';
import 'home_screen.dart';
import 'purchase_success_screen.dart';

class CheckoutSheet extends ConsumerStatefulWidget {
  final Product product;
  const CheckoutSheet({super.key, required this.product});

  @override
  ConsumerState<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends ConsumerState<CheckoutSheet> {
  bool _submitting = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final p = widget.product;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              offset: Offset(0, -12),
              blurRadius: 40,
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: SafeArea(
          top: false,
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
                'Confirm purchase',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  color: y.text,
                ),
              ),
              const SizedBox(height: 14),
              _OrderSummary(product: p),
              const SizedBox(height: 16),
              _WalletRow(onPay: _submit, disabled: _submitting),
              const SizedBox(height: 16),
              _OrDivider(),
              const SizedBox(height: 8),
              _SavedCard(),
              const SizedBox(height: 8),
              _DifferentCard(),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(
                    color: const Color(0xFFA33B2E),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              YButton(
                label: _submitting ? 'Processing…' : 'Pay ${p.formattedPrice()}',
                onTap: _submitting ? null : _submit,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 12, color: y.muted),
                  const SizedBox(width: 6),
                  Text(
                    'Payments secured by Stripe · receipt by email',
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
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final result = await api.createPurchase(productId: widget.product.id);
      // Invalidate caches that depend on entitlements/bookings.
      ref.invalidate(upcomingBookingsProvider);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PurchaseSuccessScreen(
            product: widget.product,
            entitlement: result.entitlement,
          ),
          fullscreenDialog: true,
        ),
      );
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = 'Payment failed: $e';
      });
    }
  }
}

class _OrderSummary extends StatelessWidget {
  final Product product;
  const _OrderSummary({required this.product});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: y.primarySoft,
        borderRadius: BorderRadius.circular(y.radiusCard),
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
          Text(
            product.formattedPrice(),
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: y.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _WalletRow extends StatelessWidget {
  final VoidCallback onPay;
  final bool disabled;
  const _WalletRow({required this.onPay, required this.disabled});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _ApplePayBtn(onTap: disabled ? null : onPay)),
        const SizedBox(width: 8),
        Expanded(child: _GooglePayBtn(onTap: disabled ? null : onPay)),
      ],
    );
  }
}

class _ApplePayBtn extends StatelessWidget {
  final VoidCallback? onTap;
  const _ApplePayBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: Alignment.center,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.apple, size: 18, color: Colors.white),
            SizedBox(width: 4),
            Text(
              'Pay',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GooglePayBtn extends StatelessWidget {
  final VoidCallback? onTap;
  const _GooglePayBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFDADCE0)),
        ),
        alignment: Alignment.center,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'G',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Color(0xFF4285F4),
              ),
            ),
            SizedBox(width: 5),
            Text(
              'Pay',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF3C4043),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: y.border)),
        const SizedBox(width: 10),
        Text(
          'OR PAY WITH CARD',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: y.muted,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: y.border)),
      ],
    );
  }
}

class _SavedCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.primary, width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: y.primary, width: 1.5),
            ),
            alignment: Alignment.center,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: y.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 38,
            height: 25,
            decoration: BoxDecoration(
              color: y.text,
              borderRadius: BorderRadius.circular(5),
            ),
            alignment: Alignment.center,
            child: Text(
              'VISA',
              style: TextStyle(
                color: y.background,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '···· 4242',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            'Default',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: y.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _DifferentCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: y.borderStrong, width: 1.5),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Use a different card…',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: y.muted,
              ),
            ),
          ),
          Icon(Icons.chevron_right, size: 16, color: y.muted),
        ],
      ),
    );
  }
}
