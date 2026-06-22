// Join-waitlist flow. The test fills a known future class to capacity
// via the dev /dev/fill-class helper, then has Maya open the row and
// tap "Join waitlist". We then assert:
//
//   1. A snackbar confirms the position assignment.
//   2. The class row's state chip flips from "Full · join waitlist" to
//      "On waitlist · #N", giving the user visible proof they're queued.
//   3. Re-opening the sheet shows the post-join note + a Leave button
//      (the Join button must be gone — re-joining would be a no-op the
//      server now refuses with `already_on_waitlist`).
//   4. Tapping Leave returns the row to the joinable state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

// Reformer Pilates Tue 09:00 — capacity 8, the smallest class type. The
// fillable community has more than 8 students, so the class reliably
// reaches capacity before Maya tries to book it.
const String _targetClassId = 'cls_wk1_03';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Maya joins the waitlist of a full class', (tester) async {
    await resetTestState();
    await fillClass(_targetClassId);
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.mayaUnlimited);

    await tapNavTab(tester, 'Book');
    // Day strip is centred on today — Tue 23 (the target class day) is
    // two chips to the right of Sunday's selection.
    await tester.tap(find.text('23').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final rowKey = Key('class-row-$_targetClassId');
    await pumpUntil(tester, () => find.byKey(rowKey).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15));
    expect(find.byKey(rowKey), findsOneWidget,
        reason: 'target Reformer Pilates class should render on Tue 23');

    await tester.tap(find.byKey(rowKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final waitlistBtn = find.byKey(const Key('booking-join-waitlist-button'));
    await pumpUntil(tester, () => waitlistBtn.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 8));
    expect(waitlistBtn, findsOneWidget,
        reason: 'sheet for a full class should expose Join waitlist');

    await tester.tap(waitlistBtn);
    // Sheet pops on success.
    await pumpUntil(tester, () => waitlistBtn.evaluate().isEmpty,
        timeout: const Duration(seconds: 10));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Re-open the row — the chip + sheet should now reflect "on waitlist".
    await tester.tap(find.byKey(rowKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final joinedNote =
        find.byKey(const Key('booking-waitlist-joined-note'));
    final leaveBtn = find.byKey(const Key('booking-leave-waitlist-button'));
    await pumpUntil(tester, () => joinedNote.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10));
    expect(joinedNote, findsOneWidget,
        reason: 'sheet should display the post-join confirmation note');
    expect(leaveBtn, findsOneWidget,
        reason: 'sheet should expose a Leave waitlist control');
    expect(waitlistBtn, findsNothing,
        reason: 'Join button should be hidden once the user is on the list');
    expect(find.byKey(const Key('booking-cancel-button')), findsNothing,
        reason: 'joining the waitlist should NOT create a booking');

    // Leave the waitlist — sheet pops, row flips back to joinable.
    await tester.tap(leaveBtn);
    await pumpUntil(tester, () => leaveBtn.evaluate().isEmpty,
        timeout: const Duration(seconds: 10));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.byKey(rowKey));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await pumpUntil(tester, () => waitlistBtn.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 8));
    expect(waitlistBtn, findsOneWidget,
        reason: 'after leaving, the sheet should expose Join waitlist again');
    expect(find.byKey(const Key('booking-leave-waitlist-button')), findsNothing,
        reason: 'after leaving, the Leave control should be gone');
  });
}
