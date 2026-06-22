// Cancel Maya's pre-seeded booking via the booking sheet's confirm dialog.
//
// Maya has `bk_maya_upcoming` against `cls_wk1_01` (Mon 07:30 Vinyasa Flow)
// from the seed. The dev reset endpoint preserves it because the id starts
// with `bk_`. We open the row, hit Cancel, confirm in the dialog, then
// verify the server-side booking flipped to status=cancelled.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

const String _bookedClassId = 'cls_wk1_01'; // Mon next week, Vinyasa 07:30

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Maya cancels her seeded booking via the booking sheet',
      (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.mayaUnlimited);

    await tapNavTab(tester, 'Book');

    // Day strip is centred on today (Sunday) — Mon 22 is one chip to
    // the right and visible from the initial render.
    await tester.tap(find.text('22').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final rowKey = Key('class-row-$_bookedClassId');
    await pumpUntil(tester, () => find.byKey(rowKey).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(find.byKey(rowKey), findsOneWidget,
        reason: 'seeded booking class should be visible on next week\'s Monday');

    await tester.tap(find.byKey(rowKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final cancelBtn = find.byKey(const Key('booking-cancel-button'));
    await pumpUntil(tester, () => cancelBtn.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 8));
    expect(cancelBtn, findsOneWidget,
        reason: 'sheet for a booked class should expose the Cancel control');

    await tester.tap(cancelBtn);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Confirm dialog — there's a "Cancel booking" affirmative action.
    // The dialog also has a "Keep booking" button; we want the destructive
    // one. Both contain the word "booking" so we target the bold-weight
    // affirmative directly by text.
    final confirm = find.text('Cancel booking').last;
    expect(confirm, findsWidgets,
        reason: 'confirm dialog should expose a Cancel booking action');
    await tester.tap(confirm);

    // Sheet pops on success; re-open row and verify Cancel is gone.
    await pumpUntil(
        tester, () => cancelBtn.evaluate().isEmpty,
        timeout: const Duration(seconds: 15));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.byKey(rowKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final bookBtn = find.byKey(const Key('booking-book-button'));
    await pumpUntil(tester, () => bookBtn.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 8));
    expect(bookBtn, findsOneWidget,
        reason: 'after cancelling, the row should be re-bookable');
  });
}
