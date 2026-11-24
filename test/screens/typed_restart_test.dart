// 0.3 X1: a typed value survives pause / restart / Resume (optional snapshot
// set key `entry: typed`; schema stays 1). Real engine, stub port.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/live_controller.dart';

import 'flaky_port.dart';

void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.GymEngine engine;
  late FlakyPort port;
  late String gymId;
  final live = <LiveController>[];

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    engine = eng.GymEngine(
      catalog: catalog,
      store: eng.MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(7),
    );
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
    ]);
    engine.saveGym(g);
    gymId = g.id;
    port = FlakyPort();
  });
  tearDown(() {
    for (final c in live) {
      c.dispose();
    }
    live.clear();
  });

  LiveController controller() {
    final c = LiveController(
      engine: engine,
      port: port,
      nowMs: () => now,
      tzOffsetMin: 480,
      tick: const Duration(days: 1),
    );
    live.add(c);
    return c;
  }

  /// Dispose now (the process dies) and keep it out of tearDown.
  void retire(LiveController c) {
    live.remove(c);
    c.dispose();
  }

  /// A planned load (not a first time), so a typed Done is `typed`, not the
  /// cold start the one-tap rate leaves out.
  Future<void> startPush(LiveController c) => c.start(
    eng.SessionPlan(
      gymId: gymId,
      typeId: 'push',
      muscles: const ['chest'],
      uncovered: const [],
      estimatedMinutes: 20,
      items: [
        eng.PlannedItem(
          exerciseId: 'dumbbell-bench-press',
          name: 'Dumbbell bench press',
          unit: eng.LoadUnit.ea,
          sets: const [
            eng.PlannedSet(loadG: 12000, reps: 10),
            eng.PlannedSet(loadG: 12000, reps: 10),
            eng.PlannedSet(loadG: 12000, reps: 10),
          ],
          repLo: 8,
          repHi: 12,
          restS: 90,
          reason: '',
          primary: const ['chest'],
        ),
      ],
    ),
  );

  /// The journal head, as the next app launch reads it.
  Future<eng.SessionSnapshot> journalHead() async =>
      eng.readJournal((await port.readPendingJournal())!).last!;

  eng.SnapshotSet firstSet(eng.SessionSnapshot s) =>
      s.exercises.first.sets.first;

  test('typed, pause, new controller, Done logs typed', () async {
    final a = controller();
    await startPush(a);
    await a.setLoad(14000);
    await a.setReps(9);
    expect(firstSet(a.snapshot!).entry, eng.SetEntry.typed);
    expect(await a.pause(), isTrue);
    retire(a);

    // The "restart": a fresh controller resumes from the journal alone.
    final pending = await journalHead();
    expect(
      firstSet(pending).entry,
      eng.SetEntry.typed,
      reason: 'in the journal',
    );
    final b = controller();
    await b.resume(pending);
    expect(b.lastError, isNull);
    await b.done();
    expect(b.lastError, isNull);
    final logged = firstSet(b.snapshot!);
    expect(logged.state, eng.SetState.done);
    expect(logged.loadG, 14000);
    expect(logged.reps, 9);
    expect(logged.completion, eng.Completion.typed);
  });

  test(
    'typed, kill with no pause (journal head), new controller: typed',
    () async {
      final a = controller();
      await startPush(a);
      await a.setReps(11);
      // No pause: the process just dies; the journal head is what survives.
      final pending = await journalHead();
      retire(a);
      final b = controller();
      await b.resume(pending);
      await b.load(1);
      await b.done();
      expect(firstSet(b.snapshot!).completion, eng.Completion.typed);
    },
  );

  test('a set he did not type still logs adjusted after a restart', () async {
    final a = controller();
    await startPush(a);
    await a.load(1);
    await a.load(1); // +/- only
    expect(firstSet(a.snapshot!).entry, isNull);
    expect(await a.pause(), isTrue);
    final b = controller();
    await b.resume(await journalHead());
    await b.done();
    expect(firstSet(b.snapshot!).completion, isNot(eng.Completion.typed));
  });

  test(
    'a 0.2 journal without the key resumes and logs as it did before',
    () async {
      final a = controller();
      await startPush(a);
      await a.setReps(9);
      expect(await a.pause(), isTrue);
      final line = eng.readJournal((await port.readPendingJournal())!).last!;
      // What 0.2.x wrote for the same state: no `entry` anywhere.
      final old = eng.SessionSnapshot.decode(
        line.encode().replaceAll(',"entry":"typed"', ''),
      );
      expect(firstSet(old).entry, isNull);
      final b = controller();
      await b.resume(old);
      expect(b.lastError, isNull);
      await b.done();
      expect(b.lastError, isNull);
      expect(firstSet(b.snapshot!).state, eng.SetState.done);
      expect(
        firstSet(b.snapshot!).completion,
        isNot(eng.Completion.typed),
        reason: 'the 0.2 undercount stays for journals that never had the key',
      );
    },
  );

  test(
    'undo of a typed set goes back to the plan, then Done is not typed',
    () async {
      final a = controller();
      await startPush(a);
      await a.setLoad(14000);
      await a.done();
      expect(firstSet(a.snapshot!).completion, eng.Completion.typed);
      await a.undoLast();
      expect(firstSet(a.snapshot!).entry, isNull);
      await a.load(1);
      await a.done();
      expect(firstSet(a.snapshot!).completion, isNot(eng.Completion.typed));
    },
  );

  test('typed value, then +/- on it, still typed (net-zero steps)', () async {
    final a = controller();
    await startPush(a);
    await a.setReps(9);
    for (final d in [1, 1, -1, -1]) {
      await a.reps(d);
    }
    expect(firstSet(a.snapshot!).entry, eng.SetEntry.typed);
  });
}
