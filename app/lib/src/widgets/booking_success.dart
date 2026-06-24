// Booking success animation.
//
// Plays a Lottie once after a class is booked, then auto-dismisses. One of
// [_kAssets] is picked at random each booking for variety. All entries are
// plain self-contained Lottie JSON (any images embedded as data URIs) — a
// dotLottie `.lottie` is unzipped + flattened to JSON ahead of time so the
// app never has to handle the zip at runtime. Drop more `.json` files in
// assets/lottie/ and add their paths here.
//
// The asset is loaded with a try/catch, so a missing or malformed file falls
// back to a simple checkmark rather than crashing the booking flow.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:lottie/lottie.dart';

import '../theme/yoga_tokens.dart';

const _kAssets = <String>[
  'assets/lottie/booking_success.json',
  'assets/lottie/yoga.json',
];

final _rng = Random();

/// Shows the booking-success overlay and resolves when it has dismissed
/// (after the animation finishes, or a short beat for the checkmark
/// fallback). Callers typically `await` this, then close the booking sheet.
Future<void> showBookingSuccessAnimation(BuildContext context) async {
  LottieComposition? composition;
  try {
    composition = await _load(_kAssets[_rng.nextInt(_kAssets.length)]);
  } catch (_) {
    // No animation file added yet (or it failed to parse) → checkmark.
    composition = null;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0x66000000),
    builder: (_) => _BookingSuccessDialog(composition: composition),
  );
}

/// Loads a self-contained Lottie JSON asset.
Future<LottieComposition> _load(String path) async {
  final data = await rootBundle.load(path);
  return LottieComposition.fromBytes(data.buffer.asUint8List());
}

class _BookingSuccessDialog extends StatefulWidget {
  final LottieComposition? composition;
  const _BookingSuccessDialog({this.composition});

  @override
  State<_BookingSuccessDialog> createState() => _BookingSuccessDialogState();
}

class _BookingSuccessDialogState extends State<_BookingSuccessDialog>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final comp = widget.composition;
    if (comp != null) {
      _controller = AnimationController(vsync: this, duration: comp.duration)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _dismiss();
        })
        ..forward();
      // Safety net in case the controller never reports completion.
      _timer = Timer(comp.duration + const Duration(seconds: 1), _dismiss);
    } else {
      // Checkmark fallback — show briefly, then close.
      _timer = Timer(const Duration(milliseconds: 900), _dismiss);
    }
  }

  void _dismiss() {
    if (mounted) Navigator.of(context).maybePop();
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
    final comp = widget.composition;
    return Center(
      child: SizedBox(
        width: 220,
        height: 220,
        child: comp != null
            ? Lottie(
                composition: comp,
                controller: _controller,
                fit: BoxFit.contain,
              )
            : Icon(Icons.check_circle, size: 96, color: y.primary),
      ),
    );
  }
}
