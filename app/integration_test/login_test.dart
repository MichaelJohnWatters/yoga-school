// Smoke test: dev-login as Maya (student) and wait for the signed-in shell.
//
// Requires the dev stack to be running:
//   make firebase    (Firebase Auth emulator on :9099)
//   make go          (seeds Firebase + DB, runs the API on :8080)
//
// Run with:
//   cd app && flutter test integration_test/login_test.dart -d chrome

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;
import 'package:yoga_school/src/screens/sign_in_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dev-login as Maya lands on the signed-in shell',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.byType(SignInScreen), findsOneWidget,
        reason: 'cold boot should land on the sign-in screen');

    final picker = find.text('Pick a test user…');
    expect(picker, findsOneWidget,
        reason: 'dev picker should be visible in debug builds');
    await tester.tap(picker);
    await tester.pumpAndSettle();

    final maya = find.text('Maya · unlimited (basic student)');
    expect(maya, findsOneWidget);
    await tester.tap(maya);
    await tester.pumpAndSettle();

    final signIn = find.text('Sign in');
    expect(signIn, findsOneWidget);
    await tester.tap(signIn);

    // Firebase round-trip + /me bootstrap — poll until the sign-in screen
    // is gone, then let the destination shell settle.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(SignInScreen).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.byType(SignInScreen), findsNothing,
        reason: 'sign-in screen should be torn down after a successful login');
  });
}
