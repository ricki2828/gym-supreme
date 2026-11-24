import 'package:gym_engine/gym_engine.dart' as eng;

import '../platform/platform_api.g.dart';
import 'feature_flags.dart';

/// Title of a session with no workout type (a mixed pick).
const String healthDefaultTitle = 'Strength training';

/// A stored workout as one Health Connect session (0.3 H1). `version` is
/// `edited_at_ms ?? 0`: an edit raises it, so the rewrite replaces the
/// record; the same version again is ignored (idempotent backfill). Paused
/// time stays inside start..end: the store keeps only its total.
HealthSession healthSessionOf(eng.WorkoutRecord w) => HealthSession(
  clientRecordId: w.uuid,
  version: w.editedAtMs ?? 0,
  title: eng.workoutType(w.typeId)?.name ?? healthDefaultTitle,
  startEpochMs: w.startedAtMs,
  endEpochMs: w.endedAtMs,
  utcOffsetSeconds: w.tzOffsetMin * 60,
);

/// Keeps Health Connect in step with history (0.3 H1, flag `health`): one
/// [sync] call after a finish, an edit, a delete and an undo reads the
/// store and writes the workout while it is in history, deletes its session
/// once it is deleted, and does nothing for an unknown uuid (a discarded
/// workout is never stored, so never written). Off unless the flag is on
/// and his switch is on. Never throws and never blocks the caller's flow:
/// callers fire and forget; failures are counted for Diagnostics and the
/// backfill sends them again.
class HealthSync {
  HealthSync({required this.api, required this.store, bool? flag})
    : flag = flag ?? Features.health;

  final HealthApi api;
  final eng.HistoryStore store;

  /// `Features.health` of this build.
  final bool flag;

  /// The last status Kotlin reported; null until [refresh] (or never, with
  /// the flag off).
  HealthStatus? status;

  /// Calls that came back not written: no permission, Health Connect
  /// missing, or an error. Shown in Diagnostics as `health_failed`.
  int failed = 0;

  /// Sessions written and deleted this launch.
  int written = 0;
  int deleted = 0;

  bool get enabled => flag && (status?.enabled ?? false);

  Future<HealthStatus?> refresh() async {
    if (!flag) return null;
    try {
      status = await api.status();
    } on Object {
      // Kept as it was; Diagnostics shows the last known state.
    }
    return status;
  }

  /// His switch. On asks for the permission (Health Connect's screen) when
  /// it is not granted yet and stays off when refused. Returns the new
  /// status; throws only for `already_pending` (a screen is already open).
  Future<HealthStatus?> setEnabled(bool on) async {
    if (!flag) return null;
    status = await api.setEnabled(on);
    return status;
  }

  /// Writes or deletes [uuid]'s session to match history. Never throws.
  Future<void> sync(String uuid) async {
    if (!flag) return;
    try {
      if (status == null) await refresh();
      if (!enabled) return;
      final w = store.workout(uuid);
      if (w != null) {
        _note(await api.writeSessions([healthSessionOf(w)]), write: true);
      } else if (store.hasWorkout(uuid)) {
        _note(await api.deleteSessions([uuid]), write: false);
      }
    } on Object {
      failed++;
    }
  }

  /// "Send past workouts": every workout in history, idempotent by uuid
  /// (an unchanged one is ignored by Health Connect), then a delete for
  /// every deleted workout, so a delete that failed or happened while the
  /// switch was off is caught up. Returns the write's result; null when
  /// nothing was sent (flag or switch off).
  Future<HealthResult?> backfill() async {
    if (!flag) return null;
    if (status == null) await refresh();
    if (!enabled) return null;
    try {
      final all = [for (final w in store.workouts()) healthSessionOf(w)];
      final r = await api.writeSessions(all);
      _note(r, write: true);
      final gone = store.deletedWorkoutUuids();
      if (gone.isNotEmpty) _note(await api.deleteSessions(gone), write: false);
      return r;
    } on Object catch (e) {
      failed++;
      return HealthResult(
        outcome: HealthOutcome.failed,
        count: 0,
        detail: '$e',
      );
    }
  }

  void _note(HealthResult r, {required bool write}) {
    switch (r.outcome) {
      case HealthOutcome.ok:
        if (write) {
          written += r.count;
        } else {
          deleted += r.count;
        }
      case HealthOutcome.disabled:
        break;
      case HealthOutcome.notAvailable:
      case HealthOutcome.permissionDenied:
      case HealthOutcome.failed:
        failed++;
    }
  }
}

/// One line for Diagnostics: what the switch would do right now.
String healthStatusText(HealthStatus? s) {
  if (s == null) return 'Checking Health Connect…';
  return switch (s.availability) {
    HealthAvailability.flagOff => 'Off in this build.',
    HealthAvailability.notDeclared =>
      'This build cannot write to Health Connect.',
    HealthAvailability.notInstalled =>
      'Health Connect is not installed. Install it from the Play Store, '
          'then come back.',
    HealthAvailability.needsUpdate =>
      'Health Connect needs an update. Update it in the Play Store, then '
          'come back.',
    HealthAvailability.unsupported =>
      'Health Connect is not available on this phone.',
    HealthAvailability.available =>
      !s.enabled
          ? 'Off. Turn on to send each finished workout to Health Connect.'
          : s.granted
          ? 'On. Finished workouts go to Health Connect; edits and deletes '
                'follow.'
          : 'On, but Health Connect permission is off. Turn the switch off '
                'and on again to allow it.',
  };
}
