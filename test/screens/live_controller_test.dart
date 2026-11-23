import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/workout_port.dart';
import 'package:gym_supreme/screens/live_controller.dart';
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
    await c.load(-1); // nothing below null
    await c.skipRest(); // no rest running
    expect(port.rev, 0);
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
    port.failNext['readPendingJournal'] = WorkoutPortException('io');
    await c.restDelta(15);
    expect(c.view(), isNotNull);
  });
}
