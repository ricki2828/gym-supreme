import 'dart:io';
import 'dart:math';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

/// Review P1-4 rules as properties on the condo kit (the golden shows the
/// lists; these pin what the lists must satisfy).
void main() {
  final catalog = Catalog.fromJson(
    File('../../assets/exercises_taxonomy.json').readAsStringSync(),
    File('../../assets/exercises.json').readAsStringSync(),
  );
  late GymEngine engine;
  late Gym gym;
  setUp(() {
    engine = GymEngine(
      catalog: catalog,
      store: MemoryStore(),
      nowMs: () => DateTime.utc(2026, 11, 23, 1).millisecondsSinceEpoch,
      tzOffsetMin: () => 480,
      random: Random(1),
    );
    gym = engine.gymFromPreset('condo');
    engine.saveGym(gym);
  });

  final picks = <String, List<String>>{
    for (final t in workoutTypes.where((t) => t.muscles.isNotEmpty))
      t.id: t.muscles,
    'chest+shoulders+triceps': const [
      'chest',
      'front-delts',
      'side-delts',
      'rear-delts',
      'triceps',
    ],
    'back+biceps': const ['lats', 'traps', 'lower-back', 'biceps', 'forearms'],
  };

  List<Exercise> lifts(SessionPlan p) => [
    for (final i in p.items) catalog.exercise(i.exerciseId)!,
  ];

  for (final MapEntry(key: name, value: muscles) in picks.entries) {
    group(name, () {
      SessionPlan plan(int minutes, {int seed = 0}) => engine.suggest(
        gymId: gym.id,
        muscleIds: muscles,
        minutes: minutes,
        seed: seed,
      );

      test('every picked muscle gets a direct lift (30/45/60)', () {
        for (final m in [30, 45, 60]) {
          final p = plan(m);
          for (final mu in muscles) {
            if (p.uncovered.contains(mu)) continue;
            expect(
              lifts(p).any((e) => e.primary.contains(mu)),
              isTrue,
              reason: '$mu at $m min',
            );
          }
        }
      });

      test('60 minutes fills past 45; never over budget', () {
        for (final seed in [0, 3]) {
          final a = plan(45, seed: seed), b = plan(60, seed: seed);
          expect(b.estimatedMinutes, greaterThan(a.estimatedMinutes));
          expect(a.estimatedMinutes, lessThanOrEqualTo(45));
          expect(b.estimatedMinutes, lessThanOrEqualTo(60));
        }
      });

      test('no two compounds of the same movement', () {
        for (final m in [30, 45, 60]) {
          final c = [
            for (final e in lifts(plan(m)))
              if (e.isCompound) '${movementGroup(e)}/${movementVariant(e)}',
          ];
          expect(c.toSet().length, c.length, reason: '$c at $m min');
        }
      });

      test('no two isolations of the same movement (core excepted)', () {
        for (final m in [30, 45, 60]) {
          final iso = [
            for (final e in lifts(plan(m, seed: 3)))
              if (!e.isCompound &&
                  !e.primary.any(const {'abs', 'obliques'}.contains))
                '${movementGroup(e)}/${movementVariant(e)}',
          ];
          expect(iso.toSet().length, iso.length, reason: '$iso at $m min');
        }
      });

      test('a bodyweight lift only when no loaded one of its kind is free', () {
        final p = plan(45);
        final chosen = lifts(p);
        for (final e in chosen.where((e) => e.load == bodyweight)) {
          final loaded = catalog.exercises.where(
            (x) =>
                x.load != bodyweight &&
                x.load != 'timed' &&
                x.availableWith(gym.equipmentIds) &&
                x.primary.any(e.primary.contains) &&
                !chosen.contains(x) &&
                isFreshPattern(x, chosen),
          );
          expect(loaded, isEmpty, reason: '${e.id} over ${loaded.toList()}');
        }
      });
    });
  }

  test('push gets a triceps lift; legs use the leg extension', () {
    SessionPlan p(String t) => engine.suggest(
      gymId: gym.id,
      muscleIds: workoutType(t)!.muscles,
      minutes: 45,
    );
    expect(lifts(p('push')).any((e) => e.primary.contains('triceps')), isTrue);
    expect(
      p('legs').items.map((i) => i.exerciseId),
      contains('leg-extensions'),
    );
  });

  test('seed changes ties, deterministically; tie hash is fixed', () {
    List<String> ids(int seed) => [
      for (final i
          in engine
              .suggest(gymId: gym.id, muscleIds: const ['chest'], seed: seed)
              .items)
        i.exerciseId,
    ];
    expect(ids(5), ids(5));
    expect(
      {for (var s = 1; s < 6; s++) ids(s).join(',')}.length,
      greaterThan(1),
    );
    // FNV-1a 32-bit, the same on every platform.
    expect(tieHash(0, 'a'), 0x98b2bcaa); // python reference
  });

  test('0.1 history on bodyweight lifts does not keep them over loaded', () {
    // He logged the 0.1 legs list (bodyweight squat first) twice.
    var now = DateTime.utc(2026, 11, 10, 1).millisecondsSinceEpoch;
    final e2 = GymEngine(
      catalog: catalog,
      store: MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 480,
    );
    final g = e2.gymFromPreset('condo');
    e2.saveGym(g);
    const old = SessionPlan(
      gymId: '',
      muscles: ['quads'],
      estimatedMinutes: 10,
      uncovered: [],
      items: [
        PlannedItem(
          exerciseId: 'bodyweight-squat',
          name: 'Bodyweight Squat',
          unit: LoadUnit.bodyweight,
          sets: [PlannedSet(loadG: null, reps: 10)],
          repLo: 8,
          repHi: 12,
          restS: 120,
          reason: '',
          primary: ['quads'],
        ),
      ],
    );
    for (var k = 0; k < 2; k++) {
      var s = Session.start(
        SessionPlan(
          gymId: g.id,
          muscles: old.muscles,
          estimatedMinutes: 10,
          uncovered: const [],
          items: old.items,
        ),
        nowMs: now,
        tzOffsetMin: 480,
        workoutUuid: 'old$k',
      );
      s = Session.done(s, s.currentSet!.setId, nowMs: now += 60000);
      e2.saveFinished(Session.finish(s, nowMs: now += 1000));
      now += 4 * 86400000;
    }
    final p = e2.suggest(
      gymId: g.id,
      muscleIds: workoutType('legs')!.muscles,
      minutes: 45,
    );
    expect(
      p.items.map((i) => i.exerciseId),
      isNot(contains('bodyweight-squat')),
    );
  });

  test('forearms alone: one wrist curl, never both (review P2)', () {
    for (final m in [30, 45, 60]) {
      final ids = engine
          .suggest(gymId: gym.id, muscleIds: const ['forearms'], minutes: m)
          .items
          .map((i) => i.exerciseId)
          .where((id) => id.contains('wrist-curl'));
      expect(ids.length, lessThanOrEqualTo(1), reason: '$ids at $m min');
    }
  });

  test('a repeated muscle id counts once', () {
    final a = engine.suggest(gymId: gym.id, muscleIds: const ['chest']);
    final b = engine.suggest(
      gymId: gym.id,
      muscleIds: const ['chest', 'chest'],
    );
    expect(b.items.map((i) => i.exerciseId), a.items.map((i) => i.exerciseId));
  });
}
