// Writes the session-snapshot contract fixtures (schema v1) from the Dart
// transitions with a fixed clock and uuid. Run from packages/gym_engine:
//   dart run tool/gen_contract_fixtures.dart
// then copy test/fixtures/contract/* byte-identical to
// android/core/src/test/fixtures/contract/ (CI diffs the two).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gym_engine/cut2.dart';
import 'package:gym_engine/gym_engine.dart';

const uuid = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b';
const t0 = 1795400000000; // 2026-11-17T22:13:20Z
const tz = 480; // +08:00

SessionPlan plan() => const SessionPlan(
  gymId: 'b9e1d2c3-0000-4000-8000-00000000c0d0',
  typeId: 'push',
  muscles: ['chest', 'triceps'],
  estimatedMinutes: 30,
  uncovered: [],
  items: [
    PlannedItem(
      exerciseId: 'dumbbell-bench-press',
      name: 'Dumbbell Bench Press',
      unit: LoadUnit.ea,
      sets: [
        PlannedSet(loadG: 22500, reps: 10),
        PlannedSet(loadG: 22500, reps: 10),
        PlannedSet(loadG: 22500, reps: 9),
      ],
      repLo: 8,
      repHi: 12,
      restS: 120,
      reason: '',
      primary: ['chest'],
    ),
    PlannedItem(
      exerciseId: 'cable-triceps-pushdown',
      // En dash, quote, U+2028 and DEL: canonical-encoding traps (raw bytes).
      name: 'Cable Triceps Pushdown – "rope"\u2028\x7f',
      unit: LoadUnit.kg,
      sets: [
        PlannedSet(loadG: null, reps: 12),
        PlannedSet(loadG: null, reps: 12),
      ],
      repLo: 10,
      repHi: 15,
      restS: 75,
      reason: '',
      primary: ['triceps'],
    ),
  ],
);

Map<String, SessionSnapshot> cases() {
  final fresh = Session.start(
    plan(),
    nowMs: t0,
    tzOffsetMin: tz,
    appVersion: '0.1.0+1',
    workoutUuid: uuid,
  );
  final s1 = Session.done(fresh, '$uuid:0', nowMs: t0 + 95000);
  final resting = Session.done(
    s1,
    '$uuid:1',
    nowMs: t0 + 260000,
    reps: 8,
    source: SetSource.lockscreen,
  );
  final midSet = Session.retarget(
    Session.skipRest(resting, nowMs: t0 + 300000),
    '$uuid:2',
    loadG: 20000,
  );
  final paused = Session.pause(midSet, nowMs: t0 + 400000);
  var f = Session.resume(paused, nowMs: t0 + 460000);
  f = Session.done(f, '$uuid:2', nowMs: t0 + 520000);
  f = Session.reorder(f, 1, 0);
  f = Session.done(f, '$uuid:3', nowMs: t0 + 700000, loadG: 25000, reps: 12);
  f = Session.skip(f, '$uuid:4', nowMs: t0 + 760000);
  final finished = Session.finish(f, nowMs: t0 + 800000);
  // 0.3 X1: the same moment as mid_set, but the 20 kg was TYPED on the number
  // pad, so the pending set carries the optional `entry: "typed"` key (the
  // only fixture that has it; the five above are 0.2-shaped and must keep
  // decoding without it).
  final typed = Session.retarget(
    Session.skipRest(resting, nowMs: t0 + 300000),
    '$uuid:2',
    loadG: 20000,
    typed: true,
  );
  return {
    'snapshot_v1_fresh': fresh,
    'snapshot_v1_resting': resting,
    'snapshot_v1_mid_set': midSet,
    'snapshot_v1_paused': paused,
    'snapshot_v1_finished': finished,
    'snapshot_v1_typed': typed,
  };
}

// ---- lock-screen vectors (0.3 cut L1) ------------------------------------
//
// Each `lockscreen_v1_<case>.json` is one line: {case, before, steps, after}.
// `steps` are lock-screen actions; `after[i]` is the snapshot after step i,
// computed here by the Dart transitions the app runs. android/core's
// LockReducerTest replays the steps through the Kotlin reducer and must write
// the same bytes. Never hand-edit an expected snapshot: change the Dart and
// regenerate.

/// The Dart twin of each lock-screen action (LockReducer.kt's header).
SessionSnapshot lockStep(SessionSnapshot s, Map<String, Object?> step) {
  final now = step['now_ms'] as int;
  final id = step['set_id'] as String?;
  switch (step['action']) {
    case 'done':
      return Session.done(s, id!, nowMs: now, source: SetSource.lockscreen);
    case 'plus_rep':
      // LiveController.reps(+1): max(1, target + 1), one retarget.
      SnapshotSet? set;
      for (final e in s.exercises) {
        for (final x in e.sets) {
          if (x.setId == id) set = x;
        }
      }
      return Session.retarget(s, id!, reps: max(1, (set!.targetReps ?? 0) + 1));
    case 'skip_rest':
      return Session.skipRest(s, nowMs: now);
  }
  throw ArgumentError('unknown action ${step['action']}');
}

Map<String, Object?> _step(String action, int n, int at) => {
  'action': action,
  'set_id': action == 'skip_rest' ? null : '$uuid:$n',
  'now_ms': t0 + at,
};

PlannedItem _item(
  String id,
  String name,
  LoadUnit unit,
  List<PlannedSet> sets, {
  int restS = 90,
}) => PlannedItem(
  exerciseId: id,
  name: name,
  unit: unit,
  sets: sets,
  repLo: 6,
  repHi: 15,
  restS: restS,
  reason: '',
  primary: const ['chest'],
);

SessionSnapshot _start(List<PlannedItem> items) => Session.start(
  SessionPlan(
    gymId: 'b9e1d2c3-0000-4000-8000-00000000c0d0',
    typeId: 'push',
    muscles: const ['chest'],
    estimatedMinutes: 30,
    uncovered: const [],
    items: items,
  ),
  nowMs: t0,
  tzOffsetMin: tz,
  appVersion: '0.3.0+1',
  workoutUuid: uuid,
);

/// name -> (before, steps). Every step must change the snapshot.
Map<String, (SessionSnapshot, List<Map<String, Object?>>)> lockCases() {
  final c = cases();
  final fresh = c['snapshot_v1_fresh']!;
  final resting = c['snapshot_v1_resting']!;
  final midSet = c['snapshot_v1_mid_set']!;
  // Bench all logged in the app; the pushdown (stack, no planned load) next,
  // its first set given 30 kg with + in the app.
  var bench = Session.done(fresh, '$uuid:0', nowMs: t0 + 60000);
  bench = Session.done(bench, '$uuid:1', nowMs: t0 + 200000);
  bench = Session.done(bench, '$uuid:2', nowMs: t0 + 340000);
  final pushdown = Session.retarget(
    Session.skipRest(bench, nowMs: t0 + 400000),
    '$uuid:3',
    loadG: 30000,
  );
  final pyramid = Session.retarget(
    _start([
      _item('dumbbell-curl', 'Curl', LoadUnit.ea, const [
        PlannedSet(loadG: 10000, reps: 8),
        PlannedSet(loadG: 10000, reps: 9),
        PlannedSet(loadG: 10000, reps: 10),
      ]),
    ]),
    '$uuid:0',
    reps: 7, // one - in the app first
  );
  final flat = _start([
    _item('cable-row', 'Cable Row', LoadUnit.kg, const [
      PlannedSet(loadG: 40000, reps: 10),
      PlannedSet(loadG: 40000, reps: 10),
      PlannedSet(loadG: 40000, reps: 10),
    ]),
  ]);
  // S1: a starting weight seeds the target only (plan_load_g null), so the
  // first lock-screen Done is a cold start like the app's.
  final fromStart = _start([
    PlannedItem(
      exerciseId: 'incline-db-press',
      name: 'Incline DB Press',
      unit: LoadUnit.ea,
      sets: const [
        PlannedSet(loadG: 20000, reps: 10),
        PlannedSet(loadG: 20000, reps: 10),
      ],
      repLo: 8,
      repHi: 12,
      restS: 90,
      reason: '',
      primary: const ['chest'],
      loadFromStartingWeight: true,
    ),
  ]);
  final bodyweight = _start([
    _item('push-up', 'Push-up', LoadUnit.bodyweight, const [
      PlannedSet(loadG: null, reps: 12),
      PlannedSet(loadG: null, reps: 12),
    ], restS: 0),
    _item('dip', 'Dip', LoadUnit.bodyweight, const [
      PlannedSet(loadG: null, reps: 8),
    ]),
  ]);
  // R1 (0.3.0 live reorder): the app reorders, then the lock screen acts.
  // The bench set 0 is logged (half done, resting) and the pushdown given a
  // weight, so its lock Done is offered; then the bench goes "later".
  final benchHalf = Session.retarget(
    Session.done(fresh, '$uuid:0', nowMs: t0 + 60000),
    '$uuid:3',
    loadG: 30000,
  );
  final doLater = Session.reorder(benchHalf, 0, 1);
  // The pushdown (set 3) given a weight and dragged ahead of the bench.
  final pulledForward = Session.reorder(
    Session.retarget(fresh, '$uuid:3', loadG: 30000),
    1,
    0,
  );
  return {
    // The new current exercise is the pushdown: Done logs ITS set (3), then 4;
    // the bench comes back at its next pending set (1) and Done logs that.
    'lockscreen_v1_after_do_later': (
      doLater,
      [
        _step('done', 3, 460000),
        _step('done', 4, 560000),
        _step('done', 1, 700000),
      ],
    ),
    'lockscreen_v1_after_drag_to_front': (
      pulledForward,
      [
        _step('done', 3, 95000),
        _step('done', 4, 230000),
        _step('done', 0, 380000),
      ],
    ),
    'lockscreen_v1_done_first_set': (fresh, [_step('done', 0, 95000)]),
    'lockscreen_v1_done_during_rest': (resting, [_step('done', 2, 270000)]),
    'lockscreen_v1_done_whole_lift': (
      fresh,
      [
        _step('done', 0, 95000),
        _step('done', 1, 230000),
        _step('done', 2, 380000),
      ],
    ),
    'lockscreen_v1_cold_start_then_carried': (
      pushdown,
      [_step('done', 3, 460000), _step('done', 4, 560000)],
    ),
    'lockscreen_v1_cold_start_from_starting_weight': (
      fromStart,
      [_step('done', 0, 95000), _step('done', 1, 230000)],
    ),
    'lockscreen_v1_after_pause': (
      Session.resume(
        Session.pause(midSet, nowMs: t0 + 400000),
        nowMs: t0 + 460000,
      ),
      [_step('done', 2, 520000)],
    ),
    'lockscreen_v1_no_set_ready': (
      resting.copyWith(setReadyAtMs: null),
      [_step('done', 2, 270000)],
    ),
    'lockscreen_v1_plus_rep_pyramid_steps': (
      pyramid,
      [
        _step('plus_rep', 0, 30000),
        _step('plus_rep', 0, 31000),
        _step('plus_rep', 0, 32000),
        _step('done', 0, 60000),
      ],
    ),
    'lockscreen_v1_plus_rep_carries': (
      flat,
      [
        _step('plus_rep', 0, 30000),
        _step('plus_rep', 0, 31000),
        _step('done', 0, 60000),
        _step('done', 1, 150000),
      ],
    ),
    'lockscreen_v1_bodyweight_rest_zero': (
      bodyweight,
      [
        _step('done', 0, 40000),
        _step('done', 1, 80000),
        _step('done', 2, 120000),
      ],
    ),
    // An earlier set of the lift was skipped in the app: Done judges and
    // starts against the right set (_lastLogged skips it).
    'lockscreen_v1_done_after_skipped': (
      Session.skip(fresh, '$uuid:0', nowMs: t0 + 30000),
      [_step('done', 1, 95000)],
    ),
    // A later set's target was changed in the app (12, not the old 10): +1 on
    // the first set must not carry to it.
    'lockscreen_v1_plus_rep_no_carry_to_changed': (
      Session.retarget(flat, '$uuid:2', reps: 12),
      [_step('plus_rep', 0, 30000), _step('done', 0, 60000)],
    ),
    'lockscreen_v1_skip_rest': (
      resting,
      [_step('skip_rest', 0, 280000), _step('done', 2, 300000)],
    ),
  };
}

/// The vector file line for each lock case.
Map<String, String> lockVectors() {
  final out = <String, String>{};
  for (final e in lockCases().entries) {
    var s = e.value.$1;
    final after = <Object?>[];
    for (final step in e.value.$2) {
      final next = lockStep(s, step);
      if (identical(next, s) || next.rev != s.rev + 1) {
        throw StateError('${e.key}: step $step changed nothing');
      }
      after.add(next.toJson());
      s = next;
    }
    out[e.key] = jsonEncode({
      'case': e.key,
      'before': e.value.$1.toJson(),
      'steps': e.value.$2,
      'after': after,
    });
  }
  return out;
}

// ---- timer-block vectors (0.3 cut T1) -------------------------------------
//
// `timer_v1_<case>.json` is one line: {case, steps:[{step, now_ms, snapshot}]}.
// Each snapshot is what TimerSession submits at wall time `now_ms`. android/core
// BlockSchedulerTest replays them through the native cue scheduler on a fake
// clock: every cue (set_id, run, index) fires exactly once, on time, across a
// re-applied block (mark), a pause near a cue (resume grace resend), a finish,
// and an undo + restart (run bump). Never hand-edit: change the Dart and
// regenerate.

/// The 20-minute EMOM preset (10 s lead-in, 20 x 60 s, block_end), driven
/// through start, mark, pause, resume, finish, undo, start again.
Map<String, String> timerVectors() {
  final fresh = Session.start(
    plan(),
    nowMs: t0,
    tzOffsetMin: tz,
    appVersion: '0.1.0+1',
    workoutUuid: uuid,
  );
  final emom = timerPresets.firstWhere((p) => p.id == 'emom20').block;
  final added = Session.addExercise(
    fresh,
    PlannedItem(
      exerciseId: 'burpee',
      name: 'Burpee',
      unit: LoadUnit.timed,
      sets: const [PlannedSet(loadG: null, reps: 0)],
      repLo: 0,
      repHi: 0,
      restS: 0,
      reason: emom.title,
      primary: const [],
    ),
    at: 0,
  );
  final setId = added.exercises[0].sets.first.setId;
  final steps = <(String, int, SessionSnapshot)>[];
  void step(String name, int now, SessionSnapshot s) {
    final prev = steps.isEmpty ? null : steps.last.$3;
    if (prev != null && (identical(prev, s) || s.rev <= prev.rev)) {
      throw StateError('timer step $name did not advance the rev');
    }
    steps.add((name, now, s));
  }

  final tStart = t0 + 60000;
  step(
    'attach',
    t0 + 30000,
    TimerSession.attach(added, setId, emom).copyWith(rev: fresh.rev + 1),
  );
  step(
    'start',
    tStart,
    TimerSession.start(steps.last.$3, setId, nowWallMs: tStart),
  );
  // A "round done" tap re-sends the same block (same run and anchor).
  step(
    'mark',
    tStart + 75000,
    TimerSession.mark(steps.last.$3, setId, nowMs: tStart + 75000),
  );
  // Paused 400 ms after cue 2 (10 s + 2 min): resume resends it at 0.
  final pauseAt = tStart + 130400;
  step('pause', pauseAt, TimerSession.pause(steps.last.$3, nowMs: pauseAt));
  final resumeAt = t0 + 300000;
  step('resume', resumeAt, TimerSession.resume(steps.last.$3, nowMs: resumeAt));
  final endAt = resumeAt + (emom.totalMs - 130400) + 2000;
  step(
    'finish',
    endAt,
    TimerSession.finish(steps.last.$3, setId, nowMs: endAt),
  );
  step('undo', endAt + 10000, TimerSession.undo(steps.last.$3, setId));
  final restartAt = endAt + 20000;
  step(
    'restart',
    restartAt,
    TimerSession.start(steps.last.$3, setId, nowWallMs: restartAt),
  );
  return {
    'timer_v1_emom20': jsonEncode({
      'case': 'timer_v1_emom20',
      'steps': [
        for (final s in steps)
          {'step': s.$1, 'now_ms': s.$2, 'snapshot': s.$3.toJson()},
      ],
    }),
  };
}

void main() {
  final dir = Directory('test/fixtures/contract')..createSync(recursive: true);
  final c = cases();
  for (final e in c.entries) {
    File('${dir.path}/${e.key}.json')
        .writeAsStringSync('${e.value.encode()}\n');
  }
  final v = lockVectors();
  for (final e in v.entries) {
    File('${dir.path}/${e.key}.json').writeAsStringSync('${e.value}\n');
  }
  final tv = timerVectors();
  for (final e in tv.entries) {
    File('${dir.path}/${e.key}.json').writeAsStringSync('${e.value}\n');
  }
  // A journal: three good lines, then a torn tail (power cut mid-write).
  final lines = [
    c['snapshot_v1_fresh']!.encode(),
    c['snapshot_v1_resting']!.encode(),
    c['snapshot_v1_mid_set']!.encode(),
  ];
  final torn = c['snapshot_v1_paused']!.encode();
  File('${dir.path}/journal_v1_torn_tail.jsonl').writeAsStringSync(
    '${lines.join('\n')}\n${torn.substring(0, torn.length ~/ 2)}',
  );
  stdout.writeln(
    'wrote ${c.length + 1 + v.length + tv.length} fixtures to ${dir.path}',
  );
}
