// 0.3 I1: the Diagnostics Import flow (pick -> counts -> confirm -> import
// -> result). Engine behaviour is covered in packages/gym_engine
// test/import_test.dart; here the engine calls are stubs, plus one run on the
// real engine over a MemoryStore.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/diagnostics_panel.dart';
import 'package:gym_supreme/screens/import_flow.dart';

import 'diagnostics_fixtures.dart';
import 'fixtures.dart';

eng.ImportCounts counts({
  int added = 2,
  int existing = 3,
  int deleted = 1,
  int gymsAdded = 1,
  int gymsKept = 1,
  int hr = 0,
  bool settings = false,
  int deletedInFile = 0,
}) => eng.ImportCounts(
  exportFormat: 2,
  workoutsInFile: added + existing + deleted,
  workoutsAdded: added,
  skippedExisting: existing,
  skippedDeleted: deleted,
  gymsAdded: gymsAdded,
  gymsKept: gymsKept,
  hrSamplesAdded: hr,
  settingsRestored: settings,
  deletedInFile: deletedInFile,
);

/// Records what the flow called.
class Calls {
  int picks = 0;
  final applied = <String>[];
  int after = 0;
  eng.ImportCounts? result;
}

void main() {
  Future<Calls> start(
    WidgetTester tester, {
    Future<String?> Function()? pick,
    eng.ImportCounts Function(String)? preview,
    eng.ImportCounts Function(String)? apply,
    String? blocked,
  }) async {
    phone(tester);
    final c = Calls();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                c.result = await runImport(
                  context,
                  pick:
                      pick ??
                      () async {
                        c.picks++;
                        return '{"file":1}';
                      },
                  preview: preview ?? (_) => counts(),
                  apply:
                      apply ??
                      (t) {
                        c.applied.add(t);
                        return counts();
                      },
                  afterImport: () => c.after++,
                  blockedReason: blocked,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('confirm shows new vs skipped; Import applies, persists and '
      'reports', (tester) async {
    final c = await start(tester);
    expect(find.text('Import this export?'), findsOneWidget);
    expect(find.textContaining('2 new workouts to add.'), findsOneWidget);
    expect(
      find.textContaining('3 workouts are already here: left as they are.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 workout you deleted here: staying deleted.'),
      findsOneWidget,
    );
    expect(find.textContaining('1 gym with kit to add.'), findsOneWidget);
    expect(find.textContaining('Settings: yours kept.'), findsOneWidget);
    expect(c.applied, isEmpty, reason: 'nothing before Confirm');
    await tester.tap(find.byKey(const Key('import.confirm')));
    await tester.pumpAndSettle();
    expect(c.applied, ['{"file":1}']);
    expect(c.after, 1);
    expect(find.text('Imported'), findsOneWidget);
    expect(find.textContaining('2 workouts added.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('import.ok')));
    await tester.pumpAndSettle();
    expect(find.text('Imported'), findsNothing);
    expect(c.result!.workoutsAdded, 2);
  });

  testWidgets('Cancel writes nothing', (tester) async {
    final c = await start(tester);
    await tester.tap(find.byKey(const Key('import.cancel')));
    await tester.pumpAndSettle();
    expect(c.applied, isEmpty);
    expect(c.after, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(c.result, isNull);
  });

  testWidgets('backing out of the picker shows nothing', (tester) async {
    final c = await start(tester, pick: () async => null);
    expect(find.byType(AlertDialog), findsNothing);
    expect(c.applied, isEmpty);
  });

  testWidgets('a refused file says why and imports nothing', (tester) async {
    final c = await start(
      tester,
      preview: (_) => throw const eng.ImportRefused('newer version, update'),
    );
    expect(find.text('Nothing imported'), findsOneWidget);
    expect(find.text('newer version, update'), findsOneWidget);
    expect(c.applied, isEmpty);
    expect(c.after, 0);
  });

  testWidgets('a refusal at apply is reported and nothing persists', (
    tester,
  ) async {
    final c = await start(
      tester,
      apply: (_) => throw const eng.ImportRefused('Import failed'),
    );
    await tester.tap(find.byKey(const Key('import.confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing imported'), findsOneWidget);
    expect(c.after, 0);
  });

  testWidgets('nothing new: no confirm, nothing applied', (tester) async {
    final c = await start(
      tester,
      preview: (_) => counts(added: 0, gymsAdded: 0),
    );
    expect(find.text('Nothing new'), findsOneWidget);
    expect(find.byKey(const Key('import.confirm')), findsNothing);
    expect(c.applied, isEmpty);
  });

  testWidgets('settings filled, HR and file tombstones are spelled out', (
    tester,
  ) async {
    await start(
      tester,
      preview: (_) => counts(settings: true, hr: 40, deletedInFile: 2),
    );
    expect(
      find.textContaining('Settings: will be filled in from the file'),
      findsOneWidget,
    );
    expect(find.textContaining('Heart rate: 40 samples.'), findsOneWidget);
    expect(
      find.textContaining('2 workouts deleted on the other phone: not '),
      findsOneWidget,
    );
  });

  testWidgets('picker refusals read as plain words', (tester) async {
    await start(
      tester,
      pick: () async => throw PlatformException(code: 'too_large'),
    );
    expect(find.text('Could not open the file'), findsOneWidget);
    expect(find.textContaining('too big'), findsOneWidget);
  });

  testWidgets('blocked (temporary store): no picker', (tester) async {
    final c = await start(tester, blocked: 'temporary store this launch');
    expect(find.text('Import is off right now'), findsOneWidget);
    expect(c.picks, 0);
  });

  testWidgets('real engine: a file from one phone imports into another', (
    tester,
  ) async {
    final catalog = eng.Catalog.fromJson(
      File('assets/exercises_taxonomy.json').readAsStringSync(),
      File('assets/exercises.json').readAsStringSync(),
    );
    eng.GymEngine engineOf() =>
        eng.GymEngine(catalog: catalog, store: eng.MemoryStore());
    final a = engineOf();
    final g = a.gymFromPreset('condo', name: 'Condo');
    a.saveGym(g);
    a.store.upsertWorkout(
      eng.WorkoutRecord(
        uuid: 'w1',
        gymId: g.id,
        startedAtMs: 1000,
        tzOffsetMin: 0,
        endedAtMs: 2000,
        sets: const [
          eng.SetRecord(
            setId: 's1',
            exerciseId: 'dumbbell-bench-press',
            exerciseName: 'Bench',
            exercisePosition: 0,
            setOrdinal: 1,
            loadG: 20000,
            reps: 10,
            completion: eng.Completion.tapUnchanged,
          ),
        ],
      ),
    );
    final file = a.export(appVersion: 'x').json;
    final b = engineOf();
    final c = await start(
      tester,
      pick: () async => file,
      preview: b.previewImport,
      apply: b.importBundle,
    );
    expect(find.textContaining('1 new workout to add.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('import.confirm')));
    await tester.pumpAndSettle();
    expect(c.after, 1);
    expect(b.history().map((h) => h.uuid), ['w1']);
    expect(b.gyms().single.name, 'Condo');
  });

  testWidgets('Diagnostics: Import entry only when given, and it fires', (
    tester,
  ) async {
    phone(tester);
    Widget panel(VoidCallback? onImport) => MaterialApp(
      home: Scaffold(
        body: DiagnosticsPanel(
          appVersion: 'x',
          gate: gate,
          native: native,
          device: device,
          onExportJson: () {},
          onImport: onImport,
        ),
      ),
    );
    await tester.pumpWidget(panel(null));
    await tester.scrollUntilVisible(find.text('JSON'), 200);
    expect(find.byKey(const Key('diagnostics.import')), findsNothing);
    var tapped = false;
    await tester.pumpWidget(panel(() => tapped = true));
    final entry = find.byKey(const Key('diagnostics.import'));
    await tester.scrollUntilVisible(entry, 200);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    expect(tapped, isTrue);
  });
}
