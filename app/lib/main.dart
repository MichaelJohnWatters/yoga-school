// Yoga School entrypoint.
//
// Boot order:
//   1. Init Firebase + point at the local Auth emulator (dev only).
//   2. Watch FirebaseAuth state. Signed out → SignInScreen.
//   3. Signed in → bootstrap (studio config + /me) → ManagerShell or RootShell
//      based on the resolved server-side role.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/api/api_client.dart';
import 'src/api/api_error.dart';
import 'src/api/models.dart';
import 'src/api/web_redirect.dart';
import 'src/firebase_options.dart';
import 'src/screens/buy_screen.dart' show productsProvider;
import 'src/screens/customer_display.dart';
import 'src/screens/desktop/desktop_shell.dart';
import 'src/screens/desktop/responsive.dart';
import 'src/screens/manager/manager_shell.dart';
import 'src/screens/profile_screen.dart'
    show
        entitlementsProvider,
        purchasesProvider,
        subscriptionsProvider,
        paymentMethodsProvider,
        profileSegmentProvider,
        profileSegBookings,
        profileSegWallet;
import 'src/screens/purchase_success_screen.dart';
import 'src/screens/root_shell.dart';
import 'src/screens/sign_in_screen.dart';
import 'src/screens/splash_screen.dart';
import 'src/widgets/visible_tab.dart' show currentTabProvider;
import 'src/theme/yoga_theme.dart';
import 'src/theme/yoga_tokens.dart';
import 'src/auth/auth_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (kDebugMode) {
    // Dev: route Firebase Auth at the local emulator on :9099.
    await FirebaseAuth.instance.useAuthEmulator('localhost', 9099);
    // Dev-only diagnostic — KEEP THIS. Replaces Flutter's default red
    // ErrorWidget (which silently collapses to a small box when a build
    // throws) with an inline message that surfaces the exception text
    // right where the widget would have rendered. Without this, a null
    // cast or missing-key bug looks like an empty page + a wall of
    // "Unexpected null value" in the console — painful to track down.
    // Release builds skip this block entirely so prod sees Flutter's
    // stock ErrorWidget.
    ErrorWidget.builder = (details) => Container(
          padding: const EdgeInsets.all(12),
          color: const Color(0x33FF3333),
          alignment: Alignment.center,
          child: Text(
            'Render error: ${details.exceptionAsString()}',
            style: const TextStyle(
              color: Color(0xFFA33B2E),
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
        );
  }
  runApp(const ProviderScope(child: YogaApp()));
}

class YogaApp extends ConsumerWidget {
  const YogaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `?desk=1` flips the app into customer-display mode for the desk
    // tablet — themed by the live studio config, no normal app shell.
    final deskMode = Uri.base.queryParameters['desk'] != null;
    if (deskMode) {
      return const ProviderScope(child: CustomerDisplay());
    }
    final user = ref.watch(firebaseUserProvider);
    final boot = ref.watch(bootstrapProvider);
    final prefMode = ref.watch(themeModePrefProvider);

    // Default-while-loading uses the Warm Clay preset for both slots so
    // the splash → app transition stays calm even before bootstrap lands.
    final defaultTokens = YogaTokens.derive(
      yogaPresets['clay']!.light,
      dark: false,
    );

    YogaTokens lightTokens = defaultTokens;
    YogaTokens darkTokens = defaultTokens;
    boot.whenData((b) {
      final lightSemantic =
          YogaSemanticTokens.fromHexMap(b.studio.activeThemeTokens);
      lightTokens = YogaTokens.derive(lightSemantic, dark: false);

      // Dark slot is optional. When the manager hasn't picked one, dark
      // theme falls back to the light tokens so a "dark" user pref (or
      // system dark mode) doesn't render a broken half-themed UI.
      final darkMap = b.studio.activeDarkThemeTokens;
      if (darkMap != null) {
        final darkSemantic = YogaSemanticTokens.fromHexMap(darkMap);
        darkTokens = YogaTokens.derive(darkSemantic, dark: true);
      } else {
        darkTokens = lightTokens;
      }
    });

    final themeMode = switch (prefMode) {
      ThemeModePref.light => ThemeMode.light,
      ThemeModePref.dark => ThemeMode.dark,
      ThemeModePref.system => ThemeMode.system,
    };

    return MaterialApp(
      title: 'Studio 52',
      debugShowCheckedModeBanner: false,
      theme: buildYogaTheme(lightTokens),
      darkTheme: buildYogaTheme(darkTokens),
      themeMode: themeMode,
      home: user.when(
        data: (u) {
          if (u == null) return const SignInScreen();
          return CheckoutReturnHandler(child: _SignedInRoot(boot: boot));
        },
        loading: () => const SplashScreen(),
        error: (e, _) => const SignInScreen(),
      ),
    );
  }
}

/// Handles the return leg of the web hosted-Checkout redirect. On web boot it
/// inspects the URL for ?checkout=success|cancel (set as Stripe's return URL),
/// refreshes the wallet (the webhook is what actually mints the pass), and
/// surfaces a confirmation. A no-op on mobile / when there's no return param.
class CheckoutReturnHandler extends ConsumerStatefulWidget {
  final Widget child;
  const CheckoutReturnHandler({super.key, required this.child});

  @override
  ConsumerState<CheckoutReturnHandler> createState() =>
      _CheckoutReturnHandlerState();
}

class _CheckoutReturnHandlerState extends ConsumerState<CheckoutReturnHandler> {
  @override
  void initState() {
    super.initState();
    final qp = Uri.base.queryParameters;
    if (kIsWeb &&
        (qp.containsKey('checkout') || qp.containsKey('setup'))) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleReturn());
    }
  }

  Future<void> _handleReturn() async {
    final params = Uri.base.queryParameters;
    final outcome = params['checkout'];
    final setup = params['setup'];
    final sessionId = params['session_id'];
    final bookClass = params['book_class'];
    final productId = params['product_id'];
    clearCheckoutQuery(); // so a refresh doesn't re-fire this
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    // Add-card (setup) return — independent of the purchase flow.
    if (setup != null) {
      if (setup == 'success') {
        ref.invalidate(paymentMethodsProvider);
        messenger.showSnackBar(const SnackBar(content: Text('Card saved.')));
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('Card not added — nothing changed.')),
        );
      }
      return;
    }

    if (outcome == null) return;
    if (outcome == 'cancel') {
      messenger.showSnackBar(
        const SnackBar(content: Text('Checkout cancelled — nothing was charged.')),
      );
      return;
    }
    if (outcome != 'success') return;

    final api = ref.read(apiClientProvider);

    // 1. Optimistic confirm: mint the pass now instead of waiting on the
    //    webhook (which may not be running in dev, or may land after the
    //    browser returns). Returns the minted entitlement; the webhook stays
    //    the authoritative backstop.
    PurchaseEntitlement? entitlement;
    if (sessionId != null && sessionId.isNotEmpty) {
      try {
        entitlement = await api.confirmCheckoutSession(sessionId);
      } catch (_) {}
    }

    // 2. Refresh the wallet so the pass shows up, polling briefly in case it
    //    was the webhook (not our confirm) that minted it.
    for (var i = 0; i < 6; i++) {
      ref.invalidate(entitlementsProvider);
      ref.invalidate(purchasesProvider);
      ref.invalidate(productsProvider);
      ref.invalidate(subscriptionsProvider);
      try {
        final ents = await ref.read(entitlementsProvider.future);
        if (ents.any((e) => e.isActive)) break;
      } catch (_) {}
      if (entitlement != null) break;
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;

    // 3. "Buy pass and book" flow: auto-book the class the student set out to
    //    book, then land them back on the Book tab (behind the success page).
    var booked = false;
    if (bookClass != null && bookClass.isNotEmpty) {
      try {
        var entId = entitlement?.id;
        if (entId == null) {
          final eligible = await api.eligibleEntitlements(bookClass);
          if (eligible.isNotEmpty) entId = eligible.first.id;
        }
        if (entId != null) {
          await api.createBooking(classId: bookClass, entitlementId: entId);
          booked = true;
        }
      } catch (_) {
        // Best effort — the pass still landed; the student can book manually.
      }
      // Return to the Book flow (both shells honour currentTabProvider).
      ref.read(currentTabProvider.notifier).set(1);
    }
    if (!mounted) return;

    // 4. Full-screen success page — the same one the mobile PaymentSheet flow
    //    shows. Needs the product + minted entitlement; falls back to a
    //    snackbar if either is missing (e.g. the webhook hasn't landed yet).
    if (entitlement != null && productId != null && productId.isNotEmpty) {
      try {
        final product = await api.getProduct(productId);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => PurchaseSuccessScreen(
            product: product,
            entitlement: entitlement!,
            autoBooked: booked,
            onGoToBookings: () {
              ref.read(currentTabProvider.notifier).set(3); // Profile
              ref.read(profileSegmentProvider.notifier).set(profileSegBookings);
            },
            onGoToWallet: () {
              ref.read(currentTabProvider.notifier).set(3);
              ref.read(profileSegmentProvider.notifier).set(profileSegWallet);
            },
          ),
        ));
        return;
      } catch (_) {
        // Fall through to the snackbar.
      }
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(booked
            ? "You're booked — see you in class!"
            : 'Payment received — your pass is ready.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SignedInRoot extends ConsumerWidget {
  final AsyncValue<Bootstrap> boot;
  const _SignedInRoot({required this.boot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return boot.when(
      data: (b) {
        // Staff (instructor) and manager both land in the ManagerShell —
        // the shell's sidebar filter hides tier-C sections for instructors.
        if (b.me.isStaff) {
          return ManagerShell(me: b.me, studio: b.studio);
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= kDesktopBreakpoint) {
              return DesktopShell(me: b.me, studio: b.studio);
            }
            return RootShell(me: b.me, studio: b.studio);
          },
        );
      },
      loading: () => const SplashScreen(),
      error: (e, _) => Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Can't reach the studio",
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    ApiError.fromAny(e).message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () =>
                        ref.read(authServiceProvider).signOut(),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
