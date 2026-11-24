import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/live_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';
import 'live_fixtures.dart';

/// R1: live reorder, "Do later" and the drag list that includes the current
/// exercise (0.3.0). Real engine, stub port.
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
  var disposed = false;
  tearDown(() {
    if (!disposed) c.dispose();
  });

  /// Unmounts the app and disposes the controller (its ticker is a pending
  /// timer testWidgets would flag).
  Future<void> endLive(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    disposed = true;
  }

  Future<void> startPush() => c.start(
    engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
      typeId: 'push',
    ),
  );

  List<String> order() => [for (final e in c.snapshot!.exercises) e.exerciseId];
  String cur() =>
      c.snapshot!.exercises[c.snapshot!.current!.exercise].exerciseId;

  /// One set logged on the first exercise: half done, resting.
  Future<void> halfDone() async {
    await startPush();
    await c.load(1);
    await c.done();
  }

  group('doLater', () {
    test('moves the current exercise to just after the next one', () async {
      await startPush();
      final o = order();
      expect(o.length, greaterThanOrEqualTo(3));
      await c.doLater();
      expect(order(), [o[1], o[0], ...o.skip(2)]);
      expect(cur(), o[1]);
      expect(c.view()!.exerciseName, c.snapshot!.exercises[0].name);
    });

    test(
      'a half-done exercise keeps its logged set and resumes there',
      () async {
        await halfDone();
        final o = order();
        final logged = c.snapshot!.exercises[0].sets[0];
        final rest = c.snapshot!.rest;
        expect(rest, isNotNull);
        await c.doLater();
        expect(order(), [o[1], o[0], ...o.skip(2)]);
        expect(c.snapshot!.exercises[1].sets[0].toJson(), logged.toJson());
        expect(c.snapshot!.rest?.toJson(), rest!.toJson(), reason: 'rest kept');
        // Finish the new current exercise; the first one comes back at set 2.
        var guard = 0;
        while (cur() == o[1] && guard++ < 20) {
          await c.done();
        }
        expect(cur(), o[0]);
        expect(c.snapshot!.currentSet!.setOrdinal, 2);
        expect(c.view()!.set, 2);
      },
    );

    test(
      'goes through the journal: a new controller resumes the same order',
      () async {
        await halfDone();
        await c.doLater();
        final saved = eng.SessionSnapshot.decode(
          (await port.readPendingJournal())!,
        );
        expect([for (final e in saved.exercises) e.exerciseId], order());
        final c2 = LiveController(
          engine: engine,
          port: port,
          nowMs: () => now,
          tzOffsetMin: 480,
          tick: const Duration(days: 1),
        );
        addTearDown(c2.dispose);
        await c2.resume(saved);
        expect(c2.view()!.exerciseName, c.view()!.exerciseName);
        expect(c2.snapshot!.rev, greaterThan(saved.rev - 1));
      },
    );

    test('nothing else waiting: no change, no rev', () async {
      await startPush();
      // Skip everything except the last exercise.
      final n = order().length;
      for (var i = 0; i < n - 1; i++) {
        final sets = c.snapshot!.exercises[c.snapshot!.current!.exercise].sets
            .where((s) => s.state == eng.SetState.pending)
            .length;
        for (var k = 0; k < sets; k++) {
          await c.skipSet();
        }
      }
      expect(c.view()!.queue.length, 1);
      final rev = c.snapshot!.rev;
      await c.doLater();
      expect(c.snapshot!.rev, rev);
    });
  });

  group('per-tap steps (not one jump)', () {
    test('Do later, tap after tap: the order walks, never sticks', () async {
      await startPush();
      final o = order();
      final a = o[0], b = o[1], rest = o.skip(2).toList();
      // [a b ...] -> [b a ...] -> [a b ...] (b is now the current one)
      await c.doLater();
      expect(order(), [b, a, ...rest]);
      expect(cur(), b);
      await c.doLater();
      expect(order(), [a, b, ...rest]);
      expect(cur(), a);
      await c.doLater();
      await c.doLater();
      expect(order(), [a, b, ...rest], reason: 'two taps net to zero');
    });

    test('drag steps through every position and back to net zero', () async {
      await halfDone();
      final o = order();
      final n = o.length;
      // The current exercise (queue index 0) down one place at a time...
      for (var k = 0; k < n - 1; k++) {
        await c.reorderQueue(k, k + 1);
        expect(order().indexOf(o[0]), k + 1, reason: 'step $k');
        expect(
          c.snapshot!.exercises[k + 1].sets[0].state,
          eng.SetState.done,
          reason: 'its logged set stayed with it at step $k',
        );
        expect(cur(), isNot(o[0]), reason: 'not current while later');
      }
      expect(order().last, o[0]);
      // ...and back up one place at a time, ending where it began.
      for (var k = n - 1; k > 0; k--) {
        await c.reorderQueue(k, k - 1);
        expect(order().indexOf(o[0]), k - 1, reason: 'back step $k');
      }
      expect(order(), o);
      expect(cur(), o[0]);
      expect(c.snapshot!.currentSet!.setOrdinal, 2);
    });
  });

  group('screens', () {
    Future<void> pumpLive(WidgetTester tester, {double scale = 1.0}) async {
      phone(tester, textScale: scale);
      // The controller's queue is created in the test body's zone (one made in
      // setUp would never get its microtasks flushed under testWidgets).
      c.dispose();
      disposed = false;
      c = LiveController(
        engine: engine,
        port: port,
        nowMs: () => now,
        tzOffsetMin: 480,
        tick: const Duration(days: 1),
      );
      await startPush();
      await tester.pumpWidget(
        MaterialApp(
          home: LiveFlow(controller: c, catalog: catalog),
        ),
      );
      await tester.pump();
    }

    /// The live list is lazy: scroll a control into the built range.
    Future<void> reveal(WidgetTester tester, Finder f) async {
      if (f.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          f,
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('Do later moves to the next exercise (text x$scale)', (
        tester,
      ) async {
        await pumpLive(tester, scale: scale);
        final first = c.view()!.exerciseName;
        final second = c.snapshot!.exercises[1].name;
        await reveal(tester, find.text('NOW'));
        expect(find.text('NOW'), findsOneWidget);
        final link = find.byKey(const Key('live.do_later'));
        await tester.ensureVisible(link);
        await tester.pumpAndSettle();
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(c.view()!.exerciseName, second);
        expect(c.snapshot!.exercises[1].name, first);
        await endLive(tester);
      });
    }

    testWidgets('the drag list holds the current exercise first', (
      tester,
    ) async {
      await pumpLive(tester);
      final v = c.view()!;
      expect(v.queue.length, v.upNext.length + 1);
      expect(v.queue.first.name, v.exerciseName);
      await reveal(tester, find.text('NOW'));
      expect(find.text('ORDER · DRAG TO REORDER'), findsOneWidget);
      expect(find.text('NOW'), findsOneWidget);
      await endLive(tester);
    });

    testWidgets('Do later fits at 320x580 with 1.3x text', (tester) async {
      tester.view.physicalSize = const Size(640, 1160);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final v in [liveView(), liveView(restLeftS: 60)]) {
        await tester.pumpWidget(
          MaterialApp(
            home: LiveScreen(
              view: v,
              onDoLater: () {},
              onReorder: (_, _) {},
              onFinish: () {},
              onSkipRest: () {},
              onRestDelta: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final link = find.byKey(const Key('live.do_later'));
        if (link.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            link,
            200,
            scrollable: find.byType(Scrollable).first,
          );
        }
        expect(link, findsOneWidget);
        await tester.ensureVisible(link);
        await tester.pumpAndSettle();
        expect(tester.getRect(link).right, lessThanOrEqualTo(320));
      }
    });

    testWidgets('Do later is hidden when nothing else waits', (tester) async {
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(view: liveView(), onDoLater: () {}, onFinish: () {}),
        ),
      );
      expect(find.byKey(const Key('live.do_later')), findsOneWidget);
      // The same screen, a view with canDoLater false.
      final v = liveView();
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(
            view: LiveView(
              type: v.type,
              exerciseName: v.exerciseName,
              lift: v.lift,
              lifts: v.lifts,
              set: v.set,
              sets: v.sets,
              rail: v.rail,
              reps: v.reps,
              loadG: v.loadG,
              unit: v.unit,
              targetReps: v.targetReps,
              targetLoadG: v.targetLoadG,
              restS: v.restS,
              upNext: const [],
              elapsedS: v.elapsedS,
            ),
            onDoLater: () {},
            onFinish: () {},
          ),
        ),
      );
      expect(find.byKey(const Key('live.do_later')), findsNothing);
      expect(find.text('ORDER · DRAG TO REORDER'), findsNothing);
    });

    testWidgets('the row-0 handle is dead while a timer block runs', (
      tester,
    ) async {
      phone(tester);
      Future<int> handles({required bool timer}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: LiveScreen(
              view: liveView(timerBlock: timer),
              onReorder: (_, _) {},
              onFinish: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await reveal(tester, find.text('NOW'));
        return find.byType(ReorderableDragStartListener).evaluate().length;
      }

      final all = await handles(timer: false);
      expect(all, liveView().queue.length);
      expect(await handles(timer: true), all - 1, reason: 'row 0 locked');
      expect(
        find.bySemanticsLabel(RegExp('timer running, cannot be moved')),
        findsOneWidget,
      );
    });
  });
}
