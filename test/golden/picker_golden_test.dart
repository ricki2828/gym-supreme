import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../screens/fixtures.dart';

/// Picker goldens against b2-picker.png and the state sheet s1-s6
/// (gym-supreme-jam/png). The Linux CI runner is the reference renderer.
Widget _app(Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
  home: home,
);

void main() {
  Future<void> shot(
    WidgetTester tester,
    String name,
    PickerScreen screen, {
    double textScale = 1.0,
  }) async {
    phone(tester, textScale: textScale);
    await tester.pumpWidget(_app(screen));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(PickerScreen),
      matchesGoldenFile('goldens/picker_$name.png'),
    );
  }

  testWidgets('b2: push picked, legs resting', (tester) async {
    await shot(
      tester,
      'b2',
      PickerScreen(
        gym: condo,
        days: storyDays,
        selected: pushSelection,
        plan: pushPlan,
        restNote: 'Legs trained yesterday, so they rest.',
      ),
    );
  });

  testWidgets('s1: first run, cold start', (tester) async {
    await shot(
      tester,
      's1_first_run',
      PickerScreen(
        gym: condo,
        days: firstRunDays,
        selected: pushSelection,
        plan: coldPlan(),
      ),
    );
  });

  testWidgets('s2: everything resting', (tester) async {
    await shot(
      tester,
      's2_all_resting',
      PickerScreen(
        gym: condo,
        days: allRestingDays,
        selected: const {'abs', 'obliques'},
        plan: corePlan,
      ),
    );
  });

  testWidgets('s3: nothing picked', (tester) async {
    await shot(
      tester,
      's3_none',
      PickerScreen(
        gym: condo,
        days: storyDays,
        selected: const {},
        plan: null,
        restNote: 'Legs trained yesterday, so they rest.',
      ),
    );
  });

  testWidgets('s4: no kit for a picked muscle', (tester) async {
    await shot(
      tester,
      's4_no_kit',
      PickerScreen(
        gym: const GymView(id: 'hotel', name: 'Hotel room', kit: {'bands'}),
        days: {
          ...storyDays,
          'chest': const MuscleDays(days: 5, uncovered: true),
        },
        selected: const {'lats', 'traps', 'lower-back', 'biceps', 'forearms'},
        plan: const SessionPlanView(
          type: WorkoutType.pull,
          minutes: 30,
          uncovered: ['Lats'],
          items: [
            PlanItem(
              exerciseId: 'band-pull-apart',
              name: 'Band pull-apart',
              sets: 3,
              reps: 15,
              loadG: null,
              unit: LoadUnit.bodyweight,
            ),
            PlanItem(
              exerciseId: 'back-extension-floor',
              name: 'Back extension on floor',
              sets: 3,
              reps: 12,
              loadG: null,
              unit: LoadUnit.bodyweight,
            ),
            PlanItem(
              exerciseId: 'band-curl',
              name: 'Band curl',
              sets: 3,
              reps: 12,
              loadG: null,
              unit: LoadUnit.bodyweight,
            ),
            PlanItem(
              exerciseId: 'towel-row',
              name: 'Towel isometric row',
              sets: 3,
              reps: 30,
              loadG: null,
              unit: LoadUnit.timed,
            ),
          ],
        ),
      ),
    );
  });

  testWidgets('s5: long names', (tester) async {
    await shot(
      tester,
      's5_long_names',
      PickerScreen(
        gym: condo,
        days: storyDays,
        selected: pushSelection,
        plan: longNamesPlan,
        restNote: 'Legs trained yesterday, so they rest.',
      ),
    );
  });

  testWidgets('s6: 1.3x font, sheet as a peek', (tester) async {
    await shot(
      tester,
      's6_large_font',
      PickerScreen(
        gym: condo,
        days: storyDays,
        selected: pushSelection,
        plan: pushPlan,
      ),
      textScale: 1.3,
    );
  });
}
