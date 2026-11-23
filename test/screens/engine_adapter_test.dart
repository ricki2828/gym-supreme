import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/cut2.dart' as c2;
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

  test('day of window counts local calendar days', () {
    expect(dayOfWindow(null, 5), isNull);
    // Mon 23:30 +08:00 first session; Tue 00:10 is day 2, not day 1.
    final first = DateTime.utc(2026, 11, 23, 15, 30).millisecondsSinceEpoch;
    final tue = DateTime.utc(2026, 11, 23, 16, 10).millisecondsSinceEpoch;
    expect(dayOfWindow(first, first, tzOffsetMin: 480), 1);
    expect(dayOfWindow(first, tue, tzOffsetMin: 480), 2);
    expect(dayOfWindow(first, first + 13 * 86400000, tzOffsetMin: 480), 14);
  });

  test('timerBlock follows the set block, not the timed unit', () {
    final plan = engine.suggest(gymId: gym.id, muscleIds: const ['chest']);
    final s = eng.Session.start(plan, nowMs: now, tzOffsetMin: 480);
    expect(liveViewOf(s, nowMs: now)!.timerBlock, isFalse);
    final c = s.current!;
    final ex = s.exercises[c.exercise];
    final sets = [...ex.sets];
    sets[c.set] = sets[c.set].copyWith(block: {'type': 'emom'});
    final withBlock = s.copyWith(
      exercises: [...s.exercises]..[c.exercise] = ex.withSets(sets),
    );
    expect(liveViewOf(withBlock, nowMs: now)!.timerBlock, isTrue);
  });

  test('blockTitle is the block\'s own name; null without one', () {
    final plan = engine.suggest(gymId: gym.id, muscleIds: const ['chest']);
    final s = eng.Session.start(plan, nowMs: now, tzOffsetMin: 480);
    expect(liveViewOf(s, nowMs: now)!.blockTitle, isNull);
    // As LiveController.addTimer: a timed entry before the current one,
    // then the block attached to its set.
    final ex = s.exercises[s.current!.exercise];
    final added = eng.Session.addExercise(
      s,
      eng.PlannedItem(
        exerciseId: ex.exerciseId,
        name: ex.name,
        unit: eng.LoadUnit.timed,
        sets: const [eng.PlannedSet(loadG: null, reps: 0)],
        repLo: 0,
        repHi: 0,
        restS: ex.restS,
        reason: 'EMOM',
        primary: const [],
      ),
      at: s.current!.exercise,
    );
    final withBlock = c2.TimerSession.attach(
      added,
      added.exercises[s.current!.exercise].sets.first.setId,
      c2.TimerBlock.emom(rounds: 20),
    );
    expect(withBlock, isNot(same(added)), reason: 'block attached');
    final v = liveViewOf(withBlock, nowMs: now)!;
    expect(v.timerBlock, isTrue);
    expect(v.blockTitle, 'EMOM 20 × 1:00');
  });
}
