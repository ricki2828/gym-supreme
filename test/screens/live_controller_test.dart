import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/workout_port.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/engine_adapter.dart';
import 'package:gym_supreme/screens/live_screen.dart';

import 'flaky_port.dart';

/// The controller over the real engine (MemoryStore) and t5t's stub port:
/// transitions in Dart, rev owned by the port, finish order B1.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.GymEngine engine;
  late FlakyPort port;
  late LiveController c;
  late String gymId;

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    engine = eng.GymEngine(
      catalog: catalog,
      store: eng.MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(7),
    );
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
    ]);
    engine.saveGym(g);
    gymId = g.id;
    port = FlakyPort();
    c = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
  });
  tearDown(() => c.dispose());

  Future<void> startPush() async {
    final plan = engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
      typeId: 'push',
    );
    expect(plan.items, isNotEmpty);
    await c.start(plan);
  }

  test('start sends rev 0 and shows the first set as a cold start', () async {
    await startPush();
    expect(port.rev, 0);
    final v = c.view()!;
    expect(v.lift, 1);
    expect(v.set, 1);
    expect(v.rail.first, SetTile.current);
    expect(v.coldStart, isTrue, reason: 'no history: first time here');
    expect(v.loadG, isNull);
  });

  test(
    'cold start: + picks the lightest real weight, then Done logs it',
    () async {
      await startPush();
      await c.load(1);
      final v = c.view()!;
      expect(v.loadG, isNotNull);
      expect(port.rev, 1);
      await c.done();
      expect(port.rev, 2);
      final s = c.snapshot!;
      final logged = s.exercises.first.sets.first;
      expect(logged.state, eng.SetState.done);
      expect(logged.loadG, v.loadG);
      expect(logged.completion, eng.Completion.coldStart);
      expect(c.view()!.restLeftS, greaterThan(0), reason: 'auto rest');
    },
  );

  test('same-snapshot transitions send nothing', () async {
    await startPush();
    await c.skipRest(); // no rest running
    await c.setReps(1);
    final rev = port.rev;
    await c.reps(-1); // already at 1: clamps, nothing to send
    expect(port.rev, rev);
  });

  test('rest ±15 and skip', () async {
    await startPush();
    await c.load(1);
    await c.done();
    final left = c.view()!.restLeftS!;
    await c.restDelta(15);
    expect(c.view()!.restLeftS, left + 15);
    await c.skipRest();
    expect(c.view()!.restLeftS, isNull);
  });

  test('rest countdown follows the clock', () async {
    await startPush();
    await c.load(1);
    await c.done();
    final left = c.view()!.restLeftS!;
    now += 10000;
    expect(c.view()!.restLeftS, left - 10);
    now += left * 1000;
    expect(c.view()!.restLeftS, isNull, reason: 'rest over: back to the set');
  });

  test('reorder moves up-next items only', () async {
    await startPush();
    final before = c.view()!.upNext.map((p) => p.exerciseId).toList();
    expect(before.length, greaterThanOrEqualTo(2), reason: 'condo push');
    await c.reorderUpNext(0, 1);
    final after = c.view()!.upNext.map((p) => p.exerciseId).toList();
    expect(after, [before[1], before[0], ...before.skip(2)]);
    expect(c.view()!.lift, 1, reason: 'current exercise unchanged');
  });

  test(
    'stale rev resyncs from the journal instead of double-applying',
    () async {
      await startPush();
      await c.load(1);
      // Another writer (cut 2 lock screen) moves the journal on.
      final head = eng.SessionSnapshot.decode(
        (await port.readPendingJournal())!,
      );
      final moved = eng.Session.done(head, head.currentSet!.setId, nowMs: now);
      await port.submitSnapshot(moved.encode(), head.rev);
      await c.done();
      expect(c.lastError, isA<StaleRevException>());
      expect(c.snapshot!.rev, moved.rev);
      final done = c.snapshot!.exercises.first.sets
          .where((s) => s.state == eng.SetState.done)
          .length;
      expect(done, 1, reason: 'one Done, not two');
    },
  );

  test(
    'finish: finished snapshot, SQLite upsert, then journal deleted',
    () async {
      await startPush();
      await c.load(1);
      await c.done();
      now += 60000;
      final uuid = await c.finish();
      expect(uuid, isNotNull);
      expect(engine.isStored(uuid!), isTrue);
      expect(await port.readPendingJournal(), isNull);
      expect(c.active, isFalse);
      expect(c.view(), isNull);
      expect(engine.summary(uuid).setCount, 1);
    },
  );

  test('pause stops the clock; resume continues from the journal', () async {
    await startPush();
    now += 30000;
    await c.pause();
    expect(c.view()!.paused, isTrue);
    final at = c.view()!.elapsedS;
    now += 600000;
    expect(c.view()!.elapsedS, at, reason: 'paused time not counted');
    final pending = eng.SessionSnapshot.decode(
      (await port.readPendingJournal())!,
    );
    final c2 = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    await c2.resume(pending);
    expect(c2.view()!.paused, isFalse);
    expect(c2.view()!.elapsedS, at);
    c2.dispose();
  });

  Future<void> logOne() async {
    await c.load(1);
    await c.done();
  }

  test(
    'finish failing at delete keeps the workout stored and retryable',
    () async {
      await startPush();
      await logOne();
      port.failNext['deleteJournal'] = WorkoutPortException('io');
      expect(await c.finish(), isNull);
      expect(c.lastError, isA<WorkoutPortException>());
      final uuid = c.snapshot!.workoutUuid;
      expect(engine.isStored(uuid), isTrue, reason: 'saved before delete');
      expect(await port.readPendingJournal(), isNotNull, reason: 'kept');
      expect(c.view()!.allDone, isTrue, reason: 'Finish can be tapped again');
      expect(await c.finish(), uuid);
      expect(await port.readPendingJournal(), isNull);
      expect(engine.history(), hasLength(1), reason: 'upsert, not a duplicate');
    },
  );

  test(
    'finish failing at the service: nothing stored, nothing deleted',
    () async {
      await startPush();
      await logOne();
      port.failNext['finishSession'] = WorkoutPortException('not_running');
      expect(await c.finish(), isNull);
      expect(engine.history(), isEmpty);
      expect(await port.readPendingJournal(), isNotNull);
      expect(await c.finish(), isNotNull);
      expect(engine.history(), hasLength(1));
    },
  );

  test('a second finish after success does nothing', () async {
    await startPush();
    await logOne();
    final uuid = await c.finish();
    expect(await c.finish(), uuid);
    expect(c.lastError, isNull);
  });

  test('pause: a refused paused snapshot keeps the service running', () async {
    await startPush();
    port.failNext['submitSnapshot'] = WorkoutPortException('io');
    expect(await c.pause(), isFalse);
    expect(port.running, isTrue);
    expect(c.view()!.paused, isFalse);
    expect(await c.pause(), isTrue);
    expect(port.running, isFalse);
  });

  test(
    'pause: a failing pauseSession after the paused snapshot is still safe',
    () async {
      await startPush();
      port.failNext['pauseSession'] = WorkoutPortException('io');
      expect(await c.pause(), isTrue);
      expect(c.lastError, isA<WorkoutPortException>());
    },
  );

  test('stale rev onto a head finished elsewhere completes B1 here', () async {
    await startPush();
    await logOne();
    final head = eng.SessionSnapshot.decode((await port.readPendingJournal())!);
    final fin = eng.Session.finish(head, nowMs: now += 1000);
    await port.submitSnapshot(fin.encode(), head.rev);
    await c.skipRest(); // our base is now stale
    expect(c.finishedUuid, fin.workoutUuid);
    expect(engine.isStored(fin.workoutUuid), isTrue);
    expect(await port.readPendingJournal(), isNull);
  });

  test('stale rev with an unreadable journal keeps the old view', () async {
    await startPush();
    await logOne();
    final head = eng.SessionSnapshot.decode((await port.readPendingJournal())!);
    await port.submitSnapshot(
      eng.Session.skipRest(head, nowMs: now).encode(),
      head.rev,
    );
    final before = c.snapshot!;
    port.failNext['readPendingJournal'] = WorkoutPortException('io');
    await c.restDelta(15);
    expect(c.lastError, isA<WorkoutPortException>());
    expect(c.snapshot, same(before), reason: 'tap dropped, view unchanged');
    expect(c.view()!.set, 2);
  });

  test(
    'finish keeps failing: the user can still leave (pause is safe)',
    () async {
      await startPush();
      await logOne();
      port.failNext['deleteJournal'] = WorkoutPortException('io');
      expect(await c.finish(), isNull);
      expect(await c.pause(), isTrue, reason: 'journal already finished');
    },
  );

  test('resync onto a finished head whose save fails shows all done', () async {
    await startPush();
    await logOne();
    final head = eng.SessionSnapshot.decode((await port.readPendingJournal())!);
    final fin = eng.Session.finish(head, nowMs: now += 1000);
    await port.submitSnapshot(fin.encode(), head.rev);
    port.failNext['deleteJournal'] = WorkoutPortException('io');
    await c.skipRest();
    expect(c.finishedUuid, isNull);
    expect(c.view()!.allDone, isTrue, reason: 'not the stale active base');
    final at = c.view()!.elapsedS;
    now += 60000;
    expect(c.view()!.elapsedS, at, reason: 'finished clock stops');
    expect(await c.finish(), fin.workoutUuid);
  });

  test('first weight starts mid-list, either direction (P1-1)', () async {
    await startPush();
    final steps = engine.loadSteps(
      gymId: gymId,
      exerciseId: c.snapshot!.exercises.first.exerciseId,
    );
    // Dumbbells start mid-list, machine stacks a third of the way up (the
    // first push lift may be either, depending on the suggestion).
    final n = steps.loadsG.length;
    final stack = c.snapshot!.exercises.first.loadKind == 'stack';
    final mid = steps.loadsG[stack ? (n - 1) ~/ 3 : (n - 1) ~/ 2];
    await c.load(-1);
    expect(c.view()!.loadG, mid);
    expect(mid, greaterThan(steps.loadsG.first));
  });

  test(
    'typed values log as typed; a first-time set stays cold start',
    () async {
      await startPush();
      await c.setLoad(13250); // not on the list: he logs what he lifted
      expect(c.view()!.loadG, 13250);
      await c.done();
      final first = c.snapshot!.exercises.first.sets.first;
      expect(first.loadG, 13250);
      expect(first.completion, eng.Completion.coldStart);
    },
  );

  test('typed reps on a prefilled set log as typed', () async {
    // A second session: the first one gives this lift a plan load.
    await startPush();
    await c.load(1);
    for (var i = 0; i < 3; i++) {
      await c.done();
      await c.skipRest();
    }
    await c.finish();
    final c2 = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    now += 3 * 86400000;
    final plan = engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
      typeId: 'push',
    );
    await c2.start(plan);
    final set = c2.snapshot!.currentSet!;
    expect(set.planLoadG, isNotNull, reason: 'prefilled from last time');
    await c2.setReps((set.targetReps ?? 8) + 2);
    await c2.done();
    final logged = c2.snapshot!.exercises.first.sets.first;
    expect(logged.completion, eng.Completion.typed);
    c2.dispose();
  });

  test('held +/- coalesce: many steps, few submits, exact total', () async {
    await startPush();
    await c.load(1); // starts mid-list
    final start = port.rev;
    final r0 = c.view()!.reps;
    final all = [for (var i = 0; i < 6; i++) c.reps(1)];
    await Future.wait(all);
    expect(c.view()!.reps, r0 + 6, reason: 'every tick counted once');
    expect(
      port.rev - start,
      lessThan(6),
      reason: 'coalesced into fewer submits',
    );
  });

  test('typing the value already there sends nothing', () async {
    await startPush();
    await c.load(1);
    final rev = port.rev;
    await c.setLoad(c.view()!.loadG!);
    await c.setReps(c.view()!.reps);
    expect(port.rev, rev);
  });

  test(
    'a typed value lands on the set it was typed for, not the next',
    () async {
      await startPush();
      await c.load(1);
      final first = c.snapshot!.currentSet!.setId;
      await c.done(); // the number pad was open on set 1; set 1 got logged
      await c.skipRest();
      final rev = port.rev;
      await c.setReps(3, setId: first); // set 1 is no longer pending
      expect(port.rev, rev, reason: 'dropped, not moved to set 2');
      final second = c.snapshot!.currentSet!.setId;
      await c.setReps(3, setId: second);
      expect(c.view()!.reps, 3);
    },
  );

  test('a machine stack starts a third of the way up, not mid-list', () async {
    final plan = engine.suggest(gymId: gymId, muscleIds: const ['triceps']);
    final stackItem = plan.items.indexWhere((i) => i.unit == eng.LoadUnit.kg);
    expect(stackItem, greaterThanOrEqualTo(0), reason: 'a cable lift');
    await c.start(plan);
    for (var i = 0; i < stackItem; i++) {
      final ex = c.snapshot!.exercises[i];
      for (final _ in ex.sets) {
        await c.skipSet();
      }
    }
    final steps = engine.loadSteps(
      gymId: gymId,
      exerciseId: c.snapshot!.exercises[stackItem].exerciseId,
    );
    await c.load(1);
    expect(c.view()!.loadG, steps.loadsG[(steps.loadsG.length - 1) ~/ 3]);
  });

  test('reps and kg coalesced into one job: one submit at rev + 1', () async {
    await startPush();
    await c.load(1);
    final r0 = c.view()!.reps;
    final g0 = c.view()!.loadG!;
    final a = c.reps(1); // runs now
    final b = c.reps(1); // queued
    final d = c.load(1); // joins the queued job: reps and kg together
    await Future.wait([a, b, d]);
    expect(c.lastError, isNull, reason: 'the stub enforces rev + 1');
    expect(c.view()!.reps, r0 + 2);
    expect(c.view()!.loadG, greaterThan(g0));
  });

  test('held − stops at 1 rather than dropping the batch', () async {
    await startPush();
    await c.load(1);
    await c.setReps(6);
    await Future.wait([for (var i = 0; i < 9; i++) c.reps(-1)]);
    expect(c.view()!.reps, 1);
  });

  test('steppers recover after a step lands with no current set', () async {
    await startPush();
    await c.load(1);
    // Log every set, so there is no current set, and press + meanwhile.
    final all = <Future<void>>[];
    for (final e in c.snapshot!.exercises) {
      for (final _ in e.sets) {
        all.add(c.done());
      }
    }
    all.add(c.reps(1));
    await Future.wait(all);
    expect(c.view()!.allDone, isTrue);
    await c.reps(1); // runs with no current set
    expect(c.stepQueued, isFalse, reason: 'reset even with no set');
  });

  test(
    'undo the last set: back to pending, rest cleared, typed forgotten',
    () async {
      await startPush();
      await c.setLoad(12000);
      await c.done();
      expect(c.view()!.undoLabel, contains('12 kg ea'));
      expect(c.view()!.restLeftS, isNotNull);
      await c.undoLast();
      final first = c.snapshot!.exercises.first.sets.first;
      expect(first.state, eng.SetState.pending);
      expect(c.view()!.restLeftS, isNull);
      expect(c.view()!.undoLabel, isNull);
      expect(c.view()!.set, 1);
    },
  );

  test('undo picks the latest of two sets', () async {
    await startPush();
    await c.load(1);
    await c.done();
    await c.skipRest();
    now += 1000;
    await c.done();
    final second = c.snapshot!.exercises.first.sets[1];
    await c.undoLast();
    expect(c.snapshot!.exercises.first.sets[1].state, eng.SetState.pending);
    expect(c.snapshot!.exercises.first.sets[0].state, eng.SetState.done);
    expect(second.state, eng.SetState.done);
  });

  test('add a set on the current exercise', () async {
    await startPush();
    final n = c.view()!.sets;
    await c.addSet();
    expect(c.view()!.sets, n + 1);
  });

  test('swap before logging; counted; refused once a set is logged', () async {
    await startPush();
    final s0 = c.snapshot!;
    final cur = s0.exercises.first;
    final kit = engine.gym(gymId)!.equipmentIds;
    final options = swapCandidates(catalog, s0, cur.exerciseId, kit);
    expect(options, isNotEmpty);
    expect(options.every((o) => o.availableWith(kit)), isTrue);
    await c.swapCurrent(swapItem(options.first, cur));
    expect(c.snapshot!.exercises.first.exerciseId, options.first.id);
    expect(c.snapshot!.swaps, 1);
    expect(c.view()!.sets, cur.sets.length, reason: 'same set count');
    await c.load(1);
    await c.done();
    expect(c.view()!.canSwap, isFalse);
    final before = c.snapshot!.exercises.first.exerciseId;
    await c.swapCurrent(swapItem(options.last, c.snapshot!.exercises.first));
    expect(c.snapshot!.exercises.first.exerciseId, before);
  });

  test('undo reaches across exercises and undoes a skip', () async {
    await startPush();
    final first = c.snapshot!.exercises.first;
    for (final _ in first.sets) {
      await c.skipSet();
    }
    expect(c.view()!.lift, 2);
    expect(c.view()!.undoLabel, startsWith('skip: ${first.name} set'));
    await c.undoLast(); // the last skip of exercise 1
    expect(c.view()!.lift, 1);
    expect(c.snapshot!.exercises.first.sets.last.state, eng.SetState.pending);
  });

  test('swap is tied to the exercise it was opened for', () async {
    await startPush();
    final s0 = c.snapshot!;
    final cur = s0.exercises.first;
    final kit = engine.gym(gymId)!.equipmentIds;
    final opt = swapCandidates(catalog, s0, cur.exerciseId, kit).first;
    final ok = await c.swapCurrent(
      swapItem(opt, cur),
      replacingId: 'something-else',
    );
    expect(ok, isFalse);
    expect(c.snapshot!.exercises.first.exerciseId, cur.exerciseId);
    expect(
      await c.swapCurrent(swapItem(opt, cur), replacingId: cur.exerciseId),
      isTrue,
    );
  });

  test('swap candidates exclude timed and distance; from timed uses reps', () {
    final plan = engine.suggest(gymId: gymId, muscleIds: const ['abs']);
    final s = eng.Session.start(plan, nowMs: now, tzOffsetMin: 480);
    final kit = {...engine.gym(gymId)!.equipmentIds, 'rower', 'bike'};
    for (final e in s.exercises) {
      final opts = swapCandidates(catalog, s, e.exerciseId, kit);
      expect(
        opts.where((o) => o.load == 'timed' || o.load == 'distance'),
        isEmpty,
      );
    }
    // A timed entry (as the plank or a timer block arrives): 45 s targets.
    final withTimed = eng.Session.addExercise(
      s,
      const eng.PlannedItem(
        exerciseId: 'plank',
        name: 'Plank',
        unit: eng.LoadUnit.timed,
        sets: [eng.PlannedSet(loadG: null, reps: 45)],
        repLo: 45,
        repHi: 45,
        restS: 60,
        reason: '',
        primary: ['abs'],
      ),
    );
    final timedEx = withTimed.exercises.last;
    expect(timedEx.loadKind, 'timed');
    final opts = swapCandidates(catalog, withTimed, 'plank', kit);
    expect(opts, isNotEmpty);
    final item = swapItem(opts.first, timedEx);
    expect(item.sets.first.reps, 10, reason: 'not 45 seconds as reps');
    expect(item.repLo, 8);
  });
}
