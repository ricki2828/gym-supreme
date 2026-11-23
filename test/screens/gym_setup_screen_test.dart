import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/gym_setup_screen.dart';
import 'package:gym_supreme/screens/weight_list_screen.dart';

import 'fixtures.dart';
import 'gym_setup_fixtures.dart';

void main() {
  Widget screen({
    Set<String>? kit,
    ValueChanged<String>? onToggle,
    ValueChanged<String>? onEdit,
    List<WeightRow> weights = const [],
    VoidCallback? onSave,
    ValueChanged<String>? onPreset,
  }) => MaterialApp(
    home: GymSetupScreen(
      gyms: const [condo],
      currentGymId: 'condo',
      kit: kit ?? condo.kit,
      equipment: equipmentFixture,
      presets: presetsFixture,
      weights: weights,
      firstRun: true,
      onToggle: onToggle,
      onEditWeights: onEdit,
      onSave: onSave,
      onPreset: onPreset,
    ),
  );

  testWidgets('save counts the kit, bodyweight excluded', (tester) async {
    phone(tester);
    await tester.pumpWidget(screen(kit: {...condo.kit, 'bodyweight'}));
    expect(find.text('SAVE · 5 ON THE FLOOR'), findsOneWidget);
  });

  testWidgets('bodyweight is never a pill', (tester) async {
    phone(tester);
    await tester.pumpWidget(screen());
    expect(find.text('Bodyweight'), findsNothing);
  });

  testWidgets('tapping a pill toggles its id', (tester) async {
    phone(tester);
    final got = <String>[];
    await tester.pumpWidget(screen(onToggle: got.add));
    await tester.tap(find.text('Adjustable bench'));
    await tester.tap(find.text('Kettlebells'));
    expect(got, ['adjustable-bench', 'kettlebells']);
  });

  testWidgets('weights rows summarise and open the editor', (tester) async {
    phone(tester);
    final opened = <String>[];
    await tester.pumpWidget(
      screen(
        onEdit: opened.add,
        weights: const [
          WeightRow(
            id: 'dumbbells',
            name: 'Dumbbells',
            weightsG: [2000, 4000, 24000],
            perHand: true,
          ),
          WeightRow(
            id: 'cable-stack',
            name: 'Cable stack',
            weightsG: [5000, 100000],
            fromDefaults: true,
          ),
        ],
      ),
    );
    final dumb = find.bySemanticsLabel('Dumbbells, 2–24 kg ea · 3 pairs. Edit');
    await tester.scrollUntilVisible(
      dumb,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Centre it: at the viewport edge it sits under the pinned Save bar.
    await tester.runAsync(
      () => Scrollable.ensureVisible(tester.element(dumb), alignment: 0.5),
    );
    await tester.pumpAndSettle();
    await tester.tap(dumb);
    final cable = find.bySemanticsLabel(
      'Cable stack, 5–100 kg · 2 weights, app guesses. Edit',
    );
    await tester.scrollUntilVisible(
      cable,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Centre it: at the viewport edge it sits under the pinned Save bar.
    await tester.runAsync(
      () => Scrollable.ensureVisible(tester.element(cable), alignment: 0.5),
    );
    await tester.pumpAndSettle();
    await tester.tap(cable);
    expect(opened, ['dumbbells', 'cable-stack']);
  });

  testWidgets('presets and save fire; empty kit cannot save', (tester) async {
    phone(tester);
    String? preset;
    var saved = 0;
    await tester.pumpWidget(
      screen(onPreset: (p) => preset = p, onSave: () => saved++),
    );
    await tester.tap(find.text('Condo gym'));
    expect(preset, 'condo');
    await tester.tap(find.text('SAVE · 5 ON THE FLOOR'));
    await tester.pumpWidget(screen(kit: const {}, onSave: () => saved++));
    await tester.tap(find.text('SAVE · 0 ON THE FLOOR'));
    expect(saved, 1);
  });
}
