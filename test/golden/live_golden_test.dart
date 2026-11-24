import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
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
          onDoLater: () {},
          onPickNext: (_) {},
          onChangeOrder: () {},
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
  // 0.3 P1: a barbell lift with plate math on (the line is null with the
  // flag off, which is every golden above).
  testWidgets(
    'set with plate line',
    (t) => shot(
      t,
      'plates',
      liveView(
        unit: LoadUnit.kg,
        name: 'Barbell bench press',
        loadG: 62500,
        targetLoadG: 62500,
        plateLine: 'Per side 20 + 1.25',
      ),
    ),
  );
  testWidgets('rest', (t) => shot(t, 'rest', liveView(restLeftS: 75)));
  // X1: rest used to be the Pull blue, so on a Pull day it looked like the
  // set screen it follows.
  testWidgets(
    'rest on a Pull day',
    (t) => shot(
      t,
      'rest_pull',
      liveView(restLeftS: 75, type: WorkoutType.pull, name: 'Lat pulldown'),
    ),
  );
  testWidgets('all done', (t) => shot(t, 'all_done', liveView(allDone: true)));
  testWidgets(
    'set at 1.3x text',
    (t) => shot(t, 'set_large_font', liveView(), textScale: 1.3),
  );

  // 0.3.1 R2: "What's next?" after an exercise (rest screen: the default card
  // and the other exercises), the same choice on the set screen, and the
  // Change order sheet.
  testWidgets(
    'rest, what\'s next',
    (t) => shot(
      t,
      'rest_whats_next',
      liveView(restLeftS: 75, atExerciseEnd: true),
    ),
  );
  testWidgets(
    'rest, what\'s next, 1.3x text',
    (t) => shot(
      t,
      'rest_whats_next_large_font',
      liveView(restLeftS: 75, atExerciseEnd: true),
      textScale: 1.3,
    ),
  );
  testWidgets(
    'set, what\'s next (no rest)',
    (t) => shot(t, 'set_whats_next', liveView(atExerciseEnd: true)),
  );

  Future<void> sheet(WidgetTester tester, String name, double scale) async {
    phone(tester, textScale: scale);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
        home: Builder(
          builder: (ctx) => LiveScreen(
            view: liveView(),
            onDone: () {},
            onChangeOrder: () => showReorderSheet(
              ctx,
              listenable: ValueNotifier(0),
              view: () => liveView(),
              onMove: (_, _) {},
            ),
            onDoLater: () {},
            onReorder: (_, _) {},
            onFinish: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live.change_order')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/live_$name.png'),
    );
  }

  testWidgets('reorder sheet', (t) => sheet(t, 'reorder_sheet', 1.0));
  testWidgets(
    'reorder sheet, 1.3x text',
    (t) => sheet(t, 'reorder_sheet_large_font', 1.3),
  );
}
