import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/gym_setup_screen.dart';

import 'fixtures.dart';
import 'gym_setup_fixtures.dart';

void main() {
  Widget screen({
    Set<String>? kit,
    ValueChanged<String>? onToggle,
    ValueChanged<int>? onStep,
    VoidCallback? onSave,
    ValueChanged<String>? onPreset,
  }) => MaterialApp(
    home: GymSetupScreen(
      gyms: const [condo],
      currentGymId: 'condo',
      kit: kit ?? condo.kit,
      equipment: equipmentFixture,
      presets: presetsFixture,
      dumbbellMaxG: 25000,
      firstRun: true,
      onToggle: onToggle,
      onDumbbellMax: onStep,
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

  testWidgets('dumbbell range steps and shows only with dumbbells', (
    tester,
  ) async {
    phone(tester);
    final steps = <int>[];
    await tester.pumpWidget(screen(onStep: steps.add));
    await tester.tap(find.bySemanticsLabel('Heavier'));
    await tester.tap(find.bySemanticsLabel('Lighter'));
    expect(steps, [1, -1]);
    await tester.pumpWidget(screen(kit: {'cable-stack'}));
    expect(find.text('Heaviest dumbbell pair'), findsNothing);
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
