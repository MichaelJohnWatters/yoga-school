// Past-class gating: rows whose class has ended should be visually
// muted and not open the booking sheet on tap. This is the UI half of
// the server-side `class_already_started` gate — the server refuses
// CreateBooking/CancelBooking but the client also blocks the interaction
// pre-emptively so the user never sees a doomed request.
//
// Today is Sunday so this week's Mon-Sat seed classes are all past — we
// pick the latest one (Saturday's Vinyasa) and verify tapping it doesn't
// surface a Book or Cancel control.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

const String _pastClassId = 'cls_wk0_14'; // Saturday Vinyasa (this week, past)

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('past class row is non-interactive — tap does not open the sheet',
      (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.mayaUnlimited);

    await tapNavTab(tester, 'Book');

    // The default selected day is today (Sunday) — empty. Tap Saturday's
    // day chip to surface this week's last day, where the target class is.
    // Day chips render the day-of-month as text inside the strip.
    final saturday = find.text('20').last;
    if (saturday.evaluate().isNotEmpty) {
      await tester.tap(saturday);
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }

    final rowKey = Key('class-row-$_pastClassId');
    await pumpUntil(tester, () => find.byKey(rowKey).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(find.byKey(rowKey), findsOneWidget,
        reason: 'past Saturday Vinyasa should render in the day list');

    // Tap the row — the gate is implemented as onTap: null when the
    // class has ended, so this should be a no-op.
    await tester.tap(find.byKey(rowKey), warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // No booking sheet → none of its action buttons exist.
    expect(find.byKey(const Key('booking-book-button')), findsNothing,
        reason: 'past class should not surface a Book button');
    expect(find.byKey(const Key('booking-cancel-button')), findsNothing,
        reason: 'past class should not surface a Cancel button');
    expect(find.byKey(const Key('booking-join-waitlist-button')), findsNothing,
        reason: 'past class should not surface a Join waitlist button');
    expect(find.byKey(const Key('booking-buy-and-book-button')), findsNothing,
        reason: 'past class should not surface a Buy-pass-and-book button');
  });
}
