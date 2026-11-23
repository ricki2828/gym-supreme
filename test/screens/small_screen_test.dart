import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/widgets/lit_widgets.dart';

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

  testWidgets('drag-reorder works inside the scrolling sheet at 320x616', (
    tester,
  ) async {
    small(tester, 616);
    (int, int)? moved;
    await tester.pumpWidget(
      MaterialApp(
        home: PickerScreen(
          gym: condo,
          days: storyDays,
          selected: pushSelection,
          plan: longPlan,
          minutes: 60,
          onMinutes: (_) {},
          onStart: () {},
          onReorder: (a, b) => moved = (a, b),
          sheetExtra: const SizedBox(height: 56, child: Text('rotation chip')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final grip = find.byType(Grip).first;
    // Bring the first row to the top of the scrolling middle so a one-row
    // drag stays inside the visible part of the nested scroll.
    await tester.ensureVisible(grip);
    await Scrollable.ensureVisible(tester.element(grip));
    await tester.pumpAndSettle();
    // Both the plan list and the sheet's middle really scroll here, so the
    // drag starts inside two live vertical scrollables (the nested case).
    final inner = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(PlanList),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(inner.position.maxScrollExtent, greaterThan(0));
    final outer = tester.state<ScrollableState>(
      find
          .ancestor(
            of: find.byType(PlanList),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(outer.position.maxScrollExtent, greaterThan(0));
    final g = await tester.startGesture(tester.getCenter(grip));
    await tester.pump(kLongPressTimeout);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 5));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(moved, (0, 1), reason: 'one row down, inside the nested scroll');
  });

  testWidgets('live header on a narrow phone keeps the set count readable', (
    tester,
  ) async {
    small(tester, 616);
    await tester.pumpWidget(MaterialApp(home: LiveScreen(view: liveView())));
    await tester.pumpAndSettle();
    expect(find.text('SET 3 OF 3'), findsOneWidget);
    expect(find.textContaining('LIFT 1 OF 5'), findsNothing);
    expect(
      // Merged with the clock's label in one header node.
      tester.getSemantics(find.text('SET 3 OF 3')).label,
      startsWith('Lift 1 of 5, set 3 of 3'),
      reason: 'screen readers still hear the lift',
    );
  });

  testWidgets('a 360 dp phone at 1.3x also gets the short header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 740),
          textScaler: TextScaler.linear(1.3),
        ),
        child: MaterialApp(home: LiveScreen(view: liveView())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SET 3 OF 3'), findsOneWidget);
  });
}
