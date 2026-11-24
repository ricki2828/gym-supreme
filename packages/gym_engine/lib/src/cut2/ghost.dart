/// Ghost session (plan R6, Ricki N3): each exercise against the last time he
/// did it at this gym, plus one session-total line. Pure Dart.
///
/// Key: `gym_id + exercise_id`, against the latest earlier finished workout
/// at that gym containing that exercise. Computed when shown (never stored),
/// so history edits flow through. Hidden until there is an earlier session:
/// [ghostFor] returns null on the first.
///
/// Inputs are plain records so this file does not depend on the store's
/// types; `fromWorkoutRecord` adapters are one-liners once the engine API v0
/// is on main.
library;

/// One stored set, as the ghost needs it.
class GhostInputSet {
  const GhostInputSet({
    required this.exerciseId,
    required this.setOrdinal,
    this.timed = false,
    this.skipped = false,
    this.loadG,
    this.reps,
    this.offsetMs,
  });

  final String exerciseId;

  /// 1-based within its exercise.
  final int setOrdinal;
  final bool timed;
  final bool skipped;
  final int? loadG;
  final int? reps;

  /// Workout start (pauses excluded) to the set's end.
  final int? offsetMs;

  /// Gram-reps; 0 for timed or skipped sets (same rule as the engine).
  int get volumeGReps => (timed || skipped) ? 0 : (loadG ?? 0) * (reps ?? 0);
}

/// One stored finished workout, as the ghost needs it.
class GhostInputWorkout {
  const GhostInputWorkout({
    required this.uuid,
    required this.gymId,
    required this.startedAtMs,
    required this.sets,
  });

  final String uuid;
  final String gymId;
  final int startedAtMs;
  final List<GhostInputSet> sets;
}

/// Last time's sets for one exercise.
class ExerciseGhost {
  const ExerciseGhost({
    required this.exerciseId,
    required this.workoutUuid,
    required this.workoutStartedAtMs,
    required this.sets,
    this.baseline = false,
  });

  /// A starting weight he typed (0.3 S1), not a past session: one set with
  /// the load and no reps, the same at every ordinal. It never judges
  /// ahead / behind and never counts in the session total.
  factory ExerciseGhost.startingWeight(String exerciseId, int loadG) =>
      ExerciseGhost(
        exerciseId: exerciseId,
        workoutUuid: '',
        workoutStartedAtMs: 0,
        sets: [
          GhostInputSet(exerciseId: exerciseId, setOrdinal: 1, loadG: loadG),
        ],
        baseline: true,
      );

  final String exerciseId;
  final String workoutUuid;
  final int workoutStartedAtMs;

  /// From a starting weight ([ExerciseGhost.startingWeight]).
  final bool baseline;

  /// Non-timed sets of that exercise, by ordinal ascending. Skipped ones are
  /// kept so ordinals line up; they compare as "no set last time".
  final List<GhostInputSet> sets;

  GhostInputSet? byOrdinal(int ordinal) {
    if (baseline) return sets.firstOrNull;
    for (final s in sets) {
      if (s.setOrdinal == ordinal) return s;
    }
    return null;
  }

  int get volumeGReps => sets.fold(0, (a, s) => a + s.volumeGReps);
}

/// The latest workout at [gymId] that started before [beforeMs] and has a
/// non-timed set of [exerciseId]; null when there is none (first session:
/// the ghost stays hidden). [workouts] may be in any order. Pass the live
/// workout's start as [beforeMs] and its uuid as [currentUuid], so it can
/// never be its own ghost even if the caller includes it.
ExerciseGhost? ghostFor({
  required String gymId,
  required String exerciseId,
  required int beforeMs,
  required Iterable<GhostInputWorkout> workouts,
  String? currentUuid,
}) {
  GhostInputWorkout? best;
  List<GhostInputSet>? bestSets;
  for (final w in workouts) {
    if (w.gymId != gymId || w.startedAtMs >= beforeMs) continue;
    if (w.uuid == currentUuid) continue;
    // Latest first; equal starts tie-break on uuid so input order never
    // changes the answer.
    if (best != null &&
        (w.startedAtMs < best.startedAtMs ||
            (w.startedAtMs == best.startedAtMs &&
                w.uuid.compareTo(best.uuid) <= 0))) {
      continue;
    }
    final sets = [
      for (final s in w.sets)
        if (s.exerciseId == exerciseId && !s.timed) s,
    ];
    if (sets.isEmpty || sets.every((s) => s.skipped)) continue;
    best = w;
    bestSets = sets;
  }
  if (best == null) return null;
  bestSets!.sort((a, b) => a.setOrdinal.compareTo(b.setOrdinal));
  return ExerciseGhost(
    exerciseId: exerciseId,
    workoutUuid: best.uuid,
    workoutStartedAtMs: best.startedAtMs,
    sets: List.unmodifiable(bestSets),
  );
}

/// How a set compares with the same ordinal last time.
enum GhostVerdict {
  /// More volume; on equal volume more load, then more reps (bodyweight).
  ahead,
  level,
  behind,

  /// Nothing to judge yet (no reps entered: the current set's untouched
  /// target). The ghost's values are still filled in.
  pending,

  /// Last time had no set at this ordinal (or it was skipped).
  newSet,
}

class SetGhostLine {
  const SetGhostLine({
    required this.verdict,
    this.ghostLoadG,
    this.ghostReps,
    this.loadDeltaG,
    this.repsDelta,
    this.paceDeltaMs,
    this.baseline = false,
  });

  final GhostVerdict verdict;

  /// Compared with a starting weight, not last time (0.3 S1): always
  /// [GhostVerdict.pending], load only.
  final bool baseline;
  final int? ghostLoadG;
  final int? ghostReps;

  /// This time minus last time; null when either side is missing.
  final int? loadDeltaG;
  final int? repsDelta;

  /// Negative = this set ended earlier into the session than last time
  /// (he is ahead of the ghost's pace). Null without both offsets.
  final int? paceDeltaMs;
}

/// Compares one set (done, or the current set's targets) with the ghost.
SetGhostLine compareSet({
  required ExerciseGhost ghost,
  required int setOrdinal,
  int? loadG,
  int? reps,
  int? offsetMs,
}) {
  final g = ghost.byOrdinal(setOrdinal);
  if (ghost.baseline && g != null) {
    // A typed weight, not a lifted set: nothing to beat, so no verdict.
    return SetGhostLine(
      verdict: GhostVerdict.pending,
      ghostLoadG: g.loadG,
      loadDeltaG: (loadG == null || g.loadG == null) ? null : loadG - g.loadG!,
      baseline: true,
    );
  }
  if (g == null || g.skipped) {
    return const SetGhostLine(verdict: GhostVerdict.newSet);
  }
  final ld = (loadG == null || g.loadG == null) ? null : loadG - g.loadG!;
  final rd = (reps == null || g.reps == null) ? null : reps - g.reps!;
  final pd = (offsetMs == null || g.offsetMs == null)
      ? null
      : offsetMs - g.offsetMs!;
  if (reps == null) {
    return SetGhostLine(
      verdict: GhostVerdict.pending,
      ghostLoadG: g.loadG,
      ghostReps: g.reps,
      loadDeltaG: ld,
      paceDeltaMs: pd,
    );
  }
  final now = (loadG ?? 0) * reps;
  final then = g.volumeGReps;
  final GhostVerdict v;
  if (now > then) {
    v = GhostVerdict.ahead;
  } else if (now < then) {
    v = GhostVerdict.behind;
  } else if ((ld ?? 0) > 0) {
    v = GhostVerdict.ahead;
  } else if ((ld ?? 0) < 0) {
    v = GhostVerdict.behind;
  } else if ((rd ?? 0) > 0) {
    // Same volume and load: bodyweight sets (no load, volume 0) land here.
    v = GhostVerdict.ahead;
  } else if ((rd ?? 0) < 0) {
    v = GhostVerdict.behind;
  } else {
    v = GhostVerdict.level;
  }
  return SetGhostLine(
    verdict: v,
    ghostLoadG: g.loadG,
    ghostReps: g.reps,
    loadDeltaG: ld,
    repsDelta: rd,
    paceDeltaMs: pd,
  );
}

/// One done set this session, for the session total. Leave skipped sets
/// out (`doneSetsOf` does) and pass each ordinal once.
typedef DoneSet = ({String exerciseId, int setOrdinal, int volumeGReps});

/// The session-total line (N3): volume so far against what he had done by
/// the same sets last time, over exercises that have a ghost.
class SessionGhostTotal {
  const SessionGhostTotal({
    required this.volumeGReps,
    required this.ghostSoFarGReps,
    required this.ghostFullGReps,
    required this.exercisesCompared,
  });

  /// This session's volume on compared exercises.
  final int volumeGReps;

  /// Last time's volume on the same exercises, through the same ordinals.
  final int ghostSoFarGReps;

  /// Last time's full volume on those exercises.
  final int ghostFullGReps;
  final int exercisesCompared;

  int get deltaGReps => volumeGReps - ghostSoFarGReps;

  /// Percent change against the matched ghost; null when it had no volume.
  double? get deltaPct =>
      ghostSoFarGReps == 0 ? null : deltaGReps * 100 / ghostSoFarGReps;
}

/// Null when no exercise in this session has a ghost (first session, or all
/// new exercises): the line is hidden.
SessionGhostTotal? sessionTotal({
  required Map<String, ExerciseGhost?> ghosts,
  required Iterable<DoneSet> done,
}) {
  // Like for like: last time's sets at exactly the ordinals done this time,
  // so an ordinal not reached (or skipped) yet never counts against him.
  // Matched by the map key on both sides.
  var vol = 0;
  var soFar = 0;
  for (final d in done) {
    final g = ghosts[d.exerciseId];
    if (g == null || g.baseline) continue;
    vol += d.volumeGReps;
    soFar += g.byOrdinal(d.setOrdinal)?.volumeGReps ?? 0;
  }
  // A starting weight is not a session: it is never compared.
  final compared = [
    for (final g in ghosts.values)
      if (g != null && !g.baseline) g,
  ];
  if (compared.isEmpty) return null;
  return SessionGhostTotal(
    volumeGReps: vol,
    ghostSoFarGReps: soFar,
    ghostFullGReps: compared.fold(0, (a, g) => a + g.volumeGReps),
    exercisesCompared: compared.length,
  );
}
