import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/workout_detail_screen.dart';
import 'package:supreme_ui/supreme_ui.dart';

import '../screens/fixtures.dart';
import '../screens/summary_fixtures.dart';

/// Goldens for the editable workout detail (0.2.1 D3): the header "edited"
/// mark with the edit pencils, and the tap-a-set sheet. CI renders are the
/// reference (host renders differ).
void main() {
  final edited = WorkoutDetailView(
    uuid: 'u1',
    edited: true,
    type: pushDetail.type,
    startedAt: pushDetail.startedAt,
    gymName: pushDetail.gymName,
    durationS: pushDetail.durationS,
    volumeKg: pushDetail.volumeKg,
    lifts: [
      for (final l in pushDetail.lifts)
        DetailLift(
          name: l.name,
          unit: l.unit,
          sets: [
            for (var i = 0; i < l.sets.length; i++)
              DetailSet(
                setId: '${l.name}-$i',
                loadG: l.sets[i].loadG,
                reps: l.sets[i].reps,
                skipped: l.sets[i].skipped,
                timed: l.sets[i].timed,
              ),
          ],
        ),
    ],
  );

  Future<void> pumpDetail(WidgetTester tester) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: runSoloTheme().copyWith(scaffoldBackgroundColor: Lit.ground),
        home: WorkoutDetailScreen(
          view: edited,
          onDelete: () {},
          onEditSet: (_, _, _) {},
          onRemoveSet: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('workout detail, edited and editable', (t) async {
    await pumpDetail(t);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/workout_detail_edited.png'),
    );
  });

  testWidgets('workout detail, set sheet open', (t) async {
    await pumpDetail(t);
    await t.tap(find.byKey(Key('set.${edited.lifts.first.sets[1].setId}')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('edit.reps')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/workout_detail_set_sheet.png'),
    );
  });
}
