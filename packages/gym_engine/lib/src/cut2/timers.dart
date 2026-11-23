/// EMOM / AMRAP / interval timed blocks (plan 16 Q9, R4). Pure Dart.
///
/// Dart never sounds a cue. A block compiles to a cue list of offsets from
/// the block start; WorkoutService runs that list from `elapsedRealtime`
/// (Kotlin `CuePlan`/`CueClock`), and the UI derives its countdown from
/// [TimerBlock.stateAt] with the elapsed time since the anchor, never from an
/// accumulating `Timer`. The cue vectors in `test/cut2/fixtures/timer_cues/`
/// are the contract both sides test against.
///
/// Times are integer milliseconds. A timed block is journaled as one set row
/// (`kind = timed`) carrying [TimerBlock.toJson] and a [TimedResult]; it is
/// left out of load volume and the one-tap rate, and still lights its muscles.
library;

/// The three block types.
enum TimerType {
  /// Every minute on the minute: a cue at the start of each period.
  emom('emom'),

  /// As many rounds as possible under a cap; rounds are entered at the end.
  amrap('amrap'),

  /// Work/rest alternation for a number of rounds (e.g. 20 s / 10 s x 8).
  interval('interval');

  const TimerType(this.wire);
  final String wire;

  static TimerType fromWire(String w) => values.firstWhere(
    (t) => t.wire == w,
    orElse: () => throw FormatException('unknown timer type: $w'),
  );
}

/// What a cue means. Wire names are shared with Kotlin `CueKind`
/// (`emom_minute` already exists there).
enum TimerCueKind {
  /// Lead-in finished: the block starts. Only emitted when there is a lead-in.
  go('go'),

  /// Start of an EMOM period (also the first one when there is no lead-in).
  emomMinute('emom_minute'),

  /// Start of an interval work phase.
  intervalWork('interval_work'),

  /// Start of an interval rest phase.
  intervalRest('interval_rest'),

  /// AMRAP: a warning a fixed time before the cap.
  amrapWarn('amrap_warn'),

  /// The block is over (EMOM end, interval last work end, AMRAP cap).
  blockEnd('block_end');

  const TimerCueKind(this.wire);
  final String wire;

  static TimerCueKind fromWire(String w) => values.firstWhere(
    (k) => k.wire == w,
    orElse: () => throw FormatException('unknown cue kind: $w'),
  );
}

/// One cue: fire at block anchor + [atMs].
class TimerCue {
  const TimerCue(this.index, this.kind, this.atMs, this.label);

  final int index;
  final TimerCueKind kind;
  final int atMs;
  final String label;

  Map<String, Object?> toJson() => {
    'index': index,
    'kind': kind.wire,
    'at_ms': atMs,
    'label': label,
  };

  factory TimerCue.fromJson(Map<String, Object?> j) => TimerCue(
    j['index'] as int,
    TimerCueKind.fromWire(j['kind'] as String),
    j['at_ms'] as int,
    j['label'] as String,
  );

  @override
  bool operator ==(Object other) =>
      other is TimerCue &&
      other.index == index &&
      other.kind == kind &&
      other.atMs == atMs &&
      other.label == label;

  @override
  int get hashCode => Object.hash(index, kind, atMs, label);

  @override
  String toString() => 'TimerCue($index, ${kind.wire}, $atMs, $label)';
}

/// Limits that keep a block sane and a wake lock bounded (R4).
abstract final class TimerLimits {
  static const int minPeriodMs = 5000;
  static const int maxPeriodMs = 10 * 60000;
  static const int minRestMs = 0;
  static const int maxRounds = 99;
  static const int maxLeadInMs = 60000;
  static const int maxBlockMs = 2 * 60 * 60000;
  static const int minCapMs = 60000;
}

/// Phase of a running block, for the UI.
enum TimerPhase { leadIn, work, rest, done }

/// Where a block is at a given elapsed time since its anchor.
class TimerState {
  const TimerState({
    required this.phase,
    required this.round,
    required this.rounds,
    required this.phaseRemainingMs,
    required this.totalRemainingMs,
  });

  final TimerPhase phase;

  /// 1-based round in progress; 0 in the lead-in. For AMRAP it is 1 for the
  /// whole block (rounds are counted by him, not the clock), and [rounds] is 0.
  final int round;
  final int rounds;

  /// Milliseconds until this phase ends (0 when done).
  final int phaseRemainingMs;

  /// Milliseconds until the block ends (0 when done).
  final int totalRemainingMs;

  @override
  bool operator ==(Object other) =>
      other is TimerState &&
      other.phase == phase &&
      other.round == round &&
      other.rounds == rounds &&
      other.phaseRemainingMs == phaseRemainingMs &&
      other.totalRemainingMs == totalRemainingMs;

  @override
  int get hashCode =>
      Object.hash(phase, round, rounds, phaseRemainingMs, totalRemainingMs);

  @override
  String toString() =>
      'TimerState(${phase.name}, $round/$rounds, '
      'phase ${phaseRemainingMs}ms, total ${totalRemainingMs}ms)';
}

/// A timed block definition. Use the named constructors; they validate.
class TimerBlock {
  const TimerBlock._({
    required this.type,
    required this.workMs,
    required this.restMs,
    required this.rounds,
    required this.capMs,
    required this.leadInMs,
    required this.warnMs,
  });

  /// [rounds] periods of [periodMs] (default one minute).
  factory TimerBlock.emom({
    required int rounds,
    int periodMs = 60000,
    int leadInMs = 0,
  }) => TimerBlock._validated(
    type: TimerType.emom,
    workMs: periodMs,
    restMs: 0,
    rounds: rounds,
    capMs: 0,
    leadInMs: leadInMs,
    warnMs: 0,
  );

  /// One block capped at [capMs]; optional warning [warnMs] before the cap.
  factory TimerBlock.amrap({
    required int capMs,
    int leadInMs = 0,
    int warnMs = 60000,
  }) => TimerBlock._validated(
    type: TimerType.amrap,
    workMs: 0,
    restMs: 0,
    rounds: 0,
    capMs: capMs,
    leadInMs: leadInMs,
    warnMs: warnMs,
  );

  /// [rounds] of [workMs] work then [restMs] rest; the last round has no rest.
  factory TimerBlock.interval({
    required int workMs,
    required int restMs,
    required int rounds,
    int leadInMs = 0,
  }) => TimerBlock._validated(
    type: TimerType.interval,
    workMs: workMs,
    restMs: restMs,
    rounds: rounds,
    capMs: 0,
    leadInMs: leadInMs,
    warnMs: 0,
  );

  factory TimerBlock._validated({
    required TimerType type,
    required int workMs,
    required int restMs,
    required int rounds,
    required int capMs,
    required int leadInMs,
    required int warnMs,
  }) {
    void check(bool ok, String what) {
      if (!ok) throw ArgumentError('timer block: $what');
    }

    check(
      leadInMs >= 0 && leadInMs <= TimerLimits.maxLeadInMs,
      'lead-in $leadInMs',
    );
    switch (type) {
      case TimerType.emom:
        check(
          workMs >= TimerLimits.minPeriodMs &&
              workMs <= TimerLimits.maxPeriodMs,
          'period $workMs',
        );
        check(rounds >= 1 && rounds <= TimerLimits.maxRounds, 'rounds $rounds');
      case TimerType.interval:
        check(
          workMs >= TimerLimits.minPeriodMs &&
              workMs <= TimerLimits.maxPeriodMs,
          'work $workMs',
        );
        check(
          restMs >= TimerLimits.minRestMs && restMs <= TimerLimits.maxPeriodMs,
          'rest $restMs',
        );
        check(rounds >= 1 && rounds <= TimerLimits.maxRounds, 'rounds $rounds');
      case TimerType.amrap:
        check(
          capMs >= TimerLimits.minCapMs && capMs <= TimerLimits.maxBlockMs,
          'cap $capMs',
        );
        check(warnMs >= 0 && warnMs < capMs, 'warn $warnMs');
    }
    final b = TimerBlock._(
      type: type,
      workMs: workMs,
      restMs: restMs,
      rounds: rounds,
      capMs: capMs,
      leadInMs: leadInMs,
      warnMs: warnMs,
    );
    check(b.totalMs <= TimerLimits.maxBlockMs + leadInMs, 'total ${b.totalMs}');
    return b;
  }

  final TimerType type;

  /// EMOM period, or interval work phase. 0 for AMRAP.
  final int workMs;

  /// Interval rest phase. 0 otherwise.
  final int restMs;

  /// EMOM periods or interval rounds. 0 for AMRAP.
  final int rounds;

  /// AMRAP cap. 0 otherwise.
  final int capMs;

  /// Get-ready time before the block starts; cues are offset by it.
  final int leadInMs;

  /// AMRAP: warn this long before the cap (0 = no warning).
  final int warnMs;

  /// Length of the block itself, lead-in excluded.
  int get blockMs => switch (type) {
    TimerType.emom => rounds * workMs,
    TimerType.amrap => capMs,
    TimerType.interval => rounds * workMs + (rounds - 1) * restMs,
  };

  /// Lead-in plus block.
  int get totalMs => leadInMs + blockMs;

  /// Short human name: "EMOM 20 × 1:00", "AMRAP 12:00", "Interval 8 × 0:20 / 0:10".
  String get title => switch (type) {
    TimerType.emom => 'EMOM $rounds × ${formatClock(workMs)}',
    TimerType.amrap => 'AMRAP ${formatClock(capMs)}',
    TimerType.interval =>
      'Interval $rounds × ${formatClock(workMs)} / ${formatClock(restMs)}',
  };

  /// The cue list the service runs, ordered by time, indexed from 0.
  List<TimerCue> cues() {
    final out = <(TimerCueKind, int, String)>[];
    final l = leadInMs;
    switch (type) {
      case TimerType.emom:
        for (var k = 0; k < rounds; k++) {
          out.add((
            TimerCueKind.emomMinute,
            l + k * workMs,
            'EMOM ${k + 1} of $rounds',
          ));
        }
      case TimerType.interval:
        final cycle = workMs + restMs;
        for (var k = 0; k < rounds; k++) {
          out.add((
            TimerCueKind.intervalWork,
            l + k * cycle,
            'Work ${k + 1} of $rounds',
          ));
          if (k < rounds - 1 && restMs > 0) {
            out.add((
              TimerCueKind.intervalRest,
              l + k * cycle + workMs,
              'Rest ${k + 1} of ${rounds - 1}',
            ));
          }
        }
      case TimerType.amrap:
        if (l > 0) out.add((TimerCueKind.go, l, 'Go'));
        if (warnMs > 0) {
          out.add((
            TimerCueKind.amrapWarn,
            l + capMs - warnMs,
            '${formatClock(warnMs)} left',
          ));
        }
    }
    out.add((TimerCueKind.blockEnd, totalMs, 'Done'));
    return [
      for (var i = 0; i < out.length; i++)
        TimerCue(i, out[i].$1, out[i].$2, out[i].$3),
    ];
  }

  /// State at [elapsedMs] since the anchor (lead-in start). Negative clamps
  /// to 0; past the end is [TimerPhase.done].
  TimerState stateAt(int elapsedMs) {
    final t = elapsedMs < 0 ? 0 : elapsedMs;
    final total = totalMs;
    if (t >= total) {
      return TimerState(
        phase: TimerPhase.done,
        round: rounds,
        rounds: rounds,
        phaseRemainingMs: 0,
        totalRemainingMs: 0,
      );
    }
    final left = total - t;
    if (t < leadInMs) {
      return TimerState(
        phase: TimerPhase.leadIn,
        round: 0,
        rounds: rounds,
        phaseRemainingMs: leadInMs - t,
        totalRemainingMs: left,
      );
    }
    final b = t - leadInMs;
    switch (type) {
      case TimerType.amrap:
        return TimerState(
          phase: TimerPhase.work,
          round: 1,
          rounds: 0,
          phaseRemainingMs: capMs - b,
          totalRemainingMs: left,
        );
      case TimerType.emom:
        final k = b ~/ workMs;
        return TimerState(
          phase: TimerPhase.work,
          round: k + 1,
          rounds: rounds,
          phaseRemainingMs: (k + 1) * workMs - b,
          totalRemainingMs: left,
        );
      case TimerType.interval:
        final cycle = workMs + restMs;
        final k = b ~/ cycle;
        final inCycle = b - k * cycle;
        final working = inCycle < workMs;
        return TimerState(
          phase: working ? TimerPhase.work : TimerPhase.rest,
          round: k + 1,
          rounds: rounds,
          phaseRemainingMs: working ? workMs - inCycle : cycle - inCycle,
          totalRemainingMs: left,
        );
    }
  }

  /// The `block` object for the timed set in the session snapshot (agreed
  /// with t5v, 23-Nov): the definition plus the compiled cue list, so Kotlin
  /// runs exactly these cues and needs no compiler of its own.
  ///
  /// [startedAtWallMs] is null until he taps Start. On a resume after pause,
  /// pass the new wall-clock anchor and [elapsedBeforeMs] (block time already
  /// run, lead-in included): cues already behind are dropped and the rest are
  /// re-based so `at_ms` is again an offset from [startedAtWallMs]. Each cue
  /// keeps its original `index`, so Kotlin's set_id + index key never fires a
  /// cue twice across a pause.
  Map<String, Object?> toSnapshotBlock({
    int? startedAtWallMs,
    int elapsedBeforeMs = 0,
  }) {
    if (elapsedBeforeMs < 0 || elapsedBeforeMs > totalMs) {
      throw ArgumentError('elapsedBeforeMs $elapsedBeforeMs');
    }
    return {
      ...toJson(),
      'started_at_wall_ms': startedAtWallMs,
      'elapsed_before_ms': elapsedBeforeMs,
      'cues': [
        for (final c in cues())
          if (c.atMs > elapsedBeforeMs || (elapsedBeforeMs == 0 && c.atMs == 0))
            {
              'index': c.index,
              'at_ms': c.atMs - elapsedBeforeMs,
              'kind': c.kind.wire,
              'label': c.label,
            },
      ],
    };
  }

  Map<String, Object?> toJson() => {
    'type': type.wire,
    'work_ms': workMs,
    'rest_ms': restMs,
    'rounds': rounds,
    'cap_ms': capMs,
    'lead_in_ms': leadInMs,
    'warn_ms': warnMs,
  };

  /// Decodes and re-validates; a bad block throws (ArgumentError or
  /// FormatException) rather than producing a cue list the service can't run.
  factory TimerBlock.fromJson(Map<String, Object?> j) {
    int i(String k) => (j[k] as int?) ?? 0;
    return TimerBlock._validated(
      type: TimerType.fromWire(j['type'] as String),
      workMs: i('work_ms'),
      restMs: i('rest_ms'),
      rounds: i('rounds'),
      capMs: i('cap_ms'),
      leadInMs: i('lead_in_ms'),
      warnMs: i('warn_ms'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TimerBlock &&
      other.type == type &&
      other.workMs == workMs &&
      other.restMs == restMs &&
      other.rounds == rounds &&
      other.capMs == capMs &&
      other.leadInMs == leadInMs &&
      other.warnMs == warnMs;

  @override
  int get hashCode =>
      Object.hash(type, workMs, restMs, rounds, capMs, leadInMs, warnMs);

  @override
  String toString() => 'TimerBlock(${toJson()})';
}

/// What he logged for a finished (or stopped) block.
class TimedResult {
  const TimedResult({
    this.roundMarksMs = const [],
    this.amrapRounds,
    this.amrapExtraReps,
    this.stoppedAtMs,
  });

  /// Optional taps ("round done"), offsets from the block start (lead-in
  /// excluded), ascending.
  final List<int> roundMarksMs;

  /// AMRAP only: full rounds completed, entered at the end.
  final int? amrapRounds;

  /// AMRAP only: reps into the unfinished round.
  final int? amrapExtraReps;

  /// Set when he stopped the block early: offset from the block start.
  final int? stoppedAtMs;

  /// Checks the result against its block. Returns a list of problems; empty
  /// means valid.
  List<String> problems(TimerBlock block) {
    final p = <String>[];
    var prev = -1;
    for (final m in roundMarksMs) {
      if (m < 0 || m > block.blockMs) p.add('mark $m outside block');
      if (m < prev) p.add('marks not ascending');
      prev = m;
    }
    final isAmrap = block.type == TimerType.amrap;
    if (!isAmrap && (amrapRounds != null || amrapExtraReps != null)) {
      p.add('AMRAP fields on a ${block.type.wire} block');
    }
    if ((amrapRounds ?? 0) < 0 || (amrapRounds ?? 0) > 999) {
      p.add('rounds $amrapRounds');
    }
    if ((amrapExtraReps ?? 0) < 0 || (amrapExtraReps ?? 0) > 999) {
      p.add('extra reps $amrapExtraReps');
    }
    final s = stoppedAtMs;
    if (s != null && (s < 0 || s > block.blockMs)) p.add('stop $s outside');
    return p;
  }

  Map<String, Object?> toJson() => {
    'round_marks_ms': roundMarksMs,
    'amrap_rounds': amrapRounds,
    'amrap_extra_reps': amrapExtraReps,
    'stopped_at_ms': stoppedAtMs,
  };

  factory TimedResult.fromJson(Map<String, Object?> j) => TimedResult(
    roundMarksMs: [
      for (final m in (j['round_marks_ms'] as List? ?? const [])) m as int,
    ],
    amrapRounds: j['amrap_rounds'] as int?,
    amrapExtraReps: j['amrap_extra_reps'] as int?,
    stoppedAtMs: j['stopped_at_ms'] as int?,
  );

  @override
  bool operator ==(Object other) =>
      other is TimedResult &&
      _intListEq(other.roundMarksMs, roundMarksMs) &&
      other.amrapRounds == amrapRounds &&
      other.amrapExtraReps == amrapExtraReps &&
      other.stoppedAtMs == stoppedAtMs;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(roundMarksMs),
    amrapRounds,
    amrapExtraReps,
    stoppedAtMs,
  );
}

/// The presets the picker offers first. Values only; he can edit any field.
final List<({String id, TimerBlock block})> timerPresets = [
  (id: 'emom10', block: TimerBlock.emom(rounds: 10, leadInMs: 10000)),
  (id: 'emom20', block: TimerBlock.emom(rounds: 20, leadInMs: 10000)),
  (id: 'amrap12', block: TimerBlock.amrap(capMs: 12 * 60000, leadInMs: 10000)),
  (
    id: 'tabata',
    block: TimerBlock.interval(
      workMs: 20000,
      restMs: 10000,
      rounds: 8,
      leadInMs: 10000,
    ),
  ),
  (
    id: 'int40_20',
    block: TimerBlock.interval(
      workMs: 40000,
      restMs: 20000,
      rounds: 10,
      leadInMs: 10000,
    ),
  ),
];

/// "m:ss" for under an hour, "h:mm:ss" past it. Rounds up to whole seconds,
/// so a countdown shows 0:01 until it truly ends.
String formatClock(int ms) {
  final s = ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = (s % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

bool _intListEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
