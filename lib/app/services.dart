import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_engine/sqlite_store.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/platform_api.g.dart';
import '../screens/notification_access.dart';
import 'feature_flags.dart';
import 'flavor.dart';
import 'health_sync.dart';
import 'notifications.dart';
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
    this.notifications,
    this.host,
    this.health,
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

  /// One-time notification ask + status (null in tests: ask and banner off).
  final NotificationAccess? notifications;

  /// Null in tests (no platform channel).
  final GymHostApi? host;

  /// Health Connect write (0.3 H1): only with the `health` flag and a real
  /// store (never on the temporary store of a pending restore).
  final HealthSync? health;

  /// WAL checkpoint plus the backup snapshot (plan 7, B6). Called on
  /// pause/hide and before export. Both return false when the db is busy;
  /// the next pause retries.
  ///
  /// Never throws: a failure is counted (persist_failed) and the next pause
  /// retries. Writes no snapshot while a backup is set aside (refused or
  /// unrestored): the next Auto Backup would replace his real cloud copy.
  void persist() {
    try {
      store.checkpoint();
      final snap = snapshotPath;
      if (snap == null) return;
      // While a backup is set aside, the cloud copy may be the only full
      // copy of his data: write no snapshot at all (an empty or smaller db
      // would replace it). Diagnostics shows backup_set_aside to resolve.
      if (hasSetAsideBackup(snap)) return;
      store.writeSnapshot(snap);
    } on Object catch (e) {
      persistFailed++;
      // ignore: avoid_print
      print('GymSupreme/persist failed: $e');
    }
  }

  /// Failed persist() calls this launch (Diagnostics, export).
  int persistFailed = 0;

  /// Native counters plus the app-side ones, for Diagnostics and export.
  Map<String, int> withAppCounters(Map<String, int> native) => {
    ...native,
    'restore_failed': restoreFailed,
    'restore_pending': restorePending ? 1 : 0,
    'restore_gave_up': restoreGaveUp,
    'persist_failed': persistFailed,
    'backup_set_aside': snapshotPath != null && hasSetAsideBackup(snapshotPath!)
        ? 1
        : 0,
    // Flag off: no health keys at all, so the export matches 0.3.0.
    if (health != null) ...{
      'health_written': health!.written,
      'health_deleted': health!.deleted,
      'health_failed': health!.failed,
    },
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

/// True while a backup that could not be restored is kept aside: the
/// snapshot moved to `backup/gym-snapshot.db.unrestored-<ms>` (give-up) or
/// the engine moved it to `gym.db.refused-snapshot-<ms>` (refused).
bool hasSetAsideBackup(String snapshotPath) {
  final backupDir = File(snapshotPath).parent;
  final filesDir = backupDir.parent;
  bool any(Directory d, String marker) =>
      d.existsSync() &&
      d.listSync().any((f) => f.path.split('/').last.contains(marker));
  return any(backupDir, '.unrestored-') || any(filesDir, '.refused-snapshot');
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
    final info = await host.getHostInfo().timeout(const Duration(seconds: 2));
    versionCode = '${info.versionCode}';
  } on Object {
    // Diagnostics still opens; the version line just shows '?'.
  }
  return AppServices(
    catalog: catalog,
    store: store,
    engine: eng.GymEngine(catalog: catalog, store: store),
    port: PigeonWorkoutPort(),
    // Label from pubspec (CI) + the installed versionCode from the device
    // (split APKs add 1000 * ABI, so it differs from pubspec's +N).
    appVersion:
        '${kAppVersion.isEmpty ? 'local' : kAppVersion.split('+').first}'
        '+$versionCode $flavor $buildLabel',
    snapshotPath: pending ? null : snapshotPath(dir),
    restoreFailed: restoreFailed,
    restorePending: pending,
    restoreGaveUp: _counter(dir, 'restore_gave_up', bump: gaveUp),
    notifications: HostNotificationAccess(host, dir),
    host: host,
    health: Features.health && !pending
        ? HealthSync(api: HealthApi(), store: store)
        : null,
  );
}
