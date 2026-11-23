import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/widgets/body_map.dart';
import 'package:gym_supreme/widgets/lit_widgets.dart';

import 'fixtures.dart';

void main() {
  Widget app(Widget w) => MaterialApp(home: w);

  testWidgets('tapping a row reports its group', (tester) async {
    phone(tester);
    MuscleGroup? got;
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: storyDays,
          selected: const {},
          plan: null,
          onToggleGroup: (g) => got = g,
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Back, ')));
    expect(got?.label, 'Back');
  });

  testWidgets('resting rows stay pickable; no-kit rows do not', (tester) async {
    phone(tester);
    final got = <String>[];
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: {...storyDays, 'chest': const MuscleDays(uncovered: true)},
          selected: const {},
          plan: null,
          onToggleGroup: (g) => got.add(g.label),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Quads, calves, ')));
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Chest, ')));
    expect(got, ['Quads, calves']);
    expect(find.text('NO KIT HERE'), findsOneWidget);
    expect(find.text('1 DAY · RESTING'), findsNWidgets(2));
  });

  testWidgets('nothing picked: start is disabled', (tester) async {
    phone(tester);
    var started = false;
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: storyDays,
          selected: const {},
          plan: null,
          onStart: () => started = true,
        ),
      ),
    );
    expect(find.text('NOTHING PICKED'), findsOneWidget);
    await tester.tap(find.text('PICK A MUSCLE'));
    expect(started, isFalse);
  });

  testWidgets('start button names the type and fires', (tester) async {
    phone(tester);
    var started = false;
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: storyDays,
          selected: pushSelection,
          plan: pushPlan,
          onStart: () => started = true,
        ),
      ),
    );
    expect(find.text('5 LIFTS · 45 MIN'), findsOneWidget);
    expect(find.text('3 × 10 · 22 KG EA'), findsOneWidget);
    await tester.tap(find.text('START PUSH'));
    expect(started, isTrue);
  });

  testWidgets('first run says new on every row and asks for weights', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: firstRunDays,
          selected: pushSelection,
          plan: coldPlan(),
        ),
      ),
    );
    expect(find.text('NEW'), findsNWidgets(8));
    expect(find.text('3 × 10 · SET KG'), findsNWidgets(3));
    expect(find.textContaining('First time on every lift'), findsOneWidget);
  });

  testWidgets('1.3x font collapses the sheet to a peek', (tester) async {
    phone(tester, textScale: 1.3);
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: storyDays,
          selected: pushSelection,
          plan: pushPlan,
        ),
      ),
    );
    expect(find.text('Swipe up or tap to see them'), findsOneWidget);
    expect(find.byType(PlanList), findsNothing);
    await tester.tap(find.text('Swipe up or tap to see them'));
    await tester.pumpAndSettle();
    expect(find.byType(PlanList), findsOneWidget);
    expect(find.text('START PUSH'), findsOneWidget);
  });

  testWidgets('tapping the body toggles that muscle\'s group', (tester) async {
    phone(tester);
    MuscleGroup? got;
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: storyDays,
          selected: const {},
          plan: null,
          onToggleGroup: (g) => got = g,
        ),
      ),
    );
    final map = tester.getRect(find.byType(BodyMap));
    // Front chest, left pec: viewBox (69 - 20, 69) on a 250-wide map.
    final s = map.width / 250;
    await tester.tapAt(map.topLeft + Offset(49 * s, 69 * s));
    expect(got?.label, 'Chest');
  });

  testWidgets('drag reorder reports from and to', (tester) async {
    phone(tester);
    (int, int)? moved;
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: storyDays,
          selected: pushSelection,
          plan: pushPlan,
          onReorder: (a, b) => moved = (a, b),
        ),
      ),
    );
    final grip = find.byType(Grip).first;
    final g = await tester.startGesture(tester.getCenter(grip));
    await tester.pump(kLongPressTimeout);
    await g.moveBy(const Offset(0, 110));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(moved?.$1, 0);
    expect(moved!.$2, greaterThan(0));
  });

  testWidgets('bodyweight-only plan is not called a first time', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(
      app(
        PickerScreen(
          gym: condo,
          days: storyDays,
          selected: const {'abs'},
          plan: const SessionPlanView(
            type: WorkoutType.core,
            minutes: 10,
            items: [
              PlanItem(
                exerciseId: 'plank',
                name: 'Plank',
                sets: 3,
                reps: 45,
                loadG: null,
                unit: LoadUnit.timed,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('First time'), findsNothing);
  });
}
