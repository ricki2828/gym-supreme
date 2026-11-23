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

  /// The last error (port refusal, storage), for a banner; cleared by the
  /// next success.
  Object? lastError;

  /// Set once the workout is stored and its journal deleted.
  String? finishedUuid;

  final Map<String, eng.LastTime?> _last = {};

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

  /// True when the journal holds the paused snapshot (safe to leave). The
  /// service is told to stop only after that snapshot was accepted.
  Future<bool> pause() async {
    var ok = false;
    await _enqueue(() async {
      final s = _s;
      if (s == null || s.finished) return;
      final next = eng.Session.pause(s, nowMs: nowMs());
      if (!identical(next, s) && !await _submit(next)) return;
      ok = true;
      try {
        await port.pauseSession();
      } on Object catch (e) {
        // The accepted paused snapshot already stops the service; the
        // journal is the truth, so leaving is still safe.
        lastError = e;
      }
    });
    return ok;
  }

  /// Finish order (plan 7, B1): the finished snapshot goes to the service
  /// and is fsync'd, Dart upserts it into SQLite, and only then is the
  /// journal deleted. Returns the workout uuid for the summary.
  ///
  /// Safe to call again after a failure: each step is idempotent (the
  /// service returns an already-finished journal unchanged; the upsert is by
  /// uuid). Returns null, with [lastError] set, if a step failed.
  Future<String?> finish() async {
    await _enqueue(() async {
      final s = _s;
      if (s == null || finishedUuid != null) return;
      if (!s.finished &&
          !await _submit(eng.Session.finish(s, nowMs: nowMs()))) {
        return;
      }
      try {
        final done = eng.SessionSnapshot.decode(await port.finishSession());
        await _complete(done);
      } on Object catch (e) {
        lastError = e;
        notifyListeners();
      }
    });
    return finishedUuid;
  }

  /// Store, then delete the journal (B1). Never deletes before the save.
  Future<void> _complete(eng.SessionSnapshot done) async {
    engine.saveFinished(done);
    await port.deleteJournal(done.workoutUuid);
    finishedUuid = done.workoutUuid;
    lastError = null;
    _set(done);
  }

  // ---- view ----------------------------------------------------------------

  /// Null before start and once the workout is stored. A finished snapshot
  /// that is not stored yet (a failed finish) shows as all done, so Finish
  /// can be tapped again.
  LiveView? view() {
    final s = _s;
    if (s == null || finishedUuid != null) return null;
    return liveViewOf(
      s,
      nowMs: nowMs(),
      steps: _stepsFor(s),
      // Cached per exercise: the view rebuilds every second.
      lastTime: (exerciseId) => _last.putIfAbsent(
        exerciseId,
        () => engine.lastTime(gymId: s.gymId, exerciseId: exerciseId),
      ),
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

  /// True when the service accepted [next].
  Future<bool> _submit(eng.SessionSnapshot next) async {
    final base = _s!;
    if (identical(next, base)) return true;
    try {
      await port.submitSnapshot(next.encode(), base.rev);
      lastError = null;
      _set(next);
      return true;
    } on WorkoutPortException catch (e) {
      lastError = e;
      if (e is StaleRevException || e.code == 'finished') {
        // Another writer moved the journal (cut 2: lock-screen Done or
        // Finish). Take the service's head; the tap is dropped rather than
        // applied twice.
        await _resync(base);
      } else {
        notifyListeners();
      }
      return false;
    } on Object catch (e) {
      lastError = e;
      notifyListeners();
      return false;
    }
  }

  /// Parse the journal head without side effects. A head finished elsewhere
  /// (lock screen) completes here with the same save-then-delete order.
  Future<void> _resync(eng.SessionSnapshot base) async {
    try {
      final text = await port.readPendingJournal();
      final head = text == null ? null : eng.readJournal(text).last;
      if (head == null) {
        notifyListeners();
        return;
      }
      if (head.finished) {
        await _complete(head);
      } else {
        _set(head);
      }
    } on Object catch (e) {
      lastError = e;
      _set(base);
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
