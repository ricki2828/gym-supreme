import 'dart:io';
import 'dart:math';

import 'package:gym_engine/cut2.dart';
import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
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

  GymEngine rig(Gym Function(Gym) f, {HistoryStore? store}) {
    final e = GymEngine(
      catalog: catalog,
      store: store ?? MemoryStore(),
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

  // suggest() and the starting weight must also stay on the bar: both snap to
  // loadSteps, so an off-bar history load or a typed weight never comes back.
  for (final (label, make) in <(String, HistoryStore Function())>[
    ('memory store', MemoryStore.new),
    ('sqlite store', SqliteStore.inMemory),
  ]) {
    group('suggestions stay on the bar ($label)', () {
      // 15 kg bar, 2 x 10 kg and 1 x 5 kg pairs: 15, 25, 35, 45, 55, 65 kg.
      Gym limited(Gym g) => g.withWeights('barbell', [15000]).withWeights(
        'plates',
        [10000, 10000, 5000],
      );

      Iterable<PlannedItem> barbellItems(SessionPlan p) => p.items.where(
        (i) => catalog.exercise(i.exerciseId)!.load == 'barbell',
      );

      void expectOnBar(GymEngine e, SessionPlan p) {
        final items = barbellItems(p).toList();
        expect(items, isNotEmpty, reason: 'a barbell lift was suggested');
        for (final i in items) {
          final steps = e.loadSteps(gymId: gym, exerciseId: i.exerciseId);
          final bar = e.barSetup(gymId: gym, exerciseId: i.exerciseId)!;
          for (final set in i.sets) {
            if (set.loadG == null) continue;
            expect(steps.loadsG, contains(set.loadG), reason: i.exerciseId);
            expect(
              loadBar(set.loadG!, barG: bar.barG, pairs: bar.pairs).exact,
              isNotNull,
              reason: '${set.loadG} g on ${i.exerciseId}',
            );
          }
        }
      }

      SessionPlan push(GymEngine e, {int seed = 0}) => e.suggest(
        gymId: gym,
        muscleIds: const ['chest', 'triceps', 'front-delts'],
        typeId: 'push',
        minutes: 90,
        seed: seed,
      );

      /// A push plan that includes the bench (the pick varies by seed).
      SessionPlan pushWithBench(GymEngine e) {
        for (var seed = 0; seed < 40; seed++) {
          final p = push(e, seed: seed);
          if (p.items.any((i) => i.exerciseId == lift)) return p;
        }
        fail('no seed in 0..39 suggested $lift');
      }

      test('after a workout logged at an off-bar load', () {
        final e = rig(limited, store: make());
        // He logged 51 kg (a typed weight, or the bar changed since).
        final item = PlannedItem(
          exerciseId: lift,
          name: 'Barbell bench press',
          unit: LoadUnit.kg,
          sets: const [
            PlannedSet(loadG: 51000, reps: 12),
            PlannedSet(loadG: 51000, reps: 12),
          ],
          repLo: 8,
          repHi: 12,
          restS: 120,
          reason: '',
          primary: const ['chest'],
        );
        var s = Session.start(
          SessionPlan(
            gymId: gym,
            typeId: 'push',
            muscles: const ['chest'],
            uncovered: const [],
            estimatedMinutes: 20,
            items: [item],
          ),
          nowMs: 1000,
          tzOffsetMin: 0,
        );
        var now = 1000;
        for (final x in s.exercises.first.sets) {
          s = Session.done(s, x.setId, nowMs: now += 120000);
        }
        e.saveFinished(Session.finish(s, nowMs: now += 1000));
        final plan = pushWithBench(e);
        final mine = barbellItems(plan).where((i) => i.exerciseId == lift);
        expect(mine, isNotEmpty);
        // 51 kg is not on this bar: snapped down to 45 (all sets at the top
        // of the range would go up one step, to 55: still on the bar).
        for (final set in mine.single.sets) {
          expect(const [45000, 55000], contains(set.loadG));
        }
        expectOnBar(e, plan);
      });

      test('a typed starting weight that is not on the bar', () {
        final e = rig(limited, store: make());
        e.setStartingWeight(lift, 51000);
        final plan = pushWithBench(e);
        final mine = barbellItems(plan).firstWhere((i) => i.exerciseId == lift);
        expect(mine.loadFromStartingWeight, isTrue);
        expect(mine.sets.first.loadG, 45000, reason: 'snapped down to the bar');
        expect(e.startingLoad(gymId: gym, exerciseId: lift), 45000);
        expectOnBar(e, plan);
      });

      test('a typed weight under the bar goes to the lightest load', () {
        final e = rig(limited, store: make());
        e.setStartingWeight(lift, 5000);
        expect(e.startingLoad(gymId: gym, exerciseId: lift), 15000);
      });
    });
  }
}
