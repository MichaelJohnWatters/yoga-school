// Checkout bottom sheet shown over Buy.
// Mirrors yoga-checkout.jsx YCheckoutScreen.
//
// Stripe is deferred — POST /purchases?payment_method=dev_stub instantly
// completes the purchase and returns the resulting entitlement. The Apple Pay
// and Google Pay rows are visually present but tap as "dev stub" too.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import 'book_screen.dart';
import 'buy_screen.dart';
import 'home_screen.dart';
import 'purchase_success_screen.dart';

class CheckoutSheet extends ConsumerStatefulWidget {
  final Product product;
  /// When non-null, the student entered Buy from a specific class they
  /// couldn't book. After payment, we auto-create that booking with the
  /// new entitlement and route to a "you're booked" success screen.
  final String? bookAfterPurchaseClassId;
  /// Local-day of the class above — passed so BookScreen can refresh
  /// the right day even if the user's selection has moved on.
  final DateTime? bookAfterPurchaseDay;
  const CheckoutSheet({
    super.key,
    required this.product,
    this.bookAfterPurchaseClassId,
    this.bookAfterPurchaseDay,
  });

  @override
  ConsumerState<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends ConsumerState<CheckoutSheet> {
  bool _submitting = false;
  String? _error;
  final _discountCtrl = TextEditingController();

  @override
  void dispose() {
    _discountCtrl.dispose();
    super.dispose();
  }

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
              const SizedBox(height: 16),
              TextField(
                controller: _discountCtrl,
                enabled: !_submitting,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Discount code (optional)',
                  hintText: 'WELCOME10',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
              ),
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
                key: const Key('checkout-pay-button'),
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
      // Studio rule: one active pass at a time. If the student already has
      // an active entitlement, warn them — even if it's a credit pack with
      // 1 ticket left — before taking their money a second time.
      final existing = await api.myEntitlements();
      final duplicate = existing.firstWhereOrNull(
        (e) => e.isActive && e.sourceProductId == widget.product.id,
      );
      final anyActive = existing.firstWhereOrNull((e) => e.isActive);
      if (mounted && (duplicate != null || anyActive != null)) {
        final clash = duplicate ?? anyActive!;
        final proceed = await _confirmDuplicate(clash, isSameProduct: duplicate != null);
        if (proceed != true) {
          if (mounted) setState(() => _submitting = false);
          return;
        }
      }
      final code = _discountCtrl.text.trim();
      final result = await api.createPurchase(
        productId: widget.product.id,
        discountCode: code.isEmpty ? null : code,
      );
      // Invalidate caches that depend on entitlements/bookings.
      ref.invalidate(upcomingBookingsProvider);
      ref.invalidate(productsProvider);
      // If the student came from a "Buy pass and book" flow, immediately
      // book the originally-tapped class with the freshly-minted
      // entitlement. We swallow booking failures here and fall through to
      // the regular success screen — the pass still landed in their
      // wallet, and the booking is a best-effort follow-up.
      var bookedClass = false;
      final pendingClassId = widget.bookAfterPurchaseClassId;
      if (pendingClassId != null) {
        try {
          await api.createBooking(
            classId: pendingClassId,
            entitlementId: result.entitlement.id,
          );
          bookedClass = true;
          ref.invalidate(upcomingBookingsProvider);
          // Tells the Book tab (sitting behind this flow) to refresh
          // the class's day so the new booking is visible the moment
          // the user dismisses the success screen.
          ref
              .read(classesChangedTickProvider.notifier)
              .bump(day: widget.bookAfterPurchaseDay);
        } catch (_) {}
      }
      if (!mounted) return;
      // Capture the navigator BEFORE pop — after pop the sheet's context
      // is detached and Navigator.of(context) is unsafe.
      final nav = Navigator.of(context);
      nav.pop(true);
      final successPage = MaterialPageRoute(
        builder: (_) => PurchaseSuccessScreen(
          product: widget.product,
          entitlement: result.entitlement,
          autoBooked: bookedClass,
        ),
        fullscreenDialog: true,
      );
      // In the buy+book flow we replace the BuyScreen route so tapping
      // "Done" on the success screen returns straight to the Book tab,
      // not back into Buy.
      if (pendingClassId != null) {
        nav.pushReplacement(successPage);
      } else {
        nav.push(successPage);
      }
    } on BookingConflict catch (e) {
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = 'Payment failed: ${ApiError.fromAny(e).message}';
      });
    }
  }

  Future<bool?> _confirmDuplicate(
    WalletEntitlement existing, {
    required bool isSameProduct,
  }) {
    final y = context.yoga;
    final title = isSameProduct
        ? 'You already own this pass'
        : 'You already have an active pass';
    final remaining = existing.isUnlimited
        ? 'Active until '
            '${_shortDate(existing.expiresAt ?? DateTime.now())}'
        : '${existing.creditsRemaining ?? 0} of '
            '${existing.creditsTotal ?? 0} classes left';
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: y.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(y.radiusCard),
          ),
          title: Text(
            title,
            style: TextStyle(
              color: y.text,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${existing.label} · $remaining',
                style: TextStyle(
                  color: y.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isSameProduct
                    ? 'Buying again will mint a second ${widget.product.name}. The studio recommends finishing your current pass first.'
                    : 'You can only use one pass at a time. Buying ${widget.product.name} now leaves your current pass untouched until this one expires.',
                style: TextStyle(
                  color: y.muted,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                'Not now',
                style: TextStyle(
                  color: y.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                'Buy anyway',
                style: TextStyle(
                  color: y.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _shortDate(DateTime d) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
               'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]}';
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
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
