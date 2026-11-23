import 'package:gym_engine/src/cut2/plates.dart';
import 'package:test/test.dart';

void main() {
  group('loadBar, unlimited standard plates', () {
    test('100 kg = 25 + 15 per side', () {
      final r = loadBar(100000);
      expect(r.exact!.perSideG, [25000, 15000]);
      expect(r.exact!.totalG, 100000);
      expect(r.exact!.perSideLabel, '25 + 15');
    });

    test('62.5 kg = 20 + 1.25 per side', () {
      expect(loadBar(62500).exact!.perSideG, [20000, 1250]);
    });

    test('bar only, and below the bar', () {
      expect(loadBar(20000).exact!.perSideLabel, 'bar only');
      final r = loadBar(15000);
      expect(r.exact, isNull);
      expect(r.above!.totalG, 20000);
    });

    test('not makeable: closest below and above', () {
      final r = loadBar(61000);
      expect(r.exact, isNull);
      expect(r.below!.totalG, 60000);
      expect(r.above!.totalG, 62500);
    });
  });

  group('limited pairs', () {
    test('respects counts where greedy fails', () {
      // 80 kg = 30 per side. Greedy takes the single 20 and finds no 10;
      // the DP finds 15 + 15.
      final r = loadBar(80000, pairs: {20000: 1, 15000: 2});
      expect(r.exact!.perSideG, [15000, 15000]);
    });

    test('never uses a plate more than its pair count', () {
      final pairs = {20000: 1, 10000: 2, 5000: 1, 2500: 1};
      for (var t = 20000; t <= 140000; t += 2500) {
        final r = loadBar(t, pairs: pairs);
        for (final l in [r.exact, r.below, r.above]) {
          if (l == null) continue;
          for (final e in pairs.entries) {
            expect(
              l.perSideG.where((x) => x == e.key).length,
              lessThanOrEqualTo(e.value),
              reason: 'target $t: ${l.perSideG}',
            );
          }
        }
      }
    });

    test('huge counts and unlimited stay fast', () {
      final sw = Stopwatch()..start();
      for (var t = 20000; t <= 300000; t += 2500) {
        loadBar(t);
      }
      loadBar(200000, pairs: {1250: 100000});
      // Loose bound: catches a return to the uncapped DP, not CI jitter.
      expect(sw.elapsedMilliseconds, lessThan(10000));
    });

    test('out of plates: best below, nothing above', () {
      final r = loadBar(200000, pairs: {20000: 1, 10000: 1});
      expect(r.exact, isNull);
      expect(r.below!.totalG, 80000);
      expect(r.above, isNull);
    });

    test('empty stock: bar only', () {
      expect(loadBar(40000, pairs: {}).below!.totalG, 20000);
    });

    test('custom bar', () {
      expect(loadBar(30000, barG: 10000, pairs: {10000: 2}).exact!.perSideG, [
        10000,
      ]);
    });

    test('bad input throws', () {
      expect(() => barSteps(pairs: {-5000: 1}), throwsArgumentError);
      expect(() => barSteps(pairs: {5000: -1}), throwsArgumentError);
      expect(() => loadBar(50000, pairs: {0: 1}), throwsArgumentError);
      expect(() => loadBar(50000, pairs: {5000: -1}), throwsArgumentError);
      expect(() => loadBar(50000, barG: -1), throwsArgumentError);
    });
  });

  test('matches brute force (barSteps) for every target, 20-150 kg', () {
    final pairs = {20000: 2, 15000: 1, 10000: 2, 5000: 1, 2500: 1, 1250: 2};
    final steps = barSteps(pairs: pairs);
    for (var t = 15000; t <= 150000; t += 500) {
      final r = loadBar(t, pairs: pairs);
      final below = [
        for (final x in steps)
          if (x < t) x,
      ];
      final above = [
        for (final x in steps)
          if (x > t) x,
      ];
      if (steps.contains(t)) {
        expect(r.exact?.totalG, t, reason: 'exact $t');
      } else {
        expect(r.exact, isNull, reason: '$t');
        expect(
          r.below?.totalG,
          below.isEmpty ? null : below.last,
          reason: 'below $t',
        );
        expect(
          r.above?.totalG,
          above.isEmpty ? null : above.first,
          reason: 'above $t',
        );
      }
    }
  });

  test('barSteps lists every makeable total', () {
    expect(barSteps(pairs: {10000: 1, 5000: 1}), [20000, 30000, 40000, 50000]);
  });

  group('dumbbell steps', () {
    const db = [10000, 12500, 15000, 17500, 20000, 22500, 25000];

    test('nearestStep, ties go down', () {
      expect(nearestStep(14000, db), 15000);
      expect(nearestStep(13750, db), 12500);
      expect(nearestStep(1000, db), 10000);
      expect(nearestStep(99000, db), 25000);
      expect(nearestStep(5000, const []), isNull);
    });

    test('nextStepJumpPct', () {
      expect(nextStepJumpPct(10000, db), 25);
      expect(nextStepJumpPct(20000, db), 12.5);
      expect(nextStepJumpPct(25000, db), isNull);
      expect(nextStepJumpPct(0, db), isNull);
    });
  });

  test('formatKg', () {
    expect(formatKg(20000), '20');
    expect(formatKg(22500), '22.5');
    expect(formatKg(1250), '1.25');
    expect(formatKg(0), '0');
    expect(formatKg(-1250), '-1.25');
    expect(formatKg(-500), '-0.5');
  });
}
