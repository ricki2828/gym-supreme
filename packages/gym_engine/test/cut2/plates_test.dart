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
      // 50 kg on a 20 kg bar = 15 per side. One pair of 20s, two pairs of
      // 7.5s, no 10/5: greedy would take nothing useful; DP finds 7.5 + 7.5.
      final r = loadBar(50000, pairs: {20000: 1, 7500: 2});
      expect(r.exact!.perSideG, [7500, 7500]);
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
      expect(() => loadBar(50000, pairs: {0: 1}), throwsArgumentError);
      expect(() => loadBar(50000, pairs: {5000: -1}), throwsArgumentError);
      expect(() => loadBar(50000, barG: -1), throwsArgumentError);
    });
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
  });
}
