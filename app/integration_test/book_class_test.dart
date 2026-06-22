// Book a future class as Maya — the most basic "happy path" student flow.
//
// What we exercise:
//   1. Sign in via the dev picker
//   2. Switch to the Book tab
//   3. Page the day strip forward into next week (today is Sunday and
//      this week's classes are all past)
//   4. Tap a known future Vinyasa Flow row (cls_wk1_02 — Mon evening,
//      not the one Maya already has booked as bk_maya_upcoming)
//   5. Tap "Book this class" in the bottom sheet
//   6. Verify the sheet closes and the row reports a "Booked" chip
//
// Requires the dev stack running:
//   make firebase    (Firebase Auth emulator on :9099)
//   make go          (seeds DB + Firebase, runs API on :8080)
//   chromedriver --port=4444 (in another shell)
//
// Run with:
//   cd app && flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/book_class_test.dart \
//     -d chrome

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

const String _targetClassId = 'cls_wk1_02'; // Mon next week, Power Vinyasa 17:45

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Maya books a future class via the booking sheet',
      (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.mayaUnlimited);

    await tapNavTab(tester, 'Book');

    // The day strip is centred on today, so Monday-22 sits one chip to
    // the right of the selected (Sunday) chip and is visible from the
    // initial render. Just tap it directly.
    await tester.tap(find.text('22').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final targetKey = Key('class-row-$_targetClassId');
    await pumpUntil(tester, () => find.byKey(targetKey).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15));
    expect(find.byKey(targetKey), findsOneWidget,
        reason: 'target class $_targetClassId should render on Mon 22');

    // Tap the row → booking sheet rises from bottom.
    await tester.tap(find.byKey(targetKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Preview round-trips — wait for the book button to settle (the
    // entitlement fetch is what gates rendering).
    final bookBtn = find.byKey(const Key('booking-book-button'));
    await pumpUntil(tester, () => bookBtn.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 8));
    expect(bookBtn, findsOneWidget,
        reason: 'booking sheet should expose the Book button for an eligible class');

    await tester.tap(bookBtn);

    // Booking sheet pops on success; the row's chip flips to "Booked".
    await pumpUntil(
        tester, () => bookBtn.evaluate().isEmpty,
        timeout: const Duration(seconds: 15));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Re-open the row to confirm the server's view changed — the cancel
    // button only appears for a booking that exists.
    await tester.tap(find.byKey(targetKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await pumpUntil(
        tester,
        () => find
            .byKey(const Key('booking-cancel-button'))
            .evaluate()
            .isNotEmpty,
        timeout: const Duration(seconds: 8));
    expect(find.byKey(const Key('booking-cancel-button')), findsOneWidget,
        reason: 'after booking the same class should expose a Cancel control');
  });
}
