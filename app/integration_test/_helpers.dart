// Shared helpers for integration tests. Keeping the boilerplate in one
// place means a per-test file is mostly the "actually exercise the flow"
// part, not Firebase round-tripping.

import 'dart:ui' show Size;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yoga_school/src/screens/root_shell.dart';
import 'package:yoga_school/src/screens/sign_in_screen.dart';

/// Wipe non-seed bookings/purchases/etc. via the dev reset endpoint so each
/// test starts from the same baseline. The endpoint is gated server-side
/// by FIREBASE_AUTH_EMULATOR_HOST presence; it 404s in prod-shaped
/// configurations. Safe to call before the app is even running — we hit
/// the API directly.
Future<void> resetTestState({String baseUrl = 'http://localhost:8080'}) async {
  try {
    await Dio().post('$baseUrl/dev/reset-test-state');
  } catch (e) {
    // Surface as a test failure rather than silently letting stale state
    // pollute the next assertion.
    throw StateError(
        'dev reset failed — is the server running with the auth emulator? $e');
  }
}

/// Book community-seed students into [classId] until the class hits
/// capacity. Used by tests that need the under-test student to land on
/// a full class without going through 16+ sign-in flows.
Future<void> fillClass(String classId,
    {String studioId = 's52',
    String baseUrl = 'http://localhost:8080'}) async {
  try {
    await Dio().post(
      '$baseUrl/dev/fill-class',
      data: {'studio_id': studioId, 'class_id': classId},
    );
  } catch (e) {
    throw StateError('dev fill-class failed for $classId: $e');
  }
}

/// Force the view into mobile-shell territory (< 900px wide, see
/// kDesktopBreakpoint) so every test exercises the same RootShell + bottom
/// nav regardless of the browser window. Call before pumping `app.main()`.
void useMobileViewport(WidgetTester tester) {
  final view = tester.view;
  view.physicalSize = const Size(414 * 2.0, 896 * 2.0);
  view.devicePixelRatio = 2.0;
  addTearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });
}

/// Pumps until [check] returns true or [timeout] elapses. Drains caught
/// exceptions between frames because Flutter's web HTML/CanvasKit shims
/// raise harmless asserts during programmatic text entry (`setSelectionRange`,
/// `_dirtyFields == 0`) that we don't want to fail tests on.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() check, {
  Duration timeout = const Duration(seconds: 30),
  Duration interval = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(interval);
    while (tester.takeException() != null) {}
    if (check()) return;
  }
  while (tester.takeException() != null) {}
}

/// Sign in via the dev picker. [accountLabel] must match the exact label
/// in the picker (e.g. `Maya · unlimited (basic student)`). Returns once
/// the sign-in screen is torn down or the timeout elapses.
Future<void> signInAs(
  WidgetTester tester,
  String accountLabel, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  await tester.pumpAndSettle(const Duration(seconds: 3));
  expect(find.byType(SignInScreen), findsOneWidget,
      reason: 'cold boot should land on the sign-in screen');

  await tester.tap(find.text('Pick a test user…'));
  await tester.pumpAndSettle();

  await tester.tap(find.text(accountLabel));
  await tester.pumpAndSettle();

  await tester.tap(find.text('Sign in'));

  await pumpUntil(
    tester,
    () => find.byType(SignInScreen).evaluate().isEmpty,
    timeout: timeout,
  );
  await tester.pumpAndSettle(const Duration(seconds: 2));
  expect(find.byType(SignInScreen), findsNothing,
      reason: 'sign-in screen should be torn down after a successful login');
  expect(find.byType(RootShell), findsOneWidget,
      reason: 'student should land on the RootShell after sign-in');
}

/// Tap a bottom-nav tab by its label. The labels are: Home, Book, Buy,
/// Profile, More.
Future<void> tapNavTab(WidgetTester tester, String label) async {
  // Tabs are wrapped in Expanded(InkWell(...)) — tapping the text works.
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

/// Common dev-account labels — keep this in sync with sign_in_screen.dart's
/// `_devAccounts` list so a label drift only requires editing one place.
class DevAccount {
  static const priyaManager = 'Priya · manager';
  static const mayaUnlimited = 'Maya · unlimited (basic student)';
  static const ariaMultiPass = 'Aria · 10-pack + new unlimited';
  static const benUnlimited = 'Ben · unlimited + reformer pack';
  static const chenReformer = 'Chen · reformer-only (2/5 credits)';
  static const diegoNoCredits = 'Diego · no credits left';
  static const graceFivePack = 'Grace · yoga 5-pack (4/5)';
  static const ivyTenPack = 'Ivy · 10-pack + reformer pack';
  static const kiraTenPack = 'Kira · current + depleted history';
}
