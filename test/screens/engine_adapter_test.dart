import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/engine_adapter.dart';
import 'package:gym_supreme/screens/view_models.dart';

void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  // Tue 24-Nov-2026 09:00 +08:00.
  var now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
  final engine = eng.GymEngine(
    catalog: catalog,
    store: eng.MemoryStore(),
    nowMs: () => now,
    tzOffsetMin: () => 480,
    random: Random(3),
  );
  final gym = engine.gymFromPreset('condo').withWeights('dumbbells', [
    for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
  ]);
  engine.saveGym(gym);

  test('one push session end to end through the adapters', () {
    final plan = engine.suggest(
      gymId: gym.id,
      muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
      typeId: 'push',
    );
    final pv = planViewOf(plan, muscleNames: const []);
    expect(pv.type, WorkoutType.push);
    expect(pv.items.length, plan.items.length);
    expect(pv.items.every((i) => i.loadG == null), isTrue, reason: 'cold');

    var s = eng.Session.start(plan, nowMs: now, tzOffsetMin: 480);
    final steps = engine.loadSteps(
      gymId: gym.id,
      exerciseId: plan.items.first.exerciseId,
    );
    var v = liveViewOf(s, nowMs: now, steps: steps)!;
    expect(v.coldStart, isTrue);
    expect(v.canLoadUp, isTrue);
    expect(v.canLoadDown, isFalse);
    s = eng.Session.retarget(s, s.currentSet!.setId, loadG: steps.next(null));
    s = eng.Session.done(s, s.currentSet!.setId, nowMs: now += 40000);
    v = liveViewOf(s, nowMs: now, steps: steps)!;
    expect(v.rail.first.name, 'done');
    expect(v.set, 2);
    expect(v.restLeftS, greaterThan(0));
    s = eng.Session.finish(s, nowMs: now += 600000);
    engine.saveFinished(s);

    final rows = engine.history();
    expect(rows, hasLength(1));
    final h = historyRowOf(rows.single);
    expect(h.type, WorkoutType.push);
    expect(h.startedAt.hour, 9, reason: 'local time from offset');

    final sum = engine.summary(s.workoutUuid);
    final post = postWorkoutViewOf(
      sum,
      row: rows.single,
      weekTypes: weekTypesOf(rows, localOf(now, 480)),
      unitByExercise: const {},
    );
    expect(post.setCount, 1);
    expect(post.weekTypes, {WorkoutType.push});
    expect(post.setsPerGroup.first.$1, isNotEmpty);

    final gate = gateViewOf(engine.counters(), nowMs: now);
    expect(gate.sessionsTotal, 1);
    expect(gate.dayOfWindow, 1);
    expect(gate.coldStartSets, 1);
  });

  test('setsPerGroupOf sums weighted muscles per picker row', () {
    expect(
      setsPerGroupOf({
        'chest': 9,
        'front-delts': 1.5,
        'side-delts': 1.5,
        'triceps': 0.4,
      }),
      [('Chest', 9), ('Shoulders', 3)],
    );
  });

  test('weekTypesOf starts the week on Monday, local time', () {
    final mon = eng.HistoryRow(
      uuid: 'a',
      startedAtMs: DateTime.utc(
        2026,
        11,
        22,
        16,
        30,
      ).millisecondsSinceEpoch, // Mon 00:30 +08
      tzOffsetMin: 480,
      gymId: 'g',
      gymName: 'G',
      typeId: 'legs',
      durationMs: 1,
      volumeKg: 1,
      setCount: 1,
    );
    final sun = eng.HistoryRow(
      uuid: 'b',
      startedAtMs: DateTime.utc(
        2026,
        11,
        22,
        15,
        30,
      ).millisecondsSinceEpoch, // Sun 23:30 +08
      tzOffsetMin: 480,
      gymId: 'g',
      gymName: 'G',
      typeId: 'pull',
      durationMs: 1,
      volumeKg: 1,
      setCount: 1,
    );
    expect(weekTypesOf([mon, sun], DateTime.utc(2026, 11, 24, 9)), {
      WorkoutType.legs,
    });
  });

  test('day of window', () {
    expect(dayOfWindow(null, 5), isNull);
    expect(dayOfWindow(0, 0), 1);
    expect(dayOfWindow(0, 13 * 86400000 + 1), 14);
  });
}
