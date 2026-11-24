// 0.3 X1: rename and delete a gym. The engine keeps a deleted gym's workouts
// (history rows show "Deleted gym"); a rename shows in history at once.
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/engine_adapter.dart';
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_controller.dart';

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
  late eng.Gym home;
  late eng.Gym away;
  var persists = 0;
  final saved = <String>[];

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
    home = engine.gymFromPreset('condo', name: 'Condo gym');
    away = engine.gymFromPreset('condo', name: 'Basement');
    engine.saveGym(home);
    engine.saveGym(away);
    persists = 0;
    saved.clear();
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

  /// One finished workout at [gymId].
  Future<String> logWorkout(String gymId) async {
    final c = LiveController(
      engine: engine,
      port: FlakyPort(),
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    await c.start(
      engine.suggest(
        gymId: gymId,
        muscleIds: const ['chest', 'triceps'],
        typeId: 'push',
      ),
    );
    await c.load(1);
    await c.done();
    final uuid = await c.finish();
    c.dispose();
    expect(uuid, isNotNull);
    return uuid!;
  }

  Future<void> pump(WidgetTester tester, eng.Gym gym) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: GymFlow(
          key: ValueKey(gym.id),
          deps: deps,
          gym: gym,
          onSaved: saved.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  testWidgets('rename shows in history at once and is saved', (tester) async {
    final uuid = await logWorkout(home.id);
    expect(engine.history().single.gymName, 'Condo gym');
    await pump(tester, home);
    await tapKey(tester, 'gym.rename');
    await tester.enterText(
      find.byKey(const Key('gym.rename.field')),
      '  Flat gym ',
    );
    await tapKey(tester, 'gym.rename.save');
    expect(engine.gym(home.id)!.name, 'Flat gym');
    expect(persists, 1, reason: 'the backup snapshot is refreshed');
    final row = engine.history().single;
    expect(row.uuid, uuid);
    expect(row.gymName, 'Flat gym');
    expect(historyRowOf(row).gymName, 'Flat gym');
    // The card shows it too.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(find.text('FLAT GYM'), findsOneWidget);
  });

  testWidgets('rename keeps the kit as saved: unsaved ticks wait for Save', (
    tester,
  ) async {
    await pump(tester, home);
    await tester.tap(find.text('Kettlebells'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'gym.rename');
    await tester.enterText(find.byKey(const Key('gym.rename.field')), 'Flat');
    await tapKey(tester, 'gym.rename.save');
    expect(engine.gym(home.id)!.has('kettlebells'), isFalse);
    expect(engine.gym(home.id)!.name, 'Flat');
  });

  testWidgets('an empty or unchanged name changes nothing', (tester) async {
    await pump(tester, home);
    await tapKey(tester, 'gym.rename');
    await tester.enterText(find.byKey(const Key('gym.rename.field')), '   ');
    await tapKey(tester, 'gym.rename.save');
    expect(engine.gym(home.id)!.name, 'Condo gym');
    expect(persists, 0);
  });

  testWidgets('delete keeps the workouts; history says Deleted gym', (
    tester,
  ) async {
    final uuid = await logWorkout(away.id);
    final other = await logWorkout(home.id);
    expect(engine.history(), hasLength(2));
    await pump(tester, away);
    await tapKey(tester, 'gym.delete');
    expect(find.text('Delete Basement?'), findsOneWidget);
    await tapKey(tester, 'gym.delete.confirm');
    expect(engine.gym(away.id), isNull);
    expect(engine.gyms().map((g) => g.id), [home.id]);
    expect(persists, 1);
    expect(saved, [home.id], reason: 'the tab moves to a gym that is left');
    // Both workouts are still there; the deleted gym's row has no gym name.
    final rows = {for (final r in engine.history()) r.uuid: r};
    expect(rows.keys, containsAll([uuid, other]));
    expect(rows[uuid]!.gymId, away.id);
    expect(rows[uuid]!.gymName, '');
    expect(historyRowOf(rows[uuid]!).gymName, 'Deleted gym');
    expect(historyRowOf(rows[other]!).gymName, 'Condo gym');
    expect(store.workout(uuid), isNotNull, reason: 'sets kept');
  });

  testWidgets('Keep it leaves the gym alone', (tester) async {
    await pump(tester, away);
    await tapKey(tester, 'gym.delete');
    await tapKey(tester, 'gym.delete.keep');
    expect(engine.gym(away.id), isNotNull);
    expect(saved, isEmpty);
  });

  testWidgets('the only gym cannot be deleted', (tester) async {
    engine.deleteGym(away.id);
    await pump(tester, home);
    expect(find.byKey(const Key('gym.rename')), findsOneWidget);
    expect(find.byKey(const Key('gym.delete')), findsNothing);
  });

  testWidgets('Rename and Delete fit 320x580 at 1.3x text', (tester) async {
    tester.view.physicalSize = const Size(640, 1160);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 48);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        home: GymFlow(deps: deps, gym: away, onSaved: saved.add),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final rename = tester.getRect(find.byKey(const Key('gym.rename')));
    final delete = tester.getRect(find.byKey(const Key('gym.delete')));
    expect(delete.right, lessThanOrEqualTo(320));
    expect(rename.overlaps(delete), isFalse, reason: 'wraps, never overlaps');
  });

  testWidgets('first run: no rename, no delete', (tester) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: GymFlow(deps: deps, firstRun: true, onSaved: saved.add),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gym.rename')), findsNothing);
    expect(find.byKey(const Key('gym.delete')), findsNothing);
  });
}
