// Profile → Active passes should list each entitlement by label. Maya's
// seed gives her "Unlimited Monthly"; the test signs in, opens Profile, and
// asserts the label is present in the Overview tab's wallet section.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yoga_school/main.dart' as app;

import '_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Maya\'s Profile lists her Unlimited Monthly pass', (tester) async {
    await resetTestState();
    useMobileViewport(tester);
    app.main();
    await signInAs(tester, DevAccount.mayaUnlimited);

    await tapNavTab(tester, 'Profile');

    await pumpUntil(
      tester,
      () => find.text('Unlimited Monthly').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    expect(find.text('Unlimited Monthly'), findsWidgets,
        reason: 'Active passes section should show Maya\'s Unlimited Monthly entitlement');
    expect(find.text('Active passes'), findsOneWidget,
        reason: 'Overview body should render its Active passes section head');
  });
}
