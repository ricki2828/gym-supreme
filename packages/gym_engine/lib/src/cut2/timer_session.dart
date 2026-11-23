/// Timer-block transitions on the live session (R4), layered on
/// [Session.replaceSet] so session.dart stays untouched. Pure; every
/// transition returns a new snapshot for `submitSnapshot`.
///
/// Lifecycle of a timed set's `block`:
/// attach (definition + full cue list, anchor null) → start (anchor = now)
/// → [mark]* → pause/resume (anchor cleared / re-anchored with the
/// remaining cues) → finish (result written, cues emptied so Kotlin stops,
/// then [Session.done]). The UI reads [elapsedMs] and feeds
/// [TimerBlock.stateAt]; it never keeps its own clock.
library;

import '../model.dart';
import '../session.dart';
import '../snapshot.dart';
import 'timers.dart';

abstract final class TimerSession {
  /// The timed set [setId], or null.
  static SnapshotSet? _set(SessionSnapshot s, String setId) {
    for (final e in s.exercises) {
      for (final x in e.sets) {
        if (x.setId == setId) return x;
      }
    }
    return null;
  }

  /// The block definition on [setId], or null (no block / not a timed set /
  /// unreadable block).
  static TimerBlock? blockOf(SessionSnapshot s, String setId) {
    final b = _set(s, setId)?.block;
    if (b == null) return null;
    try {
      return TimerBlock.fromJson(b);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// Whether the block's clock is running (started and not paused).
  static bool isRunning(SessionSnapshot s, String setId) =>
      _set(s, setId)?.block?['started_at_wall_ms'] is int;

  /// Block time run so far at [nowMs], lead-in included; clamped to the
  /// block's total. 0 before Start.
  static int elapsedMs(SessionSnapshot s, String setId, int nowMs) {
    final set = _set(s, setId);
    final b = set?.block;
    final def = blockOf(s, setId);
    if (b == null || def == null) return 0;
    final before = b['elapsed_before_ms'] is int
        ? b['elapsed_before_ms'] as int
        : 0;
    final at = b['started_at_wall_ms'];
    final run = at is int && nowMs > at ? nowMs - at : 0;
    final e = before + run;
    return e > def.totalMs ? def.totalMs : e;
  }

  /// Puts [block] on the pending timed set [setId]. Replaces a block that
  /// has not started; a started one is left alone (no-op).
  static SessionSnapshot attach(
    SessionSnapshot s,
    String setId,
    TimerBlock block,
  ) => Session.replaceSet(s, setId, (x) {
    if (x.kind != SetKind.timed || x.state != SetState.pending) return x;
    if (_started(x.block)) return x;
    // A replaced definition is a new run (its cue indices start again).
    final run = x.block == null ? 0 : _run(x.block) + 1;
    return x.copyWith(block: block.toSnapshotBlock(run: run));
  });

  /// Back to "attached, not started" (full cues, no anchor, no result):
  /// for a timed set put back to pending by Session.undo, or a restart.
  static SessionSnapshot reset(SessionSnapshot s, String setId) =>
      Session.replaceSet(s, setId, (x) {
        final def = _def(x);
        if (def == null || x.state != SetState.pending) return x;
        // Not while running: pause or finish first, so Kotlin never sees a
        // live block lose its anchor.
        if (x.block!['started_at_wall_ms'] is int) return x;
        return x.copyWith(block: def.toSnapshotBlock(run: _run(x.block) + 1));
      });

  /// Undo for any set: [Session.undo], and a timed set's block comes back
  /// armed (not started, no result) in the same rev step. The UI calls this
  /// instead of Session.undo, so an undone block never looks paused (which
  /// would block other timers and restart on the next resume).
  static SessionSnapshot undo(SessionSnapshot s, String setId) {
    final u = Session.undo(s, setId);
    if (identical(u, s)) return s;
    // Re-arm whatever its run state: the set was not pending, so nothing in
    // the service is legitimately running for it (a skip or a lock-screen
    // Done may have left an anchor behind).
    final r = Session.replaceSet(u, setId, (x) {
      final def = _def(x);
      if (def == null) return x;
      return x.copyWith(block: def.toSnapshotBlock(run: _run(x.block) + 1));
    });
    return identical(r, u) ? u : r.copyWith(rev: s.rev + 1);
  }

  /// Skip for any set: [Session.skip], and a timed set's block stops (anchor
  /// cleared, cues emptied) in the same rev, so the service stops firing.
  static SessionSnapshot skip(
    SessionSnapshot s,
    String setId, {
    required int nowMs,
  }) {
    final k = Session.skip(s, setId, nowMs: nowMs);
    if (identical(k, s)) return s;
    final r = settle(k);
    return identical(r, k) ? k : r.copyWith(rev: s.rev + 1);
  }

  /// Stops every block on a set that is no longer pending (anchor cleared,
  /// cues emptied). Apply to any snapshot that reached a timed set by a path
  /// other than [finish] / [skip] (e.g. a lock-screen Done echoed by the
  /// service) before submitting it. Same object when nothing changes; one
  /// rev step otherwise.
  static SessionSnapshot settle(SessionSnapshot s) {
    var next = s;
    for (final e in s.exercises) {
      for (final x in e.sets) {
        final b = x.block;
        if (b == null || x.state == SetState.pending) continue;
        final cues = b['cues'];
        if (b['started_at_wall_ms'] == null && cues is List && cues.isEmpty) {
          continue;
        }
        next = Session.replaceSet(next, x.setId, (y) {
          final m = Map<String, Object?>.of(y.block!)
            ..['started_at_wall_ms'] = null
            ..['cues'] = const <Object?>[];
          return y.copyWith(block: m);
        });
      }
    }
    return identical(next, s) ? s : next.copyWith(rev: s.rev + 1);
  }

  /// Starts the clock: the anchor is [nowWallMs] (the lead-in start).
  /// No-op when already started, paused session, or no block.
  static SessionSnapshot start(
    SessionSnapshot s,
    String setId, {
    required int nowWallMs,
  }) {
    if (s.state == SessionState.paused) return s;
    return Session.replaceSet(s, setId, (x) {
      final def = _def(x);
      if (def == null || x.state != SetState.pending || _started(x.block)) {
        return x;
      }
      // One block at a time: another started (running or frozen) block
      // must be finished first, so pause/finish never strand one.
      if (_otherStarted(s, setId)) return x;
      return x.copyWith(
        block: _withResult(
          def.toSnapshotBlock(startedAtWallMs: nowWallMs, run: _run(x.block)),
          x.block!,
        ),
      );
    });
  }

  /// Pauses the session; a running block freezes its elapsed time and
  /// clears its anchor (Kotlin clears the timer on pause anyway).
  static SessionSnapshot pause(SessionSnapshot s, {required int nowMs}) {
    if (s.finished || s.state == SessionState.paused) return s;
    var next = s;
    for (final id in _runningIds(s)) {
      final e = elapsedMs(s, id, nowMs);
      next = Session.replaceSet(next, id, (x) {
        final b = Map<String, Object?>.of(x.block!);
        b['started_at_wall_ms'] = null;
        b['elapsed_before_ms'] = e;
        b['cues'] = const <Object?>[];
        return x.copyWith(block: b);
      });
    }
    // One rev step for the whole pause, like Session.pause alone.
    return Session.pause(next, nowMs: nowMs).copyWith(rev: s.rev + 1);
  }

  /// Resumes the session; a frozen block re-anchors at [nowMs] with its
  /// remaining cues (stable indices, see [TimerBlock.toSnapshotBlock]).
  static SessionSnapshot resume(SessionSnapshot s, {required int nowMs}) {
    if (s.finished || s.state != SessionState.paused) return s;
    var next = Session.resume(s, nowMs: nowMs);
    for (final e in s.exercises) {
      for (final x in e.sets) {
        final b = x.block;
        if (b == null || x.state != SetState.pending) continue;
        final before = b['elapsed_before_ms'];
        if (!_frozen(b) || before is! int || before < 0) continue;
        final def = _def(x);
        if (def == null) continue;
        next = Session.replaceSet(
          next,
          x.setId,
          (y) => y.copyWith(
            block: _withResult(
              def.toSnapshotBlock(
                startedAtWallMs: nowMs,
                elapsedBeforeMs: before,
                run: _run(y.block),
              ),
              y.block!,
            ),
          ),
        );
      }
    }
    return next.copyWith(rev: s.rev + 1);
  }

  /// "Round done" tap: appends a mark (offset from block start, lead-in
  /// excluded). Ignored in the lead-in, after the end, or when not running.
  static SessionSnapshot mark(
    SessionSnapshot s,
    String setId, {
    required int nowMs,
  }) {
    if (!isRunning(s, setId)) return s;
    final def = blockOf(s, setId);
    if (def == null) return s;
    final e = elapsedMs(s, setId, nowMs) - def.leadInMs;
    if (e < 0 || e > def.blockMs) return s;
    return Session.replaceSet(s, setId, (x) {
      final b = Map<String, Object?>.of(x.block!);
      final marks = [..._marks(b)];
      if (marks.isNotEmpty && e < marks.last) return x;
      b['round_marks_ms'] = [...marks, e];
      return x.copyWith(block: b);
    });
  }

  /// Ends the block (at the end or early) and logs the set done. AMRAP
  /// rounds are entered here. Cues are emptied and the anchor cleared so the
  /// service stops the block timer.
  static SessionSnapshot finish(
    SessionSnapshot s,
    String setId, {
    required int nowMs,
    int? amrapRounds,
    int? amrapExtraReps,
  }) {
    if (s.finished) return s;
    final def = blockOf(s, setId);
    final set = _set(s, setId);
    if (def == null || set == null || set.state != SetState.pending) return s;
    final ran = elapsedMs(s, setId, nowMs) - def.leadInMs;
    final marks = _marks(set.block!);
    // A wall-clock step back must not make the stop precede a mark.
    var ranClamped = ran < 0 ? 0 : ran;
    if (marks.isNotEmpty && marks.last > ranClamped) ranClamped = marks.last;
    final result = TimedResult(
      roundMarksMs: marks,
      amrapRounds: def.type == TimerType.amrap ? amrapRounds : null,
      amrapExtraReps: def.type == TimerType.amrap ? amrapExtraReps : null,
      stoppedAtMs: ranClamped < def.blockMs ? ranClamped : null,
    );
    final problems = result.problems(def);
    if (problems.isNotEmpty) {
      throw ArgumentError('timed result: ${problems.join('; ')}');
    }
    final withResult = Session.replaceSet(s, setId, (x) {
      final b = Map<String, Object?>.of(x.block!)
        ..['started_at_wall_ms'] = null
        ..['elapsed_before_ms'] = ranClamped + def.leadInMs
        ..['cues'] = const <Object?>[]
        ..addAll(result.toJson());
      return x.copyWith(block: b);
    });
    // Timed rows log no load or reps (R4: out of volume and one-tap rate).
    return Session.done(
      withResult,
      setId,
      nowMs: nowMs,
      loadG: null,
      reps: null,
    ).copyWith(rev: s.rev + 1);
  }

  // ---- helpers ----

  static TimerBlock? _def(SnapshotSet x) {
    final b = x.block;
    if (b == null) return null;
    try {
      return TimerBlock.fromJson(b);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// Started = running (anchor set) or frozen by a pause.
  static bool _started(Map<String, Object?>? b) =>
      b != null && (b['started_at_wall_ms'] is int || _frozen(b));

  /// Paused: anchor cleared and cues emptied. An attached, never-started
  /// block always carries its full (non-empty) cue list, so the two never
  /// look alike, even when the pause came in the same ms as Start.
  static bool _frozen(Map<String, Object?> b) =>
      b['started_at_wall_ms'] == null &&
      b['cues'] is List &&
      (b['cues'] as List).isEmpty;

  static bool _otherStarted(SessionSnapshot s, String setId) {
    for (final e in s.exercises) {
      for (final x in e.sets) {
        if (x.setId != setId &&
            x.state == SetState.pending &&
            _started(x.block)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Re-arm generation: part of the service's durable dedup key
  /// (set_id, run, index), so a re-armed block's cues fire again. Bumped on
  /// every re-arm (attach over a block, reset, undo); kept by start/resume.
  static int _run(Map<String, Object?>? b) {
    final r = b?['run'];
    return r is int && r >= 0 ? r : 0;
  }

  static List<int> _marks(Map<String, Object?> b) => [
    for (final m in (b['round_marks_ms'] as List?) ?? const [])
      if (m is int) m,
  ];

  /// Carries marks already taken into a freshly compiled block.
  static Map<String, Object?> _withResult(
    Map<String, Object?> fresh,
    Map<String, Object?> old,
  ) => {
    ...fresh,
    if (old['round_marks_ms'] != null) 'round_marks_ms': old['round_marks_ms'],
  };

  static List<String> _runningIds(SessionSnapshot s) => [
    for (final e in s.exercises)
      for (final x in e.sets)
        if (x.state == SetState.pending &&
            x.block?['started_at_wall_ms'] is int)
          x.setId,
  ];
}
