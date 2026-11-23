import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/services.dart';
import 'package:gym_supreme/main.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';
import 'package:integration_test/integration_test.dart';

/// Widget-driven e2e on a CI emulator (t3x, before 0.2): the real app
/// (bootstrap: SQLite store, Pigeon port, WorkoutService) driven by taps,
/// covering the picker tap path and the post-workout screen that the
/// headless driver (lib/app/e2e_driver.dart) does not touch.
///
/// Each step prints `GymSupreme/ui-e2e {json}` for the CI log.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  void step(String name, [Map<String, Object?> extra = const {}]) =>
      // ignore: avoid_print
      print('GymSupreme/ui-e2e ${jsonEncode({'step': name, ...extra})}');

  testWidgets('pick → start → log → finish → post-workout → history', (
    tester,
  ) async {
    final services = await bootstrap();
    await tester.pumpWidget(GymSupremeApp(services: services));
    await _settle(tester);
    step('boot', {'gyms': services.engine.gyms().length});

    // Item 1, first run only (the headless e2e may have made its gym).
    if (find.text('WHERE ARE YOU TRAINING?').evaluate().isNotEmpty) {
      await _tap(tester, find.textContaining('ON THE FLOOR'));
      step('gym_saved');
    }
    expect(find.text('GYM SUPREME'), findsOneWidget);
    final before = services.engine.history(limit: 1);

    // Items 2-3: the picker, by tapping a row.
    await _tap(tester, find.text('LIGHT SOMETHING UP'));
    expect(find.byType(PickerScreen), findsOneWidget);
    await _tap(tester, find.bySemanticsLabel(RegExp(r'^Chest, ')));
    expect(find.textContaining('LIFTS ·'), findsOneWidget);
    step('picked');
    await _tap(tester, find.text('START PUSH'));

    // Item 4: live logging through the real WorkoutService.
    expect(find.byType(LiveScreen), findsOneWidget);
    if (find.text('Set a weight first').evaluate().isNotEmpty) {
      await _tap(tester, find.bySemanticsLabel('More').last);
    }
    await _tap(tester, find.text('DONE'));
    expect(find.text('SKIP REST'), findsOneWidget, reason: 'auto rest');
    step('set_logged');
    await _tap(tester, find.text('SKIP REST'));

    // Item 6: finish → post-workout (B1 order inside the controller).
    await _tap(tester, find.text('Finish'));
    expect(find.byType(PostWorkoutScreen), findsOneWidget);
    expect(find.text('PUSH, DONE'), findsOneWidget);
    expect(
      find.text('1 MUSCLE LIT').evaluate().isNotEmpty ||
          find.textContaining('MUSCLES LIT').evaluate().isNotEmpty,
      isTrue,
    );
    final top = services.engine.history(limit: 1);
    final journal = await services.port.readPendingJournal();
    step('post_workout', {
      'uuid': top.isEmpty ? null : top.first.uuid,
      'new_row':
          top.isNotEmpty &&
          (before.isEmpty || top.first.uuid != before.first.uuid),
      'journal_gone': journal == null,
    });
    expect(journal, isNull, reason: 'journal deleted after the save');
    expect(top, isNotEmpty);
    if (before.isNotEmpty) expect(top.first.uuid, isNot(before.first.uuid));

    // Back on Today with the new row.
    await _tap(tester, find.text('DONE'));
    expect(find.text('GYM SUPREME'), findsOneWidget);
    expect(find.text('PUSH'), findsWidgets);
    step('ok');
  });
}

/// Real time on a device: settle, but never hang on the 1 s session ticker.
Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
  } on FlutterError {
    // The live screen ticks every second; a bounded pump is enough there.
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await _settle(tester);
  final target = f.first;
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await _settle(tester);
  await tester.tap(target);
  await _settle(tester);
}
