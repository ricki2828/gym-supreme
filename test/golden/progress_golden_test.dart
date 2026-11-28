import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/progress_model.dart';
import 'package:gym_supreme/screens/progress_screen.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../screens/progress_fixtures.dart';

/// Goldens for the Progress tab (G1b). The whole list is drawn on a tall
/// surface so every section is in the picture.
void main() {
  Future<void> shot(
    WidgetTester tester,
    String name,
    ProgressView v, {
    double textScale = 1.0,
    double height = 2400,
  }) async {
    tester.view.physicalSize = Size(412 * 2.625, height * 2.625);
    tester.view.devicePixelRatio = 2.625;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final home = ProgressScreen(
      view: v,
      onOpenProfile: () {},
      onOpenLift: (_) {},
      onConfirm: (_) {},
    );
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
    'no profile',
    (t) => shot(t, 'progress_no_profile', noProfile(), height: 2100),
  );
  testWidgets(
    'stale bodyweight',
    (t) =>
        shot(t, 'progress_stale_bodyweight', staleBodyweight(), height: 2100),
  );
  testWidgets(
    'rough e1RM',
    (t) => shot(t, 'progress_rough', roughE1rm(), height: 1500),
  );
  testWidgets(
    'first data',
    (t) => shot(t, 'progress_first_data', firstData(), height: 1500),
  );
  testWidgets(
    'big number to confirm',
    (t) => shot(
      t,
      'progress_flagged',
      view(typoWorkouts(), profile: weighed('2026-11-20')),
      height: 1500,
    ),
  );
  testWidgets(
    'text scale 1.3',
    (t) => shot(
      t,
      'progress_large_font',
      staleBodyweight(),
      textScale: 1.3,
      height: 2500,
    ),
  );
}
