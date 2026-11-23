# gym_engine API changes

API v0 (C1, 23-Nov-2026): `lib/src/api.dart` (`GymApi` + view types), `GymEngine` over `HistoryStore` (`MemoryStore` fake; `SqliteStore` follows), `Session` transitions, `SessionSnapshot` schema 1.

Breaking changes after C1 are listed here, newest first, with an hc ping to t5t and the UI lane.

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
