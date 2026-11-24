// 0.3 I1 review P2: after an import in Diagnostics and Back, Today shows the
// imported workouts (GymRoot awaits onOpenDiagnostics and rebuilds).
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/import_flow.dart';

import 'fixtures.dart';
import 'flaky_port.dart';

void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  final now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;

  /// An export from another phone: one gym 'Hotel', one push workout.
  String otherPhoneExport() {
    final store = eng.MemoryStore();
    final e = eng.GymEngine(catalog: catalog, store: store, nowMs: () => now);
    final g = e.gymFromPreset('condo', name: 'Hotel');
    e.saveGym(g);
    store.upsertWorkout(
      eng.WorkoutRecord(
        uuid: 'imported-1',
        gymId: g.id,
        typeId: 'push',
        muscles: const ['chest'],
        startedAtMs: now - 2 * 86400000,
        tzOffsetMin: 480,
        endedAtMs: now - 2 * 86400000 + 2400000,
        sets: const [
          eng.SetRecord(
            setId: 'imported-1:0',
            exerciseId: 'dumbbell-bench-press',
            exerciseName: 'Dumbbell Bench Press',
            exercisePosition: 0,
            setOrdinal: 1,
            loadG: 20000,
            reps: 10,
            completion: eng.Completion.tapUnchanged,
          ),
        ],
      ),
    );
    return e.export(appVersion: 'x').json;
  }

  testWidgets('import in Diagnostics, then Back: Today lists the new workout', (
    tester,
  ) async {
    phone(tester);
    final store = eng.MemoryStore();
    final engine = eng.GymEngine(
      catalog: catalog,
      store: store,
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(3),
    );
    engine.saveGym(engine.gymFromPreset('condo', name: 'Condo'));
    final deps = GymDeps(
      engine: engine,
      port: FlakyPort(),
      catalog: catalog,
      appVersion: 'test',
      nowMs: () => now,
      tzOffsetMin: () => 480,
      store: store,
    );
    final file = otherPhoneExport();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: GymRoot(
          deps: deps,
          onOpenDiagnostics: () => nav.currentState!.push(
            MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                appBar: AppBar(title: const Text('Diagnostics')),
                body: TextButton(
                  onPressed: () => runImport(
                    context,
                    pick: () async => file,
                    preview: engine.previewImport,
                    apply: engine.importBundle,
                  ),
                  child: const Text('Import a JSON export'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('· Hotel'), findsNothing);

    final diag = find.byKey(const Key('home.diagnostics'));
    await tester.scrollUntilVisible(diag, 200);
    await tester.ensureVisible(diag);
    await tester.pumpAndSettle();
    await tester.tap(diag);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import a JSON export'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import.confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import.ok')));
    await tester.pumpAndSettle();
    expect(engine.history().map((h) => h.uuid), ['imported-1']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Import a JSON export'), findsNothing);
    final row = find.textContaining('· Hotel');
    await tester.scrollUntilVisible(row, 200);
    expect(row, findsOneWidget);
  });
}
