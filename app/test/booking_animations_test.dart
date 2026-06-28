import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';

// Verifies the bundled booking animations parse into real Lottie
// compositions (not just valid JSON) — non-empty duration and frame range.
void main() {
  for (final name in const ['booking_success.json', 'yoga.json']) {
    test('$name is a valid Lottie composition', () async {
      final bytes = File('assets/lottie/$name').readAsBytesSync();
      final comp = await LottieComposition.fromBytes(bytes);
      expect(comp.duration.inMilliseconds, greaterThan(0),
          reason: '$name should have a non-zero duration');
      expect(comp.endFrame, greaterThan(comp.startFrame),
          reason: '$name should have a real frame range');
    });
  }
}
