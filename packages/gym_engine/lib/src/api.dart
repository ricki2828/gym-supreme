/// gym_engine API v0 (contract C1). The UI codes against [GymApi] and the
/// view types below. Breaking changes after C1 go in `API_CHANGES.md` with an
/// hc ping to t5t and the UI lane.
///
/// All calls are synchronous: the store is SQLite through `package:sqlite3`
/// (FFI, sync) and the data is small. Wrap in a Future/isolate in the UI if a
/// call ever shows up in a frame.
library;

import 'cut2/rotation.dart';
import 'model.dart';
import 'snapshot.dart';

/// Days-since for one muscle (plan 5.2; body map and picker).
class MuscleStatus {
  const MuscleStatus({
    required this.muscleId,
    required this.lastTrainedAtMs,
    required this.daysSince,
    required this.resting,
    required this.uncoveredAtGym,
  });

  final String muscleId;

  /// End of the last workout that trained it hard; null = never.
  final int? lastTrainedAtMs;

  /// Whole local calendar days since then (0 = today); null = never.
  final int? daysSince;

  /// Trained hard under 48 hours ago. Still pickable (plan 18).
  final bool resting;

  /// No exercise for it with this gym's kit (B5: "No kit here").
  final bool uncoveredAtGym;

  /// Body map fill window: "trained in the last 4 days" (plan 18).
  bool get lit => daysSince != null && daysSince! < 4;
}

/// Unit label the UI shows next to a load.
enum LoadUnit {
  /// kg, total (stack pin, barbell).
  kg,

  /// kg each (dumbbells, per hand).
  ea,

  /// Bodyweight; a load, if any, is added weight.
  bodyweight,

  /// A timed or distance block; no load.
  timed,
}

class PlannedSet {
  const PlannedSet({required this.loadG, required this.reps});

  /// Null = cold start (no history and no safe guess) or plain bodyweight.
  final int? loadG;
  final int reps;
}

/// One exercise in a suggested session.
class PlannedItem {
  const PlannedItem({
    required this.exerciseId,
    required this.name,
    required this.unit,
    required this.sets,
    required this.repLo,
    required this.repHi,
    required this.restS,
    required this.reason,
    required this.primary,
  });

  final String exerciseId;
  final String name;
  final LoadUnit unit;
  final List<PlannedSet> sets;
  final int repLo;
  final int repHi;
  final int restS;

  /// One line, e.g. "Chest is 5 days rested. You did 3 x 10 at 22 kg last
  /// time."
  final String reason;
  final List<String> primary;

  int get setCount => sets.length;
}

class SessionPlan {
  const SessionPlan({
    required this.gymId,
    required this.muscles,
    required this.items,
    required this.uncovered,
    required this.estimatedMinutes,
    this.typeId,
  });

  final String gymId;
  final String? typeId;
  final List<String> muscles;
  final List<PlannedItem> items;

  /// Picked muscles with no valid exercise at this gym.
  final List<String> uncovered;
  final int estimatedMinutes;
}

/// The loads this gym has for one exercise, ascending, in grams.
class LoadSteps {
  const LoadSteps(this.unit, this.loadsG);
  final LoadUnit unit;
  final List<int> loadsG;

  /// Next load up; null at the gym's top weight.
  int? next(int? currentG) {
    if (loadsG.isEmpty) return null;
    if (currentG == null) return loadsG.first;
    for (final l in loadsG) {
      if (l > currentG) return l;
    }
    return null;
  }

  /// Next load down; null at the bottom.
  int? prev(int? currentG) {
    if (currentG == null) return null;
    for (final l in loadsG.reversed) {
      if (l < currentG) return l;
    }
    return null;
  }
}

/// What he did last time with this exercise at this gym.
class LastTime {
  const LastTime({
    required this.workoutUuid,
    required this.atMs,
    required this.sets,
  });
  final String workoutUuid;
  final int atMs;

  /// Done sets only, in ordinal order.
  final List<PlannedSet> sets;
}

/// A personal best set in a workout.
class Pb {
  const Pb({
    required this.exerciseId,
    required this.name,
    required this.kind,
    required this.loadG,
    required this.reps,
    this.wasLoadG,
    this.wasReps,
  });

  final String exerciseId;
  final String name;

  /// `load` (heaviest load), `reps` (most reps at a load already lifted).
  final String kind;
  final int? loadG;
  final int reps;

  /// The previous best; null when this is the first time.
  final int? wasLoadG;
  final int? wasReps;
}

class WorkoutSummary {
  const WorkoutSummary({
    required this.uuid,
    required this.volumeKg,
    required this.volumeDeltaPct,
    required this.setCount,
    required this.setsPerMuscle,
    required this.musclesLit,
    required this.pbs,
    required this.weeklyStreak,
    required this.durationMs,
  });

  final String uuid;
  final double volumeKg;

  /// Against the last workout of the same type (any gym); null if none.
  final double? volumeDeltaPct;
  final int setCount;

  /// Weighted: primary 1.0, secondary 0.5.
  final Map<String, double> setsPerMuscle;
  final List<String> musclesLit;
  final List<Pb> pbs;

  /// Consecutive weeks with 2+ sessions (plan 18), as of this workout.
  final int weeklyStreak;
  final int durationMs;
}

class HistoryRow {
  const HistoryRow({
    required this.uuid,
    required this.startedAtMs,
    required this.tzOffsetMin,
    required this.gymId,
    required this.gymName,
    required this.typeId,
    required this.durationMs,
    required this.volumeKg,
    required this.setCount,
  });

  final String uuid;
  final int startedAtMs;
  final int tzOffsetMin;
  final String gymId;
  final String gymName;
  final String? typeId;
  final int durationMs;
  final double volumeKg;
  final int setCount;
}

/// The gate counters (plan 3, R7). Derived from rows.
class Counters {
  const Counters({
    required this.sessionsTotal,
    required this.sessionsLast14Days,
    required this.firstSessionAtMs,
    required this.doneSets,
    required this.tapUnchangedSets,
    required this.coldStartSets,
    required this.appVersions,
    this.medianSwapsPerSession = 0,
    this.workoutsDeleted = 0,
  });

  final int sessionsTotal;
  final int sessionsLast14Days;
  final int? firstSessionAtMs;
  final int doneSets;
  final int tapUnchangedSets;
  final int coldStartSets;

  /// Sessions per app version.
  final Map<String, int> appVersions;

  /// Gate: median swaps per session (plan 3).
  final double medianSwapsPerSession;

  /// Workouts deleted from history (0.2.1). Not in any count above.
  final int workoutsDeleted;

  /// Plan 3: tap_unchanged over all reps sets except cold_start.
  double get oneTapRate {
    final n = doneSets - coldStartSets;
    return n <= 0 ? 0 : tapUnchangedSets / n;
  }

  /// Shown beside it: the same over every reps set.
  double get oneTapRateInclCold =>
      doneSets == 0 ? 0 : tapUnchangedSets / doneSets;
}

class ExportFiles {
  const ExportFiles({required this.json, required this.csv});

  /// JSON bundle (schema version, app version, counters, everything). The
  /// app hands it to `port.shareFile(name, mime, content)`; Kotlin writes it.
  final String json;

  /// CSV, one row per logged set (CRLF, RFC 4180).
  final String csv;

  static const jsonMime = 'application/json';
  static const csvMime = 'text/csv';
}

/// What to do with a journal found on open (B1, ruling 4).
enum RecoveryAction {
  /// No journal, or nothing in it decoded.
  none,

  /// Already stored: just delete the journal.
  deleteJournal,

  /// Finished (e.g. from the lock screen) but not stored: [GymApi.recover]
  /// has upserted it; delete the journal.
  savedThenDelete,

  /// Unfinished and not stored: offer Resume with the snapshot.
  offerResume,
}

/// One change to a stored workout's sets ([GymApi.editWorkout], 0.2.1 D1).
/// `set_id` never changes.
sealed class WorkoutEdit {
  const WorkoutEdit(this.setId);

  /// New load and reps for a done reps set. [reps] >= 1; [loadG] >= 0 or
  /// null (bodyweight / no load). `completion` and `source` stay as logged.
  /// Refused for timed and skipped sets.
  const factory WorkoutEdit.setValues(
    String setId, {
    required int? loadG,
    required int reps,
  }) = SetValuesEdit;

  /// Deletes the set; that exercise's remaining sets (skipped ones too) are
  /// renumbered 1..n in their order. Allowed for every kind.
  const factory WorkoutEdit.removeSet(String setId) = RemoveSetEdit;

  final String setId;
}

final class SetValuesEdit extends WorkoutEdit {
  const SetValuesEdit(super.setId, {required this.loadG, required this.reps});
  final int? loadG;
  final int reps;
}

final class RemoveSetEdit extends WorkoutEdit {
  const RemoveSetEdit(super.setId);
}

/// What [GymApi.deleteWorkout] did; pass [rotationBefore] to
/// [GymApi.undoDelete].
class DeletedWorkout {
  const DeletedWorkout({
    required this.uuid,
    required this.deletedAtMs,
    this.rotationBefore,
  });

  final String uuid;
  final int deletedAtMs;

  /// The rotation before the delete moved it back; null when it did not.
  final Rotation? rotationBefore;
}

/// The engine's face to the app. One instance per open database.
abstract interface class GymApi {
  // Gyms (item 1).
  List<Gym> gyms();
  Gym? gym(String id);

  /// A new gym pre-ticked from a preset (plan 4.3). Not saved until [saveGym].
  Gym gymFromPreset(String presetId, {String? name});
  void saveGym(Gym gym);
  void deleteGym(String id);

  Settings settings();
  void saveSettings(Settings settings);

  // Picker (item 2).
  Map<String, MuscleStatus> muscleStatus({required String gymId});

  // Suggested session (item 3).
  SessionPlan suggest({
    required String gymId,
    required List<String> muscleIds,
    int? minutes,
    String? typeId,
    int seed,
  });

  // Live logging helpers (item 4).
  LoadSteps loadSteps({required String gymId, required String exerciseId});
  LastTime? lastTime({required String gymId, required String exerciseId});

  // Finish and resume (item 5, B1).
  /// Upsert by workout uuid in one transaction, with HR samples (R2). Safe to
  /// call twice.
  void saveFinished(SessionSnapshot snapshot, {List<HrSample> hr});
  bool isStored(String workoutUuid);

  /// [hrText] is the service's `hr.jsonl`, stored in the same transaction
  /// on the save path (R2).
  ({RecoveryAction action, SessionSnapshot? snapshot}) recover(
    String? journalText, {
    String? hrText,
  });

  // Post-workout and history (items 6, 7).
  WorkoutSummary summary(String workoutUuid);

  /// [summary], or null when the uuid is unknown or deleted (0.2.1: a
  /// screen still open on a workout he just deleted).
  WorkoutSummary? summaryOrNull(String workoutUuid);
  List<HistoryRow> history({int limit, int offset});
  Counters counters();

  // Delete and edit history (0.2.1 D1).
  /// Soft-deletes a stored workout: every stat, history, ghost and export
  /// leaves it out from now on; its rows stay for undo. With [rotation]
  /// (`Features.rotation`), applies `rotationAfterDelete`; if that throws,
  /// the delete stands and `rotationBefore` is null. Null when the uuid is
  /// unknown or already deleted (nothing changes).
  DeletedWorkout? deleteWorkout(String uuid, {bool rotation});

  /// Undoes [deleteWorkout]. [rotationBefore] (from its result) is saved
  /// back only while the rotation is still what the delete left; a change he
  /// made since is kept. False when the uuid is not deleted (nothing
  /// changes, the rotation included). A rotation error never fails the
  /// restore.
  bool undoDelete(String uuid, {Rotation? rotationBefore});

  /// Applies [edits] in order, all or nothing, and stamps `edited_at_ms`.
  /// Keeps HR and the as-finished `snapshot_json`. Throws [ArgumentError]
  /// (nothing written) for an unknown or deleted uuid, an unknown set id,
  /// or a value the edit refuses. An empty list changes nothing. Returns the
  /// stored record.
  WorkoutRecord editWorkout(String uuid, List<WorkoutEdit> edits);

  // Export (item 10).
  ExportFiles export({required String appVersion, Map<String, int> native});
}

/// One heart-rate sample (R2). Not written in cut 1 but the table exists.
class HrSample {
  const HrSample(this.tMs, this.bpm);
  final int tMs;
  final int bpm;
}
