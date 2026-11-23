// Writes the session-snapshot contract fixtures (schema v1) from the Dart
// transitions with a fixed clock and uuid. Run from packages/gym_engine:
//   dart run tool/gen_contract_fixtures.dart
// then copy test/fixtures/contract/* byte-identical to
// android/core/src/test/fixtures/contract/ (CI diffs the two).
import 'dart:io';

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
      name: 'Cable Triceps Pushdown – "rope"',
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
  return {
    'snapshot_v1_fresh': fresh,
    'snapshot_v1_resting': resting,
    'snapshot_v1_mid_set': midSet,
    'snapshot_v1_paused': paused,
    'snapshot_v1_finished': finished,
  };
}

void main() {
  final dir = Directory('test/fixtures/contract')..createSync(recursive: true);
  final c = cases();
  for (final e in c.entries) {
    File('${dir.path}/${e.key}.json')
        .writeAsStringSync('${e.value.encode()}\n');
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
  stdout.writeln('wrote ${c.length + 1} fixtures to ${dir.path}');
}
