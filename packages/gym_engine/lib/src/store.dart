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
  /// are kept.
  void upsertWorkout(
    WorkoutRecord workout, {
    String? snapshotJson,
    List<HrSample> hr = const [],
  });
  bool hasWorkout(String uuid);
  WorkoutRecord? workout(String uuid);

  /// Every finished workout, oldest first.
  List<WorkoutRecord> workouts();

  /// Database schema version (`user_version`); 0 for the memory store.
  int get schemaVersion;
}

class MemoryStore implements HistoryStore {
  final Map<String, Gym> _gyms = {};
  final Map<String, WorkoutRecord> _workouts = {};
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
    _workouts[workout.uuid] = workout;
    final have = hrByWorkout[workout.uuid] ??= [];
    for (final h in hr) {
      if (!have.any((x) => x.tMs == h.tMs)) have.add(h);
    }
  }

  @override
  bool hasWorkout(String uuid) => _workouts.containsKey(uuid);

  @override
  WorkoutRecord? workout(String uuid) => _workouts[uuid];

  @override
  List<WorkoutRecord> workouts() => _workouts.values.toList()
    ..sort((a, b) {
      final c = a.startedAtMs.compareTo(b.startedAtMs);
      return c != 0 ? c : a.uuid.compareTo(b.uuid);
    });

  @override
  int get schemaVersion => 0;
}
