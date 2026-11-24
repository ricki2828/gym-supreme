/// Adapters from the store and the live snapshot to the ghost (R6, N3).
/// Pure; call with `store.workouts()` each time the screen builds, so
/// history edits flow through.
library;

import '../model.dart';
import '../snapshot.dart';
import '../starting_weights.dart';
import 'ghost.dart';

GhostInputWorkout ghostInputFromRecord(WorkoutRecord w) => GhostInputWorkout(
  uuid: w.uuid,
  gymId: w.gymId,
  startedAtMs: w.startedAtMs,
  sets: [
    for (final s in w.sets)
      GhostInputSet(
        exerciseId: s.exerciseId,
        setOrdinal: s.setOrdinal,
        timed: s.kind == SetKind.timed,
        skipped: s.skipped,
        loadG: s.loadG,
        reps: s.reps,
        offsetMs: s.offsetMs,
      ),
  ],
);

/// One ghost per exercise in the live session (null = no earlier session at
/// this gym with it: hidden). Keyed by exercise id. A lift with no logged
/// history at any gym and a starting weight in [startingWeights] (0.3 S1)
/// gets a starting-weight ghost instead of none.
Map<String, ExerciseGhost?> ghostsForSession(
  SessionSnapshot live,
  Iterable<WorkoutRecord> history, {
  Map<String, int> startingWeights = const {},
}) {
  final records = history.toList();
  final inputs = [for (final w in records) ghostInputFromRecord(w)];
  ExerciseGhost? of(String id) {
    final g = ghostFor(
      gymId: live.gymId,
      exerciseId: id,
      beforeMs: live.startedAtMs,
      workouts: inputs,
      currentUuid: live.workoutUuid,
    );
    if (g != null) return g;
    final start = startingWeights[id];
    if (start == null) return null;
    final others = records.where((w) => w.uuid != live.workoutUuid);
    return hasLoggedHistory(id, others)
        ? null
        : ExerciseGhost.startingWeight(id, start);
  }

  return {for (final e in live.exercises) e.exerciseId: of(e.exerciseId)};
}

/// The done, non-timed sets of the live session for [sessionTotal]. Skipped
/// sets are left out (so last time's set at that number never counts against
/// him), and a repeated ordinal within an exercise counts once.
List<DoneSet> doneSetsOf(SessionSnapshot live) {
  final out = <DoneSet>[];
  for (final e in live.exercises) {
    final seen = <int>{};
    for (final s in e.sets) {
      if (s.state != SetState.done || s.kind == SetKind.timed) continue;
      if (!seen.add(s.setOrdinal)) continue;
      out.add((
        exerciseId: e.exerciseId,
        setOrdinal: s.setOrdinal,
        volumeGReps: (s.loadG ?? 0) * (s.reps ?? 0),
      ));
    }
  }
  return out;
}

/// The ghost line for one set of the live session: a done set compares what
/// he logged (with pace); a pending set compares its targets (pending until
/// reps are known). Null when the exercise has no ghost, the set is timed or
/// skipped, or the id is unknown.
SetGhostLine? ghostLineFor(
  SessionSnapshot live,
  String setId,
  Map<String, ExerciseGhost?> ghosts,
) {
  for (final e in live.exercises) {
    for (final s in e.sets) {
      if (s.setId != setId) continue;
      final g = ghosts[e.exerciseId];
      if (g == null || s.kind == SetKind.timed) return null;
      return switch (s.state) {
        SetState.skipped => null,
        SetState.done => compareSet(
          ghost: g,
          setOrdinal: s.setOrdinal,
          loadG: s.loadG,
          reps: s.reps,
          offsetMs: s.offsetMs,
        ),
        SetState.pending => compareSet(
          ghost: g,
          setOrdinal: s.setOrdinal,
          loadG: s.targetLoadG,
          reps: null, // not lifted yet: show last time, judge nothing
        ),
      };
    }
  }
  return null;
}

/// The session-total line for a stored workout (post-workout screen): its
/// done reps sets against the ghosts it had when it started.
SessionGhostTotal? ghostTotalForRecord(
  WorkoutRecord w,
  Iterable<WorkoutRecord> history,
) {
  final inputs = [for (final h in history) ghostInputFromRecord(h)];
  final ids = {for (final s in w.sets) s.exerciseId};
  final ghosts = {
    for (final id in ids)
      id: ghostFor(
        gymId: w.gymId,
        exerciseId: id,
        beforeMs: w.startedAtMs,
        workouts: inputs,
        currentUuid: w.uuid,
      ),
  };
  final seen = <String>{};
  final done = <DoneSet>[
    for (final s in w.sets)
      if (!s.skipped &&
          s.kind != SetKind.timed &&
          seen.add('${s.exerciseId}#${s.setOrdinal}'))
        (
          exerciseId: s.exerciseId,
          setOrdinal: s.setOrdinal,
          volumeGReps: s.volumeGReps,
        ),
  ];
  return sessionTotal(ghosts: ghosts, done: done);
}
