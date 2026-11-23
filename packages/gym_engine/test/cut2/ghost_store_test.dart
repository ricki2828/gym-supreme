import 'package:gym_engine/src/api.dart';
import 'package:gym_engine/src/cut2/ghost.dart';
import 'package:gym_engine/src/cut2/ghost_store.dart';
import 'package:gym_engine/src/model.dart';
import 'package:gym_engine/src/session.dart';
import 'package:test/test.dart';

const day = 86400000;

SessionPlan plan(String gym, {int load = 20000}) => SessionPlan(
  gymId: gym,
  muscles: const ['chest'],
  estimatedMinutes: 20,
  uncovered: const [],
  items: [
    PlannedItem(
      exerciseId: 'db-press',
      name: 'DB press',
      unit: LoadUnit.ea,
      sets: [
        PlannedSet(loadG: load, reps: 10),
        PlannedSet(loadG: load, reps: 10),
      ],
      repLo: 8,
      repHi: 12,
      restS: 60,
      reason: '',
      primary: const ['chest'],
    ),
  ],
);

/// A finished workout as the store keeps it.
WorkoutRecord past(String uuid, String gym, int at, List<int> reps) {
  var s = Session.start(
    plan(gym),
    nowMs: at,
    tzOffsetMin: 0,
    workoutUuid: uuid,
  );
  for (var i = 0; i < reps.length; i++) {
    s = Session.done(s, '$uuid:$i', nowMs: at + (i + 1) * 60000, reps: reps[i]);
  }
  return Session.finish(s, nowMs: at + 600000).toRecord();
}

void main() {
  final history = [
    past('a', 'condo', 1 * day, [10, 9]),
    past('b', 'hotel', 2 * day, [12, 12]),
  ];

  test('second session at the same gym: ghost from the first', () {
    final live = Session.start(
      plan('condo'),
      nowMs: 3 * day,
      tzOffsetMin: 0,
      workoutUuid: 'c',
    );
    final g = ghostsForSession(live, history)['db-press']!;
    expect(g.workoutUuid, 'a');
    expect([for (final s in g.sets) s.reps], [10, 9]);
  });

  test('first session at a gym: hidden', () {
    final live = Session.start(
      plan('gym3'),
      nowMs: 3 * day,
      tzOffsetMin: 0,
      workoutUuid: 'c',
    );
    expect(ghostsForSession(live, history)['db-press'], isNull);
    expect(
      sessionTotal(ghosts: ghostsForSession(live, history), done: []),
      isNull,
    );
  });

  test('pending set: last time shown, nothing judged; done set: judged', () {
    var live = Session.start(
      plan('condo'),
      nowMs: 3 * day,
      tzOffsetMin: 0,
      workoutUuid: 'c',
    );
    final ghosts = ghostsForSession(live, history);
    final p = ghostLineFor(live, 'c:0', ghosts)!;
    expect(p.verdict, GhostVerdict.pending);
    expect(p.ghostReps, 10);
    live = Session.done(live, 'c:0', nowMs: 3 * day + 30000, reps: 11);
    final d = ghostLineFor(live, 'c:0', ghosts)!;
    expect(d.verdict, GhostVerdict.ahead);
    expect(d.repsDelta, 1);
    expect(d.paceDeltaMs, 30000 - 60000);
  });

  test('session total from the live snapshot; skipped sets left out', () {
    var live = Session.start(
      plan('condo'),
      nowMs: 3 * day,
      tzOffsetMin: 0,
      workoutUuid: 'c',
    );
    live = Session.skip(live, 'c:0', nowMs: 3 * day + 1);
    live = Session.done(live, 'c:1', nowMs: 3 * day + 60000, reps: 10);
    final done = doneSetsOf(live);
    expect(done, [
      (exerciseId: 'db-press', setOrdinal: 2, volumeGReps: 200000),
    ]);
    final t = sessionTotal(
      ghosts: ghostsForSession(live, history),
      done: done,
    )!;
    expect(t.volumeGReps, 200000);
    expect(t.ghostSoFarGReps, 20000 * 9); // last time's set 2 only
    expect(ghostLineFor(live, 'c:0', ghostsForSession(live, history)), isNull);
  });

  test('an edited record flows through (computed each build)', () {
    final edited = [
      past('a', 'condo', 1 * day, [6, 6]),
      history[1],
    ];
    final live = Session.start(
      plan('condo'),
      nowMs: 3 * day,
      tzOffsetMin: 0,
      workoutUuid: 'c',
    );
    expect(ghostsForSession(live, edited)['db-press']!.byOrdinal(1)!.reps, 6);
  });

  test('the live workout already in history is not its own ghost', () {
    final live = Session.start(
      plan('condo'),
      nowMs: 3 * day,
      tzOffsetMin: 0,
      workoutUuid: 'c',
    );
    final withSelf = [
      ...history,
      past('c', 'condo', 3 * day - 5, [1, 1]),
    ];
    expect(ghostsForSession(live, withSelf)['db-press']!.workoutUuid, 'a');
  });

  test('ghostTotalForRecord: the stored workout against its own ghosts', () {
    final mine = past('c', 'condo', 3 * day, [11, 10]);
    final t = ghostTotalForRecord(mine, [...history, mine])!;
    expect(t.volumeGReps, 20000 * 21);
    expect(t.ghostSoFarGReps, 20000 * 19); // 'a': 10 + 9
    expect(ghostTotalForRecord(past('x', 'gym9', day, [5]), history), isNull);
  });
}
