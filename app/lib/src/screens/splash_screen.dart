// Themed splash with logo + welcome message.
// Waits for bootstrap (GET /studio/config + GET /me) then routes to Home.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final boot = ref.watch(bootstrapProvider);
    final splashImage = boot.maybeWhen(
      data: (b) => b.studio.activeThemeSplashImage,
      orElse: () => null,
    );

    final onImage = splashImage != null && splashImage.isNotEmpty;
    final body = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          YLogo(size: 84, onImage: onImage),
          const SizedBox(height: 22),
          boot.when(
            data: (b) => Column(
              children: [
                Text(
                  b.studio.name,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: onImage ? Colors.white : y.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  b.studio.welcomeMessage,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: onImage ? Colors.white.withValues(alpha: 0.85) : y.muted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            loading: () => Column(
              children: [
                Text(
                  'Studio 52',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: y.text,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: y.primary,
                  ),
                ),
              ],
            ),
            error: (err, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  Text(
                    "Can't reach the studio",
                    style: TextStyle(
                      color: y.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$err',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: y.muted, fontSize: 12.5),
                  ),
                  const SizedBox(height: 16),
                  YButton(
                    label: 'Retry',
                    small: true,
                    onTap: () => ref.invalidate(bootstrapProvider),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: y.background,
      body: Stack(
        children: [
          if (onImage)
            Positioned.fill(
              child: Image.network(
                splashImage,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          if (onImage)
            Positioned.fill(
              child: Container(color: const Color(0x66000000)),
            ),
          SafeArea(child: body),
        ],
      ),
    );
  }
}
