import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/workout_port.dart';
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';
import 'live_fixtures.dart';

/// Port that records every call in order, so the tests can prove the order
/// (pause, then delete) and that nothing is submitted after the delete.
class RecordingPort extends FlakyPort {
  final calls = <String>[];
  String? lastSubmitted;

  /// Simulates a lock-screen Finish landing just before the next submit.
  bool finishBeforeNextSubmit = false;

  @override
  Future<int> startSession(String snapshotJson) {
    calls.add('start');
    return super.startSession(snapshotJson);
  }

  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) async {
    if (finishBeforeNextSubmit) {
      finishBeforeNextSubmit = false;
      await super.finishSession();
    }
    final state = (jsonDecode(snapshotJson) as Map)['state'];
    calls.add('submit:$state');
    lastSubmitted = snapshotJson;
    return super.submitSnapshot(snapshotJson, baseRev);
  }

  @override
  Future<void> pauseSession() {
    calls.add('pause');
    return super.pauseSession();
  }

  @override
  Future<String> finishSession() {
    calls.add('finish');
    return super.finishSession();
  }

  @override
  Future<void> deleteJournal(String workoutUuid) {
    calls.add('delete');
    return super.deleteJournal(workoutUuid);
  }
}

Matcher _code(String code) =>
    throwsA(isA<WorkoutPortException>().having((e) => e.code, 'code', code));

void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.MemoryStore store;
  late eng.GymEngine engine;
  late RecordingPort port;
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
    port = RecordingPort();
  });

  LiveController controller() => LiveController(
    engine: engine,
    port: port,
    nowMs: () => now,
    tzOffsetMin: 480,
    tick: const Duration(days: 1),
  );

  eng.SessionPlan plan() => engine.suggest(
    gymId: gymId,
    muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
    typeId: 'push',
  );

  /// Started, one weight picked, one set logged.
  Future<LiveController> withOneSet() async {
    final c = controller();
    addTearDown(c.dispose);
    await c.start(plan());
    await c.load(1);
    await c.done();
    return c;
  }

  group('LiveController.discard', () {
    test('pauses, then deletes the journal; nothing is stored', () async {
      final c = await withOneSet();
      final uuid = c.snapshot!.workoutUuid;
      port.calls.clear();

      expect(await c.discard(), isTrue);

      expect(port.calls, ['submit:paused', 'pause', 'delete']);
      expect(await port.readPendingJournal(), isNull);
      expect(port.running, isFalse);
      expect(engine.history(), isEmpty);
      expect(store.workouts(), isEmpty);
      expect(c.discardedUuid, uuid);
      expect(c.snapshot, isNull);
      expect(c.view(), isNull);
      expect(c.finishedUuid, isNull);
    });

    test('a fresh start is accepted afterwards', () async {
      final c = await withOneSet();
      await c.discard();
      final c2 = controller();
      addTearDown(c2.dispose);
      await c2.start(plan());
      expect(c2.lastError, isNull);
      expect(port.rev, 0);
    });

    test(
      'intents queued before and after never write after the delete',
      () async {
        final c = await withOneSet();
        port.calls.clear();
        final before = [c.done(), c.reps(1), c.skipSet()];
        final d = c.discard();
        final after = [
          c.done(),
          c.load(1),
          c.undoLast(),
          c.addSet(),
          c.restDelta(15),
          c.pause(),
          c.finish(),
        ];
        await Future.wait([...before, d, ...after]);

        final at = port.calls.indexOf('delete');
        expect(at, isNonNegative);
        expect(
          port.calls.sublist(at + 1),
          isEmpty,
          reason: 'no port call at all after the delete: ${port.calls}',
        );
        expect(await port.readPendingJournal(), isNull);
        expect(await d, isTrue);
        expect(c.discardedUuid, isNotNull);
        expect(c.finishedUuid, isNull, reason: 'a late finish must not store');
        expect(engine.history(), isEmpty);
      },
    );

    test('the service refuses a stale snapshot after the delete', () async {
      // Kotlin: LiveSession.submit with no journal head is Journal.submit
      // (current == null) -> not_running, so a write already on its way
      // when the journal goes cannot bring it back. The stub mirrors it.
      final c = await withOneSet();
      final late = port.lastSubmitted!;
      final rev = port.rev;
      await c.discard();
      await expectLater(port.submitSnapshot(late, rev), _code('not_running'));
      await expectLater(
        port.submitSnapshot(late, rev + 1),
        _code('not_running'),
      );
      expect(await port.readPendingJournal(), isNull);
    });

    test(
      'still_running on the delete: stays paused, says why, retry works',
      () async {
        final c = await withOneSet();
        port.failNext['deleteJournal'] = WorkoutPortException('still_running');

        expect(await c.discard(), isFalse);
        expect(c.discardFailed, isTrue);
        expect((c.lastError as WorkoutPortException).code, 'still_running');
        expect(c.discardedUuid, isNull);
        final journal = jsonDecode((await port.readPendingJournal())!) as Map;
        expect(journal['state'], 'paused', reason: 'the workout is not lost');
        expect(c.snapshot!.state, eng.SessionState.paused);

        expect(await c.discard(), isTrue);
        expect(c.discardFailed, isFalse);
        expect(await port.readPendingJournal(), isNull);
      },
    );

    test('a refused pause never deletes the journal', () async {
      final c = await withOneSet();
      port.calls.clear();
      port.failNext['submitSnapshot'] = WorkoutPortException('bad_snapshot');

      expect(await c.discard(), isFalse);
      expect(c.discardFailed, isTrue);
      expect(port.calls.contains('delete'), isFalse);
      expect(await port.readPendingJournal(), isNotNull);
      expect(
        c.snapshot!.state,
        eng.SessionState.active,
        reason: 'still running',
      );
    });

    test('a finished workout cannot be discarded', () async {
      final c = await withOneSet();
      await c.finish();
      expect(await c.discard(), isFalse);
      expect(engine.history(), hasLength(1));
    });
  });

  group('screens', () {
    Widget app(Widget w) => MaterialApp(home: w);

    Future<void> tapKey(WidgetTester tester, String key) async {
      final f = find.byKey(Key(key));
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('Finish confirm offers Discard behind a second confirm '
          '(text x$scale)', (tester) async {
        phone(tester, textScale: scale);
        var discarded = 0;
        var finished = 0;
        await tester.pumpWidget(
          app(
            LiveScreen(
              view: liveView(doneSets: 2, leftSets: 7),
              onFinish: () => finished++,
              onDiscard: () => discarded++,
            ),
          ),
        );
        await tapKey(tester, 'live.finish');
        expect(find.byKey(const Key('finish.discard')), findsOneWidget);
        // Keep it on the second confirm: nothing happens.
        await tapKey(tester, 'finish.discard');
        expect(find.text('2 sets will be lost.'), findsOneWidget);
        await tapKey(tester, 'discard.keep');
        expect(discarded, 0);
        // Confirm.
        await tapKey(tester, 'live.finish');
        await tapKey(tester, 'finish.discard');
        await tapKey(tester, 'discard.confirm');
        expect(discarded, 1);
        expect(finished, 0);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Finish with nothing logged offers Discard, not Finish', (
      tester,
    ) async {
      phone(tester);
      var discarded = 0;
      var finished = 0;
      await tester.pumpWidget(
        app(
          LiveScreen(
            view: liveView(doneSets: 0, leftSets: 9),
            onFinish: () => finished++,
            onDiscard: () => discarded++,
          ),
        ),
      );
      await tapKey(tester, 'live.finish');
      expect(find.text('Nothing logged'), findsOneWidget);
      expect(find.byKey(const Key('finish.confirm')), findsNothing);
      await tapKey(tester, 'finish.keep');
      expect(discarded + finished, 0);
      await tapKey(tester, 'live.finish');
      await tapKey(tester, 'finish.nothing_discard');
      expect(discarded, 1);
      expect(finished, 0);
    });

    testWidgets(
      'every set skipped (all done, none logged) also offers Discard',
      (tester) async {
        phone(tester);
        var discarded = 0;
        await tester.pumpWidget(
          app(
            LiveScreen(
              view: liveView(allDone: true, doneSets: 0),
              onFinish: () {},
              onDiscard: () => discarded++,
            ),
          ),
        );
        await tester.tap(find.text('FINISH'));
        await tester.pumpAndSettle();
        expect(find.text('Nothing logged'), findsOneWidget);
        await tapKey(tester, 'finish.nothing_discard');
        expect(discarded, 1);
      },
    );

    testWidgets('all sets logged: Finish stays one tap (no Discard prompt)', (
      tester,
    ) async {
      phone(tester);
      var finished = 0;
      await tester.pumpWidget(
        app(
          LiveScreen(
            view: liveView(allDone: true, doneSets: 5),
            onFinish: () => finished++,
            onDiscard: () {},
          ),
        ),
      );
      await tester.tap(find.text('FINISH'));
      await tester.pumpAndSettle();
      expect(finished, 1);
    });

    testWidgets('dialogs fit at 320x580 with 1.3x text', (tester) async {
      tester.view.physicalSize = const Size(640, 1160);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final v in [
        liveView(doneSets: 2, leftSets: 7),
        liveView(doneSets: 0, leftSets: 9),
      ]) {
        await tester.pumpWidget(
          app(LiveScreen(view: v, onFinish: () {}, onDiscard: () {})),
        );
        await tapKey(tester, 'live.finish');
        expect(tester.takeException(), isNull);
        final discard = find.byKey(
          Key(v.doneSets == 0 ? 'finish.nothing_discard' : 'finish.discard'),
        );
        expect(discard, findsOneWidget);
        expect(
          tester.getRect(discard).right,
          lessThanOrEqualTo(320),
          reason: 'inside the screen',
        );
        await tapKey(tester, 'finish.keep');
      }
    });

    // ---- the whole flow, real engine, recording stub port -------------------

    late GymDeps deps;
    setUp(() {
      deps = GymDeps(
        engine: engine,
        port: port,
        catalog: catalog,
        appVersion: 'test',
        nowMs: () => now,
        tzOffsetMin: () => 480,
        store: store,
      );
    });

    Future<void> pumpRoot(WidgetTester tester) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
      await tester.pumpAndSettle();
    }

    Future<void> tapText(WidgetTester tester, String text) async {
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

    Future<void> startChest(WidgetTester tester) async {
      await tapText(tester, 'LIGHT SOMETHING UP');
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
      await tester.pumpAndSettle();
      await tapText(tester, 'START PUSH');
    }

    Future<void> logOneSet(WidgetTester tester) async {
      await tester.tap(find.bySemanticsLabel('More kilograms'));
      await tester.pumpAndSettle();
      await tapText(tester, 'DONE');
      await tapText(tester, 'SKIP REST');
    }

    /// A paused workout with one set logged, then a fresh app open.
    Future<void> pausedAndReopened(WidgetTester tester) async {
      await pumpRoot(tester);
      await startChest(tester);
      await logOneSet(tester);
      await tapText(tester, 'Pause');
      await tester.pumpWidget(const SizedBox());
      await pumpRoot(tester);
      expect(find.textContaining('LIFT 1 OF'), findsOneWidget);
    }

    for (final scale in [1.0, 1.3]) {
      testWidgets('Resume card: Keep it leaves it, Discard removes it '
          '(text x$scale)', (tester) async {
        await pausedAndReopened(tester);
        phone(tester, textScale: scale);
        await tester.pumpAndSettle();
        port.calls.clear();

        await tapText(tester, 'Discard workout');
        expect(find.text('Discard this workout?'), findsOneWidget);
        expect(find.text('1 set will be lost.'), findsOneWidget);
        await tapKey(tester, 'discard.keep');
        expect(find.textContaining('LIFT 1 OF'), findsOneWidget);
        expect(port.calls.contains('delete'), isFalse);

        await tapText(tester, 'Discard workout');
        await tapKey(tester, 'discard.confirm');
        expect(find.textContaining('LIFT 1 OF'), findsNothing);
        expect(find.text('Workout discarded.'), findsOneWidget);
        expect(port.calls.where((c) => c == 'delete'), hasLength(1));
        expect(await port.readPendingJournal(), isNull);
        expect(engine.history(), isEmpty);
        // Start is enabled again.
        await tapText(tester, 'LIGHT SOMETHING UP');
        expect(find.byType(PickerScreen), findsOneWidget);
      });
    }

    testWidgets('Resume card: a failed delete keeps the card and says so', (
      tester,
    ) async {
      await pausedAndReopened(tester);
      port.failNext['deleteJournal'] = WorkoutPortException('io_error');
      await tapText(tester, 'Discard workout');
      await tapKey(tester, 'discard.confirm');
      expect(find.textContaining('LIFT 1 OF'), findsOneWidget);
      expect(
        find.textContaining('Could not discard: io_error'),
        findsOneWidget,
      );
      expect(await port.readPendingJournal(), isNotNull);
    });

    testWidgets(
      'live: Finish, Discard workout, Discard leaves; nothing stored',
      (tester) async {
        await pumpRoot(tester);
        await startChest(tester);
        await logOneSet(tester);
        port.calls.clear();
        await tester.tap(find.byKey(const Key('live.finish')));
        await tester.pumpAndSettle();
        await tapKey(tester, 'finish.discard');
        await tapKey(tester, 'discard.confirm');

        expect(find.byType(LiveScreen), findsNothing);
        expect(find.text('GYM SUPREME'), findsOneWidget);
        expect(
          find.textContaining('LIFT 1 OF'),
          findsNothing,
          reason: 'no Resume',
        );
        final at = port.calls.indexOf('delete');
        expect(port.calls.sublist(0, at + 1).last, 'delete');
        expect(port.calls.indexOf('pause'), lessThan(at));
        expect(port.calls.contains('finish'), isFalse);
        expect(port.calls.sublist(at + 1), isEmpty);
        expect(await port.readPendingJournal(), isNull);
        expect(engine.history(), isEmpty);
      },
    );

    testWidgets('live: zero sets, Finish asks "Nothing logged"', (
      tester,
    ) async {
      await pumpRoot(tester);
      await startChest(tester);
      await tester.tap(find.byKey(const Key('live.finish')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing logged'), findsOneWidget);
      await tapKey(tester, 'finish.keep');
      expect(find.byType(LiveScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('live.finish')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'finish.nothing_discard');
      expect(find.byType(LiveScreen), findsNothing);
      expect(await port.readPendingJournal(), isNull);
      expect(engine.history(), isEmpty);
    });

    testWidgets(
      'live: a lock-screen finish landing mid-discard shows the summary',
      (tester) async {
        await pumpRoot(tester);
        await startChest(tester);
        await logOneSet(tester);
        await tester.tap(find.byKey(const Key('live.finish')));
        await tester.pumpAndSettle();
        await tapKey(tester, 'finish.discard');
        // Between the confirm and the paused submit the workout finishes
        // elsewhere: the discard loses, the workout is stored, and the live
        // screen leaves for its summary instead of hanging.
        port.finishBeforeNextSubmit = true;
        await tapKey(tester, 'discard.confirm');
        expect(find.byType(LiveScreen), findsNothing);
        expect(find.byType(PostWorkoutScreen), findsOneWidget);
        expect(engine.history(), hasLength(1));
      },
    );

    testWidgets('live: a refused pause stays on the live screen', (
      tester,
    ) async {
      await pumpRoot(tester);
      await startChest(tester);
      await logOneSet(tester);
      port.failNext['submitSnapshot'] = WorkoutPortException('bad_snapshot');
      await tester.tap(find.byKey(const Key('live.finish')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'finish.discard');
      await tapKey(tester, 'discard.confirm');

      expect(find.byType(LiveScreen), findsOneWidget);
      expect(await port.readPendingJournal(), isNotNull);
      expect(port.calls.contains('delete'), isFalse);
      // Still usable: Pause leaves normally, with no "could not discard".
      await tapText(tester, 'Pause');
      expect(find.byType(LiveScreen), findsNothing);
      expect(find.textContaining('Could not discard'), findsNothing);
      expect(find.textContaining('LIFT 1 OF'), findsOneWidget);
    });

    testWidgets('a finished-but-unsaved card has no Discard', (tester) async {
      await pumpRoot(tester);
      await startChest(tester);
      await logOneSet(tester);
      // The finished snapshot is journalled, then the save fails.
      port.failNext['finishSession'] = WorkoutPortException('io_error');
      await tester.tap(find.byKey(const Key('live.finish')));
      await tester.pumpAndSettle();
      await tapKey(tester, 'finish.confirm');
      expect(find.byType(LiveScreen), findsOneWidget);
      // Finished: no Discard anywhere on the live screen.
      expect(find.byKey(const Key('finish.discard')), findsNothing);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(find.textContaining('Finished but not saved'), findsOneWidget);
      expect(find.text('Discard workout'), findsNothing);
    });

    testWidgets('the Resume card dialog fits at 320x580 with 1.3x text', (
      tester,
    ) async {
      await pausedAndReopened(tester);
      tester.view.physicalSize = const Size(640, 1160);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await tapText(tester, 'Discard workout');
      expect(tester.takeException(), isNull);
      expect(find.text('1 set will be lost.'), findsOneWidget);
      final confirm = find.byKey(const Key('discard.confirm'));
      expect(tester.getRect(confirm).right, lessThanOrEqualTo(320));
      await tapKey(tester, 'discard.confirm');
      expect(find.textContaining('LIFT 1 OF'), findsNothing);
    });

    testWidgets(
      'live: a failed delete returns to Today with Resume and a note',
      (tester) async {
        await pumpRoot(tester);
        await startChest(tester);
        await logOneSet(tester);
        port.failNext['deleteJournal'] = WorkoutPortException('still_running');
        await tester.tap(find.byKey(const Key('live.finish')));
        await tester.pumpAndSettle();
        await tapKey(tester, 'finish.discard');
        await tapKey(tester, 'discard.confirm');

        expect(find.byType(LiveScreen), findsNothing);
        expect(
          find.textContaining('Could not discard: still_running'),
          findsOneWidget,
        );
        expect(
          find.textContaining('LIFT 1 OF'),
          findsOneWidget,
          reason: 'Resume',
        );
        expect(await port.readPendingJournal(), isNotNull);
      },
    );
  });
}
