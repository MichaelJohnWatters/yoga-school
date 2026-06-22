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
import 'src/firebase_options.dart';
import 'src/screens/customer_display.dart';
import 'src/screens/desktop/desktop_shell.dart';
import 'src/screens/desktop/responsive.dart';
import 'src/screens/manager/manager_shell.dart';
import 'src/screens/root_shell.dart';
import 'src/screens/sign_in_screen.dart';
import 'src/screens/splash_screen.dart';
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
          return _SignedInRoot(boot: boot);
        },
        loading: () => const SplashScreen(),
        error: (e, _) => const SignInScreen(),
      ),
    );
  }
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
