// Notification preferences round-trip: flip the Booking confirmations
// switch off, leave the screen and come back, and verify the toggle
// reads the new server state.
//
// The screen calls PATCH /me/notifications and invalidates its provider;
// re-opening the screen re-fetches, so a stale local cache wouldn't
// produce the assertion's truth.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Maya toggles a notification pref and the change persists',
      (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.mayaUnlimited);

    await tapNavTab(tester, 'More');
    await tester.tap(find.text('Notification settings'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final toggleKey = const Key('notif-toggle-booking_confirmed');
    await pumpUntil(
      tester,
      () => find.byKey(toggleKey).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    expect(find.byKey(toggleKey), findsOneWidget);

    // Find the Switch inside this toggle row to read its current value.
    final switchInRow = find.descendant(
      of: find.byKey(toggleKey),
      matching: find.byType(Switch),
    );
    final firstSwitch = tester.widget<Switch>(switchInRow);
    final originalValue = firstSwitch.value;

    // Tap it — the row's GestureDetector forwards to the Switch.
    await tester.tap(switchInRow);
    // PATCH round-trip needs more than one pump.
    await pumpUntil(
      tester,
      () {
        final widgets = switchInRow.evaluate();
        if (widgets.isEmpty) return false;
        final s = widgets.single.widget as Switch;
        return s.value != originalValue;
      },
      timeout: const Duration(seconds: 10),
    );
    final afterTap = tester.widget<Switch>(switchInRow);
    expect(afterTap.value, isNot(equals(originalValue)),
        reason: 'tapping the toggle should flip the switch in-place');

    // Leave the screen and come back — provider invalidation forces a
    // fresh GET, so a flipped value here proves server-side persistence.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('Notification settings'));
    await pumpUntil(
      tester,
      () => find.byKey(toggleKey).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    final fromServer = tester.widget<Switch>(switchInRow);
    expect(fromServer.value, isNot(equals(originalValue)),
        reason: 'after re-opening the screen, the new value should still apply');
  });
}
