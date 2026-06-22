// Buy-pass-and-book flow as Diego. Diego's only active entitlement is the
// Beginners' Course (covers ct_beg_s26 only), so opening a Power Vinyasa
// class drops him into the `_eligibleEmpty` branch with a "Buy pass and
// book" CTA instead of the regular Book button. Tapping it routes through
// BuyScreen → CheckoutSheet, then auto-books the originally-tapped class
// before showing the success screen.
//
// We assert two things at the end:
//  1. The success screen renders the "You're booked" headline (proves the
//     auto-book completed, not just the purchase).
//  2. Re-opening the same class row exposes the Cancel button (proves the
//     server holds the booking, not just the in-memory ref).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

const String _targetClassId = 'cls_wk1_02'; // Mon next week, Power Vinyasa 17:45

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Diego buys a pass and the class auto-books',
      (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.diegoNoCredits);

    await tapNavTab(tester, 'Book');
    // Centred day strip — Mon 22 is visible from today.
    await tester.tap(find.text('22').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final rowKey = Key('class-row-$_targetClassId');
    await pumpUntil(tester, () => find.byKey(rowKey).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(find.byKey(rowKey), findsOneWidget);

    await tester.tap(find.byKey(rowKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final buyBtn = find.byKey(const Key('booking-buy-and-book-button'));
    await pumpUntil(tester, () => buyBtn.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(buyBtn, findsOneWidget,
        reason: 'Diego has no eligible pass → sheet should expose '
            '"Buy pass and book" instead of the regular Book control');
    await tester.tap(buyBtn);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // BuyScreen is now in coversClassTypeId mode — only yoga-eligible
    // products show. The drop-in row is reliably first in the packs list.
    final dropInRow = find.byKey(const Key('product-row-prod_drop'));
    await pumpUntil(tester, () => dropInRow.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(dropInRow, findsOneWidget,
        reason: 'Buy screen (filtered) should still surface the Single Class drop-in');
    await tester.tap(dropInRow);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byKey(const Key('checkout-pay-button')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Dismiss "you already have an active pass" — Diego's Beginners
    // enrollment is active and trips the duplicate dialog.
    if (find.text('Buy anyway').evaluate().isNotEmpty) {
      await tester.tap(find.text('Buy anyway'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    // autoBooked=true → headline reads "You're booked" and the primary
    // button is "Done".
    await pumpUntil(
        tester, () => find.text("You're booked").evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15));
    expect(find.text("You're booked"), findsOneWidget,
        reason: 'auto-book should land on the "You\'re booked" success variant');
    await tester.tap(find.text('Done').first);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Confirm server-side: the row now shows Cancel, not Book/Buy.
    // We're back in the Book tab (pushReplacement makes Done land here).
    await pumpUntil(tester, () => find.byKey(rowKey).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    await tester.tap(find.byKey(rowKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final cancelBtn = find.byKey(const Key('booking-cancel-button'));
    await pumpUntil(tester, () => cancelBtn.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(cancelBtn, findsOneWidget,
        reason: 'class should now be Booked on the server — sheet shows Cancel');
  });
}
