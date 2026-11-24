import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

const t0 = 1795400000000;

PlannedItem item(String id, int sets, {int rest = 90}) => PlannedItem(
  exerciseId: id,
  name: id.toUpperCase(),
  unit: LoadUnit.ea,
  sets: [
    for (var i = 0; i < sets; i++) const PlannedSet(loadG: 20000, reps: 10),
  ],
  repLo: 8,
  repHi: 12,
  restS: rest,
  reason: '',
  primary: const ['chest'],
);

SessionSnapshot start() => Session.start(
  SessionPlan(
    gymId: 'g',
    typeId: 'push',
    muscles: const ['chest'],
    estimatedMinutes: 30,
    uncovered: const [],
    items: [item('a', 3), item('b', 2), item('c', 1)],
  ),
  nowMs: t0,
  tzOffsetMin: 0,
  workoutUuid: 'u',
);

List<String> order(SessionSnapshot s) => [
  for (final e in s.exercises) e.exerciseId,
];

String curId(SessionSnapshot s) => s.exercises[s.current!.exercise].exerciseId;

/// A and its first set done: half done, resting.
SessionSnapshot halfDoneA() => Session.done(start(), 'u:0', nowMs: t0 + 60000);

/// Every set of [id] done (in snapshot order).
SessionSnapshot finishLift(SessionSnapshot s, String id, int at) {
  var t = at;
  for (final e in s.exercises.where((e) => e.exerciseId == id)) {
    for (final x in e.sets.where((x) => x.state == SetState.pending)) {
      s = Session.done(s, x.setId, nowMs: t += 60000);
    }
  }
  return s;
}

void main() {
  test('moving the current exercise keeps its logged sets with it', () {
    final before = halfDoneA();
    expect(curId(before), 'a');
    final doneA = before.exercises[0].sets[0];
    final s = Session.reorder(before, 0, 1);
    expect(s.rev, before.rev + 1);
    expect(order(s), ['b', 'a', 'c']);
    // The logged set moved with A, byte for byte.
    expect(s.exercises[1].sets[0].toJson(), doneA.toJson());
    expect(s.exercises[1].sets[0].state, SetState.done);
    // B is current now; A is not.
    expect(curId(s), 'b');
  });

  test('a half-done exercise resumes at its next pending set', () {
    var s = Session.reorder(halfDoneA(), 0, 1);
    s = finishLift(s, 'b', t0 + 100000);
    // A's second set (ordinal 2, id u:1) is the next set to do.
    expect(curId(s), 'a');
    expect(s.currentSet!.setId, 'u:1');
    expect(s.currentSet!.setOrdinal, 2);
    expect(s.exercises[s.current!.exercise].sets[0].state, SetState.done);
  });

  test('reordering while a rest runs keeps the rest timer', () {
    final before = halfDoneA();
    expect(before.rest, isNotNull);
    final s = Session.reorder(before, 0, 2);
    expect(s.rest?.toJson(), before.rest?.toJson());
    expect(s.setReadyAtMs, before.setReadyAtMs);
    // And the rest is still skippable (the timer belongs to the session).
    final skipped = Session.skipRest(s, nowMs: t0 + 70000);
    expect(skipped.rest, isNull);
    expect(order(skipped), ['b', 'c', 'a']);
  });

  test('the first set of the new current exercise is logged normally', () {
    final s = Session.reorder(halfDoneA(), 0, 1);
    final next = Session.done(s, s.currentSet!.setId, nowMs: t0 + 90000);
    expect(next.exercises[0].exerciseId, 'b');
    expect(next.exercises[0].sets[0].state, SetState.done);
    // A's logged set was not touched by it.
    expect(next.exercises[1].sets[0].toJson(), s.exercises[1].sets[0].toJson());
  });

  test('moving the current exercise to the end, then back', () {
    var s = Session.reorder(start(), 0, 2);
    expect(order(s), ['b', 'c', 'a']);
    s = Session.reorder(s, 2, 0);
    expect(order(s), ['a', 'b', 'c']);
    expect(curId(s), 'a');
  });

  test('a no-op reorder changes nothing (same rev)', () {
    final s = start();
    expect(identical(Session.reorder(s, 1, 1), s), isTrue);
    expect(identical(Session.reorder(s, 0, 9), s), isTrue);
  });

  test('a reordered session survives encode/decode (the journal line)', () {
    final s = Session.reorder(halfDoneA(), 0, 1);
    final back = SessionSnapshot.decode(s.encode());
    expect(back.encode(), s.encode());
    expect(order(back), ['b', 'a', 'c']);
    expect(back.current, s.current);
  });

  test('last time and history are keyed by exercise, not by order', () {
    final catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
    final store = MemoryStore();
    final engine = GymEngine(
      catalog: catalog,
      store: store,
      nowMs: () => t0 + 900000,
      tzOffsetMin: () => 0,
      random: Random(1),
    );
    var s = Session.reorder(halfDoneA(), 0, 1);
    s = finishLift(s, 'b', t0 + 100000);
    s = finishLift(s, 'a', t0 + 400000);
    s = finishLift(s, 'c', t0 + 600000);
    s = Session.finish(s, nowMs: t0 + 800000);
    engine.saveFinished(s);
    final a = engine.lastTime(gymId: 'g', exerciseId: 'a')!;
    expect(a.sets.length, 3, reason: 'all three of A, whichever came first');
    expect(engine.lastTime(gymId: 'g', exerciseId: 'b')!.sets.length, 2);
    // Stored positions follow the order he did them in: B, A, C.
    final w = store.workout('u')!;
    final byPos = <int, String>{
      for (final x in w.sets) x.exercisePosition: x.exerciseId,
    };
    expect(
      [for (final k in byPos.keys.toList()..sort()) byPos[k]],
      ['b', 'a', 'c'],
    );
    expect(jsonDecode(s.encode()), isA<Map>());
  });
}
