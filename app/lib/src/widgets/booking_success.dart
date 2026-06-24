// Booking success animation.
//
// Fire-and-forget celebratory Lottie. On a successful booking the sheet
// closes immediately and this floats a "You're booked!" card on the *root
// overlay* — over a very slight scrim that draws the eye, pointer-transparent
// (the user can keep tapping), removing itself when the animation finishes.
// Nothing is awaited, so the booking flow never blocks on it.
//
// One of [_kAssets] is picked at random for variety. Loaded via AssetLottie
// so an image-based animation resolves its frames from sibling assets
// (lottie 3.x doesn't decode base64-embedded images) — e.g. yoga.json
// references PNGs in assets/lottie/yoga_assets/. A missing/unparseable file
// falls back to a brief checkmark rather than crashing.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../theme/yoga_tokens.dart';

const _kAssets = <String>[
  'assets/lottie/booking_success.json',
  'assets/lottie/yoga.json',
];

final _rng = Random();

/// Plays the booking-success animation as a non-blocking overlay. Grab the
/// overlay from [context] *before* popping the booking sheet — the entry
/// lives on the root overlay, so it survives the sheet closing.
///
/// Theme values are read here, from the themed [context], and passed in: the
/// root overlay sits outside the app's themed subtree, so reading the
/// YogaTokens extension from inside the overlay would throw.
void showBookingSuccessAnimation(BuildContext context) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final y = context.yoga;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _BookingSuccessOverlay(
      onDone: entry.remove,
      surfaceColor: y.surface,
      textColor: y.text,
      accentColor: y.primary,
    ),
  );
  overlay.insert(entry);
}

Future<LottieComposition> _load(String path) => AssetLottie(path).load();

class _BookingSuccessOverlay extends StatefulWidget {
  final VoidCallback onDone;
  final Color surfaceColor;
  final Color textColor;
  final Color accentColor;
  const _BookingSuccessOverlay({
    required this.onDone,
    required this.surfaceColor,
    required this.textColor,
    required this.accentColor,
  });

  @override
  State<_BookingSuccessOverlay> createState() => _BookingSuccessOverlayState();
}

class _BookingSuccessOverlayState extends State<_BookingSuccessOverlay>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  LottieComposition? _composition;
  bool _ready = false;
  bool _done = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    LottieComposition? comp;
    try {
      comp = await _load(_kAssets[_rng.nextInt(_kAssets.length)]);
    } catch (_) {
      comp = null;
    }
    if (!mounted) return;
    if (comp != null) {
      _composition = comp;
      _controller = AnimationController(vsync: this, duration: comp.duration)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _finish();
        })
        ..forward();
      // Safety net in case completion is never reported.
      _timer = Timer(comp.duration + const Duration(seconds: 1), _finish);
    } else {
      // Checkmark fallback — show briefly, then remove.
      _timer = Timer(const Duration(milliseconds: 900), _finish);
    }
    setState(() => _ready = true);
  }

  void _finish() {
    if (_done) return;
    _done = true;
    widget.onDone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hold the frame until the composition is ready so the card doesn't flash
    // empty (bundled assets load near-instantly).
    if (!_ready) return const SizedBox.shrink();

    final art = _composition != null
        ? Lottie(
            composition: _composition,
            controller: _controller,
            fit: BoxFit.contain,
          )
        : Icon(Icons.check_circle, size: 88, color: widget.accentColor);

    // Pointer-transparent so the celebration never blocks interaction. A very
    // slight scrim draws the eye to the centre card; it fades in for polish.
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        builder: (_, t, child) => Opacity(opacity: t, child: child),
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0x14000000))),
            Center(
              // Translucent card — see-through rather than a solid white box,
              // but no BackdropFilter blur (not supported on Flutter web's
              // HTML renderer, where it throws every frame).
              child: Container(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
                decoration: BoxDecoration(
                  color: widget.surfaceColor.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0x14000000)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 24,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 150, height: 150, child: art),
                    const SizedBox(height: 2),
                    Text(
                      "You're booked!",
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: widget.textColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
