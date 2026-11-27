import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/body_screen.dart';
import 'package:gym_supreme/app/self_checks.dart';
import 'package:gym_supreme/screens/diagnostics_panel.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/screens/workout_detail_screen.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../screens/diagnostics_fixtures.dart' as diag;
import '../screens/fixtures.dart';
import '../screens/summary_fixtures.dart';

/// Goldens for post-workout (b-post), history, resume card (b-home) and the
/// Body tab (b2-body).
void main() {
  Future<void> shot(WidgetTester tester, String name, Widget home) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byWidget(home),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets(
    'post-workout',
    (t) => shot(
      t,
      'post_workout',
      PostWorkoutScreen(view: pushDone, onDone: () {}),
    ),
  );
  testWidgets(
    'history',
    (t) => shot(t, 'history', HistoryScreen(rows: historyRows, onOpen: (_) {})),
  );
  testWidgets(
    'body tab',
    (t) => shot(
      t,
      'body',
      const BodyScreen(muscles: bodyMuscles, weeklyStreak: 6),
    ),
  );
  testWidgets(
    'resume card',
    (t) => shot(
      t,
      'resume_card',
      Scaffold(
        backgroundColor: Lit.ground,
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ResumeCard(
              type: WorkoutType.legs,
              lift: 3,
              lifts: 6,
              set: 2,
              pausedWhen: 'Sunday',
              onResume: () {},
              onDiscard: () {},
            ),
          ),
        ),
      ),
    ),
  );
  testWidgets(
    'diagnostics',
    (t) => shot(
      t,
      'diagnostics',
      Scaffold(
        backgroundColor: Lit.ground,
        body: SafeArea(
          child: DiagnosticsPanel(
            appVersion: '0.1.0+12 (abc1234)',
            gate: diag.gate,
            native: diag.native,
            device: diag.device,
            onExportJson: () {},
            onExportCsv: () {},
            onOpenNotificationSettings: () {},
            onOpenSpike: () {},
          ),
        ),
      ),
    ),
  );
  testWidgets('diagnostics self-checks', (t) {
    // Built by the app's own verdict code from counters shaped like the
    // native rings, so titles and wording cannot drift from the app.
    const now = 1790000000000;
    final native = <String, int>{
      'sc_cue_slots': 60,
      'sc_rest_slots': 30,
      'sc_lock_slots': 20,
      for (var i = 1; i <= 8; i++) ...{
        'sc_cue_0${i}_seq': i,
        'sc_cue_0${i}_wall': now - 60000 + i * 1000,
        'sc_cue_0${i}_late': i == 3 ? 340 : 40,
        'sc_cue_0${i}_flags': 0,
        'sc_cue_0${i}_blk': 7,
      },
      'sc_rest_01_seq': 1,
      'sc_rest_01_wall': now - 30000,
      'sc_rest_01_late': 20,
      'sc_rest_01_flags': 32,
      'sc_rest_01_blk': 0,
      for (var i = 1; i <= 2; i++) ...{
        'sc_lock_0${i}_seq': i,
        'sc_lock_0${i}_wall': now - 20000 + i * 1500,
        'sc_lock_0${i}_act': 1,
        'sc_lock_0${i}_out': 0,
        'sc_lock_0${i}_set': 9,
        'sc_lock_0${i}_src': i - 1,
      },
    };
    return shot(
      t,
      'diagnostics_self_checks',
      Scaffold(
        backgroundColor: Lit.ground,
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: SelfChecksSection(
            checks: evaluateSelfChecks(
              native,
              timers: true,
              lockDone: true,
              health: true,
              nowMs: now,
            ),
          ),
        ),
      ),
    );
  });
  testWidgets(
    'workout detail',
    (t) => shot(t, 'workout_detail', WorkoutDetailScreen(view: pushDetail)),
  );
}
