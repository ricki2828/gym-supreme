// 0.3 S1: the starting-weights screen (plan gym-supreme-0.3 §9), over the
// real engine (MemoryStore) and the stub port. Engine rules are covered in
// packages/gym_engine/test/starting_weights_test.dart.
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/starting_weights_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';

void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.MemoryStore store;
  late eng.GymEngine engine;
  late GymDeps deps;
  late String gymId;
  var persists = 0;

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
    final g = engine.gymFromPreset('condo');
    engine.saveGym(g);
    gymId = g.id;
    persists = 0;
    deps = GymDeps(
      engine: engine,
      port: FlakyPort(),
      catalog: catalog,
      appVersion: 'test',
      nowMs: () => now,
      tzOffsetMin: () => 480,
      store: store,
      persist: () => persists++,
    );
  });

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  /// Types [text] into the open number pad and presses Set.
  Future<void> typeAndSet(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('live.keypad')), text);
    await tester.tap(find.byKey(const Key('live.keypad.set')));
    await tester.pumpAndSettle();
  }

  eng.StartingWeightLift firstLift() =>
      engine.startingWeightLifts(gymId: gymId).firstWhere((l) => !l.hasHistory);

  String unitText(eng.StartingWeightLift l) =>
      l.unit == eng.LoadUnit.ea ? 'kg ea' : 'kg';

  Text valueOf(WidgetTester tester, String id) =>
      tester.widget<Text>(find.byKey(Key('start.value.$id')));

  testWidgets('per tap: Today -> screen -> type -> clear -> back', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
    await tester.pumpAndSettle();
    final lifts = engine.startingWeightLifts(gymId: gymId);
    final l = firstLift();

    // Tap 1: the empty-Today entry opens the screen; nothing written.
    expect(find.text('Set starting weights'), findsOneWidget);
    await tapKey(tester, 'today.starting_weights');
    expect(find.byType(StartingWeightsScreen), findsOneWidget);
    expect(find.text('0 of ${lifts.length} set'), findsOneWidget);
    expect(valueOf(tester, l.exerciseId).data, 'Not set');
    expect(find.byKey(Key('start.clear.${l.exerciseId}')), findsNothing);
    expect(persists, 0);

    // Tap 2: the lift opens the number pad with its name; still nothing.
    await tapKey(tester, 'start.row.${l.exerciseId}');
    expect(find.byKey(const Key('live.keypad')), findsOneWidget);
    expect(find.text(l.name), findsWidgets);
    expect(engine.startingWeights(), isEmpty);

    // Tap 3: Cancel writes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.startingWeights(), isEmpty);
    expect(persists, 0);

    // Taps 4-5: type 21.5 and Set: stored in grams, persisted once, shown.
    await tapKey(tester, 'start.row.${l.exerciseId}');
    await typeAndSet(tester, '21,5'); // a comma decimal is accepted
    expect(engine.startingWeights(), {l.exerciseId: 21500});
    expect(persists, 1);
    expect(valueOf(tester, l.exerciseId).data, '21.5 ${unitText(l)}');
    await tester.drag(
      find.byKey(const Key('start.list')),
      const Offset(0, 3000),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 of ${lifts.length} set'), findsOneWidget);

    // Tap 6: the pad reopens on the stored value; a new one replaces it.
    await tapKey(tester, 'start.row.${l.exerciseId}');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('live.keypad')))
          .controller!
          .text,
      '21.5',
    );
    await typeAndSet(tester, '20');
    expect(engine.startingWeights(), {l.exerciseId: 20000});
    expect(persists, 2);
    expect(valueOf(tester, l.exerciseId).data, '20 ${unitText(l)}');

    // Tap 7: clear.
    await tapKey(tester, 'start.clear.${l.exerciseId}');
    expect(engine.startingWeights(), isEmpty);
    expect(persists, 3);
    expect(valueOf(tester, l.exerciseId).data, 'Not set');

    // Taps 8-9: set again, then 0 clears it too.
    await tapKey(tester, 'start.row.${l.exerciseId}');
    await typeAndSet(tester, '30');
    expect(engine.startingWeights(), {l.exerciseId: 30000});
    await tapKey(tester, 'start.row.${l.exerciseId}');
    await typeAndSet(tester, '0');
    expect(engine.startingWeights(), isEmpty);
    expect(persists, 5);

    // Tap 10: set one, then Back: Today shows the count (it rebuilt).
    await tapKey(tester, 'start.row.${l.exerciseId}');
    await typeAndSet(tester, '20');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(StartingWeightsScreen), findsNothing);
    expect(find.text('Starting weights: 1 set'), findsOneWidget);
    // Not history: Today still has no workout.
    expect(engine.history(), isEmpty);
    expect(
      find.textContaining('Nothing logged yet'),
      findsOneWidget,
      reason: 'a starting weight is not a workout',
    );
  });

  testWidgets('the plan for that lift now starts at the starting weight', (
    tester,
  ) async {
    phone(tester);
    final l = firstLift();
    await tester.pumpWidget(
      MaterialApp(
        home: StartingWeightsFlow(engine: engine, gymId: gymId),
      ),
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'start.row.${l.exerciseId}');
    await typeAndSet(tester, '20');
    expect(engine.startingLoad(gymId: gymId, exerciseId: l.exerciseId), 20000);
  });

  test('live: the first set starts at it and the ghost says so', () async {
    final l = firstLift();
    engine.setStartingWeight(l.exerciseId, 20000);
    final plan = engine.suggest(
      gymId: gymId,
      muscleIds: eng.workoutType(l.typeId)!.muscles,
      typeId: l.typeId,
      minutes: 60,
    );
    final item = plan.items.firstWhere((i) => i.exerciseId == l.exerciseId);
    final c = LiveController(
      store: store,
      engine: engine,
      port: FlakyPort(),
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    addTearDown(c.dispose);
    await c.start(
      eng.SessionPlan(
        gymId: plan.gymId,
        typeId: plan.typeId,
        muscles: plan.muscles,
        items: [item],
        uncovered: const [],
        estimatedMinutes: plan.estimatedMinutes,
      ),
    );
    expect(c.snapshot!.currentSet!.targetLoadG, 20000);
    // The live view knows the load came from his starting weight.
    expect(c.view()!.startingWeightG, 20000);
    expect(c.view()!.coldStart, isTrue, reason: 'metric unchanged');
    final g = c.currentGhost()!;
    expect(g.baseline, isTrue);
    expect(g.ghostLoadG, 20000);
  });

  test('live: Do later and a drag keep the starting-weight target', () async {
    final l = firstLift();
    engine.setStartingWeight(l.exerciseId, 20000);
    final plan = engine.suggest(
      gymId: gymId,
      muscleIds: eng.workoutType(l.typeId)!.muscles,
      typeId: l.typeId,
      minutes: 60,
    );
    final item = plan.items.firstWhere((i) => i.exerciseId == l.exerciseId);
    final other = plan.items.firstWhere((i) => i.exerciseId != l.exerciseId);
    final c = LiveController(
      store: store,
      engine: engine,
      port: FlakyPort(),
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    addTearDown(c.dispose);
    await c.start(
      eng.SessionPlan(
        gymId: plan.gymId,
        typeId: plan.typeId,
        muscles: plan.muscles,
        items: [other, item],
        uncovered: const [],
        estimatedMinutes: plan.estimatedMinutes,
      ),
    );
    String currentId() =>
        c.snapshot!.exercises[c.snapshot!.current!.exercise].exerciseId;
    expect(currentId(), other.exerciseId);
    expect(c.view()!.startingWeightG, isNull, reason: 'not seeded by one');
    // Do later: the starting-weight lift becomes current, target intact.
    await c.doLater();
    expect(c.lastError, isNull);
    expect(currentId(), l.exerciseId);
    expect(c.snapshot!.currentSet!.targetLoadG, 20000);
    expect(c.currentGhost()!.baseline, isTrue);
    expect(c.currentGhost()!.ghostLoadG, 20000);
    // Drag the other lift back to the front, then this one again.
    await c.reorderQueue(1, 0);
    expect(currentId(), other.exerciseId);
    await c.reorderQueue(1, 0);
    expect(currentId(), l.exerciseId);
    expect(c.snapshot!.currentSet!.targetLoadG, 20000);
    expect(c.currentGhost()!.baseline, isTrue);
    // Logging it keeps 20 kg; it is the first real set of that lift.
    now += 60000;
    await c.done();
    final done = c.snapshot!.exercises
        .firstWhere((e) => e.exerciseId == l.exerciseId)
        .sets
        .first;
    expect(done.loadG, 20000);
    // Not an engine suggestion: a cold start, out of the one-tap rate.
    expect(done.completion, eng.Completion.coldStart);
  });

  testWidgets('dumbbells read per hand (kg ea), stack lifts plain kg', (
    tester,
  ) async {
    final lifts = engine.startingWeightLifts(gymId: gymId);
    final db = lifts.firstWhere((l) => l.unit == eng.LoadUnit.ea);
    final stack = lifts.firstWhere((l) => l.unit == eng.LoadUnit.kg);
    expect(catalog.exercise(db.exerciseId)!.load, 'dumbbell');
    engine.setStartingWeight(db.exerciseId, 20000);
    engine.setStartingWeight(stack.exerciseId, 30000);
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: StartingWeightsFlow(engine: engine, gymId: gymId),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> reveal(String id) => tester.scrollUntilVisible(
      find.byKey(Key('start.row.$id')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await reveal(db.exerciseId);
    expect(valueOf(tester, db.exerciseId).data, '20 kg ea');
    await tapKey(tester, 'start.row.${db.exerciseId}');
    expect(find.text('kg ea'), findsOneWidget, reason: 'pad suffix');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('start.list')),
      const Offset(0, 5000),
    );
    await tester.pumpAndSettle();
    await reveal(stack.exerciseId);
    expect(valueOf(tester, stack.exerciseId).data, '30 kg');
    await tapKey(tester, 'start.row.${stack.exerciseId}');
    expect(find.text('kg'), findsOneWidget, reason: 'pad suffix');
    expect(find.text('kg ea'), findsNothing);
  });

  testWidgets('Gyms tab: the entry opens the screen for that gym', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('gym.starting_weights')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tapKey(tester, 'gym.starting_weights');
    expect(find.byType(StartingWeightsScreen), findsOneWidget);
    expect(
      find.byKey(Key('start.row.${firstLift().exerciseId}')),
      findsOneWidget,
    );
  });

  testWidgets('history: the Today entry goes, the row says history is used', (
    tester,
  ) async {
    final l = firstLift();
    engine.setStartingWeight(l.exerciseId, 20000);
    store.upsertWorkout(
      eng.WorkoutRecord(
        uuid: 'w1',
        gymId: gymId,
        typeId: l.typeId,
        muscles: const ['chest'],
        startedAtMs: now - 86400000,
        tzOffsetMin: 480,
        endedAtMs: now - 86400000 + 1800000,
        appVersion: 'test',
        sets: [
          eng.SetRecord(
            setId: 'w1:0',
            exerciseId: l.exerciseId,
            exerciseName: l.name,
            exercisePosition: 0,
            setOrdinal: 1,
            kind: eng.SetKind.reps,
            loadG: 16000,
            reps: 10,
            completion: eng.Completion.tapUnchanged,
          ),
        ],
      ),
    );
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today.starting_weights')), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: StartingWeightsFlow(engine: engine, gymId: gymId),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(Key('start.row.${l.exerciseId}'));
    await tester.ensureVisible(row);
    expect(find.text('Logged already: your history is used'), findsOneWidget);
    expect(valueOf(tester, l.exerciseId).data, contains('20 kg'));
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('fits at 320x580 with ${scale}x text, pad included', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 1160);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'today.starting_weights');
      expect(tester.takeException(), isNull);
      // Every lift row, scrolled into view, is a 48 dp target and lays out.
      final lifts = engine.startingWeightLifts(gymId: gymId);
      for (final l in lifts) {
        final row = find.byKey(Key('start.row.${l.exerciseId}'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: l.name);
        expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      }
      final l = lifts.last;
      await tapKey(tester, 'start.row.${l.exerciseId}');
      expect(tester.takeException(), isNull);
      await typeAndSet(tester, '12.5');
      expect(tester.takeException(), isNull);
      expect(engine.startingWeights()[l.exerciseId], 12500);
      final clear = find.byKey(Key('start.clear.${l.exerciseId}'));
      expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
    });
  }
}
