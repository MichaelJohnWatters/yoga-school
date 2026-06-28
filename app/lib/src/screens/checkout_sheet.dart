// Checkout bottom sheet shown over Buy.
// Mirrors yoga-checkout.jsx YCheckoutScreen.
//
// Payment always goes through Stripe — there is no non-Stripe fallback. On web
// it creates a hosted Checkout Session and redirects to checkout.stripe.com; on
// mobile it runs the native PaymentSheet (card + Apple Pay / Google Pay when the
// manager has enabled those wallets). The studio's keys must be configured (the
// server requires STRIPE_KEY_ENC_MASTER), or these calls surface a real error.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../api/web_redirect.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';
import '../widgets/visible_tab.dart' show currentTabProvider;
import 'book_screen.dart';
import 'buy_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart'
    show profileSegmentProvider, profileSegBookings, profileSegWallet;
import 'purchase_success_screen.dart';

/// Apple Pay merchant identifier. This is a PLATFORM-level value (one per app),
/// not per-studio: it must match the Apple Pay merchant ID configured in the
/// iOS app's Xcode entitlements and registered with Stripe. Payments still
/// route to each studio's own Stripe account via the server-created
/// PaymentIntent. Update this to the real `merchant.<reverse-domain>` id once
/// the Apple Pay capability is set up.
const _appleMerchantId = 'merchant.com.studio52.yoga';

/// Stripe API version the server must mint ephemeral keys with — it has to
/// match the version flutter_stripe's native SDKs are pinned to, or the
/// PaymentSheet rejects the key. If a device test logs a version-mismatch
/// error, set this to the version named in that error.
const _stripeApiVersion = '2020-08-27';

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
                label: _submitting
                    ? 'Processing…'
                    : 'Pay ${p.formattedPrice()}',
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
        final proceed = await _confirmDuplicate(
          clash,
          isSameProduct: duplicate != null,
        );
        if (proceed != true) {
          if (mounted) setState(() => _submitting = false);
          return;
        }
      }
      final code = _discountCtrl.text.trim();
      final discountCode = code.isEmpty ? null : code;

      final cfg = await ref.read(paymentConfigProvider.future);

      // Memberships (recurring) go through subscription-mode hosted Checkout —
      // the native PaymentSheet can't drive a subscription. Best practice is
      // Stripe's hosted page: a full-page redirect on web, the system browser
      // on mobile (never an embedded WebView). The checkout.session.completed
      // webhook is the authoritative fulfilment either way.
      if (widget.product.billingType == 'recurring') {
        if (kIsWeb) {
          final base = Uri.base;
          String ret(String outcome) => base
              .replace(
                queryParameters: {...base.queryParameters, 'checkout': outcome},
              )
              .toString();
          final session = await api.createCheckoutSubscription(
            productId: widget.product.id,
            successUrl: ret('success'),
            cancelUrl: ret('cancel'),
          );
          redirectToCheckout(session.url);
          return;
        }
        // Native: open the hosted Checkout in the system browser. It returns
        // to the web app's handler in-browser; the native app picks up the new
        // membership when it next resumes (RootShell's lifecycle refresh).
        final origin = api.origin;
        final session = await api.createCheckoutSubscription(
          productId: widget.product.id,
          successUrl: '$origin/?checkout=success',
          cancelUrl: '$origin/?checkout=cancel',
        );
        final launched = await launchUrl(
          Uri.parse(session.url),
          mode: LaunchMode.externalApplication,
        );
        if (!mounted) return;
        if (!launched) {
          setState(() {
            _submitting = false;
            _error = "Couldn't open the browser to finish checkout.";
          });
          return;
        }
        Navigator.of(context).pop(false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            "Finish your membership in the browser — it'll appear in your "
            'wallet when you return.',
          ),
        ));
        return;
      }

      // Web → hosted Checkout redirect, always. The browser navigates away to
      // Stripe and returns to ?checkout=success; CheckoutReturnHandler then
      // confirms the session (optimistic), and — when we came from a
      // "buy pass and book" flow — auto-books the class and lands on Book.
      // Nothing after redirectToCheckout runs — the page is unloaded, so the
      // book intent has to travel in the return URL.
      if (kIsWeb) {
        final base = Uri.base;
        String ret(String outcome) {
          final qp = {...base.queryParameters, 'checkout': outcome};
          if (outcome == 'success') {
            // Carry the product so the return handler can render the
            // full-screen success page (it has no app state after the redirect).
            qp['product_id'] = widget.product.id;
          }
          final classId = widget.bookAfterPurchaseClassId;
          if (outcome == 'success' && classId != null) {
            qp['book_class'] = classId;
            final day = widget.bookAfterPurchaseDay;
            if (day != null) {
              qp['book_day'] = day.toIso8601String();
            }
          }
          var url = base.replace(queryParameters: qp).toString();
          if (outcome == 'success') {
            // Stripe substitutes the literal {CHECKOUT_SESSION_ID} on return
            // (must stay un-encoded, so it's appended raw after the built Uri).
            url += '${url.contains('?') ? '&' : '?'}session_id={CHECKOUT_SESSION_ID}';
          }
          return url;
        }

        final session = await api.createCheckoutSession(
          productId: widget.product.id,
          discountCode: discountCode,
          successUrl: ret('success'),
          cancelUrl: ret('cancel'),
        );
        redirectToCheckout(session.url);
        return;
      }

      // Native (mobile) card path: the Stripe PaymentSheet, always. Card
      // payments go through Stripe — there is no non-Stripe fallback.
      final PurchaseResult? result = await _payWithSheet(
        api,
        cfg,
        discountCode,
      );
      // Null = the user dismissed the PaymentSheet. The pending purchase is
      // left for the server-side janitor to void; just reset the form.
      if (result == null) {
        if (mounted) setState(() => _submitting = false);
        return;
      }
      final purchase = result;
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
            entitlementId: purchase.entitlement.id,
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
          entitlement: purchase.entitlement,
          autoBooked: bookedClass,
          onGoToBookings: () {
            ref.read(currentTabProvider.notifier).set(3); // Profile
            ref.read(profileSegmentProvider.notifier).set(profileSegBookings);
          },
          onGoToWallet: () {
            ref.read(currentTabProvider.notifier).set(3);
            ref.read(profileSegmentProvider.notifier).set(profileSegWallet);
          },
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

  /// Runs the Stripe PaymentSheet for the card/wallet path. Returns the
  /// confirmed [PurchaseResult], or null if the user cancelled the sheet (the
  /// pending purchase is left for the server janitor to void).
  ///
  /// Fulfilment is belt-and-braces: the optimistic confirmPurchase below makes
  /// the success screen instant, and the Stripe webhook is the authoritative
  /// backstop that mints the pass even if this call never lands.
  Future<PurchaseResult?> _payWithSheet(
    ApiClient api,
    PaymentConfig cfg,
    String? discountCode,
  ) async {
    final pending = await api.createCardPurchaseIntent(
      productId: widget.product.id,
      discountCode: discountCode,
    );

    // Saved cards: when the intent is attached to a Stripe Customer, fetch a
    // matching ephemeral key so the PaymentSheet lists the buyer's saved cards
    // and offers to save this one. Skipped on the dev_stub path (no customer).
    String? ephemeralKeySecret;
    if (pending.stripeCustomerId.isNotEmpty) {
      ephemeralKeySecret = await api.stripeEphemeralKey(
        apiVersion: _stripeApiVersion,
      );
    }

    stripe.Stripe.publishableKey = cfg.publishableKey;
    if (cfg.applePayEnabled) {
      stripe.Stripe.merchantIdentifier = _appleMerchantId;
    }
    await stripe.Stripe.instance.applySettings();

    await stripe.Stripe.instance.initPaymentSheet(
      paymentSheetParameters: stripe.SetupPaymentSheetParameters(
        paymentIntentClientSecret: pending.clientSecret,
        merchantDisplayName: cfg.merchantDisplayName.isEmpty
            ? 'Yoga School'
            : cfg.merchantDisplayName,
        // Attaching the customer + ephemeral key turns on the saved-cards UI
        // (list + "save this card" checkbox). allowsDelayedPaymentMethods lets
        // the sheet offer methods that confirm asynchronously.
        customerId: ephemeralKeySecret == null
            ? null
            : pending.stripeCustomerId,
        customerEphemeralKeySecret: ephemeralKeySecret,
        allowsDelayedPaymentMethods: true,
        applePay: cfg.applePayEnabled
            ? stripe.PaymentSheetApplePay(
                merchantCountryCode: cfg.merchantCountryCode,
              )
            : null,
        googlePay: cfg.googlePayEnabled
            ? stripe.PaymentSheetGooglePay(
                merchantCountryCode: cfg.merchantCountryCode,
                testEnv: cfg.isTestMode,
              )
            : null,
      ),
    );

    try {
      await stripe.Stripe.instance.presentPaymentSheet();
    } on stripe.StripeException catch (e) {
      if (e.error.code == stripe.FailureCode.Canceled) {
        return null; // user dismissed the sheet
      }
      rethrow;
    }
    return api.confirmPurchase(pending.purchaseId);
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
                style: TextStyle(color: y.muted, fontSize: 12.5, height: 1.45),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                'Not now',
                style: TextStyle(color: y.muted, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                'Buy anyway',
                style: TextStyle(color: y.primary, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _shortDate(DateTime d) {
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
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

// Card selection lives in Stripe — on web the hosted Checkout page, on native
// the PaymentSheet. Both present Apple Pay / Google Pay, the saved card, and
// "use a different card", so the sheet here is just Order Summary → discount →
// Pay. (Earlier builds had decorative wallet/saved-card mockups; they implied
// a chooser this screen never owned — removed.)
