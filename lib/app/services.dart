import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_engine/sqlite_store.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/platform_api.g.dart';
import 'flavor.dart';
import 'workout_port.dart';

/// Everything the app needs, built once before runApp (integration doc,
/// step 6). Tests build their own [AppServices] with an in-memory store and
/// the stub port.
class AppServices {
  AppServices({
    required this.catalog,
    required this.store,
    required this.engine,
    required this.port,
    required this.appVersion,
    this.snapshotPath,
    this.restoreFailed = 0,
    this.restorePending = false,
    this.restoreGaveUp = 0,
    this.host,
  });

  final eng.Catalog catalog;
  final SqliteStore store;
  final eng.GymApi engine;
  final WorkoutPort port;
  final String appVersion;

  /// files/backup/gym-snapshot.db: the only database file Auto Backup copies
  /// (res/xml/*_rules.xml). Null in tests.
  final String? snapshotPath;

  /// Times a backup snapshot was refused on restore (integrity check or a
  /// newer schema; moved aside to `gym.db.refused-snapshot`) and the app started
  /// with a fresh database. Shown in Diagnostics and the export.
  final int restoreFailed;

  /// The backup snapshot could not be restored this launch (I/O, busy,
  /// memory). The app runs on an in-memory store, writes no snapshot and
  /// shows a banner; the snapshot is kept and retried next launch.
  final bool restorePending;

  /// Times the app stopped retrying a snapshot restore and moved it aside to
  /// `backup/gym-snapshot.db.unrestored-<ms>` (kept for recovery).
  final int restoreGaveUp;

  /// Null in tests (no platform channel).
  final GymHostApi? host;

  /// WAL checkpoint plus the backup snapshot (plan 7, B6). Called on
  /// pause/hide and before export. Both return false when the db is busy;
  /// the next pause retries.
  void persist() {
    store.checkpoint();
    final snap = snapshotPath;
    if (snap != null) store.writeSnapshot(snap);
  }

  /// Native counters plus the app-side ones, for Diagnostics and export.
  Map<String, int> withAppCounters(Map<String, int> native) => {
    ...native,
    'restore_failed': restoreFailed,
    'restore_pending': restorePending ? 1 : 0,
    'restore_gave_up': restoreGaveUp,
  };
}

/// The database lives in getApplicationSupportDirectory() == files/ on
/// Android: the Auto Backup rules (res/xml/*_rules.xml) and the native lane
/// address files/ paths. Never getApplicationDocumentsDirectory() (app_flutter/).
String databasePath(String supportDir) => '$supportDir/gym.db';

String snapshotPath(String supportDir) => '$supportDir/backup/gym-snapshot.db';

/// A plain counter file under files/ (not backed up).
int _counter(String supportDir, String name, {required bool bump}) {
  final f = File('$supportDir/$name');
  var n = 0;
  try {
    n = int.parse(f.readAsStringSync().trim());
  } on Object {
    n = 0;
  }
  if (bump) {
    n++;
    f.writeAsStringSync('$n\n', flush: true);
  }
  return n;
}

const int maxRestoreRetries = 3;

/// Counts launches that ended in retryLater (files/restore_retries). Returns
/// true when this launch gives up: the snapshot has been moved aside and the
/// app should open a real database. Resets once a launch is not pending.
bool restoreRetries(String supportDir, {required bool pending}) {
  final marker = File('$supportDir/restore_retries');
  if (!pending) {
    if (marker.existsSync()) marker.deleteSync();
    return false;
  }
  final n = _counter(supportDir, 'restore_retries', bump: true);
  if (n < maxRestoreRetries) return false;
  final snap = File(snapshotPath(supportDir));
  try {
    if (snap.existsSync()) {
      snap.renameSync(
        '${snap.path}.unrestored-${DateTime.now().millisecondsSinceEpoch}',
      );
    }
  } on FileSystemException {
    // Cannot move it aside: keep it in place and stay on the temporary
    // store, so a real db never shadows the only backup.
    return false;
  }
  marker.deleteSync();
  return true;
}

Future<AppServices> bootstrap() async {
  final catalog = eng.Catalog.fromJson(
    await rootBundle.loadString('assets/exercises_taxonomy.json'),
    await rootBundle.loadString('assets/exercises.json'),
  );
  final dir = (await getApplicationSupportDirectory()).path;
  // A restored phone has no gym.db but may have the backed-up snapshot.
  final restore = SqliteStore.restoreSnapshotIfMissing(
    databasePath(dir),
    snapshotPath(dir),
  );
  final restoreFailed = _counter(
    dir,
    'restore_failed',
    bump: restore == RestoreResult.refused,
  );
  // retryLater: never create a fresh gym.db or write a snapshot this
  // launch, or the next pause would overwrite the only backup (#17). A
  // deterministic error would repeat on every launch, so after
  // [maxRestoreRetries] launches the snapshot is moved aside (kept, never
  // deleted) and the app opens a real database.
  var pending = restore == RestoreResult.retryLater;
  final gaveUp = restoreRetries(dir, pending: pending);
  if (gaveUp) pending = false;
  final store = pending
      ? SqliteStore.inMemory()
      : SqliteStore.open(databasePath(dir));
  final host = GymHostApi();
  var versionCode = '?';
  try {
    versionCode = '${(await host.getHostInfo()).versionCode}';
  } on Object {
    // Diagnostics still opens; the version line just shows '?'.
  }
  return AppServices(
    catalog: catalog,
    store: store,
    engine: eng.GymEngine(catalog: catalog, store: store),
    port: PigeonWorkoutPort(),
    appVersion: '0.1.0+$versionCode $flavor $buildLabel',
    snapshotPath: pending ? null : snapshotPath(dir),
    restoreFailed: restoreFailed,
    restorePending: pending,
    restoreGaveUp: _counter(dir, 'restore_gave_up', bump: gaveUp),
    host: host,
  );
}
