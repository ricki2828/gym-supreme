import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/body_screen.dart';
import 'package:gym_supreme/screens/diagnostics_panel.dart';
import 'package:gym_supreme/screens/gym_setup_screen.dart';
import 'package:gym_supreme/screens/history_screen.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/picker_screen.dart';
import 'package:gym_supreme/screens/post_workout_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/screens/weight_list_screen.dart';

import 'diagnostics_fixtures.dart';
import 'fixtures.dart';
import 'gym_setup_fixtures.dart';
import 'live_fixtures.dart';
import 'summary_fixtures.dart';

/// Every enabled button a screen reader announces must also have a tap
/// action. `Semantics(excludeSemantics: true)` over an InkWell drops the
/// child's action, so TalkBack read "button" and a double-tap did nothing
/// (found in review, 23-Nov). Taps in widget tests go by position and
/// cannot catch it; this walks the semantics tree instead.
void main() {
  List<String> missing(WidgetTester tester) {
    final out = <String>[];
    void visit(SemanticsNode n) {
      final d = n.getSemanticsData();
      final f = d.flagsCollection;
      final isButton = f.isButton;
      final enabled = f.isEnabled != Tristate.isFalse;
      if (isButton && enabled && !d.hasAction(SemanticsAction.tap)) {
        out.add(d.label.isEmpty ? '(no label)' : d.label);
      }
      n.visitChildren((c) {
        visit(c);
        return true;
      });
    }

    var root = tester.getSemantics(find.byType(MaterialApp));
    while (root.parent != null) {
      root = root.parent!;
    }
    visit(root);
    return out;
  }

  void noop() {}
  void noop1(Object? _) {}

  final screens = <String, Widget>{
    'picker': PickerScreen(
      gym: condo,
      days: storyDays,
      selected: pushSelection,
      plan: pushPlan,
      onToggleGroup: noop1,
      onStart: noop,
      onClose: noop,
      onGymTap: noop,
      onReorder: (_, _) {},
    ),
    'gym setup': GymSetupScreen(
      gyms: const [condo],
      currentGymId: 'condo',
      kit: condo.kit,
      equipment: equipmentFixture,
      presets: presetsFixture,
      weights: const [
        WeightRow(
          id: 'dumbbells',
          name: 'Dumbbells',
          weightsG: [2000, 4000],
          perHand: true,
        ),
      ],
      onPickGym: noop1,
      onAddGym: noop,
      onPreset: noop1,
      onToggle: noop1,
      onEditWeights: noop1,
      onSave: noop,
    ),
    'live': LiveScreen(
      view: liveView(),
      onReps: noop1,
      onLoad: noop1,
      onTypeReps: (_, _) {},
      onTypeLoad: (_, _) {},
      onDone: noop,
      onSkipSet: noop,
      onRestDelta: noop1,
      onSkipRest: noop,
      onReorder: (_, _) {},
      onPause: noop,
      onFinish: noop,
    ),
    'rest': LiveScreen(
      view: liveView(restLeftS: 60),
      onRestDelta: noop1,
      onSkipRest: noop,
      onFinish: noop,
    ),
    'weights': const WeightListScreen(
      row: WeightRow(
        id: 'cable-stack',
        name: 'Cable stack',
        weightsG: [5000, 10000, 15000],
      ),
    ),
    'post': PostWorkoutScreen(view: pushDone, onDone: noop),
    'history': HistoryScreen(rows: historyRows, onOpen: noop1),
    'body': const BodyScreen(muscles: bodyMuscles),
    'diagnostics': const Scaffold(
      body: DiagnosticsPanel(
        appVersion: 'x',
        gate: gate,
        native: native,
        device: device,
      ),
    ),
  };

  for (final e in screens.entries) {
    testWidgets('${e.key}: every enabled button has a tap action', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: e.value));
      await tester.pumpAndSettle();
      expect(missing(tester), isEmpty);
    });
  }

  // Keep the enum import used if fixtures change.
  test('types compile', () => expect(WorkoutType.push.label, 'Push'));
}
