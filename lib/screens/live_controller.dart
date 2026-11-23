import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gym_engine/gym_engine.dart' as eng;

import '../app/workout_port.dart';
import 'engine_adapter.dart';
import 'live_screen.dart';

/// Runs one live workout: gym_engine's Session transitions in Dart, each new
/// snapshot sent whole to the WorkoutService through [WorkoutPort], which
/// writes the journal and owns `rev` (integration rulings 1-2, t3x 23-Nov).
///
/// Every intent is queued, so two quick taps never race on `baseRev`. A
/// transition that returns the same snapshot is a no-op and sends nothing.
class LiveController extends ChangeNotifier {
  LiveController({
    required this.engine,
    required this.port,
    required this.nowMs,
    required this.tzOffsetMin,
    this.appVersion = '',
    this.tick = const Duration(seconds: 1),
  });

  final eng.GymApi engine;
  final WorkoutPort port;
  final int Function() nowMs;
  final int tzOffsetMin;
  final String appVersion;

  /// Clock and rest countdown refresh.
  final Duration tick;

  eng.SessionSnapshot? _s;
  Timer? _timer;
  Future<void> _queue = Future.value();
  final Map<String, eng.LoadSteps> _steps = {};

  /// The last error from the port, for a banner; cleared by the next success.
  WorkoutPortException? lastError;

  eng.SessionSnapshot? get snapshot => _s;
  bool get active => _s != null && !_s!.finished;

  /// Starts a session from [plan] at rev 0.
  Future<void> start(eng.SessionPlan plan) => _enqueue(() async {
    final s = eng.Session.start(
      plan,
      nowMs: nowMs(),
      tzOffsetMin: tzOffsetMin,
      appVersion: appVersion,
    );
    await port.startSession(s.encode());
    _set(s);
  });

  /// Resumes a pending journal (found on open; plan 7). The service accepts a
  /// submit against the journal head and runs again.
  Future<void> resume(eng.SessionSnapshot pending) => _enqueue(() async {
    _s = pending;
    final next = eng.Session.resume(pending, nowMs: nowMs());
    if (identical(next, pending)) {
      _set(pending);
      return;
    }
    await _submit(next);
  });

  // ---- intents from LiveScreen --------------------------------------------

  Future<void> reps(int delta) => _onCurrent((s, set) {
    final r = (set.targetReps ?? 0) + delta;
    if (r < 1) return s;
    return eng.Session.retarget(s, set.setId, reps: r);
  });

  /// Steps along the gym's real weight list (plan 5.6); never invents a load.
  Future<void> load(int delta) => _onCurrent((s, set) {
    final steps = _stepsFor(s);
    if (steps == null) return s;
    final next = delta > 0
        ? steps.next(set.targetLoadG)
        : steps.prev(set.targetLoadG);
    if (next == null) return s;
    return eng.Session.retarget(s, set.setId, loadG: next);
  });

  Future<void> done() =>
      _onCurrent((s, set) => eng.Session.done(s, set.setId, nowMs: nowMs()));

  Future<void> skipSet() =>
      _onCurrent((s, set) => eng.Session.skip(s, set.setId, nowMs: nowMs()));

  Future<void> restDelta(int seconds) => _transition(
    (s) => eng.Session.extendRest(s, seconds * 1000, nowMs: nowMs()),
  );

  Future<void> skipRest() =>
      _transition((s) => eng.Session.skipRest(s, nowMs: nowMs()));

  /// [from]/[to] index the up-next list, which starts after the current
  /// exercise.
  Future<void> reorderUpNext(int from, int to) => _transition((s) {
    final base = (s.current?.exercise ?? -1) + 1;
    return eng.Session.reorder(s, base + from, base + to);
  });

  Future<void> pause() => _enqueue(() async {
    final s = _s;
    if (s == null) return;
    await _submit(eng.Session.pause(s, nowMs: nowMs()));
    await port.pauseSession();
  });

  /// Finish order (plan 7, B1): the finished snapshot goes to the service
  /// and is fsync'd, Dart upserts it into SQLite, and only then is the
  /// journal deleted. Returns the workout uuid for the summary.
  Future<String?> finish() async {
    String? uuid;
    await _enqueue(() async {
      final s = _s;
      if (s == null) return;
      await _submit(eng.Session.finish(s, nowMs: nowMs()));
      final finalJson = await port.finishSession();
      final done = eng.SessionSnapshot.decode(finalJson);
      engine.saveFinished(done);
      await port.deleteJournal(done.workoutUuid);
      uuid = done.workoutUuid;
      _set(done);
    });
    return uuid;
  }

  // ---- view ----------------------------------------------------------------

  /// Null when no session is running.
  LiveView? view() {
    final s = _s;
    if (s == null || s.finished) return null;
    return liveViewOf(
      s,
      nowMs: nowMs(),
      steps: _stepsFor(s),
      lastTime: (exerciseId) =>
          engine.lastTime(gymId: s.gymId, exerciseId: exerciseId),
    );
  }

  // ---- plumbing ------------------------------------------------------------

  eng.LoadSteps? _stepsFor(eng.SessionSnapshot s) {
    final c = s.current;
    if (c == null) return null;
    final id = s.exercises[c.exercise].exerciseId;
    return _steps.putIfAbsent(
      '${s.gymId}/$id',
      () => engine.loadSteps(gymId: s.gymId, exerciseId: id),
    );
  }

  Future<void> _onCurrent(
    eng.SessionSnapshot Function(eng.SessionSnapshot, eng.SnapshotSet) f,
  ) => _transition((s) {
    final set = s.currentSet;
    return set == null ? s : f(s, set);
  });

  Future<void> _transition(
    eng.SessionSnapshot Function(eng.SessionSnapshot) f,
  ) => _enqueue(() async {
    final s = _s;
    if (s == null || s.finished) return;
    final next = f(s);
    if (identical(next, s)) return;
    await _submit(next);
  });

  Future<void> _submit(eng.SessionSnapshot next) async {
    final base = _s!;
    if (identical(next, base)) return;
    try {
      await port.submitSnapshot(next.encode(), base.rev);
      lastError = null;
      _set(next);
    } on StaleRevException catch (e) {
      // Another writer moved the journal (cut 2: lock-screen Done). Take the
      // service's head; the tap is dropped rather than applied twice.
      lastError = e;
      final head = await port.readPendingJournal();
      final rec = head == null ? null : engine.recover(head).snapshot;
      _set(rec ?? base);
    } on WorkoutPortException catch (e) {
      lastError = e;
      notifyListeners();
    }
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.catchError((Object _) {});
    return run;
  }

  void _set(eng.SessionSnapshot s) {
    _s = s;
    _syncTimer();
    notifyListeners();
  }

  /// Ticks the clock and rest countdown once a second while a session runs.
  void _syncTimer() {
    final running =
        _s != null && !_s!.finished && _s!.state == eng.SessionState.active;
    if (running && _timer == null) {
      _timer = Timer.periodic(tick, (_) => notifyListeners());
    } else if (!running) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
