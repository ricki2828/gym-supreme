import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_engine/sqlite_store.dart';
import 'package:gym_supreme/app/diagnostics_screen.dart';
import 'package:gym_supreme/app/services.dart';
import 'package:gym_supreme/app/workout_port.dart';
import 'package:gym_supreme/main.dart';
import 'package:gym_supreme/screens/diagnostics_panel.dart';
import 'package:gym_supreme/screens/flows/flows.dart';

eng.Catalog realCatalog() => eng.Catalog.fromJson(
  File('assets/exercises_taxonomy.json').readAsStringSync(),
  File('assets/exercises.json').readAsStringSync(),
);

AppServices testServices(SqliteStore store, StubWorkoutPort port) {
  final catalog = realCatalog();
  return AppServices(
    catalog: catalog,
    store: store,
    engine: eng.GymEngine(catalog: catalog, store: store),
    port: port,
    appVersion: '0.1.0+test',
  );
}

void main() {
  test(
    'database and snapshot live under files/ (backup rules depend on it)',
    () {
      expect(databasePath('/data/x/files'), '/data/x/files/gym.db');
      expect(
        snapshotPath('/data/x/files'),
        '/data/x/files/backup/gym-snapshot.db',
      );
    },
  );

  testWidgets('the app boots into GymRoot on the real catalog', (tester) async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    await tester.pumpWidget(
      GymSupremeApp(services: testServices(store, StubWorkoutPort())),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GymRoot), findsOneWidget);
  });

  test('persist writes a snapshot that restores onto a phone with no db', () {
    final dir = Directory.systemTemp.createTempSync('gs-boot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = databasePath(dir.path), snap = snapshotPath(dir.path);
    final store = SqliteStore.open(db);
    final catalog = realCatalog();
    final s = AppServices(
      catalog: catalog,
      store: store,
      engine: eng.GymEngine(catalog: catalog, store: store),
      port: StubWorkoutPort(),
      appVersion: 't',
      snapshotPath: snap,
    );
    s.persist();
    store.close();
    expect(File(snap).existsSync(), isTrue);
    for (final f in [db, '$db-wal', '$db-shm']) {
      if (File(f).existsSync()) File(f).deleteSync();
    }
    expect(
      SqliteStore.restoreSnapshotIfMissing(db, snap),
      RestoreResult.restored,
    );
    SqliteStore.open(db).close();
  });

  testWidgets('Diagnostics exports through the port with app counters', (
    tester,
  ) async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final port = StubWorkoutPort();
    final s = testServices(store, port);
    await tester.pumpWidget(MaterialApp(home: DiagnosticsScreen(services: s)));
    await tester.pumpAndSettle();
    expect(find.byType(DiagnosticsPanel), findsOneWidget);
    final panel = tester.widget<DiagnosticsPanel>(
      find.byType(DiagnosticsPanel),
    );
    expect(panel.native['restore_failed'], 0);
    panel.onExportJson!();
    panel.onExportCsv!();
    await tester.pumpAndSettle();
    expect(port.shared.map((e) => e.$2), [
      eng.ExportFiles.jsonMime,
      eng.ExportFiles.csvMime,
    ]);
    expect(port.shared.first.$1, endsWith('.json'));
    expect(port.shared.first.$3, contains('"'));
  });

  testWidgets('restore pending: banner shown, no snapshot path', (
    tester,
  ) async {
    final store = SqliteStore.inMemory();
    addTearDown(store.close);
    final catalog = realCatalog();
    final s = AppServices(
      catalog: catalog,
      store: store,
      engine: eng.GymEngine(catalog: catalog, store: store),
      port: StubWorkoutPort(),
      appVersion: 't',
      restorePending: true,
    );
    expect(s.snapshotPath, isNull);
    expect(s.withAppCounters(const {})['restore_pending'], 1);
    await tester.pumpWidget(GymSupremeApp(services: s));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restore.pending')), findsOneWidget);
  });

  test('restore gives up after 3 pending launches; snapshot kept aside', () {
    final dir = Directory.systemTemp.createTempSync('gs-retry');
    addTearDown(() => dir.deleteSync(recursive: true));
    final snap = File(snapshotPath(dir.path))
      ..createSync(recursive: true)
      ..writeAsStringSync('snap');
    expect(restoreRetries(dir.path, pending: true), isFalse);
    expect(restoreRetries(dir.path, pending: true), isFalse);
    expect(restoreRetries(dir.path, pending: true), isTrue);
    expect(snap.existsSync(), isFalse);
    final kept = snap.parent.listSync().whereType<File>().where(
      (f) => f.path.contains('.unrestored-'),
    );
    expect(kept, hasLength(1));
    expect(kept.single.readAsStringSync(), 'snap');
  });

  test('a successful launch resets the retry count', () {
    final dir = Directory.systemTemp.createTempSync('gs-retry2');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(restoreRetries(dir.path, pending: true), isFalse);
    expect(restoreRetries(dir.path, pending: true), isFalse);
    expect(restoreRetries(dir.path, pending: false), isFalse);
    expect(restoreRetries(dir.path, pending: true), isFalse);
    expect(restoreRetries(dir.path, pending: true), isFalse);
  });

  test('persist writes no snapshot while a backup is set aside', () {
    final dir = Directory.systemTemp.createTempSync('gs-guard');
    addTearDown(() => dir.deleteSync(recursive: true));
    final snap = snapshotPath(dir.path);
    File('$snap.unrestored-1')
      ..createSync(recursive: true)
      ..writeAsStringSync('his real data');
    final store = SqliteStore.open(databasePath(dir.path));
    addTearDown(store.close);
    final catalog = realCatalog();
    final s = AppServices(
      catalog: catalog,
      store: store,
      engine: eng.GymEngine(catalog: catalog, store: store),
      port: StubWorkoutPort(),
      appVersion: 't',
      snapshotPath: snap,
    );
    expect(hasSetAsideBackup(snap), isTrue);
    s.persist();
    expect(
      File(snap).existsSync(),
      isFalse,
      reason: 'no snapshot while a backup is set aside',
    );
    expect(s.withAppCounters(const {})['backup_set_aside'], 1);
    expect(s.persistFailed, 0);
  });

  test('persist failures are counted, never thrown', () {
    final store = SqliteStore.inMemory();
    final catalog = realCatalog();
    final s = AppServices(
      catalog: catalog,
      store: store,
      engine: eng.GymEngine(catalog: catalog, store: store),
      port: StubWorkoutPort(),
      appVersion: 't',
      snapshotPath: '/nonexistent/dir/backup/gym-snapshot.db',
    );
    store.close();
    s.persist();
    expect(s.persistFailed, 1);
    expect(s.withAppCounters(const {})['persist_failed'], 1);
  });

  testWidgets('a failed boot shows an error screen, not a blank app', (
    tester,
  ) async {
    final port = StubWorkoutPort();
    await tester.pumpWidget(
      BootErrorApp(error: 'StateError: boom', port: port),
    );
    expect(find.byKey(const Key('boot.error')), findsOneWidget);
    await tester.tap(find.text('Share error'));
    await tester.pump();
    expect(port.shared.single.$3, contains('boom'));
  });
}
