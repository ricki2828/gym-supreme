import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:gym_engine/cut2.dart' as c2;
import 'package:gym_engine/gym_engine.dart' as eng;

import '../app/feature_flags.dart';
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
    this.store,
    this.onStored,
  }) {
    _foreign = port.snapshots.listen(_onSnapshot, onError: (Object _) {});
  }

  /// History for the cut-2 ghost and rotation; null hides both.
  final eng.HistoryStore? store;

  final eng.GymApi engine;
  final WorkoutPort port;
  final int Function() nowMs;
  final int tzOffsetMin;
  final String appVersion;

  /// Clock and rest countdown refresh.
  final Duration tick;

  /// Called once a finished workout is in the store (0.3 H1: Health
  /// Connect). Must not throw or block; never called for a discard.
  final void Function(String workoutUuid)? onStored;

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
    // TimerSession.resume re-anchors a paused timer block; with no block it
    // is byte-identical to Session.resume.
    final next = c2.TimerSession.resume(pending, nowMs: nowMs());
    if (identical(next, pending)) {
      _set(pending);
      return;
    }
    await _submit(next);
  });

  // ---- intents from LiveScreen --------------------------------------------

  // Held +/- (8 a second) add up here while one submit is in flight, so a
  // long hold writes a few journal lines, not one per tick, and the steps
  // never run on after he lets go (review of #36, P2).
  int _pendingReps = 0;
  int _pendingLoad = 0;
  bool _stepQueued = false;

  /// A step job is queued and not yet run (tests: it must never stick).
  @visibleForTesting
  bool get stepQueued => _stepQueued;

  Future<void> reps(int delta) {
    _pendingReps += delta;
    return _flushSteps();
  }

  /// Steps along the gym's real weight list (plan 5.6). A lift with no weight
  /// yet (first time here) starts partway up the list, not at the lightest:
  /// mid-list for dumbbells (about 12 kg, not a dozen taps from 2 kg; P1-1),
  /// a third of the way for machine stacks (about 35 kg, not 50).
  Future<void> load(int delta) {
    _pendingLoad += delta;
    return _flushSteps();
  }

  Future<void> _flushSteps() {
    if (_stepQueued) return _queue;
    _stepQueued = true;
    return _enqueue(() async {
      // Reset first, whatever happens below (no current set, finished...),
      // so the steppers can never stay dead (review of #36 fixes).
      _stepQueued = false;
      final dr = _pendingReps;
      final dl = _pendingLoad;
      _pendingReps = 0;
      _pendingLoad = 0;
      final s = _s;
      if (s == null || s.finished) return;
      final set = s.currentSet;
      if (set == null) return;
      int? reps;
      int? loadG;
      if (dr != 0) {
        // A held − stops at 1, it doesn't drop the whole batch.
        final r = max(1, (set.targetReps ?? 0) + dr);
        if (r != set.targetReps) reps = r;
      }
      if (dl != 0) {
        final g = _stepLoad(s, set, dl);
        if (g != null && g != set.targetLoadG) loadG = g;
      }
      if (reps == null && loadG == null) return;
      // One retarget, so the snapshot is exactly rev + 1 (two chained
      // retargets made rev + 2, which the service refuses).
      final next = reps != null && loadG != null
          ? eng.Session.retarget(s, set.setId, reps: reps, loadG: loadG)
          : reps != null
          ? eng.Session.retarget(s, set.setId, reps: reps)
          : eng.Session.retarget(s, set.setId, loadG: loadG);
      await _submit(next);
    });
  }

  int? _stepLoad(eng.SessionSnapshot s, eng.SnapshotSet set, int delta) {
    final steps = _stepsFor(s);
    if (steps == null || steps.loadsG.isEmpty) return null;
    var g = set.targetLoadG;
    var left = delta.abs();
    if (g == null) {
      final c = s.current;
      final kind = c == null ? '' : s.exercises[c.exercise].loadKind;
      final n = steps.loadsG.length;
      g = steps.loadsG[kind == 'stack' ? (n - 1) ~/ 3 : (n - 1) ~/ 2];
      left--;
    }
    for (; left > 0; left--) {
      final n = delta > 0 ? steps.next(g) : steps.prev(g);
      if (n == null) break;
      g = n;
    }
    return g;
  }

  /// Set ids whose value he typed; their Done is logged as `typed` (B4).
  /// Kept in this controller only: after a restart and Resume a typed set
  /// logs as `adjusted` (a known undercount until the snapshot carries it).
  final Set<String> _typed = {};

  /// A typed rep count (or seconds on a timed set), for the set the number
  /// pad was opened on ([setId]); dropped if that set is no longer pending.
  Future<void> setReps(int reps, {String? setId}) => _onSet(setId, (s, set) {
    if (reps < 1 || reps == set.targetReps) return s;
    _typed.add(set.setId);
    return eng.Session.retarget(s, set.setId, reps: reps);
  });

  /// A typed load in grams. Any value, on the gym's list or not: he logs
  /// what he lifted (P1-2); the list only drives +/- and progression.
  Future<void> setLoad(int grams, {String? setId}) => _onSet(setId, (s, set) {
    if (grams < 0 || grams == set.targetLoadG) return s;
    _typed.add(set.setId);
    return eng.Session.retarget(s, set.setId, loadG: grams);
  });

  /// Runs [f] on the set [setId] if it is still pending, else on the current
  /// set when no id is given.
  Future<void> _onSet(
    String? setId,
    eng.SessionSnapshot Function(eng.SessionSnapshot, eng.SnapshotSet) f,
  ) => _transition((s) {
    if (setId == null) {
      final cur = s.currentSet;
      return cur == null ? s : f(s, cur);
    }
    for (final e in s.exercises) {
      for (final x in e.sets) {
        if (x.setId == setId) {
          return x.state == eng.SetState.pending ? f(s, x) : s;
        }
      }
    }
    return s;
  });

  /// `typed` when he typed this set's value, except a first-time set, which
  /// stays a cold start (the one-tap rate leaves those out).
  eng.Completion? _completionFor(eng.SessionSnapshot s, eng.SnapshotSet set) {
    if (!_typed.contains(set.setId)) return null;
    final c = s.current;
    final kind = c == null ? '' : s.exercises[c.exercise].loadKind;
    final loaded = const {'dumbbell', 'stack', 'barbell'}.contains(kind);
    if (loaded && set.planLoadG == null) return null;
    return eng.Completion.typed;
  }

  /// Done on a timer block logs the block (TimerSession.finish); any other
  /// set is a plain Done.
  Future<void> done() => _onCurrent((s, set) {
    final now = nowMs();
    final f = c2.TimerSession.finish(s, set.setId, nowMs: now);
    return identical(f, s)
        ? eng.Session.done(
            s,
            set.setId,
            nowMs: now,
            completion: _completionFor(s, set),
          )
        : f;
  });

  /// Undo the most recently logged set (P1-6): it goes back to pending with
  /// its plan, and its rest is cleared. One path with timers (TimerSession).
  Future<void> undoLast() => _transition((s) {
    final last = lastDoneSet(s);
    if (last == null) return s;
    _typed.remove(last.setId);
    return c2.TimerSession.undo(s, last.setId);
  });

  /// One more set on the current exercise, copying its last set's targets.
  Future<void> addSet() => _transition((s) {
    final c = s.current;
    return c == null ? s : eng.Session.addSet(s, c.exercise);
  });

  /// Swap the current exercise for [item] (only before any set of it is
  /// logged; the engine refuses otherwise). Counts toward the swaps metric.
  /// [replacingId]: the exercise the swap sheet was opened for. If a Done
  /// (or a lock-screen Done) moved the session on meanwhile, nothing is
  /// swapped rather than the next exercise. Returns whether it swapped.
  Future<bool> swapCurrent(eng.PlannedItem item, {String? replacingId}) async {
    var swapped = false;
    await _transition((s) {
      final c = s.current;
      if (c == null) return s;
      if (replacingId != null &&
          s.exercises[c.exercise].exerciseId != replacingId) {
        return s;
      }
      final next = eng.Session.swap(s, c.exercise, item);
      swapped = !identical(next, s);
      return next;
    });
    return swapped && lastError == null;
  }

  /// One path for skip (and undo): the TimerSession versions stop or re-arm a
  /// timer block; for any other set they equal the Session versions.
  Future<void> skipSet() => _onCurrent(
    (s, set) => c2.TimerSession.skip(s, set.setId, nowMs: nowMs()),
  );

  // ---- cut 2: timer blocks (entry points gated by Features.timers) ---------

  /// Adds [block] as a timed entry of the current exercise, placed before it
  /// so it is the current set now. Lights that exercise's muscles (R4).
  Future<void> addTimer(c2.TimerBlock block) => _transition((s) {
    final cur = s.current;
    if (cur == null || s.state == eng.SessionState.paused) return s;
    final ex = s.exercises[cur.exercise];
    final added = eng.Session.addExercise(
      s,
      eng.PlannedItem(
        exerciseId: ex.exerciseId,
        name: ex.name,
        unit: eng.LoadUnit.timed,
        sets: const [eng.PlannedSet(loadG: null, reps: 0)],
        repLo: 0,
        repHi: 0,
        restS: ex.restS,
        reason: block.title,
        primary: const [],
      ),
      at: cur.exercise,
    );
    if (identical(added, s)) return s;
    final setId = added.exercises[cur.exercise].sets.first.setId;
    // One rev for the whole tap.
    return c2.TimerSession.attach(added, setId, block).copyWith(rev: s.rev + 1);
  });

  /// The current set's timer block, or null.
  c2.TimerBlock? get currentTimer {
    final s = _s;
    final set = s?.currentSet;
    if (s == null || set == null) return null;
    return c2.TimerSession.blockOf(s, set.setId);
  }

  int timerElapsedMs(int now) {
    final s = _s;
    final set = s?.currentSet;
    if (s == null || set == null) return 0;
    return c2.TimerSession.elapsedMs(s, set.setId, now);
  }

  bool get timerRunning {
    final s = _s;
    final set = s?.currentSet;
    return s != null && set != null && c2.TimerSession.isRunning(s, set.setId);
  }

  Future<void> startTimer() => _onCurrent(
    (s, set) => c2.TimerSession.start(s, set.setId, nowWallMs: nowMs()),
  );

  Future<void> markRound() => _onCurrent(
    (s, set) => c2.TimerSession.mark(s, set.setId, nowMs: nowMs()),
  );

  Future<void> finishTimer({int? amrapRounds, int? amrapExtraReps}) =>
      _onCurrent(
        // Paused (a Pause raced the dialog): never resume the session here.
        (s, set) => s.state == eng.SessionState.paused
            ? s
            : c2.TimerSession.finish(
                s,
                set.setId,
                nowMs: nowMs(),
                amrapRounds: amrapRounds,
                amrapExtraReps: amrapExtraReps,
              ),
      );

  // ---- cut 2: ghost (gated by Features.ghost) ------------------------------

  String? _ghostFor;
  Map<String, c2.ExerciseGhost?> _ghosts = const {};

  /// Last time's sets per exercise, read once per workout (history does not
  /// change during it); new exercises added later get looked up then.
  Map<String, c2.ExerciseGhost?> _ghostsOf(eng.SessionSnapshot s) {
    final st = store;
    if (st == null) return const {};
    final missing = s.exercises.any((e) => !_ghosts.containsKey(e.exerciseId));
    if (_ghostFor != s.workoutUuid || missing) {
      _ghosts = c2.ghostsForSession(s, st.workouts());
      _ghostFor = s.workoutUuid;
    }
    return _ghosts;
  }

  /// The ghost line for the current set; null when hidden.
  c2.SetGhostLine? currentGhost() {
    final s = _s;
    final set = s?.currentSet;
    if (s == null || set == null) return null;
    return c2.ghostLineFor(s, set.setId, _ghostsOf(s));
  }

  /// Whether the current exercise is loaded per hand (dumbbells: "ea").
  bool get currentPerHand {
    final s = _s;
    final c = s?.current;
    return c != null && s!.exercises[c.exercise].loadKind == 'dumbbell';
  }

  Future<void> restDelta(int seconds) => _transition(
    (s) => eng.Session.extendRest(s, seconds * 1000, nowMs: nowMs()),
  );

  Future<void> skipRest() =>
      _transition((s) => eng.Session.skipRest(s, nowMs: nowMs()));

  /// Drag in the reorder list: [from]/[to] index the exercises that still
  /// have sets to do (the current one is index 0; [to] is the final index).
  /// Logged sets stay inside their exercise, and the rest timer, ghosts and
  /// rotation do not care about order, so one `Session.reorder` is the whole
  /// change. Whichever exercise is first with a pending set is then current.
  Future<void> reorderQueue(int from, int to) => _transition((s) {
    final pend = pendingExercises(s);
    if (from < 0 || to < 0 || from >= pend.length || to >= pend.length) {
      return s;
    }
    // A timer block in progress cannot move (its clock is on that set).
    if ((from == 0 || to == 0) && _currentHasBlock(s)) return s;
    return eng.Session.reorder(s, pend[from], pend[to]);
  });

  /// "Do later": the current exercise goes to just after the next one that
  /// still has sets to do. A no-op with nothing else waiting.
  Future<void> doLater() => reorderQueue(0, 1);

  bool _currentHasBlock(eng.SessionSnapshot s) => s.currentSet?.block != null;

  /// True when the journal holds the paused snapshot (safe to leave). The
  /// service is told to stop only after that snapshot was accepted.
  Future<bool> pause() async {
    var ok = false;
    await _enqueue(() async {
      ok = await _pauseNow();
    });
    return ok;
  }

  /// [pause] without queueing, for jobs that already hold the queue.
  Future<bool> _pauseNow() async {
    final s = _s;
    if (s == null) return false;
    if (s.finished) {
      // The journal already holds the finished snapshot: leaving is safe,
      // and the next open (or Resume) retries the save.
      return true;
    }
    if (!await _submitLifecycle(
      (x) => c2.TimerSession.pause(x, nowMs: nowMs()),
    )) {
      return false;
    }
    try {
      await port.pauseSession();
    } on Object catch (e) {
      // The accepted paused snapshot already stops the service; the
      // journal is the truth, so leaving is still safe.
      lastError = e;
    }
    return true;
  }

  /// Set once [discard] deleted the journal.
  String? discardedUuid;

  /// The last [discard] did not finish: the pause was refused (the workout
  /// still runs; a pause that collided with a lock-screen tap was already
  /// retried once on the new head, see [_submitLifecycle]) or the delete
  /// failed after a good pause (the workout is paused and still offered as
  /// Resume). [lastError] always says why. Cleared by the next snapshot
  /// change.
  bool discardFailed = false;

  /// Throws the workout away: pause (the journal holds the paused snapshot
  /// and the service stops), then delete the journal. Nothing is written to
  /// SQLite and the rotation does not move. True when the journal is gone.
  ///
  /// Kotlin stops a running service synchronously on the main thread (the
  /// paused snapshot's `endSession` resets `status.running` before the submit
  /// returns), and a start still queued behind it is cancelled natively
  /// (`WorkoutService.cancelPendingStart`), so the delete needs no retry. A
  /// `still_running` refusal means something else (a spike run) holds the
  /// service: the workout stays paused.
  ///
  /// Every intent shares [_queue], so anything queued before this runs
  /// first and anything after sees no session and does nothing: no
  /// submitSnapshot can follow the delete (and the service would refuse it
  /// with not_running anyway).
  Future<bool> discard() async {
    var ok = false;
    await _enqueue(() async {
      final s = _s;
      if (s == null || s.finished || finishedUuid != null) return;
      discardFailed = false;
      if (!await _pauseNow()) {
        discardFailed = true;
        return;
      }
      try {
        await port.deleteJournal(s.workoutUuid);
      } on Object catch (e) {
        lastError = e;
        discardFailed = true;
        notifyListeners();
        return;
      }
      discardedUuid = s.workoutUuid;
      lastError = null;
      _s = null;
      _syncTimer();
      notifyListeners();
      ok = true;
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
          !await _submitLifecycle(
            (x) => eng.Session.finish(x, nowMs: nowMs()),
          )) {
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
    // H1: stored, so Health Connect may have it; fire and forget.
    onStored?.call(done.workoutUuid);
    await port.deleteJournal(done.workoutUuid);
    final st = store;
    if (Features.rotation && st != null) {
      try {
        c2.rotationAfterFinish(st, done.typeId, workoutUuid: done.workoutUuid);
      } on Object {
        // Cosmetic: the workout is stored; the rotation pointer just stays
        // one step behind (he can tap the right row in the editor). No
        // error banner.
      }
    }
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

  /// Finish and pause (discard pauses first): a lock-screen tap that landed
  /// just before must not swallow them. [f] is applied to the current
  /// snapshot; on a collision (stale rev, the view now on the newer head) it
  /// is applied ONCE more to that head. Both are idempotent, so the retry
  /// cannot double anything. A second collision is reported as
  /// `changed_elsewhere` so the tap never fails silently. A head finished
  /// elsewhere is stored by the resync ([finishedUuid] set): false here.
  Future<bool> _submitLifecycle(
    eng.SessionSnapshot Function(eng.SessionSnapshot) f,
  ) async {
    final s0 = _s!;
    final n0 = f(s0);
    if (identical(n0, s0)) return true;
    if (await _submit(n0, quietCollision: false)) return true;
    final s1 = _s;
    if (lastError is! StaleRevException ||
        s1 == null ||
        finishedUuid != null ||
        s1.finished ||
        s1.workoutUuid != s0.workoutUuid ||
        s1.rev <= s0.rev) {
      return false;
    }
    final n1 = f(s1);
    if (identical(n1, s1)) return true;
    if (await _submit(n1, quietCollision: false)) return true;
    if (lastError is StaleRevException) {
      lastError = WorkoutPortException(
        'changed_elsewhere',
        'the workout changed on the lock screen while saving; try again',
      );
      notifyListeners();
    }
    return false;
  }

  /// True when the service accepted [next]. [quietCollision]: a stale rev
  /// that resyncs onto a newer head of this workout (a lock-screen tap won)
  /// clears [lastError] - right for set-level taps (Done, +/-, skip), which
  /// are simply dropped; lifecycle intents keep it ([_submitLifecycle]).
  Future<bool> _submit(
    eng.SessionSnapshot next, {
    bool quietCollision = true,
  }) async {
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
        await _resync(base, quietCollision: quietCollision);
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
  Future<void> _resync(
    eng.SessionSnapshot base, {
    bool quietCollision = true,
  }) async {
    try {
      final text = await port.readPendingJournal();
      final head = text == null ? null : eng.readJournal(text).last;
      if (head == null) {
        notifyListeners();
        return;
      }
      // A higher rev of this workout is another writer's tap (0.3 L1: the
      // lock screen) that landed first: the view catches up and this tap is
      // dropped, which is not an error to show.
      if (quietCollision &&
          head.workoutUuid == base.workoutUuid &&
          head.rev > base.rev) {
        lastError = null;
      }
      // Show the head first: if completing it fails, the view is "all
      // done" (Finish retries) rather than the stale active base.
      _set(head);
      if (head.finished) await _complete(head);
    } on Object catch (e) {
      lastError = e;
      notifyListeners();
    }
  }

  // ---- snapshots written by the service (0.3 L1: lock-screen actions) ------

  StreamSubscription<String>? _foreign;
  bool _disposed = false;

  /// Every snapshot the service accepted or wrote. Our own submits come back
  /// at a rev we already hold and are ignored; a lock-screen Done / +1 rep /
  /// Skip rest arrives at a higher rev for the same workout and is adopted,
  /// so the screen shows it and the next tap is based on it (not dropped as
  /// stale). Queued like any intent: never runs beside an in-flight submit.
  /// Ignored once this workout is stored or discarded.
  void _onSnapshot(String json) {
    if (_disposed) return;
    unawaited(
      _enqueue(() async {
        final s = _s;
        if (_disposed ||
            s == null ||
            finishedUuid != null ||
            discardedUuid != null) {
          return;
        }
        final eng.SessionSnapshot head;
        try {
          head = eng.SessionSnapshot.decode(json);
        } on Object {
          return;
        }
        if (head.workoutUuid != s.workoutUuid || head.rev <= s.rev) return;
        lastError = null;
        _set(head);
        // Finished elsewhere: store it here, same order as Finish (B1).
        if (head.finished) {
          try {
            await _complete(head);
          } on Object catch (e) {
            // Shown as all done; Finish retries (as in _resync).
            if (_disposed) return;
            lastError = e;
            notifyListeners();
          }
        }
      }),
    );
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.catchError((Object _) {});
    return run;
  }

  void _set(eng.SessionSnapshot s) {
    _s = s;
    discardFailed = false;
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
    _disposed = true;
    unawaited(_foreign?.cancel());
    _timer?.cancel();
    super.dispose();
  }
}

/// The most recently logged set of [s] (latest end time), or null.
eng.SnapshotSet? lastDoneSet(eng.SessionSnapshot s) {
  eng.SnapshotSet? best;
  for (final e in s.exercises) {
    for (final set in e.sets) {
      // A skip is undoable too (review of #40: Skip sits beside Swap and
      // Add a set, so a mis-tap needs a way back). Skip stamps endedAtMs.
      if (set.state == eng.SetState.pending) continue;
      if (best == null || (set.endedAtMs ?? 0) >= (best.endedAtMs ?? 0)) {
        best = set;
      }
    }
  }
  return best;
}
