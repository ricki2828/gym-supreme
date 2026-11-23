import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';

/// The cut-1 loop end to end in widgets: real engine (MemoryStore), t5t's
/// stub port. Items 1-6: setup, pick, suggest, log, resume, post-workout.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.GymEngine engine;
  late FlakyPort port;
  late GymDeps deps;

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    engine = eng.GymEngine(
      catalog: catalog,
      store: eng.MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(5),
    );
    port = FlakyPort();
    deps = GymDeps(
      engine: engine,
      port: port,
      catalog: catalog,
      appVersion: 'test',
      nowMs: () => now,
      tzOffsetMin: () => 480,
    );
  });

  Future<void> pumpRoot(WidgetTester tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final f = find.text(text);
    // With cut-2 flags on, LiveScreen's lazy ListView may not have built
    // Pause/Finish yet (ADD TIMER pushes them down): scroll them in.
    if (f.evaluate().isEmpty && find.byType(Scrollable).evaluate().isNotEmpty) {
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

  testWidgets('first run → pick → log a set → finish → history', (
    tester,
  ) async {
    await pumpRoot(tester);
    // Item 1: first run lands on gym setup with the condo preset ticked.
    expect(find.text('WHERE ARE YOU TRAINING?'), findsOneWidget);
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    expect(engine.gyms(), hasLength(1));
    expect(find.text('GYM SUPREME'), findsOneWidget);

    // Item 2-3: pick chest, a suggestion appears.
    await tapText(tester, 'LIGHT SOMETHING UP');
    expect(find.byType(PickerScreen), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    await tester.pumpAndSettle();
    expect(find.textContaining('LIFTS ·'), findsOneWidget);
    await tapText(tester, 'START PUSH');

    // Item 4: live logging, cold start → pick a weight → Done.
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(port.rev, 0);
    expect(find.text('Set a weight first'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('More').last);
    await tester.pumpAndSettle();
    await tapText(tester, 'DONE');
    expect(port.rev, 2);
    expect(find.text('SKIP REST'), findsOneWidget, reason: 'auto rest');
    await tapText(tester, 'SKIP REST');

    // Finish: B1 order, then post-workout.
    now += 20 * 60000;
    await tapText(tester, 'Finish');
    expect(find.byType(PostWorkoutScreen), findsOneWidget);
    expect(find.text('PUSH, DONE'), findsOneWidget);
    expect(await port.readPendingJournal(), isNull);
    expect(engine.history(), hasLength(1));
    await tapText(tester, 'DONE');

    // Back on Today with the history row.
    expect(find.text('GYM SUPREME'), findsOneWidget);
    expect(find.text('PUSH'), findsOneWidget);
  });

  testWidgets('item 5: pause, then resume from the journal on next open', (
    tester,
  ) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    await pumpRoot(tester);
    await tapText(tester, 'LIGHT SOMETHING UP');
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    await tester.pumpAndSettle();
    await tapText(tester, 'START PUSH');
    await tapText(tester, 'Pause');
    expect(find.textContaining('Paused'), findsOneWidget);

    // A fresh app open (Flutter restarted): the journal is offered as Resume.
    await tester.pumpWidget(const SizedBox());
    await pumpRoot(tester);
    expect(find.textContaining('LIFT 1 OF'), findsOneWidget);
    await tapText(tester, 'Resume');
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(find.text('Set a weight first'), findsOneWidget, reason: 'same set');
    // Leave again: the controller and its 1 s ticker are disposed.
    await tapText(tester, 'Pause');
    expect(find.textContaining('Paused'), findsOneWidget);
  });

  testWidgets('a finished-but-unsaved journal is saved, then deleted', (
    tester,
  ) async {
    final gym = engine.gymFromPreset('condo');
    engine.saveGym(gym);
    final plan = engine.suggest(gymId: gym.id, muscleIds: const ['chest']);
    var s = eng.Session.start(plan, nowMs: now, tzOffsetMin: 480);
    await port.startSession(s.encode());
    final set = s.currentSet!;
    final done = eng.Session.done(s, set.setId, nowMs: now + 1, loadG: 10000);
    await port.submitSnapshot(done.encode(), s.rev);
    s = eng.Session.finish(done, nowMs: now + 2);
    await port.submitSnapshot(s.encode(), done.rev);
    await port.finishSession(); // e.g. finished from the lock screen

    await pumpRoot(tester);
    expect(engine.isStored(s.workoutUuid), isTrue);
    expect(await port.readPendingJournal(), isNull);
    expect(find.textContaining('Paused'), findsNothing);
  });

  Future<void> startChest(WidgetTester tester) async {
    await tapText(tester, 'LIGHT SOMETHING UP');
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    await tester.pumpAndSettle();
    await tapText(tester, 'START PUSH');
  }

  testWidgets('double back from the live screen never pops the home route', (
    tester,
  ) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    await pumpRoot(tester);
    await startChest(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(nav.maybePop());
    unawaited(nav.maybePop());
    await tester.pumpAndSettle();
    unawaited(nav.maybePop());
    await tester.pumpAndSettle();
    expect(find.byType(GymRoot), findsOneWidget);
    expect(find.text('GYM SUPREME'), findsOneWidget);
    expect(find.textContaining('Paused'), findsOneWidget);
  });

  testWidgets('a recovery that throws still opens the app, journal kept', (
    tester,
  ) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    port.failNext['readPendingJournal'] = StateError('disk');
    await pumpRoot(tester);
    expect(find.text('GYM SUPREME'), findsOneWidget);
    expect(find.textContaining('could not be restored'), findsOneWidget);
  });

  testWidgets('gym setup: heavier dumbbells add one pair, keep his own', (
    tester,
  ) async {
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
    ]);
    engine.saveGym(g);
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    expect(find.text('Dumbbells to 24 kg'), findsOneWidget);
    // Centre the dumbbell row, clear of the Save bar pinned under the list.
    // The Heavier step is the last + (the first is Add gym).
    await tester.runAsync(
      () => Scrollable.ensureVisible(
        tester.element(find.text('Heaviest dumbbell pair')),
        alignment: 0.5,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    expect(find.text('Dumbbells to 25 kg'), findsOneWidget);
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    expect(engine.gym(g.id)!.kit['dumbbells']!.weightsG, [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
      25000,
    ]);
  });

  testWidgets('gym setup: down then up gives his own top pair back', (
    tester,
  ) async {
    final own = [for (var kg = 2; kg <= 24; kg += 2) kg * 1000];
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', own);
    engine.saveGym(g);
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Scrollable.ensureVisible(
        tester.element(find.text('Heaviest dumbbell pair')),
        alignment: 0.5,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.remove).last);
    await tester.pumpAndSettle();
    expect(find.text('Dumbbells to 22 kg'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    expect(find.text('Dumbbells to 24 kg'), findsOneWidget);
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    expect(engine.gym(g.id)!.kit['dumbbells']!.weightsG, own);
  });

  testWidgets('switching gyms in setup never carries dumbbell pairs over', (
    tester,
  ) async {
    // Pairs that are not in the engine's default list, so a leak shows.
    final condoGym = engine.gymFromPreset('condo').withWeights(
      'dumbbells',
      const [3000, 9000, 26000],
    );
    engine.saveGym(condoGym);
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Add a gym'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Scrollable.ensureVisible(
        tester.element(find.text('Heaviest dumbbell pair')),
        alignment: 0.5,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    final added = engine.gyms().firstWhere((g) => g.id != condoGym.id);
    final w = added.kit['dumbbells']!.weightsG;
    expect(
      w.any(const [3000, 9000, 26000].contains),
      isFalse,
      reason: "condo's own pairs leaked",
    );
    expect(
      w.every(eng.defaultWeightsG['dumbbell']!.followedBy([27500]).contains),
      isTrue,
    );
  });
}
