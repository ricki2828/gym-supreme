import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';

/// 0.3 L1: snapshots the service writes on its own (lock-screen Done / +1 rep
/// / Skip rest, Kotlin reducer) reach LiveController on the snapshot stream
/// and are adopted: same workout, strictly higher rev, through the intent
/// queue, never once the workout is stored or discarded.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.MemoryStore store;
  late eng.GymEngine engine;
  late FlakyPort port;
  late String gymId;

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    store = eng.MemoryStore();
    engine = eng.GymEngine(
      catalog: catalog,
      store: store,
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
  });

  LiveController controller() {
    final c = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Started, a weight picked, one set logged in the app.
  Future<LiveController> started() async {
    final c = controller();
    await c.start(
      engine.suggest(
        gymId: gymId,
        muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
        typeId: 'push',
      ),
    );
    await c.load(1);
    await c.done();
    return c;
  }

  Future<eng.SessionSnapshot> head() async =>
      eng.SessionSnapshot.decode((await port.readPendingJournal())!);

  /// What the Kotlin reducer journals for a lock-screen Done.
  Future<eng.SessionSnapshot> lockDone() async {
    final h = await head();
    final moved = eng.Session.done(
      h,
      h.currentSet!.setId,
      nowMs: now += 30000,
      source: eng.SetSource.lockscreen,
    );
    port.foreignWrite(moved.encode());
    return moved;
  }

  int doneSets(eng.SessionSnapshot s) => [
    for (final e in s.exercises)
      for (final x in e.sets)
        if (x.state == eng.SetState.done) x,
  ].length;

  test('a lock-screen Done is adopted; the next tap builds on it', () async {
    final c = await started();
    final moved = await lockDone();
    await pumpEventQueue();
    expect(c.snapshot!.rev, moved.rev);
    expect(c.lastError, isNull);
    expect(doneSets(c.snapshot!), 2);
    // +1 rep in the app now applies to the set after the lock-screen one.
    final next = c.snapshot!.currentSet!;
    await c.reps(1);
    expect(c.lastError, isNull, reason: 'not dropped as stale');
    expect(port.rev, moved.rev + 1);
    expect(c.snapshot!.currentSet!.setId, next.setId);
    expect(c.snapshot!.currentSet!.targetReps, (next.targetReps ?? 0) + 1);
  });

  test('a tap queued before the adopt is dropped once, never applied on a '
      'stale base', () async {
    final c = await started();
    final moved = await lockDone();
    // Queued before the stream event is delivered: it runs first, meets
    // stale_rev, resyncs; the adopt that follows is then a no-op.
    final tap = c.done();
    await tap;
    await pumpEventQueue();
    expect(port.rev, moved.rev, reason: 'the queued Done was not journalled');
    expect(c.snapshot!.rev, moved.rev);
    expect(doneSets(c.snapshot!), 2, reason: 'one in the app, one locked');
    // And the controller is usable afterwards.
    await c.done();
    expect(port.rev, moved.rev + 1);
    expect(doneSets(c.snapshot!), 3);
  });

  test(
    'stale, equal, foreign-workout and garbled events are ignored',
    () async {
      final c = await started();
      final before = c.snapshot!;
      final older = before.copyWith(rev: before.rev - 1);
      port.emitForTest(older.encode()); // lower rev
      port.emitForTest(before.encode()); // our own echo
      final other = eng.Session.start(
        engine.suggest(gymId: gymId, muscleIds: const ['chest']),
        nowMs: now,
        tzOffsetMin: 480,
        workoutUuid: '00000000-0000-4000-8000-000000000000',
      ).copyWith(rev: before.rev + 5);
      port.emitForTest(other.encode());
      port.emitForTest('{not json');
      await pumpEventQueue();
      expect(c.snapshot, same(before));
      expect(c.lastError, isNull);
    },
  );

  test('nothing is adopted after a discard', () async {
    final c = await started();
    final h = await head();
    expect(await c.discard(), isTrue);
    expect(await port.readPendingJournal(), isNull);
    // A late lock-screen event of the discarded workout.
    port.emitForTest(
      eng.Session.done(
        h,
        h.currentSet!.setId,
        nowMs: now,
        source: eng.SetSource.lockscreen,
      ).copyWith(rev: h.rev + 5).encode(),
    );
    await pumpEventQueue();
    expect(c.snapshot, isNull);
    expect(c.view(), isNull);
  });

  test('a finished head from elsewhere is stored here (B1)', () async {
    final c = await started();
    final h = await head();
    final fin = eng.Session.finish(h, nowMs: now += 1000);
    port.foreignWrite(fin.encode());
    await pumpEventQueue();
    expect(c.finishedUuid, fin.workoutUuid);
    expect(engine.isStored(fin.workoutUuid), isTrue);
    expect(await port.readPendingJournal(), isNull);
    // A late duplicate of the same head does nothing more.
    port.emitForTest(fin.encode());
    await pumpEventQueue();
    expect(engine.history(), hasLength(1));
  });

  testWidgets('live screen: a lock-screen Done updates the screen, and a '
      'finish from elsewhere leads to the summary', (tester) async {
    phone(tester);
    final deps = GymDeps(
      engine: engine,
      port: port,
      catalog: catalog,
      appVersion: 'test',
      nowMs: () => now,
      tzOffsetMin: () => 480,
      store: store,
    );
    await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
    await tester.pumpAndSettle();
    Future<void> tapText(String text) async {
      final f = find.text(text);
      if (f.evaluate().isEmpty &&
          find.byType(Scrollable).evaluate().isNotEmpty) {
        await tester.scrollUntilVisible(
          f,
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      await tester.ensureVisible(f.first);
      await tester.pumpAndSettle();
      await tester.tap(f.first);
      await tester.pumpAndSettle();
    }

    await tapText('LIGHT SOMETHING UP');
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    await tester.pumpAndSettle();
    await tapText('START PUSH');
    await tester.tap(find.bySemanticsLabel('More kilograms'));
    await tester.pumpAndSettle();
    await tapText('DONE');
    await tapText('SKIP REST');
    expect(find.byType(LiveScreen), findsOneWidget);

    final moved = await lockDone();
    await tester.pumpAndSettle();
    expect(find.byType(LiveScreen), findsOneWidget);
    // The screen moved on with the lock-screen set: the next in-app Done is
    // journalled on top of it, not refused as stale.
    await tapText('SKIP REST');
    expect(port.rev, moved.rev + 1);

    final h = await head();
    port.foreignWrite(eng.Session.finish(h, nowMs: now += 1000).encode());
    await tester.pumpAndSettle();
    expect(find.byType(LiveScreen), findsNothing);
    expect(find.byType(PostWorkoutScreen), findsOneWidget);
    expect(engine.history(), hasLength(1));
  });
}
