// Web hosted-Checkout e2e (the client→server→real-Stripe half).
//
// A Flutter integration test can't drive Stripe's hosted page, so this proves
// everything UP TO the redirect: tapping Pay on web creates a REAL Stripe
// Checkout Session (using the studio's test keys) and hands the app a
// checkout.stripe.com URL. The redirect itself is captured via the test seam
// instead of navigating the browser away. The payment-completion + fulfilment
// half is covered by the Go test TestStripeRealAPI_E2E.
//
// Prereqs:
//   make firebase                      (auth emulator)
//   STRIPE_KEY_ENC_MASTER=<hex32> make go   (API on :8080 with encryption on)
//   chromedriver --port=4444 &
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/checkout_session_test.dart \
//     -d web-server --browser-name=chrome \
//     --dart-define=STRIPE_TEST_SK=sk_test_… \
//     --dart-define=STRIPE_TEST_PK=pk_test_…
//
// (Web integration tests need `flutter drive` + chromedriver — `flutter test
// -d chrome` reports "web devices are not supported".) With the --dart-define
// keys it exercises real Stripe; without them it skips.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;
import 'package:yoga_school/src/api/web_redirect.dart' as redirect;

import '_helpers.dart';

const _sk = String.fromEnvironment('STRIPE_TEST_SK');
const _pk = String.fromEnvironment('STRIPE_TEST_PK');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('web checkout creates a real Stripe Checkout session',
      (tester) async {
    // Skip (don't fail) when keys aren't supplied — this target is only run
    // deliberately (flutter drive / the Tilt e2e resource), so a missing key
    // means "not set up for the live e2e here", not a broken test.
    if (_sk.isEmpty || _pk.isEmpty) {
      markTestSkipped(
        'No STRIPE_TEST_SK / STRIPE_TEST_PK (--dart-define, or the Tilt '
        'yoga-e2e-stripe-flutter resource supplies them from .env) — skipping.',
      );
      return;
    }

    await resetTestState();
    await configureStripeKeys(secretKey: _sk, publishableKey: _pk);

    // Capture the Checkout URL instead of navigating the browser to Stripe.
    String? capturedUrl;
    redirect.debugCheckoutRedirectOverride = (url) => capturedUrl = url;
    addTearDown(() => redirect.debugCheckoutRedirectOverride = null);

    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.diegoNoCredits);

    await tapNavTab(tester, 'Buy');
    final dropInRow = find.byKey(const Key('product-row-prod_drop'));
    await pumpUntil(tester, () => dropInRow.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(dropInRow, findsOneWidget,
        reason: 'Buy tab should list the seeded Single Class drop-in');
    await tester.tap(dropInRow);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byKey(const Key('checkout-pay-button')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Diego has an active enrollment → the "you already have a pass" dialog.
    if (find.text('Buy anyway').evaluate().isNotEmpty) {
      await tester.tap(find.text('Buy anyway'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    // The web branch calls POST /checkout/session (real Stripe) and hands the
    // resulting hosted-page URL to our redirect seam.
    await pumpUntil(tester, () => capturedUrl != null,
        timeout: const Duration(seconds: 20));
    expect(capturedUrl, isNotNull,
        reason: 'tapping Pay on web should create a Stripe Checkout session');
    expect(capturedUrl, contains('checkout.stripe.com'),
        reason: 'the redirect target should be a real Stripe hosted Checkout page');
  });
}
