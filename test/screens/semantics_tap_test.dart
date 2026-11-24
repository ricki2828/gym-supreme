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
import 'package:gym_supreme/screens/starting_weights_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/screens/weight_list_screen.dart';
import 'package:gym_supreme/screens/workout_detail_screen.dart';

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
      onStartingWeights: noop,
      onSave: noop,
    ),
    'starting weights': StartingWeightsScreen(
      rows: const [
        StartingWeightRow(
          exerciseId: 'a',
          name: 'Incline Dumbbell Press',
          unit: LoadUnit.kgEach,
          section: 'Push',
          loadG: 20000,
        ),
        StartingWeightRow(
          exerciseId: 'b',
          name: 'Triceps Pushdown',
          unit: LoadUnit.kg,
          section: 'More lifts',
          hasHistory: true,
        ),
      ],
      onEdit: noop1,
      onClear: noop1,
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
      onDoLater: noop,
      onPause: noop,
      onFinish: noop,
    ),
    'live (discard offered)': LiveScreen(
      view: liveView(doneSets: 2, leftSets: 7),
      onReps: noop1,
      onLoad: noop1,
      onTypeReps: (_, _) {},
      onTypeLoad: (_, _) {},
      onDone: noop,
      onSkipSet: noop,
      onRestDelta: noop1,
      onSkipRest: noop,
      onReorder: (_, _) {},
      onDoLater: noop,
      onPause: noop,
      onFinish: noop,
      onDiscard: noop,
    ),
    'resume card with discard': Scaffold(
      body: ResumeCard(
        type: WorkoutType.push,
        lift: 2,
        lifts: 5,
        set: 1,
        pausedWhen: 'today',
        onResume: noop,
        onDiscard: noop,
      ),
    ),
    'rest': LiveScreen(
      view: liveView(restLeftS: 60),
      onRestDelta: noop1,
      onSkipRest: noop,
      onDoLater: noop,
      onReorder: (_, _) {},
      onFinish: noop,
    ),
    'weights': const WeightListScreen(
      row: WeightRow(
        id: 'cable-stack',
        name: 'Cable stack',
        weightsG: [5000, 10000, 15000],
      ),
    ),
    'workout detail': WorkoutDetailScreen(view: pushDetail),
    'workout detail (editable)': WorkoutDetailScreen(
      view: pushDetail,
      onDelete: noop,
      onEditSet: (_, _, _) {},
      onRemoveSet: noop1,
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
    'diagnostics (import)': Scaffold(
      body: DiagnosticsPanel(
        appVersion: 'x',
        gate: gate,
        native: native,
        device: device,
        onExportJson: noop,
        onExportCsv: noop,
        onImport: noop,
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

  for (final nothing in [false, true]) {
    testWidgets('finish dialog (${nothing ? 'nothing logged' : 'with sets'}): '
        'every enabled button has a tap action', (tester) async {
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(
            view: liveView(doneSets: nothing ? 0 : 2, leftSets: 7),
            onFinish: noop,
            onDiscard: noop,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('live.finish')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key(nothing ? 'finish.nothing_discard' : 'finish.discard')),
        findsOneWidget,
      );
      expect(missing(tester), isEmpty);
    });
  }

  testWidgets('discard confirm: every enabled button has a tap action', (
    tester,
  ) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => askDiscard(c, 2),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('discard.confirm')), findsOneWidget);
    expect(missing(tester), isEmpty);
  });

  Future<void> editableDetail(WidgetTester tester) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: WorkoutDetailScreen(
          view: pushDetail,
          onDelete: noop,
          onEditSet: (_, _, _) {},
          onRemoveSet: noop1,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('detail menu, set sheet and confirms: every enabled button '
      'has a tap action', (tester) async {
    await editableDetail(tester);
    // Overflow menu.
    await tester.tap(find.byKey(const Key('detail.menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail.delete')), findsOneWidget);
    expect(missing(tester), isEmpty);
    await tester.tap(find.byKey(const Key('detail.delete')));
    await tester.pumpAndSettle();
    // Delete confirm.
    expect(find.byKey(const Key('delete.confirm')), findsOneWidget);
    expect(missing(tester), isEmpty);
    await tester.tap(find.byKey(const Key('delete.keep')));
    await tester.pumpAndSettle();
    // A set row, its sheet, the remove confirm.
    await tester.tap(find.byKey(const Key('set.0')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit.remove')), findsOneWidget);
    expect(missing(tester), isEmpty);
    await tester.tap(find.byKey(const Key('edit.remove')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remove.confirm')), findsOneWidget);
    expect(missing(tester), isEmpty);
  });

  // Keep the enum import used if fixtures change.
  test('types compile', () => expect(WorkoutType.push.label, 'Push'));
}
