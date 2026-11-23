import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

const t0 = 1795400000000;

SessionPlan plan() => const SessionPlan(
  gymId: 'g',
  muscles: ['chest'],
  estimatedMinutes: 20,
  uncovered: [],
  items: [
    PlannedItem(
      exerciseId: 'a',
      name: 'A',
      unit: LoadUnit.ea,
      sets: [
        PlannedSet(loadG: 20000, reps: 10),
        PlannedSet(loadG: 20000, reps: 10),
      ],
      repLo: 8,
      repHi: 12,
      restS: 90,
      reason: '',
      primary: ['chest'],
    ),
    PlannedItem(
      exerciseId: 'b',
      name: 'B',
      unit: LoadUnit.bodyweight,
      sets: [PlannedSet(loadG: null, reps: 12)],
      repLo: 10,
      repHi: 15,
      restS: 60,
      reason: '',
      primary: ['abs'],
    ),
  ],
);

SessionSnapshot start() =>
    Session.start(plan(), nowMs: t0, tzOffsetMin: 0, workoutUuid: 'u');

void main() {
  test('start: rev 0, set ids unique, first set current', () {
    final s = start();
    expect(s.rev, 0);
    final ids = [
      for (final e in s.exercises)
        for (final x in e.sets) x.setId,
    ];
    expect(ids, ['u:0', 'u:1', 'u:2']);
    expect(s.currentSet!.setId, 'u:0');
  });

  test('done: tap_unchanged, rest started, rev +1, R6 fields', () {
    final s = Session.done(start(), 'u:0', nowMs: t0 + 60000);
    expect(s.rev, 1);
    final set = s.exercises[0].sets[0];
    expect(set.state, SetState.done);
    expect(set.completion, Completion.tapUnchanged);
    expect(set.loadG, 20000);
    expect(set.startedAtMs, t0);
    expect(set.offsetMs, 60000);
    expect(s.rest!.endsAtWallMs, t0 + 60000 + 90000);
    expect(s.currentSet!.setId, 'u:1');
  });

  test('done with changed values is adjusted; bodyweight null load is tap', () {
    var s = Session.done(start(), 'u:0', nowMs: t0 + 1, reps: 9);
    expect(s.exercises[0].sets[0].completion, Completion.adjusted);
    s = Session.done(s, 'u:2', nowMs: t0 + 2, reps: 12);
    expect(s.exercises[1].sets[0].completion, Completion.tapUnchanged);
  });

  test('+/- via retarget then Done is adjusted, not tap_unchanged (B4)', () {
    var s = Session.retarget(start(), 'u:0', loadG: 22000);
    expect(s.exercises[0].sets[0].planLoadG, 20000);
    s = Session.done(s, 'u:0', nowMs: t0 + 1);
    expect(s.exercises[0].sets[0].loadG, 22000);
    expect(s.exercises[0].sets[0].completion, Completion.adjusted);
  });

  test('cold start: loaded exercise with no planned load', () {
    const cold = SessionPlan(
      gymId: 'g',
      muscles: ['chest'],
      estimatedMinutes: 5,
      uncovered: [],
      items: [
        PlannedItem(
          exerciseId: 'a',
          name: 'A',
          unit: LoadUnit.ea,
          sets: [PlannedSet(loadG: null, reps: 10)],
          repLo: 8,
          repHi: 12,
          restS: 90,
          reason: '',
          primary: ['chest'],
        ),
      ],
    );
    var s = Session.start(cold, nowMs: t0, tzOffsetMin: 0, workoutUuid: 'u');
    s = Session.done(s, 'u:0', nowMs: t0 + 1, loadG: 12000);
    expect(s.exercises[0].sets[0].completion, Completion.coldStart);
  });

  test('lock-screen Done counts as tap_unchanged (R3)', () {
    var s = Session.retarget(start(), 'u:0', reps: 8);
    s = Session.done(s, 'u:0', nowMs: t0 + 1, source: SetSource.lockscreen);
    expect(s.exercises[0].sets[0].completion, Completion.tapUnchanged);
    expect(s.exercises[0].sets[0].reps, 8);
  });

  test(
    'journal reader: mid-file junk, wrong uuid, non-rising rev are corrupt',
    () {
      final a = start();
      final b = Session.done(a, 'u:0', nowMs: t0 + 1);
      final other = Session.start(
        plan(),
        nowMs: t0,
        tzOffsetMin: 0,
        workoutUuid: 'v',
      );
      final r = readJournal(
        [
          a.encode(),
          '{"x',
          other.encode(),
          b.encode(),
          a.encode(),
          '',
        ].join('\n'),
      );
      expect(r.last!.rev, b.rev);
      expect(r.corruptLines, 3);
      expect(r.tornTail, isFalse);
    },
  );

  test('next set starts when the rest ended, or now if earlier', () {
    var s = Session.done(start(), 'u:0', nowMs: t0 + 60000);
    s = Session.done(s, 'u:1', nowMs: t0 + 300000);
    expect(s.exercises[0].sets[1].startedAtMs, t0 + 150000);
  });

  test('double tap on the same set logs one set (no-op, same rev)', () {
    final a = Session.done(start(), 'u:0', nowMs: t0 + 1);
    final b = Session.done(a, 'u:0', nowMs: t0 + 2);
    expect(identical(a, b), isTrue);
  });

  test('last set: no rest; done does not finish (R3)', () {
    var s = start();
    for (final id in ['u:0', 'u:1', 'u:2']) {
      s = Session.done(s, id, nowMs: t0 + 1000);
    }
    expect(s.rest, isNull);
    expect(s.finished, isFalse);
    expect(s.current, isNull);
  });

  test('pause folds into paused_total on resume, and on done while paused', () {
    var s = Session.pause(start(), nowMs: t0 + 10000);
    expect(s.state, SessionState.paused);
    s = Session.resume(s, nowMs: t0 + 70000);
    expect(s.pausedTotalMs, 60000);
    expect(s.state, SessionState.active);
    s = Session.pause(s, nowMs: t0 + 80000);
    s = Session.done(s, 'u:0', nowMs: t0 + 100000);
    expect(s.pausedTotalMs, 80000);
    expect(s.exercises[0].sets[0].offsetMs, 100000 - 80000);
  });

  test('finish while paused folds the pause; finished is terminal', () {
    var s = Session.pause(start(), nowMs: t0 + 10000);
    s = Session.finish(s, nowMs: t0 + 20000);
    expect(s.finished, isTrue);
    expect(s.pausedTotalMs, 10000);
    expect(s.endedAtMs, t0 + 20000);
    expect(identical(Session.done(s, 'u:0', nowMs: t0), s), isTrue);
  });

  test('reorder, add/remove set, skip, undo, retarget', () {
    var s = Session.reorder(start(), 1, 0);
    expect(s.exercises.first.exerciseId, 'b');
    s = Session.addSet(s, 1);
    expect(s.exercises[1].sets.last.setId, 'u:3');
    expect(s.exercises[1].sets.last.setOrdinal, 3);
    s = Session.removeSet(s, 'u:1');
    expect([for (final x in s.exercises[1].sets) x.setOrdinal], [1, 2]);
    s = Session.retarget(s, 'u:0', loadG: 22500);
    expect(s.exercises[1].sets[0].targetLoadG, 22500);
    s = Session.skip(s, 'u:2', nowMs: t0 + 5);
    expect(s.exercises[0].sets[0].state, SetState.skipped);
    s = Session.done(s, 'u:0', nowMs: t0 + 9);
    expect(s.rest, isNotNull);
    s = Session.undo(s, 'u:0');
    expect(s.exercises[1].sets[0].state, SetState.pending);
    expect(s.rest, isNull);
  });

  test('swap only before anything is logged', () {
    const item = PlannedItem(
      exerciseId: 'c',
      name: 'C',
      unit: LoadUnit.kg,
      sets: [PlannedSet(loadG: 30000, reps: 12)],
      repLo: 10,
      repHi: 15,
      restS: 75,
      reason: '',
      primary: ['chest'],
    );
    var s = Session.swap(start(), 1, item);
    expect(s.exercises[1].exerciseId, 'c');
    expect(s.exercises[1].loadKind, 'stack');
    s = Session.done(s, 'u:0', nowMs: t0 + 1);
    expect(identical(Session.swap(s, 0, item), s), isTrue);
  });

  test('stored form drops pending sets and keeps skipped', () {
    var s = Session.done(start(), 'u:0', nowMs: t0 + 1000);
    s = Session.skip(s, 'u:1', nowMs: t0 + 2000);
    s = Session.finish(s, nowMs: t0 + 3000);
    final r = s.toRecord();
    expect(r.sets.length, 2);
    expect(r.sets[1].skipped, isTrue);
    expect(r.volumeGReps, 20000 * 10);
    expect(r.durationMs, 3000);
  });

  test('set ids are never reused after remove + add, or swap (review P1)', () {
    var s = Session.removeSet(start(), 'u:2');
    s = Session.addSet(s, 1);
    expect(s.exercises[1].sets.last.setId, 'u:3');
    const item = PlannedItem(
      exerciseId: 'c',
      name: 'C',
      unit: LoadUnit.kg,
      sets: [PlannedSet(loadG: 1000, reps: 10)],
      repLo: 10,
      repHi: 15,
      restS: 60,
      reason: '',
      primary: ['chest'],
    );
    s = Session.swap(s, 1, item);
    expect(s.exercises[1].sets.single.setId, 'u:4');
    expect(s.swaps, 1);
    expect(Session.finish(s, nowMs: t0 + 9).toRecord().swaps, 1);
    expect(s.nextSetN, 5);
  });

  test('set start after a pause is the resume time (review P2)', () {
    var s = Session.done(start(), 'u:0', nowMs: t0 + 60000);
    s = Session.pause(s, nowMs: t0 + 70000);
    s = Session.resume(s, nowMs: t0 + 670000);
    s = Session.done(s, 'u:1', nowMs: t0 + 700000);
    expect(s.exercises[0].sets[1].startedAtMs, t0 + 670000);
  });

  test('skipped rest: the next set starts at the skip', () {
    var s = Session.done(start(), 'u:0', nowMs: t0 + 60000);
    s = Session.skipRest(s, nowMs: t0 + 80000);
    s = Session.done(s, 'u:1', nowMs: t0 + 120000);
    expect(s.exercises[0].sets[1].startedAtMs, t0 + 80000);
  });

  test('uuidV4 shape', () {
    expect(
      uuidV4(),
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });

  test('decode rejects newer schema and junk', () {
    expect(() => SessionSnapshot.decode('{"schema":2}'), throwsFormatException);
    expect(() => SessionSnapshot.decode('[1]'), throwsFormatException);
    expect(() => SessionSnapshot.decode('{"schema":1}'), throwsFormatException);
    expect(() => SessionSnapshot.decode('{"sch'), throwsFormatException);
    final paused = Session.pause(start(), nowMs: t0 + 1).encode();
    expect(
      () => SessionSnapshot.decode(
        paused.replaceFirst(
          RegExp(r'"paused_at_ms":\d+'),
          '"paused_at_ms":null',
        ),
      ),
      throwsFormatException,
    );
  });
}
