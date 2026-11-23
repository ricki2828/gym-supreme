import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/gym_setup_screen.dart';
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
          dumbbellMaxG: 25000,
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
}
