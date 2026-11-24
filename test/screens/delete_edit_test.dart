import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/workout_detail_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';

/// Delete with undo and edit from the history detail (0.2.1 D3), over the
/// real engine (MemoryStore) and the stub port.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.MemoryStore store;
  late eng.GymEngine engine;
  late FlakyPort port;
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
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
    ]);
    engine.saveGym(g);
    gymId = g.id;
    port = FlakyPort();
    persists = 0;
    deps = GymDeps(
      engine: engine,
      port: port,
      catalog: catalog,
      appVersion: 'test',
      nowMs: () => now,
      tzOffsetMin: () => 480,
      store: store,
      persist: () => persists++,
    );
  });

  /// A stored workout with [sets] logged sets, through the real controller.
  Future<String> storeWorkout({int sets = 2}) async {
    final c = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    addTearDown(c.dispose);
    await c.start(
      engine.suggest(
        gymId: gymId,
        muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
        typeId: 'push',
      ),
    );
    await c.load(1);
    for (var i = 0; i < sets; i++) {
      now += 60000;
      await c.done();
    }
    now += 60000;
    final uuid = await c.finish();
    expect(uuid, isNotNull);
    return uuid!;
  }

  Future<void> pumpRoot(WidgetTester tester, {double scale = 1.0}) async {
    phone(tester, textScale: scale);
    await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> openDetail(WidgetTester tester) async {
    final row = find.byType(HistoryRowTile).first;
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(WorkoutDetailScreen), findsOneWidget);
  }

  Future<void> deleteFromDetail(WidgetTester tester) async {
    await tapKey(tester, 'detail.menu');
    await tapKey(tester, 'detail.delete');
    await tapKey(tester, 'delete.confirm');
  }

  group('delete', () {
    for (final scale in [1.0, 1.3]) {
      testWidgets('detail: confirm, row gone, UNDO restores it, persists '
          '(text x$scale)', (tester) async {
        final uuid = await storeWorkout();
        await pumpRoot(tester, scale: scale);
        expect(find.byType(HistoryRowTile), findsOneWidget);
        await openDetail(tester);
        persists = 0;

        // Keep it: nothing changes.
        await tapKey(tester, 'detail.menu');
        await tapKey(tester, 'detail.delete');
        await tapKey(tester, 'delete.keep');
        expect(engine.history(), hasLength(1));
        expect(persists, 0);

        await tapKey(tester, 'detail.menu');
        await tapKey(tester, 'detail.delete');
        await tapKey(tester, 'delete.confirm');
        expect(find.byType(WorkoutDetailScreen), findsNothing);
        expect(find.byType(HistoryRowTile), findsNothing);
        expect(engine.history(), isEmpty);
        expect(persists, 1);
        expect(find.text('Workout deleted'), findsOneWidget);
        expect(find.text('UNDO'), findsOneWidget);

        await tester.tap(find.text('UNDO'));
        await tester.pumpAndSettle();
        expect(engine.history().map((r) => r.uuid), [uuid]);
        expect(find.byType(HistoryRowTile), findsOneWidget);
        expect(persists, 2);
      });
    }

    testWidgets('the undo snackbar goes after 10 s (no undo later)', (
      tester,
    ) async {
      await storeWorkout();
      await pumpRoot(tester);
      await openDetail(tester);
      await deleteFromDetail(tester);
      expect(find.text('UNDO'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('UNDO'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('UNDO'), findsNothing);
      expect(engine.history(), isEmpty);
    });

    testWidgets('long-press a history row deletes it the same way', (
      tester,
    ) async {
      final uuid = await storeWorkout();
      await pumpRoot(tester);
      await tester.longPress(find.byType(HistoryRowTile).first);
      await tester.pumpAndSettle();
      await tapKey(tester, 'delete.confirm');
      expect(engine.history(), isEmpty);
      expect(find.byType(HistoryRowTile), findsNothing);
      await tester.tap(find.text('UNDO'));
      await tester.pumpAndSettle();
      expect(engine.history().single.uuid, uuid);
    });

    testWidgets('PostWorkoutFlow never throws for a deleted workout', (
      tester,
    ) async {
      final uuid = await storeWorkout();
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: PostWorkoutFlow(deps: deps, uuid: uuid),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('This workout is no longer in your history.'),
        findsNothing,
      );
      // Deleted while a route that holds the uuid exists; it is rebuilt.
      engine.deleteWorkout(uuid);
      await tester.pumpWidget(
        MaterialApp(
          home: PostWorkoutFlow(deps: deps, uuid: uuid),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text('This workout is no longer in your history.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('post.gone.back')));
      await tester.pumpAndSettle();
    });

    testWidgets('detail of a workout deleted elsewhere is blank, not a throw', (
      tester,
    ) async {
      final uuid = await storeWorkout();
      engine.deleteWorkout(uuid);
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: WorkoutDetailFlow(deps: deps, uuid: uuid),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(WorkoutDetailScreen), findsNothing);
    });
  });

  group('edit', () {
    eng.WorkoutRecord stored(String uuid) => store.workout(uuid)!;

    testWidgets('change reps: saved, totals and the edited mark update', (
      tester,
    ) async {
      final uuid = await storeWorkout();
      await pumpRoot(tester);
      await openDetail(tester);
      expect(find.textContaining('edited'), findsNothing);
      final first = stored(uuid).sets.first;
      final before = stored(uuid).volumeGReps;
      persists = 0;

      await tapKey(tester, 'set.${first.setId}');
      await tapKey(tester, 'edit.reps');
      await tester.enterText(find.byKey(const Key('live.keypad')), '14');
      await tapKey(tester, 'live.keypad.set');

      final after = stored(uuid);
      expect(after.sets.first.reps, 14);
      expect(after.editedAtMs, isNotNull);
      expect(after.volumeGReps, isNot(before));
      expect(persists, 1);
      expect(find.textContaining('edited'), findsOneWidget);
    });

    testWidgets('change load: typed kg becomes grams', (tester) async {
      final uuid = await storeWorkout();
      await pumpRoot(tester);
      await openDetail(tester);
      final first = stored(uuid).sets.first;
      await tapKey(tester, 'set.${first.setId}');
      await tapKey(tester, 'edit.load');
      await tester.enterText(find.byKey(const Key('live.keypad')), '17.5');
      await tapKey(tester, 'live.keypad.set');
      expect(stored(uuid).sets.first.loadG, 17500);
      expect(persists, 1);
    });

    testWidgets('remove a set asks first, then renumbers', (tester) async {
      final uuid = await storeWorkout(sets: 2);
      await pumpRoot(tester);
      await openDetail(tester);
      final ids = [for (final s in stored(uuid).sets) s.setId];
      expect(ids.length, 2);
      persists = 0;

      await tapKey(tester, 'set.${ids.first}');
      await tapKey(tester, 'edit.remove');
      expect(find.textContaining('Remove set 1?'), findsOneWidget);
      await tapKey(tester, 'remove.keep');
      expect(stored(uuid).sets, hasLength(2));
      expect(persists, 0);

      await tapKey(tester, 'set.${ids.first}');
      await tapKey(tester, 'edit.remove');
      await tapKey(tester, 'remove.confirm');
      final left = stored(uuid).sets;
      expect(left.map((s) => s.setId), [ids.last]);
      expect(left.single.setOrdinal, 1);
      expect(persists, 1);
    });

    testWidgets('removing the only set offers Delete workout instead', (
      tester,
    ) async {
      final uuid = await storeWorkout(sets: 1);
      await pumpRoot(tester);
      await openDetail(tester);
      final only = stored(uuid).sets.single;
      await tapKey(tester, 'set.${only.setId}');
      await tapKey(tester, 'edit.remove');
      expect(find.text('Delete this workout?'), findsOneWidget);
      expect(find.text('Delete workout'), findsOneWidget);
      await tapKey(tester, 'remove.confirm');
      expect(engine.history(), isEmpty);
      expect(find.text('UNDO'), findsOneWidget);
    });

    testWidgets('sheet and dialogs fit at 320x580 with 1.3x text', (
      tester,
    ) async {
      final uuid = await storeWorkout();
      tester.view.physicalSize = const Size(640, 1160);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
      await tester.pumpAndSettle();
      await openDetail(tester);
      final first = stored(uuid).sets.first;
      await tapKey(tester, 'set.${first.setId}');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('edit.remove')), findsOneWidget);
      await tapKey(tester, 'edit.remove');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'remove.keep');
      await tapKey(tester, 'detail.menu');
      await tapKey(tester, 'detail.delete');
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'delete.keep');
    });
  });
}
