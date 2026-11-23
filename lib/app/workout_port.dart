import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;

import '../platform/platform_api.g.dart' as pg;

/// The live-workout boundary between Dart and the Kotlin WorkoutService
/// (integration doc ruling 1). Dart (gym_engine) runs the transitions and
/// sends each new snapshot whole; the service is the only journal writer and
/// owns `rev`. Snapshots are JSON in the contracts/session_snapshot.md schema.
abstract class WorkoutPort {
  /// Starts the service with [snapshotJson] at rev 0; returns 0.
  Future<int> startSession(String snapshotJson);

  /// Returns the new rev. Throws [StaleRevException] if [baseRev] is stale.
  Future<int> submitSnapshot(String snapshotJson, int baseRev);

  Future<void> pauseSession();

  /// Final snapshot with `finished: true`, already fsync'd by the service.
  Future<String> finishSession();

  Future<String?> readPendingJournal();

  /// Call only after the SQLite upsert of the finished workout (plan 7, B1).
  Future<void> deleteJournal(String workoutUuid);

  Future<void> shareFile(String path, String mimeType);

  Future<Map<String, int>> nativeCounters();

  /// Every snapshot the service accepted.
  Stream<String> get snapshots;
}

class StaleRevException implements Exception {
  StaleRevException(this.message);
  final String? message;
  @override
  String toString() => 'StaleRevException($message)';
}

/// The real port over Pigeon. Its Kotlin side is lane t5v's.
class PigeonWorkoutPort implements WorkoutPort {
  PigeonWorkoutPort({pg.WorkoutApi? api}) : _api = api ?? pg.WorkoutApi();

  final pg.WorkoutApi _api;

  @override
  Future<int> startSession(String snapshotJson) =>
      _api.startSession(snapshotJson);

  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) async {
    try {
      return await _api.submitSnapshot(snapshotJson, baseRev);
    } on PlatformException catch (e) {
      if (e.code == 'stale_rev') throw StaleRevException(e.message);
      rethrow;
    }
  }

  @override
  Future<void> pauseSession() => _api.pauseSession();

  @override
  Future<String> finishSession() => _api.finishSession();

  @override
  Future<String?> readPendingJournal() => _api.readPendingJournal();

  @override
  Future<void> deleteJournal(String workoutUuid) =>
      _api.deleteJournal(workoutUuid);

  @override
  Future<void> shareFile(String path, String mimeType) =>
      _api.shareFile(path, mimeType);

  @override
  Future<Map<String, int>> nativeCounters() => _api.getNativeCounters();

  @override
  Stream<String> get snapshots => pg.snapshots();
}

/// In-memory port for tests and for UI work before the service lands. It
/// behaves like the service: rev authority, stale-rev rejection, a one-entry
/// "journal", finished flag on finish. It never runs transitions itself.
class StubWorkoutPort implements WorkoutPort {
  final _controller = StreamController<String>.broadcast();
  String? _journal;
  int _rev = -1;
  bool _running = false;
  final List<(String, String)> shared = [];

  bool get running => _running;
  int get rev => _rev;

  @override
  Future<int> startSession(String snapshotJson) async {
    _rev = 0;
    _running = true;
    _write(snapshotJson);
    return _rev;
  }

  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) async {
    if (!_running) throw StateError('no live session');
    if (baseRev != _rev) {
      throw StaleRevException('base $baseRev, current $_rev');
    }
    _rev++;
    _write(snapshotJson);
    return _rev;
  }

  @override
  Future<void> pauseSession() async => _running = false;

  @override
  Future<String> finishSession() async {
    final json = _journal;
    if (json == null) throw StateError('no journal');
    final map = jsonDecode(json) as Map<String, dynamic>;
    map['finished'] = true;
    final done = jsonEncode(map);
    _journal = done;
    _running = false;
    return done;
  }

  @override
  Future<String?> readPendingJournal() async => _journal;

  @override
  Future<void> deleteJournal(String workoutUuid) async {
    final json = _journal;
    if (json == null) return;
    final map = jsonDecode(json) as Map<String, dynamic>;
    if (map['uuid'] == workoutUuid) _journal = null;
  }

  @override
  Future<void> shareFile(String path, String mimeType) async =>
      shared.add((path, mimeType));

  @override
  Future<Map<String, int>> nativeCounters() async => const {};

  @override
  Stream<String> get snapshots => _controller.stream;

  void _write(String json) {
    _journal = json;
    _controller.add(json);
  }
}
