import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/live_screen.dart';

import 'live_fixtures.dart';

/// Small phones (320 dp wide, 580-616 tall, a status bar): the live set,
/// rest and all-done screens fit with the pinned Finish bar, Pause in the
/// header and every link shown (Undo, Swap, Add a set, Skip).
void main() {
  void small(WidgetTester tester, double h) {
    tester.view.physicalSize = Size(640, h * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48);
    tester.view.viewPadding = const FakeViewPadding(top: 48);
    addTearDown(tester.view.reset);
  }

  const undo = 'Single-arm incline dumbbell bench press 10 × 22 kg ea';
  for (final h in [580.0, 616.0]) {
    testWidgets('live screens fit at 320x${h.toInt()}', (tester) async {
      small(tester, h);
      for (final v in [
        liveView(undoLabel: undo, canSwap: true),
        liveView(restLeftS: 60, undoLabel: undo),
        liveView(allDone: true, undoLabel: undo),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: LiveScreen(
              view: v,
              onFinish: () {},
              onPause: () {},
              onUndo: () {},
              onAddSet: () {},
              onSwap: () {},
              onSkipSet: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      // Finish is on screen and tappable without scrolling.
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(
            view: liveView(undoLabel: undo, canSwap: true),
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('live.finish'))).bottom,
        lessThanOrEqualTo(h),
      );
    });
  }
}
