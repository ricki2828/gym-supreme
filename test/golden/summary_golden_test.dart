import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/body_screen.dart';
import 'package:gym_supreme/screens/diagnostics_panel.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
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
}
