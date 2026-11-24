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
/// Steps that end on a platform call (journal read, service start, submit,
/// finish + fsync + save + delete) schedule no frames while they run, so
/// every such step waits for the widget it expects, not for "settled".
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
    expect(
      services.restorePending,
      isFalse,
      reason: 'booted on a temporary store: nothing here would be kept',
    );
    await tester.pumpWidget(GymSupremeApp(services: services));

    // Boot: recovery reads the journal over Pigeon before Today shows.
    final today = find.text('GYM SUPREME');
    final setup = find.text('WHERE ARE YOU TRAINING?');
    await _waitFor(
      tester,
      'boot',
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data == 'GYM SUPREME' || w.data == 'WHERE ARE YOU TRAINING?'),
      ),
    );
    step('boot', {'gyms': services.engine.gyms().length});

    // Item 1, first run only (the headless e2e may have made its gym).
    if (setup.evaluate().isNotEmpty) {
      await _tap(tester, find.textContaining('ON THE FLOOR'));
      await _waitFor(tester, 'gym_saved', today);
      step('gym_saved');
    }
    if (find.text('Resume').evaluate().isNotEmpty) {
      fail('pending journal from a previous run: Start is disabled');
    }
    final before = services.engine.history(limit: 1);

    // Items 2-3: the picker, by tapping a row.
    await _tap(tester, find.text('LIGHT SOMETHING UP'));
    await _waitFor(tester, 'picker', find.byType(PickerScreen));
    final chest = find.bySemanticsLabel(RegExp(r'^Chest, '));
    expect(chest, findsOneWidget);
    expect(
      tester.getSemantics(chest).label.contains('no kit'),
      isFalse,
      reason: 'chest must be trainable at this gym',
    );
    await _tap(tester, chest);
    await _waitFor(tester, 'plan', find.textContaining('LIFTS ·'));
    step('picked');
    await _tap(tester, find.text('START PUSH'));

    // Item 4: live logging through the real WorkoutService.
    await _waitFor(tester, 'live', find.byType(LiveScreen));
    // The lazy list may not have built DONE's sub line yet (the Change order
    // row sits above it now): bring DONE in before reading it.
    await _settle(tester);
    final doneBtn = find.text('DONE');
    if (doneBtn.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        doneBtn,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(doneBtn.first);
    await _settle(tester);
    if (find.text('Set a weight first').evaluate().isNotEmpty) {
      // DONE was scrolled in above the stepper: back to the top for it.
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 1500),
        3000,
      );
      await _settle(tester);
      await _tap(tester, find.bySemanticsLabel('More kilograms'));
      await _waitFor(tester, 'weight', find.textContaining('first time'));
    }
    await _tap(tester, find.text('DONE'));
    await _waitFor(tester, 'rest', find.text('SKIP REST'));
    step('set_logged');
    await _tap(tester, find.text('SKIP REST'));
    // Back on the set (DONE), or all sets logged (FINISH screen).
    await _waitFor(
      tester,
      'after_rest',
      find.byWidgetPredicate(
        (w) => w is Text && (w.data == 'DONE' || w.data == 'FINISH'),
      ),
    );

    // Item 6: finish → post-workout (B1 order inside the controller).
    // Finish is pinned under the list (item 2); with sets left it asks.
    final allDone = find.text('FINISH').evaluate().isNotEmpty;
    await _tap(
      tester,
      allDone ? find.text('FINISH') : find.byKey(const Key('live.finish')),
    );
    if (!allDone) {
      await _waitFor(
        tester,
        'confirm',
        find.byKey(const Key('finish.confirm')),
      );
      await _tap(tester, find.byKey(const Key('finish.confirm')));
    }
    await _waitFor(tester, 'post', find.byType(PostWorkoutScreen));
    expect(find.text('PUSH, DONE'), findsOneWidget);

    final top = services.engine.history(limit: 1);
    final journal = await services.port.readPendingJournal();
    expect(top, isNotEmpty);
    final row = top.first;
    final summary = services.engine.summary(row.uuid);
    step('post_workout', {
      'uuid': row.uuid,
      'new_row': before.isEmpty || row.uuid != before.first.uuid,
      'type': row.typeId,
      'sets': row.setCount,
      'lit': summary.musclesLit,
      'journal_gone': journal == null,
    });
    expect(journal, isNull, reason: 'journal deleted after the save');
    if (before.isNotEmpty) expect(row.uuid, isNot(before.first.uuid));
    expect(row.typeId, 'push');
    expect(row.setCount, 1);
    expect(summary.musclesLit, contains('chest'));

    // Back on Today.
    await _tap(tester, find.text('DONE'));
    await _waitFor(tester, 'today', today);
    step('ok');
  });
}

/// Pumps every 100 ms until [f] matches, or fails naming [stepName].
Future<void> _waitFor(
  WidgetTester tester,
  String stepName,
  Finder f, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
  fail(
    'ui-e2e: step $stepName did not show $f within ${timeout.inSeconds} s; '
    'on screen: ${_texts()}',
  );
}

/// The visible texts, for a failure message.
String _texts() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data ?? '')
    .where((t) => t.isNotEmpty)
    .take(40)
    .join(' | ');

/// Real time on a device: settle animations, never hang on the 1 s ticker.
Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
  } on FlutterError {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await _settle(tester);
  // Not built yet (low in a lazy list): scroll it in first. Check the plain
  // finder: `.first` on an empty finder throws instead of matching nothing.
  if (f.evaluate().isEmpty) {
    try {
      await tester.scrollUntilVisible(
        f,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    } on Object {
      fail('ui-e2e: nothing matches $f; on screen: ${_texts()}');
    }
  }
  final target = f.first;
  await tester.ensureVisible(target);
  await _settle(tester);
  await tester.tap(target);
  await _settle(tester);
}
