// Buy a pass as Diego — seeded with no active credits, so the duplicate-
// pass dialog stays out of the way.
//
// Flow:
//   1. Sign in as Diego
//   2. Buy tab → tap the Single Class drop-in row → CheckoutSheet
//   3. Tap "Pay £16" (dev stub flips status=completed and mints
//      a new entitlement)
//   4. PurchaseSuccessScreen pushes — pop back via "Done"
//   5. Profile → Overview → assert "Single Class" pass appears under
//      Active passes

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Diego buys a drop-in pass and it lands in his wallet',
      (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.diegoNoCredits);

    await tapNavTab(tester, 'Buy');

    // Open the checkout sheet for the Single Class drop-in.
    final dropInRow = find.byKey(const Key('product-row-prod_drop'));
    await pumpUntil(tester, () => dropInRow.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(dropInRow, findsOneWidget,
        reason: 'Buy tab should list the seeded Single Class drop-in row');
    await tester.tap(dropInRow);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final payBtn = find.byKey(const Key('checkout-pay-button'));
    expect(payBtn, findsOneWidget,
        reason: 'CheckoutSheet should expose a Pay button');
    await tester.tap(payBtn);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Diego is seeded with an active Beginners' Course enrollment, which
    // triggers the "you already have an active pass" confirmation dialog.
    // Dismiss it via "Buy anyway" to proceed with the test purchase.
    if (find.text('Buy anyway').evaluate().isNotEmpty) {
      await tester.tap(find.text('Buy anyway'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    // Server completes synchronously via dev_stub, then pushes the
    // PurchaseSuccessScreen. We assert the headline first (proves the
    // route pushed) then dismiss via the primary YButton.
    await pumpUntil(
        tester, () => find.text("You're all set").evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15));
    expect(find.text("You're all set"), findsOneWidget,
        reason: 'success screen should render its "You\'re all set" headline');
    await tester.tap(find.text('Book your first class'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Profile → wallet check.
    await tapNavTab(tester, 'Profile');
    await pumpUntil(
      tester,
      () => find.text('Single Class').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    expect(find.text('Single Class'), findsWidgets,
        reason: 'newly-bought Single Class pass should show in Active passes');
  });
}
