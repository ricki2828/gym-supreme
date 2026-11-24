import 'dart:io';
import 'dart:math';

import 'package:gym_engine/cut2.dart';
import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

/// 0.3 P1: the loads a barbell lift steps through are exactly the totals the
/// bar and plates make, so the per-side line always sums to the load.
void main() {
  final catalog = Catalog.fromJson(
    File('../../assets/exercises_taxonomy.json').readAsStringSync(),
    File('../../assets/exercises.json').readAsStringSync(),
  );
  const lift = 'barbell-bench-press-medium-grip';
  late String gym;

  GymEngine rig(Gym Function(Gym) f) {
    final e = GymEngine(
      catalog: catalog,
      store: MemoryStore(),
      nowMs: () => 0,
      tzOffsetMin: () => 0,
      random: Random(1),
    );
    final base = e.gymFromPreset('condo');
    final g = f(
      base.copyWith(
        kit: {
          ...base.kit,
          for (final id in ['barbell', 'squat-rack', 'flat-bench', 'plates'])
            id: KitItem(equipmentId: id),
        },
      ),
    );
    e.saveGym(g);
    gym = g.id;
    return e;
  }

  test('no plates listed: standard bar, 2.5 kg steps, unlimited plates', () {
    final e = rig((g) => g);
    final steps = e.loadSteps(gymId: gym, exerciseId: lift).loadsG;
    expect(steps.first, 20000);
    expect(steps.last, 140000);
    final bar = e.barSetup(gymId: gym, exerciseId: lift)!;
    expect(bar.barG, 20000);
    expect(bar.pairs, isNull);
    for (final t in steps) {
      expect(loadBar(t, barG: bar.barG).exact?.totalG, t, reason: '$t');
    }
  });

  test('plate pairs are multiplicity; every step sums, none is unmakeable', () {
    // 15 kg bar; pairs: 2 x 10 kg, 1 x 5 kg, 1 x 2.5 kg.
    final e = rig(
      (g) => g.withWeights('barbell', [15000]).withWeights('plates', [
        10000,
        5000,
        10000,
        2500,
      ]),
    );
    final bar = e.barSetup(gymId: gym, exerciseId: lift)!;
    expect(bar.barG, 15000);
    expect(bar.pairs, {2500: 1, 5000: 1, 10000: 2});
    final steps = e.loadSteps(gymId: gym, exerciseId: lift).loadsG;
    expect(steps, barSteps(barG: 15000, pairs: bar.pairs!));
    expect(steps.first, 15000);
    expect(steps.last, 15000 + 2 * (20000 + 5000 + 2500));
    for (final t in steps) {
      final r = loadBar(t, barG: bar.barG, pairs: bar.pairs);
      expect(r.exact, isNotNull, reason: '$t g');
      expect(r.exact!.totalG, t);
    }
    // 22.5 total (3.75 a side) cannot be made: never a step.
    expect(steps, isNot(contains(22500)));
    final s = e.loadSteps(gymId: gym, exerciseId: lift);
    expect(s.next(20000), 25000);
  });

  test('non-barbell lifts have no bar setup', () {
    final e = rig((g) => g);
    expect(e.barSetup(gymId: gym, exerciseId: 'pushups'), isNull);
    expect(e.barSetup(gymId: gym, exerciseId: 'nope'), isNull);
  });

  test('Gym.withWeights keeps repeats for plates only', () {
    const g = Gym(id: 'g', name: 'g', kit: {});
    expect(g.withWeights('plates', [5000, 5000]).kit['plates']!.weightsG, [
      5000,
      5000,
    ]);
    expect(
      g.withWeights('dumbbells', [5000, 5000]).kit['dumbbells']!.weightsG,
      [5000],
    );
  });
}
