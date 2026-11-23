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
    for (final t in workoutTypes.where((t) => t.muscles.isNotEmpty)) {
      for (final minutes in [30, 45, 60]) {
        final p = engine.suggest(
          gymId: gym.id,
          muscleIds: t.muscles,
          minutes: minutes,
          typeId: t.id,
        );
        out.writeln(
          '## ${t.id} ${minutes}min est=${p.estimatedMinutes} '
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

    // Session 1: cold start, first exercise at 24 kg (top of range), the
    // rest at 20 kg mid-range. Session 2 (3 days later) shows progression:
    // 24 → 25 kg; then session 3 at 25 kg top → ceiling (more reps).
    final out = StringBuffer();
    for (var round = 0; round < 3; round++) {
      final p = engine.suggest(
        gymId: gym.id,
        muscleIds: ['chest', 'triceps'],
        minutes: 45,
        typeId: 'push',
      );
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
          final first = e == 0;
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
  });
}
