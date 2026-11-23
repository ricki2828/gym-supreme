// Pigeon definitions for the Flutter <-> Kotlin channel contract (plan 6.1).
// Regenerate with: dart run pigeon --input pigeons/platform_api.dart
// Generated files are committed; CI fails if they drift. This file belongs to lane A:
// other lanes send the lines they need.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/platform_api.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/app/gymsupreme/platform/PlatformApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.gymsupreme.platform'),
    dartPackageName: 'gym_supreme',
  ),
)
library;

import 'package:pigeon/pigeon.dart';

/// Device facts for the diagnostics page and the spike log.
class HostInfo {
  HostInfo({
    required this.sdkInt,
    required this.model,
    required this.versionCode,
  });

  int sdkInt;
  String model;
  int versionCode;
}

@HostApi()
abstract class GymHostApi {
  HostInfo getHostInfo();
}

/// Cut-1 live workout contract (t3x decision 23-Nov, integration doc ruling 1).
///
/// Dart runs the session transitions (gym_engine) and sends every change whole.
/// Kotlin's WorkoutService is the only journal writer and the rev authority:
/// it rejects a stale `baseRev` (PlatformException code `stale_rev`), appends
/// one fsync'd journal line, drives the rest alert and the notification, and
/// echoes the accepted snapshot on [WorkoutEvents.snapshots]. Snapshots are
/// JSON strings in the schema of contracts/session_snapshot.md (one schema for
/// the channel, the journal line and the finish payload).
@HostApi()
abstract class WorkoutApi {
  /// Starts the foreground service from the visible activity with rev 0.
  /// Returns the accepted rev (0).
  @async
  int startSession(String snapshotJson);

  /// Replaces the live snapshot. Returns the new rev; `stale_rev` if
  /// [baseRev] is not the current rev.
  @async
  int submitSnapshot(String snapshotJson, int baseRev);

  /// Stops the service and keeps the journal (resume on next open).
  @async
  void pauseSession();

  /// Writes the final snapshot with `finished: true`, fsyncs, stops the
  /// service and returns that snapshot. Dart then upserts it into SQLite and
  /// only after that calls [deleteJournal].
  @async
  String finishSession();

  /// The last good journal snapshot on disk (torn tail ignored), or null.
  @async
  String? readPendingJournal();

  /// Deletes the journal for [workoutUuid] (after the SQLite upsert).
  @async
  void deleteJournal(String workoutUuid);

  /// Opens the Android share sheet for a file the app wrote (export).
  void shareFile(String path, String mimeType);

  /// Native counters for the export: lost/corrupt journals, rest alerts
  /// fired/late.
  Map<String, int> getNativeCounters();
}

@EventChannelApi()
abstract class WorkoutEvents {
  /// Every snapshot the service accepted, as JSON.
  String snapshots();
}
