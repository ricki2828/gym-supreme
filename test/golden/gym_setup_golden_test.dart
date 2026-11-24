import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/gym_setup_screen.dart';
import 'package:gym_supreme/screens/weight_list_screen.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../screens/fixtures.dart';
import '../screens/gym_setup_fixtures.dart';

/// Gym setup golden against b-gym.png, with the condo preset ticked.
void main() {
  testWidgets('first run, condo preset', (tester) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
        home: GymSetupScreen(
          gyms: const [condo],
          currentGymId: 'condo',
          kit: condo.kit,
          equipment: equipmentFixture,
          presets: presetsFixture,
          firstRun: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GymSetupScreen),
      matchesGoldenFile('goldens/gym_setup_first_run.png'),
    );
  });

  // 0.3 P1: bar and plates rows (Features.plateMath on).
  testWidgets('bar and plates section', (tester) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
        home: GymSetupScreen(
          gyms: const [condo],
          currentGymId: 'condo',
          kit: {...condo.kit, 'barbell', 'plates', 'squat-rack'},
          equipment: equipmentFixture,
          presets: const [],
          plateRows: const [
            PlateRow(id: 'barbell', name: 'Barbell bar', summary: '15 kg'),
            PlateRow(
              id: 'plates',
              name: 'Plates',
              summary: '2 × 20 · 1 × 10 · 1 × 2.5 kg a side',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -4000));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(GymSetupScreen),
      matchesGoldenFile('goldens/gym_setup_plates.png'),
    );
  });
}
