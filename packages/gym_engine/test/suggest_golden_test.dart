import 'dart:io';
import 'dart:math';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

/// Goldens on Ricki's real condo kit (plan 5): fixed clock, seed and kit.
/// Regenerate after a deliberate rules change:
///   UPDATE_GOLDENS=1 dart test test/suggest_golden_test.dart
/// and review the diff of test/goldens/suggest_condo.txt like code.
void main() {
  test('condo suggestions match the golden', () {
    final catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
    final engine = GymEngine(
      catalog: catalog,
      store: MemoryStore(),
      nowMs: () => DateTime.utc(2026, 11, 23, 1).millisecondsSinceEpoch,
      tzOffsetMin: () => 480,
      random: Random(1),
    );
    final gym = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
      25000,
    ]);
    engine.saveGym(gym);

    final out = StringBuffer();
    // The four types, then picker-row picks (review P1-3/P1-4): Chest +
    // Shoulders + Triceps, Shoulders alone, Back + Biceps, Legs rows; and
    // one non-zero seed.
    final picks = <(String, List<String>, String?, int)>[
      for (final t in workoutTypes.where((t) => t.muscles.isNotEmpty))
        (t.id, t.muscles, t.id, 0),
      (
        'rows:chest+shoulders+triceps',
        const ['chest', 'front-delts', 'side-delts', 'rear-delts', 'triceps'],
        'push',
        0,
      ),
      (
        'rows:shoulders',
        const ['front-delts', 'side-delts', 'rear-delts'],
        'push',
        0,
      ),
      (
        'rows:back+biceps',
        const ['lats', 'traps', 'lower-back', 'biceps', 'forearms'],
        'pull',
        0,
      ),
      (
        'rows:quads+glutes',
        const ['quads', 'calves', 'glutes', 'hamstrings'],
        'legs',
        0,
      ),
      ('push seed=7', workoutTypes.first.muscles, 'push', 7),
    ];
    for (final (name, muscles, typeId, seed) in picks) {
      for (final minutes in [30, 45, 60]) {
        final p = engine.suggest(
          gymId: gym.id,
          muscleIds: muscles,
          minutes: minutes,
          typeId: typeId,
          seed: seed,
        );
        out.writeln(
          '## $name ${minutes}min est=${p.estimatedMinutes} '
          'uncovered=${p.uncovered}',
        );
        for (final i in p.items) {
          final kit = gym.equipmentIds;
          final e = catalog.exercise(i.exerciseId)!;
          expect(e.availableWith(kit), isTrue);
          out.writeln(
            '${i.exerciseId} ${i.setCount}x${i.sets.first.reps} '
            'rest=${i.restS} ${i.unit.name}',
          );
        }
        expect(p.estimatedMinutes, lessThanOrEqualTo(minutes));
      }
    }
    final golden = File('test/goldens/suggest_condo.txt');
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync(out.toString());
    }
    expect(out.toString(), golden.readAsStringSync());
  });

  test('condo progression + ceiling golden (B7)', () {
    final catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
    var now = DateTime.utc(2026, 11, 16, 1).millisecondsSinceEpoch;
    final engine = GymEngine(
      catalog: catalog,
      store: MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(1),
    );
    final gym = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
      25000,
    ]);
    engine.saveGym(gym);

    // Session 1: cold start, the first dumbbell lift at 24 kg (top of range), the
    // rest at 20 kg mid-range. Session 2 (3 days later) shows progression:
    // 24 → 25 kg; then session 3 at 25 kg top → ceiling (more reps).
    final out = StringBuffer();
    String? ceilingId;
    for (var round = 0; round < 3; round++) {
      final p = engine.suggest(
        gymId: gym.id,
        muscleIds: ['chest', 'triceps'],
        minutes: 45,
        typeId: 'push',
      );
      ceilingId ??= p.items.firstWhere((i) => i.unit == LoadUnit.ea).exerciseId;
      out.writeln('## session ${round + 1}');
      for (final i in p.items) {
        out.writeln(
          '${i.exerciseId} ${i.sets.map((x) => '${x.loadG ?? '-'}x${x.reps}').join(' ')}'
          ' | ${i.reason}',
        );
      }
      var s = Session.start(
        p,
        nowMs: now,
        tzOffsetMin: 480,
        workoutUuid: 'w$round',
      );
      for (var e = 0; e < s.exercises.length; e++) {
        final ex = s.exercises[e];
        for (final x in ex.sets) {
          now += 120000;
          // The first dumbbell lift is driven to the ceiling (B7).
          final first = ex.exerciseId == ceilingId;
          final load =
              x.targetLoadG ??
              (ex.loadKind == 'bodyweight' ? null : (first ? 24000 : 20000));
          final reps = first ? (ex.repHi ?? 12) : x.targetReps;
          s = load == null
              ? Session.done(s, x.setId, nowMs: now, reps: reps)
              : Session.done(s, x.setId, nowMs: now, loadG: load, reps: reps);
        }
      }
      engine.saveFinished(Session.finish(s, nowMs: now += 60000));
      now += 3 * 86400000;
    }
    final golden = File('test/goldens/suggest_condo_progression.txt');
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      golden.writeAsStringSync(out.toString());
    }
    final text = golden.readAsStringSync();
    expect(out.toString(), text);
    expect(text, contains('25000x8'));
    expect(text, contains('Top weight here'));
    expect(text, contains('$ceilingId 25000x13'));
  });
}
