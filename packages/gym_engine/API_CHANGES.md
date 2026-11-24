# gym_engine API changes

API v0 (C1, 23-Nov-2026): `lib/src/api.dart` (`GymApi` + view types), `GymEngine` over `HistoryStore` (`MemoryStore` fake; `SqliteStore` follows), `Session` transitions, `SessionSnapshot` schema 1.

Breaking changes after C1 are listed here, newest first, with an hc ping to t5t and the UI lane.

## 0.3 S1: starting weights (additive API; no schema change)
- `GymApi.startingWeights()`, `setStartingWeight(exerciseId, loadG?)` (null clears; ArgumentError for an unknown, bodyweight or timed lift, or outside 1 g..500 kg), `startingLoad({gymId, exerciseId})`, `startingWeightLifts({gymId})` → `List<StartingWeightLift>`.
- Stored as the setting row `starting_weights` (`{"<exercise id>": grams}`): no table, no migration, schema stays v2, so 0.2.x can still open the db and the install-over is unchanged.
- Used only while the lift has no done, non-skipped, non-timed set in any workout that is not deleted, at any gym: `suggest` seeds the first session from it (snapped down to a load the gym has); `lastTime` is unchanged (never fake "last time").
- Cut 2: `ghostsForSession(..., startingWeights:)`; `ExerciseGhost.baseline` / `ExerciseGhost.startingWeight`, `SetGhostLine.baseline` (always `pending`, never in `sessionTotal`); `ghostSetText` reads "Starting weight 20 kg".
- Export: optional top-level `starting_weights` list (`{exercise_id, load_g}`) inside `export_format` 2, no bump (0.2.x imports ignore it). Import adds lifts without one here, keeps his own: `ImportCounts.startingWeightsAdded` / `startingWeightsKept`; `isNoOp` is false when one is added.

## 0.2.1 D1: soft delete, edit, export v2 (additive API; schema v2)
- Schema v2: `workout.deleted_at_ms`, `workout.edited_at_ms`. 0.2.0 refuses a v2 db: fix-forward only.
- `HistoryStore.deleteWorkout(uuid, atMs)`, `restoreWorkout(uuid)`, `deletedWorkoutUuids()`. `workout()` / `workouts()` now hide deleted rows; `hasWorkout()` (and `GymApi.isStored`) stays true for them, so recovery never re-saves one.
- `GymApi.deleteWorkout(uuid, {rotation})` → `DeletedWorkout?`, `undoDelete(uuid, {rotationBefore})`, `editWorkout(uuid, List<WorkoutEdit>)`; `WorkoutEdit.setValues` / `.removeSet` (renumbers the exercise's sets 1..n).
- `WorkoutRecord.editedAtMs`, `Counters.workoutsDeleted`.
- Cut 2: `rotationAfterDelete(store, uuid, typeId)`; `rotationAfterFinish` is a no-op for a deleted uuid.
- Export `export_format` 2: deleted workouts left out, `deleted_workout_uuids`, per-workout `edited_at_ms`, `counters.workouts_deleted`.

## Additive (PR #9)
- `SqliteStore` (`package:gym_engine/sqlite_store.dart`), `HistoryStore.setting/saveSetting`, `HistoryStore.hrSamples`.
- `SnapshotSet.copyWith(block:)`, `Session.replaceSet(s, setId, f)` for cut-2 timers (t61).
