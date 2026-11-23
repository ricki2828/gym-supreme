import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';

import 'fixtures.dart';
import 'live_fixtures.dart';

/// Small phones (320 dp wide, 580-616 tall, a status bar): no overflow on
/// the picker with a long plan, the minutes chips and the rotation chip, or
/// on the live set and rest screens (ui-e2e on #42 hit 26 px at 320x616).
void main() {
  void small(WidgetTester tester, double h) {
    tester.view.physicalSize = Size(640, h * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 48);
    addTearDown(tester.view.reset);
  }

  final longPlan = SessionPlanView(
    type: WorkoutType.push,
    minutes: 60,
    items: [...longNamesPlan.items, ...pushPlan.items],
  );

  for (final h in [580.0, 616.0]) {
    testWidgets('picker sheet fits at 320x${h.toInt()}', (tester) async {
      small(tester, h);
      await tester.pumpWidget(
        MaterialApp(
          home: PickerScreen(
            gym: condo,
            days: storyDays,
            selected: pushSelection,
            plan: longPlan,
            restNote: 'Legs trained yesterday, so they rest.',
            minutes: 60,
            onMinutes: (_) {},
            onStart: () {},
            onReorder: (_, _) {},
            sheetExtra: const SizedBox(
              height: 56,
              child: Text('rotation chip'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('START PUSH'), findsOneWidget);
      // START stays on screen, tappable.
      expect(
        tester.getRect(find.text('START PUSH')).bottom,
        lessThanOrEqualTo(h),
      );
    });

    testWidgets('live set and rest fit at 320x${h.toInt()}', (tester) async {
      small(tester, h);
      for (final v in [liveView(), liveView(restLeftS: 60)]) {
        await tester.pumpWidget(
          MaterialApp(
            home: LiveScreen(
              view: v,
              onFinish: () {},
              onPause: () {},
              onSkipSet: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}
