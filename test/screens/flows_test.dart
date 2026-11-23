import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';
import 'package:gym_supreme/screens/workout_detail_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';

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
  late eng.MemoryStore store;

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    store = eng.MemoryStore();
    engine = eng.GymEngine(
      catalog: catalog,
      store: store,
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
    await tester.tap(find.bySemanticsLabel('More kilograms'));
    await tester.pumpAndSettle();
    await tapText(tester, 'DONE');
    expect(port.rev, 2);
    expect(find.text('SKIP REST'), findsOneWidget, reason: 'auto rest');
    await tapText(tester, 'SKIP REST');

    // Finish: B1 order, then post-workout.
    now += 20 * 60000;
    await tester.tap(find.byKey(const Key('live.finish')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finish.confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(PostWorkoutScreen), findsOneWidget);
    expect(find.text('PUSH, DONE'), findsOneWidget);
    expect(await port.readPendingJournal(), isNull);
    expect(engine.history(), hasLength(1));
    await tapText(tester, 'DONE');

    // Back on Today with the history row.
    expect(find.text('GYM SUPREME'), findsOneWidget);
    expect(find.text('PUSH'), findsOneWidget);
  });

  testWidgets('review P1-3: Chest + Shoulders + Triceps through the real '
      'picker is a Push session', (tester) async {
    await pumpRoot(tester);
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    await tapText(tester, 'LIGHT SOMETHING UP');
    for (final row in ['Chest', 'Shoulders', 'Triceps']) {
      final f = find.bySemanticsLabel(RegExp('^$row, '));
      await tester.ensureVisible(f.first);
      await tester.tap(f.first);
      await tester.pumpAndSettle();
    }
    expect(find.text('START PUSH'), findsOneWidget);
  });

  testWidgets('review P1-3: Back + Biceps is a Pull session', (tester) async {
    await pumpRoot(tester);
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    await tapText(tester, 'LIGHT SOMETHING UP');
    for (final row in ['Back', 'Biceps, forearms']) {
      final f = find.bySemanticsLabel(RegExp('^${RegExp.escape(row)}, '));
      await tester.ensureVisible(f.first);
      await tester.tap(f.first);
      await tester.pumpAndSettle();
    }
    expect(find.text('START PULL'), findsOneWidget);
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

  testWidgets('a preset adds its kit and keeps his dumbbell pairs', (
    tester,
  ) async {
    final mine = engine
        .gymFromPreset('condo')
        .toggle('adjustable-bench') // he has no bench
        .toggle('kettlebells')
        .withWeights('dumbbells', const [3000, 9000, 26000]);
    engine.saveGym(mine);
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    await tapText(tester, 'Condo gym');
    await tapText(tester, 'SAVE · 6 ON THE FLOOR');
    final g = engine.gym(mine.id)!;
    expect(g.kit['dumbbells']!.weightsG, const [3000, 9000, 26000]);
    expect(g.has('kettlebells'), isTrue, reason: 'his own tick kept');
    expect(g.has('adjustable-bench'), isTrue, reason: 'preset pre-ticks');
  });

  testWidgets('picker minutes feed the suggestion', (tester) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    await pumpRoot(tester);
    await tapText(tester, 'LIGHT SOMETHING UP');
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    await tester.pumpAndSettle();
    final at30 = engine.suggest(
      gymId: engine.gyms().single.id,
      muscleIds: const ['chest'],
      minutes: 30,
    );
    await tester.tap(find.byKey(const Key('picker.minutes.30')));
    await tester.pumpAndSettle();
    expect(
      find.text('${at30.items.length} LIFTS · ${at30.estimatedMinutes} MIN'),
      findsOneWidget,
      reason: 'the sheet shows the 30-minute plan',
    );
    expect(at30.estimatedMinutes, lessThanOrEqualTo(30));
  });

  testWidgets('the picker passes a fixed seed: same list across taps', (
    tester,
  ) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    await pumpRoot(tester);
    await tapText(tester, 'LIGHT SOMETHING UP');
    final chest = find.bySemanticsLabel(RegExp(r'^Chest, '));
    await tester.tap(chest);
    await tester.pumpAndSettle();
    String sheet() => find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .join('|');
    final first = sheet();
    await tester.tap(chest); // off
    await tester.pumpAndSettle();
    await tester.tap(chest); // on again
    await tester.pumpAndSettle();
    expect(sheet(), first);
    final expected = engine.suggest(
      gymId: engine.gyms().single.id,
      muscleIds: const ['chest'],
      minutes: 45,
      seed: engine.counters().sessionsTotal + 1,
    );
    expect(find.text(expected.items.first.name), findsOneWidget);
  });

  testWidgets('weights editor: drop a pair, add one, save to the gym', (
    tester,
  ) async {
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', const [
      2000,
      4000,
      24000,
    ]);
    engine.saveGym(g);
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    final row = find.bySemanticsLabel(RegExp(r'^Dumbbells, 2–24 kg ea'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.runAsync(
      () => Scrollable.ensureVisible(tester.element(row), alignment: 0.5),
    );
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('4 kg ea'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add one'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('live.keypad')), '13.5');
    await tester.tap(find.byKey(const Key('live.keypad.set')));
    await tester.pumpAndSettle();
    await tapText(tester, 'SAVE · 3');
    // Stored by the editor's Save alone: leaving for Today keeps it.
    expect(engine.gym(g.id)!.kit['dumbbells']!.weightsG, const [
      2000,
      13500,
      24000,
    ]);
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(engine.gym(g.id)!.kit['dumbbells']!.weightsG, contains(13500));
  });

  testWidgets('weights editor: fill a range for the cable stack', (
    tester,
  ) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    final row = find.bySemanticsLabel(RegExp(r'^Cable stack, .*app guesses'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.runAsync(
      () => Scrollable.ensureVisible(tester.element(row), alignment: 0.5),
    );
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tapText(tester, 'Clear all');
    await tester.tap(find.text('Fill a range'));
    await tester.pumpAndSettle();
    for (final v in ['4.5', '9', '2.25']) {
      await tester.enterText(find.byKey(const Key('live.keypad')), v);
      await tester.tap(find.byKey(const Key('live.keypad.set')));
      await tester.pumpAndSettle();
    }
    await tapText(tester, 'SAVE · 3');
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    final gym = engine.gyms().single;
    expect(gym.kit['cable-stack']!.weightsG, const [4500, 6750, 9000]);
    expect(
      engine
          .loadSteps(gymId: gym.id, exerciseId: 'cable-crossover')
          .loadsG
          .contains(6750),
      isTrue,
      reason: 'the engine steps along his list now',
    );
  });

  testWidgets('fill a range refuses a zero step with a message', (
    tester,
  ) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    final row = find.bySemanticsLabel(RegExp(r'^Cable stack, \d'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.runAsync(
      () => Scrollable.ensureVisible(tester.element(row), alignment: 0.5),
    );
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Fill a range'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Fill a range'));
    await tester.pumpAndSettle();
    for (final v in ['5', '10', '0.0001']) {
      await tester.enterText(find.byKey(const Key('live.keypad')), v);
      await tester.tap(find.byKey(const Key('live.keypad.set')));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('That range does not work'), findsOneWidget);
  });

  testWidgets('weights rows only for loaded kit; pairs only on dumbbells', (
    tester,
  ) async {
    // No exercise in today's catalog loads kettlebells or the condo's bench
    // with overhead cable, so neither gets a row that would change nothing.
    final g = engine.gymFromPreset('condo').toggle('kettlebells');
    engine.saveGym(g);
    await pumpRoot(tester);
    await tester.tap(find.text('Gyms'));
    await tester.pumpAndSettle();
    final dumb = find.bySemanticsLabel(RegExp(r'^Dumbbells, \d'));
    await tester.scrollUntilVisible(
      dumb,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.getSemantics(dumb).label, contains('pairs'));
    expect(find.bySemanticsLabel(RegExp(r'^Kettlebells, \d')), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp(r'^Bench with overhead cable, \d')),
      findsNothing,
    );
  });

  testWidgets('swap from the live screen picks a same-muscle lift', (
    tester,
  ) async {
    engine.saveGym(engine.gymFromPreset('condo'));
    await pumpRoot(tester);
    await tapText(tester, 'LIGHT SOMETHING UP');
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    await tester.pumpAndSettle();
    await tapText(tester, 'START PUSH');
    final before = port.rev;
    await tester.ensureVisible(find.byKey(const Key('live.swap')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live.swap')));
    await tester.pumpAndSettle();
    expect(find.textContaining('SWAP '), findsOneWidget);
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(port.rev, before + 1, reason: 'one submit for the swap');
    // Pause is in the header, which scrolled up with the list: back to top.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live.pause')));
    await tester.pumpAndSettle();
  });
  testWidgets('a history row opens the workout with its sets (5a)', (
    tester,
  ) async {
    await pumpRoot(tester);
    await tapText(tester, 'SAVE · 5 ON THE FLOOR');
    await tapText(tester, 'LIGHT SOMETHING UP');
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    await tester.pumpAndSettle();
    await tapText(tester, 'START PUSH');
    await tester.tap(find.bySemanticsLabel('More kilograms'));
    await tester.pumpAndSettle();
    await tapText(tester, 'DONE');
    await tapText(tester, 'SKIP REST');
    now += 600000;
    await tester.tap(find.byKey(const Key('live.finish')));
    await tester.pumpAndSettle();
    if (find.byKey(const Key('finish.confirm')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('finish.confirm')));
      await tester.pumpAndSettle();
    }
    await tapText(tester, 'DONE');
    await tester.ensureVisible(find.byType(HistoryRowTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(HistoryRowTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(WorkoutDetailScreen), findsOneWidget);
    final w = store.workout(engine.history().first.uuid)!;
    final logged = w.doneSets.single;
    expect(find.text(logged.exerciseName), findsOneWidget);
    // 'KG EA' for dumbbells, 'KG' for a stack (#42 may lead with one).
    expect(
      find.textContaining('${logged.reps} × ${kg(logged.loadG!)} KG'),
      findsOneWidget,
    );
  });
}
