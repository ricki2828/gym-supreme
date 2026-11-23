/// Persistence behind [GymApi]. SQLite is the truth in the app
/// (`SqliteStore`); [MemoryStore] is the fake for tests and UI stubs.
library;

import 'api.dart';
import 'model.dart';

abstract interface class HistoryStore {
  List<Gym> gyms();
  Gym? gym(String id);
  void upsertGym(Gym gym);
  void deleteGym(String id);

  Settings settings();
  void saveSettings(Settings settings);

  /// Raw key/value settings for other features (e.g. `rotation`, cut 2).
  /// Values are JSON text. The key `settings` is reserved for [settings].
  String? setting(String key);
  void saveSetting(String key, String json);

  /// Insert or replace the workout and its sets, and add its HR samples, in
  /// one transaction (B1, R2). Idempotent by uuid; samples already stored
  /// are kept. Never clears a tombstone ([deleteWorkout]); a null
  /// `snapshotJson` or `editedAtMs` keeps the stored one.
  void upsertWorkout(
    WorkoutRecord workout, {
    String? snapshotJson,
    List<HrSample> hr = const [],
  });

  /// True for every stored uuid, deleted (tombstoned) ones included, so
  /// journal recovery never re-saves a workout he deleted. Not "visible in
  /// history": use [workout] for that.
  bool hasWorkout(String uuid);

  /// HR samples stored with a workout (R2), by time.
  List<HrSample> hrSamples(String uuid);

  /// The workout, or null when unknown or deleted.
  WorkoutRecord? workout(String uuid);

  /// Every finished workout that is not deleted, oldest first.
  List<WorkoutRecord> workouts();

  /// Soft delete (schema v2): stamps `deleted_at_ms`; the row, its sets and
  /// HR stay. Returns false when the uuid is unknown or already deleted (the
  /// first stamp is kept).
  bool deleteWorkout(String uuid, int atMs);

  /// Clears the tombstone. Returns false when the uuid is unknown or not
  /// deleted.
  bool restoreWorkout(String uuid);

  /// Deleted workout uuids, by delete time then uuid.
  List<String> deletedWorkoutUuids();

  /// Database schema version (`user_version`); 0 for the memory store.
  int get schemaVersion;
}

class MemoryStore implements HistoryStore {
  final Map<String, Gym> _gyms = {};
  final Map<String, WorkoutRecord> _workouts = {};

  /// Tombstones (uuid → deleted at), kept apart from [_workouts] so an
  /// upsert never clears one.
  final Map<String, int> _deleted = {};
  final Map<String, List<HrSample>> hrByWorkout = {};
  Settings _settings = const Settings();
  final Map<String, String> _raw = {};

  @override
  String? setting(String key) => _raw[key];

  @override
  void saveSetting(String key, String json) {
    if (key == 'settings') throw ArgumentError('reserved key');
    _raw[key] = json;
  }

  @override
  List<Gym> gyms() =>
      _gyms.values.toList()
        ..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));

  @override
  Gym? gym(String id) => _gyms[id];

  @override
  void upsertGym(Gym gym) => _gyms[gym.id] = gym;

  @override
  void deleteGym(String id) => _gyms.remove(id);

  @override
  Settings settings() => _settings;

  @override
  void saveSettings(Settings settings) => _settings = settings;

  @override
  void upsertWorkout(
    WorkoutRecord workout, {
    String? snapshotJson,
    List<HrSample> hr = const [],
  }) {
    final old = _workouts[workout.uuid];
    _workouts[workout.uuid] =
        workout.editedAtMs == null && old?.editedAtMs != null
        ? WorkoutRecord(
            uuid: workout.uuid,
            gymId: workout.gymId,
            typeId: workout.typeId,
            muscles: workout.muscles,
            startedAtMs: workout.startedAtMs,
            tzOffsetMin: workout.tzOffsetMin,
            endedAtMs: workout.endedAtMs,
            pausedMs: workout.pausedMs,
            appVersion: workout.appVersion,
            swaps: workout.swaps,
            sets: workout.sets,
            editedAtMs: old!.editedAtMs,
          )
        : workout;
    final have = hrByWorkout[workout.uuid] ??= [];
    for (final h in hr) {
      if (!have.any((x) => x.tMs == h.tMs)) have.add(h);
    }
  }

  @override
  bool hasWorkout(String uuid) => _workouts.containsKey(uuid);

  @override
  List<HrSample> hrSamples(String uuid) =>
      [...?hrByWorkout[uuid]]..sort((a, b) => a.tMs.compareTo(b.tMs));

  @override
  WorkoutRecord? workout(String uuid) =>
      _deleted.containsKey(uuid) ? null : _workouts[uuid];

  @override
  List<WorkoutRecord> workouts() =>
      [
        for (final w in _workouts.values)
          if (!_deleted.containsKey(w.uuid)) w,
      ]..sort((a, b) {
        final c = a.startedAtMs.compareTo(b.startedAtMs);
        return c != 0 ? c : a.uuid.compareTo(b.uuid);
      });

  @override
  bool deleteWorkout(String uuid, int atMs) {
    if (!_workouts.containsKey(uuid) || _deleted.containsKey(uuid)) {
      return false;
    }
    _deleted[uuid] = atMs;
    return true;
  }

  @override
  bool restoreWorkout(String uuid) => _deleted.remove(uuid) != null;

  @override
  List<String> deletedWorkoutUuids() =>
      (_deleted.entries.toList()..sort((a, b) {
            final c = a.value.compareTo(b.value);
            return c != 0 ? c : a.key.compareTo(b.key);
          }))
          .map((e) => e.key)
          .toList();

  @override
  int get schemaVersion => 0;
}
