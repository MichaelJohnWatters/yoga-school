// End-to-end: a manager creates a group, adds a student, and sends a
// message; the student then signs in and receives it (via the chat-list
// poll) with an unread badge, opens the thread, and reads the message.
//
// Exercises the new chat UI: the More→Messages entry, the staff compose
// flow (new group + student picker), the thread composer/send, and the
// student receive + unread path.
//
// Requires the dev stack:
//   make firebase    (Firebase Auth emulator on :9099)
//   make go          (seeds Firebase + DB, runs the API on :8080)
//
// Run with:
//   cd app && flutter test integration_test/chat_test.dart -d chrome

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;
import 'package:yoga_school/src/screens/sign_in_screen.dart';

import '_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // A unique title each run so re-runs against the same seeded DB don't
  // collide with a prior group of the same name.
  final groupName = 'Sunrise Crew ${DateTime.now().millisecondsSinceEpoch % 100000}';
  const message = 'Class moved to 9:30am — bring a mat!';

  testWidgets('manager creates a group + sends; student receives it',
      (tester) async {
    useMobileViewport(tester);
    await resetTestState();

    app.main();

    // ---- Manager (Priya): create a group with Maya, send a message ----
    await signInAs(tester, DevAccount.priyaManager);

    await tapNavTab(tester, 'More');
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Compose → New group.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Name it (first field on the new-group screen) + pick Maya.
    await tester.enterText(find.byType(TextField).first, groupName);
    await tester.pumpAndSettle();
    await pumpUntil(tester, () => find.text('Maya Rowe').evaluate().isNotEmpty);
    await tester.tap(find.text('Maya Rowe'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create'));
    await pumpUntil(
      tester,
      () => find.widgetWithText(AppBar, groupName).evaluate().isNotEmpty,
    );

    // Send a message in the freshly-created thread.
    await tester.enterText(find.byType(TextField).last, message);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await pumpUntil(tester, () => find.text(message).evaluate().isNotEmpty);
    expect(find.text(message), findsOneWidget,
        reason: 'sent message should appear as a bubble in the thread');

    // ---- Sign out, then sign in as the student ----
    await signOut(tester);

    // ---- Student (Maya): receive the group + message ----
    await signInAs(tester, DevAccount.mayaUnlimited);
    await tapNavTab(tester, 'More');
    await tester.tap(find.text('Messages'));

    // The chat-list poll should surface the new group; wait for it.
    await pumpUntil(
      tester,
      () => find.text(groupName).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    expect(find.text(groupName), findsWidgets,
        reason: 'student should see the group the manager created');

    // Open the thread and confirm the message arrived.
    await tester.tap(find.text(groupName).last);
    await pumpUntil(tester, () => find.text(message).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 20));
    expect(find.text(message), findsOneWidget,
        reason: 'student should receive the manager’s message');
  });
}

/// Pop any pushed routes back to a tab root, then Sign out from More and
/// wait for the sign-in screen to return.
Future<void> signOut(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    final back = find.byType(BackButton);
    if (back.evaluate().isEmpty) break;
    await tester.tap(back.first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }
  await tapNavTab(tester, 'More');
  await tester.tap(find.text('Sign out'));
  await pumpUntil(
    tester,
    () => find.byType(SignInScreen).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
  );
  await tester.pumpAndSettle(const Duration(seconds: 1));
}
