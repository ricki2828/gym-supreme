import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

const t0 = 1795400000000;

PlannedItem item(
  String id,
  List<PlannedSet> sets, {
  LoadUnit unit = LoadUnit.ea,
}) => PlannedItem(
  exerciseId: id,
  name: id,
  unit: unit,
  sets: sets,
  repLo: 8,
  repHi: 12,
  restS: 90,
  reason: '',
  primary: const ['chest'],
);

SessionSnapshot start(List<PlannedItem> items) => Session.start(
  SessionPlan(
    gymId: 'g',
    muscles: const ['chest'],
    estimatedMinutes: 20,
    uncovered: const [],
    items: items,
  ),
  nowMs: t0,
  tzOffsetMin: 0,
  workoutUuid: 'u',
);

List<int?> loads(SessionSnapshot s, int e) => [
  for (final x in s.exercises[e].sets) x.targetLoadG,
];
List<int?> reps(SessionSnapshot s, int e) => [
  for (final x in s.exercises[e].sets) x.targetReps,
];

const three = [
  PlannedSet(loadG: null, reps: 10),
  PlannedSet(loadG: null, reps: 10),
  PlannedSet(loadG: null, reps: 10),
];

void main() {
  test('first-time lift: load set on set 1 fills sets 2-3 (one rev)', () {
    final s0 = start([item('a', three), item('b', three)]);
    final s = Session.retarget(s0, 'u:0', loadG: 16000);
    expect(s.rev, 1);
    expect(loads(s, 0), [16000, 16000, 16000]);
    expect(loads(s, 1), [null, null, null]); // other lift untouched
    // Plan stays, so set 2 is still judged against its (empty) plan.
    expect(s.exercises[0].sets[1].planLoadG, isNull);
  });

  test('drop 22 -> 20 on set 1 carries; reps carry independently', () {
    const p = [
      PlannedSet(loadG: 22000, reps: 10),
      PlannedSet(loadG: 22000, reps: 10),
      PlannedSet(loadG: 22000, reps: 10),
    ];
    var s = Session.retarget(start([item('a', p)]), 'u:0', loadG: 20000);
    expect(loads(s, 0), [20000, 20000, 20000]);
    expect(reps(s, 0), [10, 10, 10]);
    s = Session.retarget(s, 'u:1', reps: 8);
    expect(reps(s, 0), [10, 8, 8]); // only later sets
    expect(loads(s, 0), [20000, 20000, 20000]);
  });

  test('done with different values carries them to remaining sets', () {
    final s = Session.done(
      start([item('a', three)]),
      'u:0',
      nowMs: t0 + 1,
      loadG: 14000,
      reps: 9,
    );
    expect(s.exercises[0].sets[0].loadG, 14000);
    expect(loads(s, 0).skip(1), [14000, 14000]);
    expect(reps(s, 0).skip(1), [9, 9]);
    expect(s.rev, 1);
  });

  test('done at target changes nothing downstream', () {
    const p = [
      PlannedSet(loadG: 20000, reps: 10),
      PlannedSet(loadG: 22000, reps: 8),
    ];
    final s0 = start([item('a', p)]);
    final s = Session.done(s0, 'u:0', nowMs: t0 + 1);
    expect(loads(s, 0), [20000, 22000]);
    expect(reps(s, 0), [10, 8]);
  });

  test('a set changed on its own, or a pyramid, is not overwritten', () {
    const p = [
      PlannedSet(loadG: 20000, reps: 12),
      PlannedSet(loadG: 20000, reps: 10),
      PlannedSet(loadG: 20000, reps: 10),
    ];
    var s = start([item('a', p)]);
    s = Session.retarget(s, 'u:2', loadG: 24000); // own choice for set 3
    s = Session.retarget(s, 'u:0', loadG: 18000, reps: 11);
    expect(loads(s, 0), [18000, 18000, 24000]);
    expect(reps(s, 0), [11, 10, 10]); // 12 -> 11 does not hit the 10s
  });

  test('done and skipped sets and earlier sets are never touched', () {
    var s = start([item('a', three)]);
    s = Session.done(s, 'u:0', nowMs: t0 + 1, loadG: 10000);
    s = Session.skip(s, 'u:1', nowMs: t0 + 2);
    s = Session.retarget(s, 'u:2', loadG: 12000);
    expect(s.exercises[0].sets[0].loadG, 10000);
    expect(s.exercises[0].sets[1].state, SetState.skipped);
    expect(s.exercises[0].sets[1].targetLoadG, 10000);
    expect(loads(s, 0)[2], 12000);
  });

  test('a cleared load (null) does not carry', () {
    const p = [
      PlannedSet(loadG: 5000, reps: 10),
      PlannedSet(loadG: 5000, reps: 10),
    ];
    final s = Session.retarget(start([item('a', p)]), 'u:0', loadG: null);
    expect(loads(s, 0), [null, 5000]);
  });

  test('timed sets do not carry', () {
    const p = [
      PlannedSet(loadG: null, reps: 1),
      PlannedSet(loadG: null, reps: 1),
    ];
    final s = Session.retarget(
      start([item('t', p, unit: LoadUnit.timed)]),
      'u:0',
      reps: 5,
    );
    expect(reps(s, 0), [5, 1]);
  });

  test('undo after a carried change leaves the later sets carried', () {
    var s = start([item('a', three)]);
    s = Session.retarget(s, 'u:0', loadG: 16000);
    s = Session.done(s, 'u:0', nowMs: t0 + 1);
    s = Session.undo(s, 'u:0');
    expect(s.exercises[0].sets[0].state, SetState.pending);
    expect(loads(s, 0), [16000, 16000, 16000]);
  });

  test('completion is judged against what was shown (t5t ruling)', () {
    // First-time lift: set 1 entered = cold start; sets 2-3 accepted as
    // carried = tap_unchanged; a +/- on set 3 itself = adjusted.
    var s = start([item('a', three)]);
    s = Session.retarget(s, 'u:0', loadG: 16000);
    s = Session.done(s, 'u:0', nowMs: t0 + 1);
    s = Session.done(s, 'u:1', nowMs: t0 + 2);
    s = Session.retarget(s, 'u:2', loadG: 18000);
    s = Session.done(s, 'u:2', nowMs: t0 + 3);
    final c = [for (final x in s.exercises[0].sets) x.completion];
    expect(c, [
      Completion.coldStart,
      Completion.tapUnchanged,
      Completion.adjusted, // 16 kg was shown; he changed it
    ]);
    // Plan values never move (ghost and progression keep the plan).
    expect(s.exercises[0].sets[2].planLoadG, isNull);
  });

  test('planned lift: carried drop is tap on the next set; own +/- is '
      'adjusted', () {
    const p = [
      PlannedSet(loadG: 22000, reps: 10),
      PlannedSet(loadG: 22000, reps: 10),
      PlannedSet(loadG: 22000, reps: 10),
    ];
    var s = start([item('a', p)]);
    s = Session.retarget(s, 'u:0', loadG: 20000);
    s = Session.done(s, 'u:0', nowMs: t0 + 1);
    s = Session.done(s, 'u:1', nowMs: t0 + 2);
    s = Session.retarget(s, 'u:2', reps: 8);
    s = Session.done(s, 'u:2', nowMs: t0 + 3);
    expect(
      [for (final x in s.exercises[0].sets) x.completion],
      [
        Completion.adjusted, // B4: +/- on the set itself
        Completion.tapUnchanged, // carried 20 kg accepted
        Completion.adjusted, // own reps change
      ],
    );
    expect(s.exercises[0].sets[1].planLoadG, 22000);
  });
}
