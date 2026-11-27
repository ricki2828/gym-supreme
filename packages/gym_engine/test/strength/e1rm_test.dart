import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

void main() {
  group('e1rm', () {
    // Golden vectors, grams, Epley w x (1 + r/30).
    const golden = <(int, int, double)>[
      (100000, 1, 100000),
      (100000, 2, 106666.6666666667),
      (100000, 3, 110000),
      (100000, 5, 116666.6666666667),
      (100000, 8, 126666.6666666667),
      (100000, 10, 133333.3333333333),
      (60000, 12, 84000),
    ];
    for (final (load, reps, want) in golden) {
      test('$load g x $reps', () {
        expect(e1rm(load, reps)!.grams, closeTo(want, 1e-6));
      });
    }

    test('rough tier is 11-12 reps only; over 12 is excluded', () {
      expect(e1rm(50000, 10)!.rough, isFalse);
      expect(e1rm(50000, 11)!.rough, isTrue);
      expect(e1rm(50000, 12)!.rough, isTrue);
      expect(e1rm(50000, 13), isNull);
    });

    test('missing or non-positive inputs give no estimate', () {
      expect(e1rm(null, 5), isNull);
      expect(e1rm(50000, null), isNull);
      expect(e1rm(0, 5), isNull);
      expect(e1rm(50000, 0), isNull);
    });

    test('agrees with Brzycki: <=4% for 3-8 reps, <=3% for 7-10 reps', () {
      // The brief asked for 3% across 3-8 reps, but Epley sits 3.9% above
      // Brzycki at 3-4 reps (design-specified formula, kept). The 3% bound
      // holds from 7 reps up.
      for (var r = 3; r <= 10; r++) {
        final ratio = e1rm(100000, r)!.grams / brzyckiG(100000, r)!;
        expect(
          (ratio - 1).abs(),
          lessThanOrEqualTo(r <= 6 ? 0.04 : 0.03),
          reason: 'reps $r ratio $ratio',
        );
      }
    });

    test('brzycki out of range is null', () {
      expect(brzyckiG(100000, 13), isNull);
      expect(brzyckiG(0, 5), isNull);
    });
  });
}
