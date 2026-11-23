import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/workout_port.dart';
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';

import 'fixtures.dart';

/// The cut-1 loop end to end in widgets: real engine (MemoryStore), t5t's
/// stub port. Items 1-6: setup, pick, suggest, log, resume, post-workout.
void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.GymEngine engine;
  late StubWorkoutPort port;
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
    port = StubWorkoutPort();
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
}
