import 'package:gym_supreme/app/workout_port.dart';

/// t5t's stub with one-shot failures injected per call, for the error paths.
class FlakyPort extends StubWorkoutPort {
  /// Method name -> error thrown on its next call (then cleared).
  final Map<String, Object> failNext = {};

  Future<T> _maybe<T>(String name, Future<T> Function() call) {
    final e = failNext.remove(name);
    if (e != null) return Future.error(e);
    return call();
  }

  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) => _maybe(
    'submitSnapshot',
    () => super.submitSnapshot(snapshotJson, baseRev),
  );

  @override
  Future<void> pauseSession() => _maybe('pauseSession', super.pauseSession);

  @override
  Future<String> finishSession() =>
      _maybe('finishSession', super.finishSession);

  @override
  Future<String?> readPendingJournal() =>
      _maybe('readPendingJournal', super.readPendingJournal);

  @override
  Future<void> deleteJournal(String workoutUuid) =>
      _maybe('deleteJournal', () => super.deleteJournal(workoutUuid));
}
