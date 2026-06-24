// Customer-facing desk display — themed by the studio's active theme.
// Activated via the URL flag `?desk=1`. Runs as a top-level widget instead
// of the normal RootShell/ManagerShell.
//
// Demo behavior: the display loops Paying → Approved → Idle → Paying… every
// few seconds so the screen stays visually alive for product walkthroughs.
// Real-world wiring would subscribe to the Terminal SDK or a server-driven
// active-sale stream; the visuals stay the same.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../theme/yoga_theme.dart';
import '../theme/yoga_tokens.dart';
import '../widgets/yoga_primitives.dart';

enum _DeskPhase { idle, paying, approved }

class CustomerDisplay extends ConsumerStatefulWidget {
  const CustomerDisplay({super.key});

  @override
  ConsumerState<CustomerDisplay> createState() => _CustomerDisplayState();
}

class _CustomerDisplayState extends ConsumerState<CustomerDisplay> {
  _DeskPhase _phase = _DeskPhase.idle;
  Timer? _timer;
  final String _orderName = '5-Class Pack';
  final String _orderTerms = '5 credits · valid 90 days';
  final String _orderAmount = '£60';
  final String _customerName = 'Maya';

  @override
  void initState() {
    super.initState();
    _scheduleNext();
  }

  void _scheduleNext() {
    _timer?.cancel();
    final delay = switch (_phase) {
      _DeskPhase.idle => const Duration(seconds: 3),
      _DeskPhase.paying => const Duration(seconds: 5),
      _DeskPhase.approved => const Duration(seconds: 4),
    };
    _timer = Timer(delay, () {
      setState(() {
        _phase = switch (_phase) {
          _DeskPhase.idle => _DeskPhase.paying,
          _DeskPhase.paying => _DeskPhase.approved,
          _DeskPhase.approved => _DeskPhase.idle,
        };
      });
      _scheduleNext();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(bootstrapProvider);
    // Use studio's active theme tokens; fall back to default if not ready.
    final tokens = boot.maybeWhen(
      data: (b) => YogaTokens.derive(
        YogaSemanticTokens.fromHexMap(b.studio.activeThemeTokens),
        dark: b.studio.activeThemeMode == 'dark',
      ),
      orElse: () => YogaTokens.derive(yogaPresets['clay']!.light, dark: false),
    );
    final splashImage = boot.maybeWhen(
      data: (b) => b.studio.activeThemeSplashImage,
      orElse: () => null,
    );
    return MaterialApp(
      title: 'Studio 52 · Desk',
      debugShowCheckedModeBanner: false,
      theme: buildYogaTheme(tokens),
      home: Scaffold(
        backgroundColor: tokens.background,
        body: SafeArea(
          child: _Shell(
            studioName: boot.maybeWhen(
              data: (b) => b.studio.name,
              orElse: () => 'Studio 52',
            ),
            phase: _phase,
            orderName: _orderName,
            orderTerms: _orderTerms,
            orderAmount: _orderAmount,
            customerName: _customerName,
            splashImageUrl: splashImage,
          ),
        ),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  final String studioName;
  final _DeskPhase phase;
  final String orderName;
  final String orderTerms;
  final String orderAmount;
  final String customerName;
  final String? splashImageUrl;
  const _Shell({
    required this.studioName,
    required this.phase,
    required this.orderName,
    required this.orderTerms,
    required this.orderAmount,
    required this.customerName,
    required this.splashImageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Stack(
      children: [
        // Optional studio splash image fills the background in idle state.
        if (phase == _DeskPhase.idle &&
            splashImageUrl != null &&
            splashImageUrl!.isNotEmpty)
          Positioned.fill(
            child: Image(
              image: studioImageProvider(splashImageUrl!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        if (phase == _DeskPhase.idle &&
            splashImageUrl != null &&
            splashImageUrl!.isNotEmpty)
          Positioned.fill(child: Container(color: const Color(0x66000000))),
        // Top-left logo + studio name.
        Positioned(
          top: 24,
          left: 32,
          child: Row(
            children: [
              const YLogo(size: 38),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    studioName,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: y.text,
                    ),
                  ),
                  Text(
                    'DESK · PAYMENT TERMINAL',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Bottom Stripe footnote.
        Positioned(
          bottom: 24,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 14, color: y.muted),
              const SizedBox(width: 6),
              Text(
                'Payments secured by Stripe',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: y.muted,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        // Center content — driven by phase.
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            child: switch (phase) {
              _DeskPhase.idle => _IdleState(
                key: const ValueKey('idle'),
                onImage: splashImageUrl != null && splashImageUrl!.isNotEmpty,
              ),
              _DeskPhase.paying => _PayingState(
                key: const ValueKey('paying'),
                orderName: orderName,
                orderTerms: orderTerms,
                orderAmount: orderAmount,
              ),
              _DeskPhase.approved => _ApprovedState(
                key: const ValueKey('approved'),
                orderAmount: orderAmount,
                customerName: customerName,
              ),
            },
          ),
        ),
      ],
    );
  }
}

class _IdleState extends StatelessWidget {
  final bool onImage;
  const _IdleState({super.key, this.onImage = false});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          YLogo(size: 120, onImage: onImage),
          const SizedBox(height: 32),
          Text(
            'Welcome to the studio',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: onImage ? Colors.white : y.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "We'll be with you in just a moment.",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: onImage ? Colors.white.withValues(alpha: 0.85) : y.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _PayingState extends StatelessWidget {
  final String orderName;
  final String orderTerms;
  final String orderAmount;
  const _PayingState({
    super.key,
    required this.orderName,
    required this.orderTerms,
    required this.orderAmount,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 80),
      child: Row(
        children: [
          // Left: order summary.
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: y.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: y.border),
                    boxShadow: y.shadow,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'YOUR ORDER',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          color: y.muted,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        orderName,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: y.text,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        orderTerms,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: y.muted,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(height: 1, color: y.border),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Total',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: y.muted,
                            ),
                          ),
                          Text(
                            orderAmount,
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1,
                              color: y.text,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Right: tap indicator.
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      color: y.primarySoft,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.contactless, color: y.primary, size: 70),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Tap, insert or swipe',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Apple Pay · Google Pay · Visa · Mastercard',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: y.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovedState extends StatelessWidget {
  final String orderAmount;
  final String customerName;
  const _ApprovedState({
    super.key,
    required this.orderAmount,
    required this.customerName,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              color: y.primary,
              shape: BoxShape.circle,
              boxShadow: y.shadow,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.check, color: y.onPrimary, size: 64),
          ),
          const SizedBox(height: 24),
          Text(
            'Thank you, $customerName',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: y.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$orderAmount · Visa ···· 4242 · Receipt sent by email',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            decoration: BoxDecoration(
              color: y.primarySoft,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'See you in class 🙏',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: y.primaryStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
