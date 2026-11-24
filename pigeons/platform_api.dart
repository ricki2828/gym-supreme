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
    required this.release,
    required this.notificationsEnabled,
    required this.batterySaver,
  });

  int sdkInt;
  String model;
  int versionCode;

  /// Android release name, e.g. "15".
  String release;

  /// False: rest alerts only buzz and beep; Diagnostics and the live screen
  /// show the standing banner (plan 6.2).
  bool notificationsEnabled;

  /// Battery saver on right now.
  bool batterySaver;
}

@HostApi()
abstract class GymHostApi {
  HostInfo getHostInfo();

  /// Opens this app's notification settings (the banner's "Turn on").
  void openNotificationSettings();

  /// CI e2e (phase-1 exit): the `gym_e2e` string extra of the latest launch
  /// intent (onCreate or onNewIntent), returned once and then cleared. Dogfood
  /// and debug builds only; always null on play. Dart calls it on start and on
  /// every resume.
  String? takeLaunchCommand();

  /// Asks for POST_NOTIFICATIONS through the current activity (API 33+) and
  /// returns whether notifications are now on. Below 33 there is no runtime
  /// permission and it returns the current notificationsEnabled. If the
  /// permission is already granted it returns notificationsEnabled without a
  /// dialog. Android stops showing the dialog after two refusals, so false
  /// means: offer openNotificationSettings. A second call while one is pending
  /// fails with code `already_pending`. If the activity goes away while a
  /// dialog is open, the call returns false.
  @async
  bool requestNotificationPermission();

  /// Import (I1): opens the system file picker (ACTION_OPEN_DOCUMENT; no
  /// storage permission) and returns the picked file's text, decoded as
  /// strict UTF-8, or null when the user backs out. Nothing is written on
  /// either side: Dart parses and imports the text. Refusals: `already_pending`
  /// (a pick is already open), `too_large` (file over 8 MiB), `io_error` (the
  /// file cannot be read or is not UTF-8). If the activity goes away while the
  /// picker is open, the call returns null.
  @async
  String? pickImportFile();

  /// Keep the screen on while a workout is being logged (0.3 X1): adds or
  /// clears FLAG_KEEP_SCREEN_ON on the activity window. Dart turns it on when
  /// a session starts or resumes and off when it pauses, finishes or is
  /// discarded (and when the controller goes away). Needs no permission and
  /// never fails; it logs `keep_screen_on` with `on` for CI. Calls with the
  /// current value are fine (idempotent).
  void setKeepScreenOn(bool on);
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
///
/// Revs: Dart writes `rev` into every snapshot it sends: 0 in [startSession],
/// baseRev + 1 in [submitSnapshot]. The service validates it (a mismatch is
/// `bad_snapshot`) and stores and echoes the JSON as sent, so every journal
/// line, event and finish payload carries its rev.
///
/// Resume (after pause, crash, force-stop or reboot): never [startSession].
/// Read the pending journal (rev R) and [submitSnapshot] with baseRev R; the
/// service accepts it against the journal head and runs again (re-arming a
/// rest still due). [startSession] while any journal exists is refused:
/// `already_running` (unfinished) or `finish_pending` (finished).
///
/// Refusals are PlatformException codes: `stale_rev`, `wrong_workout`,
/// `finished`, `not_running`, `already_running`, `finish_pending` (a finished
/// journal not yet deleted at start), `still_running` (delete while active),
/// `bad_snapshot`, `bad_schema`, `bad_file_name`, `io_error` (a real I/O
/// failure, e.g. [deleteJournal]; counted natively as journal_delete_failed).
///
/// Ordering: the service applies calls one at a time in the order received.
/// Dart awaits each submit before the next call (finish included); there is
/// no concurrent submit.
///
/// A submitted snapshot with `state: paused` or `finished: true` stops the
/// service; `state: active` (re)starts it.
/// [finishSession]: if Dart already submitted the finished snapshot (the
/// preferred path) it is returned unchanged; otherwise the service stamps
/// `finished: true` and rev + 1 (folding in a pause). `not_running` when
/// there is no journal. The finished snapshot is emitted on
/// [WorkoutEvents.snapshots] either way.
/// [pauseSession] is idempotent while an unfinished journal exists;
/// `not_running` when there is none or it is finished.
/// Snapshots are listened to by rev: the preferred finish path emits the
/// finished snapshot twice (submit, then finishSession), so ignore a rev
/// already seen. `state` is required (schema 1).
/// [deleteJournal] on a paused, unfinished journal discards that workout;
/// `still_running` only while the service is active for that uuid.
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

  /// Writes [content] to files/export/[fileName] (a plain name, no slashes;
  /// refused with `bad_file_name` otherwise) and opens the Android share
  /// sheet for it (export).
  @async
  void shareFile(String fileName, String mimeType, String content);

  /// Native counters for the export: journals_lost, journal_corrupt_lines,
  /// journal_torn_tails, rest_alerts_fired, rest_alerts_late (>1 s),
  /// rest_alerts_missed, rest_alert_max_late_ms, rest_alerts_audio_failed.
  Map<String, int> getNativeCounters();
}

@EventChannelApi()
abstract class WorkoutEvents {
  /// Every snapshot the service accepted, as JSON; each carries its own
  /// `rev`. No replay: a late subscriber starts from the next change and
  /// reads the current state with [WorkoutApi.readPendingJournal].
  String snapshots();
}
