// Booking success animation.
//
// Fire-and-forget celebratory Lottie. On a successful booking the sheet
// closes immediately and this floats the animation on the *root overlay* —
// above whatever's now on screen, pointer-transparent (the user can keep
// tapping), removing itself when the animation finishes. Nothing is awaited,
// so the booking flow never blocks on it.
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
void showBookingSuccessAnimation(BuildContext context) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _BookingSuccessOverlay(onDone: entry.remove),
  );
  overlay.insert(entry);
}

Future<LottieComposition> _load(String path) => AssetLottie(path).load();

class _BookingSuccessOverlay extends StatefulWidget {
  final VoidCallback onDone;
  const _BookingSuccessOverlay({required this.onDone});

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
    final y = context.yoga;
    Widget child;
    if (!_ready) {
      child = const SizedBox.shrink();
    } else if (_composition != null) {
      child = Lottie(
        composition: _composition,
        controller: _controller,
        fit: BoxFit.contain,
      );
    } else {
      child = Icon(Icons.check_circle, size: 96, color: y.primary);
    }
    // Pointer-transparent so the celebration never blocks interaction.
    return IgnorePointer(
      child: Center(child: SizedBox(width: 220, height: 220, child: child)),
    );
  }
}
