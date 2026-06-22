// Smoke test: create a brand-new account via the sign-in screen's signup mode
// and confirm the app lands on the signed-in shell.
//
// The signup UI only mints students — the server auto-provisions a student
// row from the ID token's `name` claim (see app/lib/src/auth/auth_state.dart).
// Managers don't have a UI signup path; they're seeded server-side or created
// via the admin/staff API.
//
// Requires the dev stack to be running:
//   make firebase    (Firebase Auth emulator on :9099)
//   make go          (seeds Firebase + DB, runs the API on :8080)
//
// Run with:
//   cd app && flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/create_account_test.dart \
//     -d chrome

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;
import 'package:yoga_school/src/screens/sign_in_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('signup mode creates a student and lands on the shell',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.byType(SignInScreen), findsOneWidget,
        reason: 'cold boot should land on the sign-in screen');

    // Switch into signup mode via the keyed toggle GestureDetector.
    await tester.tap(find.byKey(const Key('auth-toggle-mode')));
    await tester.pumpAndSettle();

    expect(find.text('Create your account'), findsOneWidget,
        reason: 'header should switch to the signup variant');

    // Fresh email per run — the Auth emulator persists state until you
    // restart it, so reusing a fixed email would trip `email-already-in-use`.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final email = 'newuser-$stamp@studio52.dev';
    const password = 'dev123456';
    final fullName = 'Test User $stamp';

    // Three TextFields in this order: full name, email, password.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), fullName);
    await tester.enterText(fields.at(1), email);
    await tester.enterText(fields.at(2), password);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create account'));

    // Poll the sign-in screen out. We drain takeException() between frames
    // to swallow Flutter web engine quirks unrelated to the app under test:
    //   * `setSelectionRange` on <input type="email"> (Chrome forbids it),
    //   * `_dirtyFields == 0` asserts in the web semantics layer.
    // Both fire during programmatic text entry into keyboardType-tagged
    // fields and aren't bugs we can fix from app code.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      while (tester.takeException() != null) {}
      if (find.byType(SignInScreen).evaluate().isEmpty) break;
    }

    expect(find.byType(SignInScreen), findsNothing,
        reason: 'sign-in screen should be torn down after a successful signup');
  });
}
