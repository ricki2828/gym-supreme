/// Cut-1 live-session transitions (t3x ruling (a), 23-Nov): pure functions
/// from one [SessionSnapshot] to the next. The UI calls these, then sends the
/// whole result to Kotlin with `submitSnapshot(json, baseRev)`. Kotlin is the
/// rev authority and sole journal writer; these functions bump `rev` by one so
/// the result can be submitted with `baseRev = before.rev`.
///
/// Every transition is a no-op (returns the input unchanged, same rev) when it
/// does not apply: unknown set id, a set already logged, a finished session.
/// Callers can compare `rev` to see whether anything changed.
library;

import 'dart:math';

import 'api.dart';
import 'model.dart';
import 'snapshot.dart';

/// Random UUID v4 (Random.secure).
String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

class Session {
  const Session._();

  /// A new session from a plan. Rev 0. Set ids are `<uuid>:<n>`.
  static SessionSnapshot start(
    SessionPlan plan, {
    required int nowMs,
    required int tzOffsetMin,
    String appVersion = '',
    Map<String, String> loadKinds = const {},
    String? workoutUuid,
    Random? random,
  }) {
    final uuid = workoutUuid ?? uuidV4(random);
    var n = 0;
    return SessionSnapshot(
      workoutUuid: uuid,
      rev: 0,
      appVersion: appVersion,
      gymId: plan.gymId,
      typeId: plan.typeId,
      muscles: plan.muscles,
      startedAtMs: nowMs,
      tzOffsetMin: tzOffsetMin,
      exercises: [
        for (final item in plan.items)
          SnapshotExercise(
            exerciseId: item.exerciseId,
            name: item.name,
            loadKind: loadKinds[item.exerciseId] ?? _unitKind(item.unit),
            restS: item.restS,
            repLo: item.repLo,
            repHi: item.repHi,
            sets: [
              for (var i = 0; i < item.sets.length; i++)
                SnapshotSet(
                  setId: '$uuid:${n++}',
                  setOrdinal: i + 1,
                  kind: item.unit == LoadUnit.timed
                      ? SetKind.timed
                      : SetKind.reps,
                  targetLoadG: item.sets[i].loadG,
                  targetReps: item.sets[i].reps,
                ),
            ],
          ),
      ],
    );
  }

  /// Logs a set. Values default to the targets. Starts the exercise's rest
  /// unless nothing is left to do. [completion] defaults to tap_unchanged
  /// when the values equal the targets, else adjusted.
  static SessionSnapshot done(
    SessionSnapshot s,
    String setId, {
    required int nowMs,
    int? loadG,
    int? reps,
    Completion? completion,
    SetSource source = SetSource.app,
  }) {
    if (s.finished) return s;
    final at = _find(s, setId);
    if (at == null) return s;
    final ex = s.exercises[at.e];
    final set = ex.sets[at.s];
    if (set.state != SetState.pending) return s;

    final live = s.state == SessionState.paused ? _resumed(s, nowMs) : s;
    final load = loadG ?? set.targetLoadG;
    final r = reps ?? set.targetReps;
    final how =
        completion ??
        (set.targetLoadG == null && set.targetReps == null
            ? Completion.coldStart
            : (load == set.targetLoadG && r == set.targetReps)
            ? Completion.tapUnchanged
            : Completion.adjusted);
    final started = _setStart(live, nowMs);
    final logged = set.copyWith(
      state: SetState.done,
      loadG: load,
      reps: r,
      completion: how,
      source: source,
      startedAtMs: started,
      endedAtMs: nowMs,
      offsetMs: nowMs - live.startedAtMs - live.pausedTotalMs,
    );
    var next = _replaceSet(live, at.e, at.s, logged);
    final restMs = ex.restS * 1000;
    final more = next.current != null;
    next = next.copyWith(
      rev: s.rev + 1,
      rest: more && restMs > 0
          ? Rest(setId: setId, endsAtWallMs: nowMs + restMs, durationMs: restMs)
          : null,
    );
    return next;
  }

  /// Puts a logged set back to pending (undo). Clears a rest it started.
  static SessionSnapshot undo(SessionSnapshot s, String setId) {
    if (s.finished) return s;
    final at = _find(s, setId);
    if (at == null) return s;
    final set = s.exercises[at.e].sets[at.s];
    if (set.state == SetState.pending) return s;
    final back = SnapshotSet(
      setId: set.setId,
      setOrdinal: set.setOrdinal,
      kind: set.kind,
      targetLoadG: set.targetLoadG,
      targetReps: set.targetReps,
    );
    final next = _replaceSet(s, at.e, at.s, back);
    return next.copyWith(
      rev: s.rev + 1,
      rest: s.rest?.setId == setId ? null : s.rest,
    );
  }

  /// Marks a pending set skipped. Kept for history; no volume.
  static SessionSnapshot skip(
    SessionSnapshot s,
    String setId, {
    required int nowMs,
  }) {
    if (s.finished) return s;
    final at = _find(s, setId);
    if (at == null) return s;
    final set = s.exercises[at.e].sets[at.s];
    if (set.state != SetState.pending) return s;
    return _replaceSet(
      s,
      at.e,
      at.s,
      set.copyWith(state: SetState.skipped, endedAtMs: nowMs),
    ).copyWith(rev: s.rev + 1);
  }

  /// Changes what Done will log for a pending set (+/- before the tap).
  static SessionSnapshot retarget(
    SessionSnapshot s,
    String setId, {
    Object? loadG = _keep,
    Object? reps = _keep,
  }) {
    if (s.finished) return s;
    final at = _find(s, setId);
    if (at == null) return s;
    final set = s.exercises[at.e].sets[at.s];
    if (set.state != SetState.pending) return s;
    return _replaceSet(
      s,
      at.e,
      at.s,
      set.copyWith(
        targetLoadG: identical(loadG, _keep) ? set.targetLoadG : loadG,
        targetReps: identical(reps, _keep) ? set.targetReps : reps,
      ),
    ).copyWith(rev: s.rev + 1);
  }

  /// Adds a set to an exercise, copying the last set's targets.
  static SessionSnapshot addSet(SessionSnapshot s, int exerciseIndex) {
    if (s.finished ||
        exerciseIndex < 0 ||
        exerciseIndex >= s.exercises.length) {
      return s;
    }
    final ex = s.exercises[exerciseIndex];
    final last = ex.sets.isEmpty ? null : ex.sets.last;
    final added = SnapshotSet(
      setId: '${s.workoutUuid}:${_nextSetNumber(s)}',
      setOrdinal: ex.sets.length + 1,
      kind: last?.kind ?? SetKind.reps,
      targetLoadG: last?.loadG ?? last?.targetLoadG,
      targetReps: last?.reps ?? last?.targetReps,
    );
    return _replaceExercise(
      s,
      exerciseIndex,
      ex.withSets([...ex.sets, added]),
    ).copyWith(rev: s.rev + 1);
  }

  /// Removes a pending set; ordinals of later sets close up.
  static SessionSnapshot removeSet(SessionSnapshot s, String setId) {
    if (s.finished) return s;
    final at = _find(s, setId);
    if (at == null) return s;
    final ex = s.exercises[at.e];
    if (ex.sets[at.s].state != SetState.pending) return s;
    final sets = [...ex.sets]..removeAt(at.s);
    return _replaceExercise(
      s,
      at.e,
      ex.withSets(_renumber(sets)),
    ).copyWith(rev: s.rev + 1);
  }

  /// Drag to reorder exercises (item 4).
  static SessionSnapshot reorder(SessionSnapshot s, int from, int to) {
    final n = s.exercises.length;
    if (s.finished ||
        from < 0 ||
        from >= n ||
        to < 0 ||
        to >= n ||
        from == to) {
      return s;
    }
    final list = [...s.exercises];
    final moved = list.removeAt(from);
    list.insert(to, moved);
    return s.copyWith(rev: s.rev + 1, exercises: list);
  }

  /// Adds an exercise at the end (or [at]).
  static SessionSnapshot addExercise(
    SessionSnapshot s,
    PlannedItem item, {
    int? at,
    String? loadKind,
  }) {
    if (s.finished) return s;
    var n = _nextSetNumber(s);
    final ex = SnapshotExercise(
      exerciseId: item.exerciseId,
      name: item.name,
      loadKind: loadKind ?? _unitKind(item.unit),
      restS: item.restS,
      repLo: item.repLo,
      repHi: item.repHi,
      sets: [
        for (var i = 0; i < item.sets.length; i++)
          SnapshotSet(
            setId: '${s.workoutUuid}:${n++}',
            setOrdinal: i + 1,
            kind: item.unit == LoadUnit.timed ? SetKind.timed : SetKind.reps,
            targetLoadG: item.sets[i].loadG,
            targetReps: item.sets[i].reps,
          ),
      ],
    );
    final list = [...s.exercises];
    list.insert((at ?? list.length).clamp(0, list.length), ex);
    return s.copyWith(rev: s.rev + 1, exercises: list);
  }

  /// Swaps an exercise that has nothing logged yet for another.
  static SessionSnapshot swap(
    SessionSnapshot s,
    int index,
    PlannedItem item, {
    String? loadKind,
  }) {
    if (s.finished || index < 0 || index >= s.exercises.length) return s;
    if (s.exercises[index].anyLogged) return s;
    final removed = [...s.exercises]..removeAt(index);
    return addExercise(
      s.copyWith(exercises: removed),
      item,
      at: index,
      loadKind: loadKind,
    );
  }

  /// Removes an exercise with nothing logged.
  static SessionSnapshot removeExercise(SessionSnapshot s, int index) {
    if (s.finished || index < 0 || index >= s.exercises.length) return s;
    if (s.exercises[index].anyLogged) return s;
    return s.copyWith(
      rev: s.rev + 1,
      exercises: [...s.exercises]..removeAt(index),
    );
  }

  static SessionSnapshot skipRest(SessionSnapshot s) =>
      (s.finished || s.rest == null)
      ? s
      : s.copyWith(rev: s.rev + 1, rest: null);

  /// Changes the running rest's end, e.g. +30 s (min: now).
  static SessionSnapshot extendRest(
    SessionSnapshot s,
    int deltaMs, {
    required int nowMs,
  }) {
    final r = s.rest;
    if (s.finished || r == null) return s;
    final end = max(nowMs, r.endsAtWallMs + deltaMs);
    return s.copyWith(
      rev: s.rev + 1,
      rest: Rest(
        setId: r.setId,
        endsAtWallMs: end,
        durationMs: max(0, r.durationMs + (end - r.endsAtWallMs)),
      ),
    );
  }

  /// Pause clears the rest (the service stops; plan ruling 5).
  static SessionSnapshot pause(SessionSnapshot s, {required int nowMs}) {
    if (s.finished || s.state == SessionState.paused) return s;
    return s.copyWith(
      rev: s.rev + 1,
      state: SessionState.paused,
      pausedAtMs: nowMs,
      rest: null,
    );
  }

  static SessionSnapshot resume(SessionSnapshot s, {required int nowMs}) {
    if (s.finished || s.state != SessionState.paused) return s;
    return _resumed(s, nowMs).copyWith(rev: s.rev + 1);
  }

  /// Ends the workout. Pending sets stay pending (dropped when stored).
  static SessionSnapshot finish(SessionSnapshot s, {required int nowMs}) {
    if (s.finished) return s;
    final live = s.state == SessionState.paused ? _resumed(s, nowMs) : s;
    return live.copyWith(
      rev: s.rev + 1,
      finished: true,
      endedAtMs: nowMs,
      rest: null,
    );
  }
}

const Object _keep = Object();

String _unitKind(LoadUnit u) => switch (u) {
  LoadUnit.kg => 'stack',
  LoadUnit.ea => 'dumbbell',
  LoadUnit.bodyweight => 'bodyweight',
  LoadUnit.timed => 'timed',
};

SessionSnapshot _resumed(SessionSnapshot s, int nowMs) {
  final at = s.pausedAtMs;
  if (s.state != SessionState.paused || at == null) return s;
  return s.copyWith(
    state: SessionState.active,
    pausedAtMs: null,
    pausedTotalMs: s.pausedTotalMs + max(0, nowMs - at),
  );
}

/// A set starts when the previous logged set's rest ended (or at that set's
/// end plus its rest), capped at now; the first set starts with the session.
int _setStart(SessionSnapshot s, int nowMs) {
  final rest = s.rest;
  if (rest != null) return min(rest.endsAtWallMs, nowMs);
  var last = s.startedAtMs + s.pausedTotalMs;
  for (final e in s.exercises) {
    for (final x in e.sets) {
      final end = x.endedAtMs;
      if (x.state == SetState.done && end != null && end > last) last = end;
    }
  }
  return min(last, nowMs);
}

({int e, int s})? _find(SessionSnapshot snap, String setId) {
  for (var e = 0; e < snap.exercises.length; e++) {
    final sets = snap.exercises[e].sets;
    for (var i = 0; i < sets.length; i++) {
      if (sets[i].setId == setId) return (e: e, s: i);
    }
  }
  return null;
}

int _nextSetNumber(SessionSnapshot s) {
  var n = 0;
  final prefix = '${s.workoutUuid}:';
  for (final e in s.exercises) {
    for (final x in e.sets) {
      if (x.setId.startsWith(prefix)) {
        final k = int.tryParse(x.setId.substring(prefix.length));
        if (k != null && k >= n) n = k + 1;
      }
    }
  }
  return n;
}

List<SnapshotSet> _renumber(List<SnapshotSet> sets) => [
  for (var i = 0; i < sets.length; i++) sets[i].copyWith(setOrdinal: i + 1),
];

SessionSnapshot _replaceExercise(
  SessionSnapshot s,
  int e,
  SnapshotExercise ex,
) => s.copyWith(exercises: [...s.exercises]..[e] = ex);

SessionSnapshot _replaceSet(SessionSnapshot s, int e, int i, SnapshotSet set) {
  final ex = s.exercises[e];
  return _replaceExercise(s, e, ex.withSets([...ex.sets]..[i] = set));
}
