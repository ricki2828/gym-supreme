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

  /// The service writes files/export/[fileName] and opens the share sheet.
  Future<void> shareFile(String fileName, String mimeType, String content);

  Future<Map<String, int>> nativeCounters();

  /// Every snapshot the service accepted.
  Stream<String> get snapshots;
}

/// A refusal from the service, by code (pigeons/platform_api.dart lists
/// them): stale_rev, wrong_workout, finished, not_running, already_running,
/// finish_pending, still_running, bad_snapshot, bad_schema, bad_file_name.
class WorkoutPortException implements Exception {
  WorkoutPortException(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => 'WorkoutPortException($code: $message)';
}

/// `stale_rev`: resync from the latest snapshot and retry.
class StaleRevException extends WorkoutPortException {
  StaleRevException([String? message]) : super('stale_rev', message);
}

/// The real port over Pigeon. Its Kotlin side is lane t5v's.
class PigeonWorkoutPort implements WorkoutPort {
  PigeonWorkoutPort({pg.WorkoutApi? api}) : _api = api ?? pg.WorkoutApi();

  final pg.WorkoutApi _api;

  @override
  Future<int> startSession(String snapshotJson) =>
      _guard(() => _api.startSession(snapshotJson));

  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) =>
      _guard(() => _api.submitSnapshot(snapshotJson, baseRev));

  @override
  Future<void> pauseSession() => _guard(_api.pauseSession);

  @override
  Future<String> finishSession() => _guard(_api.finishSession);

  @override
  Future<String?> readPendingJournal() => _guard(_api.readPendingJournal);

  @override
  Future<void> deleteJournal(String workoutUuid) =>
      _guard(() => _api.deleteJournal(workoutUuid));

  @override
  Future<void> shareFile(String fileName, String mimeType, String content) =>
      _guard(() => _api.shareFile(fileName, mimeType, content));

  @override
  Future<Map<String, int>> nativeCounters() => _guard(_api.getNativeCounters);

  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      if (e.code == 'stale_rev') throw StaleRevException(e.message);
      throw WorkoutPortException(e.code, e.message);
    }
  }

  // One EventChannel subscription shared by every listener: a second native
  // listen would replace the sink, and any cancel would end it for all.
  @override
  late final Stream<String> snapshots = pg.snapshots().asBroadcastStream();
}

/// In-memory port for tests and for UI work before the service lands. It
/// refuses the way the service does (same codes), owns rev, keeps a one-entry
/// journal and sets `finished` on finish. It never runs transitions itself.
class StubWorkoutPort implements WorkoutPort {
  final _controller = StreamController<String>.broadcast();
  String? _journal;
  int _rev = -1;
  bool _running = false;
  final List<(String, String, String)> shared = [];

  bool get running => _running;
  int get rev => _rev;

  @override
  Future<int> startSession(String snapshotJson) async {
    final pending = _journalMap();
    if (pending != null) {
      throw WorkoutPortException(
        pending['finished'] == true ? 'finish_pending' : 'already_running',
      );
    }
    _checkRev(snapshotJson, 0);
    _rev = 0;
    _running = true;
    _write(snapshotJson);
    return _rev;
  }

  /// Also the resume path (t5v, 23-Nov): after a pause, crash or reboot, Dart
  /// reads the pending journal (rev R) and submits with baseRev R; the
  /// service accepts it against the journal head and runs again. Revs never
  /// reset within a journal.
  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) async {
    final head = _journalMap();
    if (head == null) throw WorkoutPortException('not_running');
    if (head['finished'] == true) throw WorkoutPortException('finished');
    if (_uuidOf(snapshotJson) != head['uuid']) {
      throw WorkoutPortException('wrong_workout');
    }
    if (baseRev != _rev) {
      throw StaleRevException('base $baseRev, current $_rev');
    }
    _checkRev(snapshotJson, _rev + 1);
    _rev++;
    _running = true;
    _write(snapshotJson);
    return _rev;
  }

  @override
  Future<void> pauseSession() async {
    if (!_running) throw WorkoutPortException('not_running');
    _running = false;
  }

  /// Works while paused too: the service folds the pause in (contract).
  @override
  Future<String> finishSession() async {
    final head = _journalMap();
    if (head == null) throw WorkoutPortException('not_running');
    if (head['finished'] == true) throw WorkoutPortException('finished');
    final map = head..['finished'] = true;
    final done = jsonEncode(map);
    _running = false;
    _write(done);
    return done;
  }

  @override
  Future<String?> readPendingJournal() async => _journal;

  @override
  Future<void> deleteJournal(String workoutUuid) async {
    if (_running) throw WorkoutPortException('still_running');
    final map = _journalMap();
    if (map == null) return;
    if (map['uuid'] != workoutUuid) throw WorkoutPortException('wrong_workout');
    _journal = null;
  }

  @override
  Future<void> shareFile(
    String fileName,
    String mimeType,
    String content,
  ) async {
    if (fileName.isEmpty ||
        fileName.contains('/') ||
        fileName.startsWith('.')) {
      throw WorkoutPortException('bad_file_name');
    }
    shared.add((fileName, mimeType, content));
  }

  @override
  Future<Map<String, int>> nativeCounters() async => const {};

  @override
  Stream<String> get snapshots => _controller.stream;

  Map<String, dynamic>? _journalMap() =>
      _journal == null ? null : jsonDecode(_journal!) as Map<String, dynamic>;

  static void _checkRev(String json, int expected) {
    final Object? rev;
    try {
      rev = (jsonDecode(json) as Map<String, dynamic>)['rev'];
    } on Object {
      throw WorkoutPortException('bad_snapshot');
    }
    if (rev != expected) {
      throw WorkoutPortException(
        'bad_snapshot',
        'rev $rev, expected $expected',
      );
    }
  }

  static Object? _uuidOf(String json) {
    try {
      return (jsonDecode(json) as Map<String, dynamic>)['uuid'];
    } on Object {
      throw WorkoutPortException('bad_snapshot');
    }
  }

  Future<void> dispose() => _controller.close();

  void _write(String json) {
    _journal = json;
    _controller.add(json);
  }
}
