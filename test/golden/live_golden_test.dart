import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../screens/fixtures.dart';
import '../screens/live_fixtures.dart';

/// Live logging goldens against b-live.png (condo kit: dumbbells, no plate
/// line; plate math is phase 2).
void main() {
  Future<void> shot(
    WidgetTester tester,
    String name,
    LiveView v, {
    double textScale = 1.0,
  }) async {
    phone(tester, textScale: textScale);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
        home: LiveScreen(
          view: v,
          onReps: (_) {},
          onLoad: (_) {},
          onDone: () {},
          onRestDelta: (_) {},
          onSkipRest: () {},
          onReorder: (_, _) {},
          onPause: () {},
          onFinish: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LiveScreen),
      matchesGoldenFile('goldens/live_$name.png'),
    );
  }

  testWidgets('set, as planned', (t) => shot(t, 'set', liveView()));
  testWidgets(
    'cold start',
    (t) => shot(t, 'cold_start', liveView(loadG: 12000, targetLoadG: null)),
  );
  testWidgets('rest', (t) => shot(t, 'rest', liveView(restLeftS: 75)));
  testWidgets('all done', (t) => shot(t, 'all_done', liveView(allDone: true)));
  testWidgets(
    'set at 1.3x text',
    (t) => shot(t, 'set_large_font', liveView(), textScale: 1.3),
  );
}
