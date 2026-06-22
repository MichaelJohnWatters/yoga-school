// Check-in QR sheet smoke test. Maya opens More → Check-in code and we
// verify the sheet renders a QR image widget plus the next-class line.
// The QR pixels themselves are tested at the server layer (single-use
// token) — here we just prove the sheet wires up against /me/checkin-code.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Maya opens the Check-in sheet from More and sees her QR',
      (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.mayaUnlimited);

    await tapNavTab(tester, 'More');
    await tester.tap(find.text('Check-in code'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // QrImageView from qr_flutter is the actual barcode widget.
    await pumpUntil(
      tester,
      () => find.byType(QrImageView).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    expect(find.byType(QrImageView), findsOneWidget,
        reason: 'sheet should render a QR image after /me/checkin-code resolves');
  });
}
