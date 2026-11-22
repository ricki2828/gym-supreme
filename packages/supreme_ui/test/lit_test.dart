import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supreme_ui/supreme_ui.dart';

/// Euclidean RGB distance, 0-441.
double _distance(Color a, Color b) {
  final dr = (a.r - b.r) * 255, dg = (a.g - b.g) * 255, db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

void main() {
  test('PB cyan is reserved: every session type sits well away from it', () {
    for (final c in Lit.sessionTypes) {
      expect(
        _distance(c, Lit.pb),
        greaterThan(90),
        reason: '$c too close to PB cyan',
      );
    }
  });

  test('session type colours are distinct from each other', () {
    final types = Lit.sessionTypes;
    for (var i = 0; i < types.length; i++) {
      for (var j = i + 1; j < types.length; j++) {
        expect(_distance(types[i], types[j]), greaterThan(90));
      }
    }
  });

  test('ink on the LIT ground reads at 7:1 or better', () {
    final ratio =
        (Lit.ground.computeLuminance() + 0.05) /
        (Lit.ink.computeLuminance() + 0.05);
    expect(ratio, greaterThan(7));
  });

  test('the copied theme builds in both brightnesses', () {
    expect(runSoloTheme().brightness, Brightness.light);
    expect(
      runSoloTheme(brightness: Brightness.dark).brightness,
      Brightness.dark,
    );
  });
}
