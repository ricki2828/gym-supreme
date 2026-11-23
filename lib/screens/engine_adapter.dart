import 'package:gym_engine/gym_engine.dart' as eng;

import 'body_screen.dart';
import 'diagnostics_panel.dart';
import 'history_screen.dart';
import 'live_screen.dart';
import 'post_workout_screen.dart';
import 'view_models.dart';

/// The one place gym_engine types become UI view models. Screens never
/// import the engine; a contract change touches this file only.

WorkoutType? workoutTypeOf(String? typeId) => switch (typeId) {
  'push' => WorkoutType.push,
  'pull' => WorkoutType.pull,
  'legs' => WorkoutType.legs,
  'engine' => WorkoutType.engine,
  'core' => WorkoutType.core,
  _ => null,
};

LoadUnit unitOf(eng.LoadUnit u) => switch (u) {
  eng.LoadUnit.kg => LoadUnit.kg,
  eng.LoadUnit.ea => LoadUnit.kgEach,
  eng.LoadUnit.bodyweight => LoadUnit.bodyweight,
  eng.LoadUnit.timed => LoadUnit.timed,
};

/// Snapshot exercises carry a load kind, not the engine unit.
LoadUnit unitOfKind(String loadKind) => switch (loadKind) {
  'dumbbell' => LoadUnit.kgEach,
  'stack' || 'barbell' || 'plates' => LoadUnit.kg,
  'timed' || 'distance' => LoadUnit.timed,
  _ => LoadUnit.bodyweight,
};

Map<String, MuscleDays> muscleDaysOf(Map<String, eng.MuscleStatus> status) => {
  for (final e in status.entries)
    e.key: MuscleDays(
      days: e.value.daysSince,
      resting: e.value.resting,
      uncovered: e.value.uncoveredAtGym,
    ),
};

SessionPlanView planViewOf(
  eng.SessionPlan p, {
  required List<String> muscleNames,
}) => SessionPlanView(
  type: workoutTypeOf(p.typeId),
  minutes: p.estimatedMinutes,
  uncovered: muscleNames,
  items: [
    for (final i in p.items)
      PlanItem(
        exerciseId: i.exerciseId,
        name: i.name,
        sets: i.setCount,
        reps: i.sets.isEmpty ? i.repLo : i.sets.first.reps,
        loadG: i.sets.isEmpty ? null : i.sets.first.loadG,
        unit: unitOf(i.unit),
        reason: i.reason,
      ),
  ],
);

/// "Last time 3 × 10 · 22 kg ea" (sets equal) or "Last time 10, 10, 8 · 22 kg ea".
String? lastTimeLine(eng.LastTime? t, LoadUnit unit) {
  if (t == null || t.sets.isEmpty) return null;
  final reps = {for (final s in t.sets) s.reps};
  final loads = {for (final s in t.sets) s.loadG};
  final work = reps.length == 1
      ? '${t.sets.length} × ${t.sets.first.reps}'
      : t.sets.map((s) => s.reps).join(', ');
  final load = loads.length == 1 ? loadLabel(t.sets.first.loadG, unit) : '';
  return load.isEmpty ? 'Last time $work' : 'Last time $work · $load';
}

/// Builds the live screen's view from a snapshot. [nowMs] drives the clock
/// and the rest countdown (wall time, as the service re-anchors its own).
LiveView? liveViewOf(
  eng.SessionSnapshot s, {
  required int nowMs,
  eng.LoadSteps? steps,
  eng.LastTime? Function(String exerciseId)? lastTime,
}) {
  final type = workoutTypeOf(s.typeId);
  final pausedNow = s.state == eng.SessionState.paused && s.pausedAtMs != null
      ? nowMs - s.pausedAtMs!
      : 0;
  final elapsedS =
      ((nowMs - s.startedAtMs - s.pausedTotalMs - pausedNow) / 1000).floor();
  final c = s.current;
  // Finished (even with sets left unlogged) or nothing left: only Finish.
  if (c == null || s.finished) {
    final last = s.exercises.isEmpty ? null : s.exercises.last;
    return LiveView(
      type: type,
      exerciseName: last?.name ?? '',
      lift: s.exercises.length,
      lifts: s.exercises.length,
      set: last?.sets.length ?? 0,
      sets: last?.sets.length ?? 0,
      rail: const [],
      reps: 0,
      loadG: null,
      unit: LoadUnit.bodyweight,
      targetReps: null,
      targetLoadG: null,
      restS: 0,
      upNext: const [],
      elapsedS: elapsedS,
      allDone: true,
    );
  }
  final ex = s.exercises[c.exercise];
  final set = ex.sets[c.set];
  final unit = unitOfKind(ex.loadKind);
  final rest = s.rest;
  final restLeftMs = rest == null ? null : rest.endsAtWallMs - nowMs;
  final load = set.targetLoadG;
  return LiveView(
    type: type,
    exerciseName: ex.name,
    lift: c.exercise + 1,
    lifts: s.exercises.length,
    set: c.set + 1,
    sets: ex.sets.length,
    rail: [
      for (var i = 0; i < ex.sets.length; i++)
        i == c.set
            ? SetTile.current
            : switch (ex.sets[i].state) {
                eng.SetState.done => SetTile.done,
                eng.SetState.skipped => SetTile.skipped,
                eng.SetState.pending => SetTile.pending,
              },
    ],
    reps: set.targetReps ?? ex.repLo ?? 0,
    loadG: load,
    unit: unit,
    targetReps: set.planReps,
    targetLoadG: set.planLoadG,
    lastTime: lastTimeLine(lastTime?.call(ex.exerciseId), unit),
    canLoadUp: steps != null && steps.next(load) != null,
    canLoadDown: steps != null && steps.prev(load) != null,
    restS: ex.restS,
    upNext: [
      for (final e in s.exercises.skip(c.exercise + 1))
        PlanItem(
          exerciseId: e.exerciseId,
          name: e.name,
          sets: e.sets.where((x) => x.state == eng.SetState.pending).length,
          reps: e.sets.isEmpty
              ? (e.repLo ?? 0)
              : (e.sets.first.targetReps ?? 0),
          loadG: e.sets.isEmpty ? null : e.sets.first.targetLoadG,
          unit: unitOfKind(e.loadKind),
        ),
    ],
    restLeftS: restLeftMs == null || restLeftMs <= 0
        ? null
        : (restLeftMs / 1000).ceil(),
    elapsedS: elapsedS < 0 ? 0 : elapsedS,
    paused: s.state == eng.SessionState.paused,
  );
}

/// Picker group sets, weighted primary 1.0 / secondary 0.5, rounded, largest
/// first, empty groups dropped.
List<(String, int)> setsPerGroupOf(Map<String, double> perMuscle) {
  final out = <(String, int)>[];
  for (final g in MuscleGroup.picker) {
    final n = g.muscleIds.fold<double>(0, (a, m) => a + (perMuscle[m] ?? 0));
    if (n.round() > 0) out.add((g.label, n.round()));
  }
  out.sort((a, b) => b.$2.compareTo(a.$2));
  return out;
}

/// Local wall time of a stored UTC instant plus its offset.
DateTime localOf(int utcMs, int tzOffsetMin) =>
    DateTime.fromMillisecondsSinceEpoch(
      utcMs + tzOffsetMin * 60000,
      isUtc: true,
    );

/// Types trained in the Monday week containing [nowLocal], from history.
Set<WorkoutType> weekTypesOf(List<eng.HistoryRow> rows, DateTime nowLocal) {
  final day = DateTime.utc(nowLocal.year, nowLocal.month, nowLocal.day);
  final monday = day.subtract(Duration(days: day.weekday - 1));
  return {
    for (final r in rows)
      if (!localOf(r.startedAtMs, r.tzOffsetMin).isBefore(monday))
        ?workoutTypeOf(r.typeId),
  };
}

PostWorkoutView postWorkoutViewOf(
  eng.WorkoutSummary s, {
  required eng.HistoryRow row,
  required Set<WorkoutType> weekTypes,
  required Map<String, LoadUnit> unitByExercise,
}) => PostWorkoutView(
  type: workoutTypeOf(row.typeId),
  gymName: row.gymName,
  durationS: s.durationMs ~/ 1000,
  volumeKg: s.volumeKg,
  volumeDeltaPct: s.volumeDeltaPct,
  setCount: s.setCount,
  musclesLit: s.musclesLit,
  setsPerGroup: setsPerGroupOf(s.setsPerMuscle),
  weeklyStreak: s.weeklyStreak,
  pbs: [
    for (final p in s.pbs)
      PbView(
        exercise: p.name,
        loadG: p.loadG,
        reps: p.reps,
        unit: unitByExercise[p.exerciseId] ?? LoadUnit.kg,
        wasLoadG: p.wasLoadG,
        wasReps: p.wasReps,
      ),
  ],
  weekTypes: weekTypes,
);

HistoryRowView historyRowOf(eng.HistoryRow r) => HistoryRowView(
  uuid: r.uuid,
  startedAt: localOf(r.startedAtMs, r.tzOffsetMin),
  gymName: r.gymName,
  type: workoutTypeOf(r.typeId),
  durationS: r.durationMs ~/ 1000,
  volumeKg: r.volumeKg,
  setCount: r.setCount,
);

/// The Body tab rows in taxonomy order. [lastTypeOf] names the type of the
/// session that last trained a muscle (null if unknown).
List<BodyMuscle> bodyMusclesOf(
  List<eng.Muscle> muscles,
  Map<String, eng.MuscleStatus> status, {
  WorkoutType? Function(String muscleId)? lastTypeOf,
}) => [
  for (final m in muscles)
    BodyMuscle(
      id: m.id,
      name: m.name,
      days: status[m.id]?.daysSince,
      resting: status[m.id]?.resting ?? false,
      lastType: lastTypeOf?.call(m.id),
    ),
];

/// Day N of the 14-day window from the first session, in local calendar
/// days (the day of the first session is day 1); null before it.
int? dayOfWindow(int? firstSessionAtMs, int nowMs, {int tzOffsetMin = 0}) {
  if (firstSessionAtMs == null) return null;
  DateTime day(int ms) {
    final d = localOf(ms, tzOffsetMin);
    return DateTime.utc(d.year, d.month, d.day);
  }

  return day(nowMs).difference(day(firstSessionAtMs)).inDays + 1;
}

GateView gateViewOf(
  eng.Counters c, {
  required int nowMs,
  int tzOffsetMin = 0,
}) => GateView(
  sessionsTotal: c.sessionsTotal,
  sessionsLast14Days: c.sessionsLast14Days,
  dayOfWindow: dayOfWindow(c.firstSessionAtMs, nowMs, tzOffsetMin: tzOffsetMin),
  doneSets: c.doneSets,
  tapUnchangedSets: c.tapUnchangedSets,
  coldStartSets: c.coldStartSets,
  oneTapRate: c.oneTapRate,
  oneTapRateInclCold: c.oneTapRateInclCold,
  medianSwapsPerSession: c.medianSwapsPerSession,
  appVersions: c.appVersions,
);
