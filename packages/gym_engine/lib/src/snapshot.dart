/// Session snapshot schema v1: the Pigeon event payload, the journal line and
/// the finish payload (integration ruling 2). Spec:
/// `contracts/session_snapshot.md`. The Kotlin twin lives in `android/core`.
///
/// Encoding is canonical so both sides produce the same bytes: keys in the
/// order written in [SessionSnapshot.toJson] (and its children), no
/// whitespace, `null` written out (never omitted), integers only.
library;

import 'dart:convert';

import 'model.dart';

const int snapshotSchema = 1;

enum SetState { pending, done, skipped }

enum SessionState { active, paused }

class SnapshotSet {
  const SnapshotSet({
    required this.setId,
    required this.setOrdinal,
    this.kind = SetKind.reps,
    this.planLoadG,
    this.planReps,
    this.targetLoadG,
    this.targetReps,
    this.state = SetState.pending,
    this.loadG,
    this.reps,
    this.completion,
    this.source,
    this.startedAtMs,
    this.endedAtMs,
    this.offsetMs,
    this.block,
  });

  final String setId;
  final int setOrdinal;
  final SetKind kind;

  /// The engine's prefill, fixed at plan time. Completion is judged against
  /// it: Done with exactly these values is `tap_unchanged`.
  final int? planLoadG;
  final int? planReps;

  /// What Done will log if he does not touch it. Null load = cold start or
  /// bodyweight with nothing added.
  final int? targetLoadG;
  final int? targetReps;

  final SetState state;
  final int? loadG;
  final int? reps;
  final Completion? completion;
  final SetSource? source;
  final int? startedAtMs;
  final int? endedAtMs;
  final int? offsetMs;

  /// Timer block definition and marks (R4); opaque JSON object, cut 2.
  final Map<String, Object?>? block;

  SnapshotSet copyWith({
    int? setOrdinal,
    Object? targetLoadG = _keep,
    Object? targetReps = _keep,
    SetState? state,
    Object? loadG = _keep,
    Object? reps = _keep,
    Object? completion = _keep,
    Object? source = _keep,
    Object? startedAtMs = _keep,
    Object? endedAtMs = _keep,
    Object? offsetMs = _keep,
  }) => SnapshotSet(
    setId: setId,
    setOrdinal: setOrdinal ?? this.setOrdinal,
    kind: kind,
    planLoadG: planLoadG,
    planReps: planReps,
    targetLoadG: _pick(targetLoadG, this.targetLoadG),
    targetReps: _pick(targetReps, this.targetReps),
    state: state ?? this.state,
    loadG: _pick(loadG, this.loadG),
    reps: _pick(reps, this.reps),
    completion: _pick(completion, this.completion),
    source: _pick(source, this.source),
    startedAtMs: _pick(startedAtMs, this.startedAtMs),
    endedAtMs: _pick(endedAtMs, this.endedAtMs),
    offsetMs: _pick(offsetMs, this.offsetMs),
    block: block,
  );

  Map<String, Object?> toJson() => {
    'set_id': setId,
    'set_ordinal': setOrdinal,
    'kind': kind.name,
    'plan_load_g': planLoadG,
    'plan_reps': planReps,
    'target_load_g': targetLoadG,
    'target_reps': targetReps,
    'state': state.name,
    'load_g': loadG,
    'reps': reps,
    'completion': completion?.wire,
    'source': source?.name,
    'started_at_ms': startedAtMs,
    'ended_at_ms': endedAtMs,
    'offset_ms': offsetMs,
    'block': block,
  };

  static const keys = [
    'set_id', 'set_ordinal', 'kind', 'plan_load_g', 'plan_reps', //
    'target_load_g', 'target_reps', 'state', 'load_g', 'reps', 'completion',
    'source', 'started_at_ms', 'ended_at_ms', 'offset_ms', 'block',
  ];

  factory SnapshotSet.fromJson(Map<String, Object?> j) =>
      _fromJson(_require(j, keys, 'set'));

  static SnapshotSet _fromJson(Map<String, Object?> j) => SnapshotSet(
    setId: j['set_id'] as String,
    setOrdinal: j['set_ordinal'] as int,
    kind: SetKind.values.byName(j['kind'] as String),
    planLoadG: j['plan_load_g'] as int?,
    planReps: j['plan_reps'] as int?,
    targetLoadG: j['target_load_g'] as int?,
    targetReps: j['target_reps'] as int?,
    state: SetState.values.byName(j['state'] as String),
    loadG: j['load_g'] as int?,
    reps: j['reps'] as int?,
    completion: j['completion'] == null
        ? null
        : Completion.fromWire(j['completion'] as String),
    source: j['source'] == null
        ? null
        : SetSource.values.byName(j['source'] as String),
    startedAtMs: j['started_at_ms'] as int?,
    endedAtMs: j['ended_at_ms'] as int?,
    offsetMs: j['offset_ms'] as int?,
    block: (j['block'] as Map?)?.cast<String, Object?>(),
  );
}

class SnapshotExercise {
  const SnapshotExercise({
    required this.exerciseId,
    required this.name,
    required this.loadKind,
    required this.restS,
    required this.sets,
    this.unilateral = false,
    this.repLo,
    this.repHi,
  });

  final String exerciseId;
  final String name;

  /// `dumbbell` (per hand), `stack`, `barbell`, `bodyweight`, `timed`, ...
  final String loadKind;
  final bool unilateral;
  final int restS;
  final int? repLo;
  final int? repHi;
  final List<SnapshotSet> sets;

  SnapshotExercise withSets(List<SnapshotSet> sets) => SnapshotExercise(
    exerciseId: exerciseId,
    name: name,
    loadKind: loadKind,
    restS: restS,
    sets: sets,
    unilateral: unilateral,
    repLo: repLo,
    repHi: repHi,
  );

  bool get anyLogged => sets.any((s) => s.state != SetState.pending);

  Map<String, Object?> toJson() => {
    'exercise_id': exerciseId,
    'name': name,
    'load_kind': loadKind,
    'unilateral': unilateral,
    'rest_s': restS,
    'rep_lo': repLo,
    'rep_hi': repHi,
    'sets': [for (final s in sets) s.toJson()],
  };

  static const keys = [
    'exercise_id', 'name', 'load_kind', 'unilateral', 'rest_s', 'rep_lo', //
    'rep_hi', 'sets',
  ];

  factory SnapshotExercise.fromJson(Map<String, Object?> j) =>
      _fromJson(_require(j, keys, 'exercise'));

  static SnapshotExercise _fromJson(Map<String, Object?> j) => SnapshotExercise(
    exerciseId: j['exercise_id'] as String,
    name: j['name'] as String,
    loadKind: j['load_kind'] as String,
    unilateral: j['unilateral'] as bool,
    restS: j['rest_s'] as int,
    repLo: j['rep_lo'] as int?,
    repHi: j['rep_hi'] as int?,
    sets: [
      for (final s in j['sets'] as List)
        SnapshotSet.fromJson((s as Map).cast<String, Object?>()),
    ],
  );
}

/// A running rest. Kotlin re-anchors it to elapsedRealtime on receipt.
class Rest {
  const Rest({
    required this.setId,
    required this.endsAtWallMs,
    required this.durationMs,
  });

  /// The set whose Done started this rest.
  final String setId;
  final int endsAtWallMs;
  final int durationMs;

  Map<String, Object?> toJson() => {
    'set_id': setId,
    'ends_at_wall_ms': endsAtWallMs,
    'duration_ms': durationMs,
  };

  static const keys = ['set_id', 'ends_at_wall_ms', 'duration_ms'];

  factory Rest.fromJson(Map<String, Object?> j) =>
      _fromJson(_require(j, keys, 'rest'));

  static Rest _fromJson(Map<String, Object?> j) => Rest(
    setId: j['set_id'] as String,
    endsAtWallMs: j['ends_at_wall_ms'] as int,
    durationMs: j['duration_ms'] as int,
  );
}

class SessionSnapshot {
  /// Every key, in canonical order. All required on decode (null allowed
  /// where the field is nullable); extra keys are ignored.
  static const topKeys = [
    'schema', 'workout_uuid', 'rev', 'app_version', 'gym_id', 'type_id', //
    'muscles', 'started_at_ms', 'tz_offset_min', 'state', 'paused_at_ms',
    'paused_total_ms', 'rest', 'finished', 'ended_at_ms', 'set_ready_at_ms',
    'next_set_n', 'swaps', 'exercises',
  ];

  const SessionSnapshot({
    required this.workoutUuid,
    required this.rev,
    required this.gymId,
    required this.startedAtMs,
    required this.tzOffsetMin,
    required this.exercises,
    this.schema = snapshotSchema,
    this.appVersion = '',
    this.typeId,
    this.muscles = const [],
    this.state = SessionState.active,
    this.pausedAtMs,
    this.pausedTotalMs = 0,
    this.rest,
    this.finished = false,
    this.endedAtMs,
    this.setReadyAtMs,
    this.nextSetN,
    this.swaps = 0,
  });

  final int schema;
  final String workoutUuid;

  /// Kotlin is the rev authority (submitSnapshot(json, baseRev)).
  final int rev;
  final String appVersion;
  final String gymId;
  final String? typeId;
  final List<String> muscles;
  final int startedAtMs;
  final int tzOffsetMin;
  final SessionState state;
  final int? pausedAtMs;
  final int pausedTotalMs;
  final Rest? rest;
  final bool finished;
  final int? endedAtMs;

  /// When the current set became ready: session start, a rest's end, a
  /// skipped rest, or a resume. A Done logs its set as started here (capped
  /// at now), so rest and paused time are not set time (R2 HR join).
  final int? setReadyAtMs;

  /// The next set id number (`<uuid>:<n>`); never reused. Null in older
  /// lines: derived from the highest id present.
  final int? nextSetN;

  /// Exercises swapped out in this session (plan 3 gate: median swaps).
  final int swaps;
  final List<SnapshotExercise> exercises;

  /// (exercise index, set index) of the first pending set, or null.
  ({int exercise, int set})? get current {
    for (var e = 0; e < exercises.length; e++) {
      final sets = exercises[e].sets;
      for (var s = 0; s < sets.length; s++) {
        if (sets[s].state == SetState.pending) return (exercise: e, set: s);
      }
    }
    return null;
  }

  SnapshotSet? get currentSet {
    final c = current;
    return c == null ? null : exercises[c.exercise].sets[c.set];
  }

  SessionSnapshot copyWith({
    int? rev,
    SessionState? state,
    Object? pausedAtMs = _keep,
    int? pausedTotalMs,
    Object? rest = _keep,
    bool? finished,
    Object? endedAtMs = _keep,
    Object? setReadyAtMs = _keep,
    int? nextSetN,
    int? swaps,
    List<SnapshotExercise>? exercises,
  }) => SessionSnapshot(
    schema: schema,
    workoutUuid: workoutUuid,
    rev: rev ?? this.rev,
    appVersion: appVersion,
    gymId: gymId,
    typeId: typeId,
    muscles: muscles,
    startedAtMs: startedAtMs,
    tzOffsetMin: tzOffsetMin,
    state: state ?? this.state,
    pausedAtMs: _pick(pausedAtMs, this.pausedAtMs),
    pausedTotalMs: pausedTotalMs ?? this.pausedTotalMs,
    rest: _pick(rest, this.rest),
    finished: finished ?? this.finished,
    endedAtMs: _pick(endedAtMs, this.endedAtMs),
    setReadyAtMs: _pick(setReadyAtMs, this.setReadyAtMs),
    nextSetN: nextSetN ?? this.nextSetN,
    swaps: swaps ?? this.swaps,
    exercises: exercises ?? this.exercises,
  );

  Map<String, Object?> toJson() => {
    'schema': schema,
    'workout_uuid': workoutUuid,
    'rev': rev,
    'app_version': appVersion,
    'gym_id': gymId,
    'type_id': typeId,
    'muscles': muscles,
    'started_at_ms': startedAtMs,
    'tz_offset_min': tzOffsetMin,
    'state': state.name,
    'paused_at_ms': pausedAtMs,
    'paused_total_ms': pausedTotalMs,
    'rest': rest?.toJson(),
    'finished': finished,
    'ended_at_ms': endedAtMs,
    'set_ready_at_ms': setReadyAtMs,
    'next_set_n': nextSetN,
    'swaps': swaps,
    'exercises': [for (final e in exercises) e.toJson()],
  };

  /// Canonical single-line encoding (no trailing newline).
  String encode() => jsonEncode(toJson());

  /// Throws [FormatException] on bad JSON, a wrong shape or an unknown
  /// (newer) schema.
  static SessionSnapshot decode(String json) {
    final Object? raw;
    try {
      raw = jsonDecode(json);
    } on FormatException {
      rethrow;
    }
    if (raw is! Map) throw const FormatException('snapshot is not an object');
    final j = raw.cast<String, Object?>();
    final schema = j['schema'];
    if (schema is! int || schema < 1 || schema > snapshotSchema) {
      throw FormatException('unsupported snapshot schema $schema');
    }
    _require(j, topKeys, 'snapshot');
    if ((j['state'] == 'paused') != (j['paused_at_ms'] is int)) {
      throw const FormatException(
        'paused_at_ms must be set exactly when state is paused',
      );
    }
    final SessionSnapshot snap;
    try {
      snap = SessionSnapshot(
        schema: schema,
        workoutUuid: j['workout_uuid'] as String,
        rev: j['rev'] as int,
        appVersion: j['app_version'] as String,
        gymId: j['gym_id'] as String,
        typeId: j['type_id'] as String?,
        muscles: [for (final m in j['muscles'] as List) m as String],
        startedAtMs: j['started_at_ms'] as int,
        tzOffsetMin: j['tz_offset_min'] as int,
        state: SessionState.values.byName(j['state'] as String),
        pausedAtMs: j['paused_at_ms'] as int?,
        pausedTotalMs: j['paused_total_ms'] as int,
        rest: j['rest'] == null
            ? null
            : Rest.fromJson((j['rest'] as Map).cast<String, Object?>()),
        finished: j['finished'] as bool,
        endedAtMs: j['ended_at_ms'] as int?,
        setReadyAtMs: j['set_ready_at_ms'] as int?,
        nextSetN: j['next_set_n'] as int?,
        swaps: j['swaps'] as int,
        exercises: [
          for (final e in j['exercises'] as List)
            SnapshotExercise.fromJson((e as Map).cast<String, Object?>()),
        ],
      );
    } on TypeError catch (e) {
      throw FormatException('bad snapshot shape: $e');
    } on ArgumentError catch (e) {
      throw FormatException('bad snapshot value: $e');
    }
    final prefix = '${snap.workoutUuid}:';
    var maxN = -1;
    for (final e in snap.exercises) {
      for (final x in e.sets) {
        if (x.setId.startsWith(prefix)) {
          final n = int.tryParse(x.setId.substring(prefix.length));
          if (n != null && n > maxN) maxN = n;
        }
        final done = x.state == SetState.done;
        if (done != (x.completion != null) || done != (x.source != null)) {
          throw FormatException(
            'set ${x.setId}: completion and source are set exactly when done',
          );
        }
      }
    }
    final next = snap.nextSetN;
    if (next != null && next <= maxN) {
      throw FormatException('next_set_n $next would reuse set id $maxN');
    }
    return snap;
  }

  /// Finished sets in the stored form (done and skipped; pending dropped).
  List<SetRecord> toSetRecords() => [
    for (var e = 0; e < exercises.length; e++)
      for (final s in exercises[e].sets)
        if (s.state != SetState.pending)
          SetRecord(
            setId: s.setId,
            exerciseId: exercises[e].exerciseId,
            exerciseName: exercises[e].name,
            exercisePosition: e,
            setOrdinal: s.setOrdinal,
            kind: s.kind,
            loadG: s.loadG,
            reps: s.reps,
            completion: s.completion,
            skipped: s.state == SetState.skipped,
            source: s.source ?? SetSource.app,
            startedAtMs: s.startedAtMs,
            endedAtMs: s.endedAtMs,
            offsetMs: s.offsetMs,
            blockJson: s.block == null ? null : jsonEncode(s.block),
          ),
  ];

  /// The stored form. [endedAtMs] falls back to the last set's end.
  WorkoutRecord toRecord() {
    final sets = toSetRecords();
    var end = endedAtMs ?? startedAtMs;
    if (endedAtMs == null) {
      for (final s in sets) {
        if ((s.endedAtMs ?? 0) > end) end = s.endedAtMs!;
      }
    }
    return WorkoutRecord(
      uuid: workoutUuid,
      gymId: gymId,
      typeId: typeId,
      muscles: muscles,
      startedAtMs: startedAtMs,
      tzOffsetMin: tzOffsetMin,
      endedAtMs: end,
      pausedMs: pausedTotalMs,
      appVersion: appVersion,
      swaps: swaps,
      sets: sets,
    );
  }
}

/// Reads a journal file's text: one snapshot per line. FOR TESTS AND
/// TOOLS: Kotlin is the journal reader of record (`readPendingJournal`
/// returns its last good line).
///
/// Returns the last good line. A half last line is a torn tail (normal after
/// a crash), not corruption. Corrupt = a line before the last that does not
/// decode, or a line with another uuid or a rev that does not rise; those
/// are skipped.
({SessionSnapshot? last, bool tornTail, int corruptLines}) readJournal(
  String text,
) {
  final lines = [
    for (final l in const LineSplitter().convert(text))
      if (l.trim().isNotEmpty) l,
  ];
  final decoded = <SessionSnapshot?>[];
  var torn = false;
  var bad = 0;
  for (var i = 0; i < lines.length; i++) {
    try {
      decoded.add(SessionSnapshot.decode(lines[i]));
    } on FormatException {
      decoded.add(null);
      if (i == lines.length - 1) {
        torn = true;
      } else {
        bad++;
      }
    }
  }
  // The workout is the one in the last good line; a stale leading line from
  // another workout is the corrupt one, not everything after it.
  final uuid = decoded
      .lastWhere((d) => d != null, orElse: () => null)
      ?.workoutUuid;
  SessionSnapshot? last;
  for (final d in decoded) {
    if (d == null) continue;
    if (d.workoutUuid != uuid || (last != null && d.rev <= last.rev)) {
      bad++;
      continue;
    }
    last = d;
  }
  return (last: last, tornTail: torn, corruptLines: bad);
}

Map<String, Object?> _require(
  Map<String, Object?> j,
  List<String> keys,
  String what,
) {
  for (final k in keys) {
    if (!j.containsKey(k)) throw FormatException('$what: missing key "$k"');
  }
  return j;
}

const Object _keep = _Keep();

class _Keep {
  const _Keep();
}

T _pick<T>(Object? v, T current) => identical(v, _keep) ? current : v as T;
