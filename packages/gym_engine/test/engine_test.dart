import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:test/test.dart';

const day = 86400000;
// Mon 16-Nov-2026 09:00 +08:00.
final monday = DateTime.utc(2026, 11, 16, 1).millisecondsSinceEpoch;

Catalog loadCatalog() => Catalog.fromJson(
  File('../../assets/exercises_taxonomy.json').readAsStringSync(),
  File('../../assets/exercises.json').readAsStringSync(),
);

/// Which store the rigs use; each group sets it.
HistoryStore Function() newStore = MemoryStore.new;

class Rig {
  Rig() {
    engine = GymEngine(
      catalog: catalog,
      store: store,
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(7),
    );
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
      25000,
    ]);
    engine.saveGym(g);
    gymId = g.id;
  }

  static final catalog = loadCatalog();
  final HistoryStore store = newStore();
  late final GymEngine engine;
  late final String gymId;
  int now = monday;

  /// Runs a plan: every set done as planned (cold start → [coldLoadG]),
  /// with [reps] overriding planned reps when given.
  SessionSnapshot run(
    SessionPlan plan, {
    int? reps,
    int coldLoadG = 10000,
    String app = '0.1.0',
  }) {
    var s = Session.start(
      plan,
      nowMs: now,
      tzOffsetMin: 480,
      appVersion: app,
      random: Random(now),
    );
    for (final e in s.exercises) {
      for (final x in e.sets) {
        now += 120000;
        final cold = x.targetLoadG == null && e.loadKind != 'bodyweight';
        s = cold
            ? Session.done(
                s,
                x.setId,
                nowMs: now,
                loadG: coldLoadG,
                reps: reps ?? x.targetReps,
              )
            : Session.done(s, x.setId, nowMs: now, reps: reps ?? x.targetReps);
      }
    }
    s = Session.finish(s, nowMs: now += 60000);
    engine.saveFinished(s);
    return s;
  }
}

void main() {
  group('memory store', () {
    setUp(() => newStore = MemoryStore.new);
    engineTests();
  });
  group('sqlite store', () {
    setUp(() => newStore = SqliteStore.inMemory);
    engineTests();
  });
}

void engineTests() {
  test('condo push suggestion: kit-valid, loads available, fits 45 min', () {
    final r = Rig();
    final p = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest', 'triceps'],
      minutes: 45,
      typeId: 'push',
    );
    expect(p.items, isNotEmpty);
    expect(p.uncovered, isEmpty);
    expect(p.estimatedMinutes, lessThanOrEqualTo(45));
    final kit = r.store.gym(r.gymId)!.equipmentIds;
    for (final i in p.items) {
      final e = Rig.catalog.exercise(i.exerciseId)!;
      expect(e.availableWith(kit), isTrue, reason: i.exerciseId);
      expect(e.load, isNot('barbell'));
      expect(i.reason, isNotEmpty);
      expect(i.sets.every((s) => s.loadG == null), isTrue); // cold start
    }
    // Compounds first.
    final mech = [
      for (final i in p.items) Rig.catalog.exercise(i.exerciseId)!.isCompound,
    ];
    expect(mech, [...mech]..sort((a, b) => a == b ? 0 : (a ? -1 : 1)));
    // Lead muscle gets the most work.
    expect(
      p.items.where((i) => i.primary.contains('chest')).length,
      greaterThanOrEqualTo(
        p.items.where((i) => i.primary.contains('triceps')).length,
      ),
    );
  });

  test('time budget trims sets then exercises', () {
    final r = Rig();
    final long = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest', 'triceps', 'side-delts'],
      minutes: 90,
    );
    final short = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest', 'triceps', 'side-delts'],
      minutes: 20,
    );
    expect(short.estimatedMinutes, lessThanOrEqualTo(20));
    final setsLong = long.items.fold<int>(0, (a, i) => a + i.setCount);
    final setsShort = short.items.fold<int>(0, (a, i) => a + i.setCount);
    expect(setsShort, lessThan(setsLong));
  });

  test('uncovered muscle at a gym without the kit', () {
    final r = Rig();
    final bare = Gym(id: 'bare', name: 'Hotel', kit: const {});
    r.engine.saveGym(bare);
    final p = r.engine.suggest(gymId: 'bare', muscleIds: ['lats', 'chest']);
    expect(p.uncovered, contains('lats'));
    expect(
      r.engine.muscleStatus(gymId: 'bare')['lats']!.uncoveredAtGym,
      isTrue,
    );
    expect(
      r.engine.muscleStatus(gymId: 'bare')['chest']!.uncoveredAtGym,
      isFalse,
    );
  });

  test('days-since and resting from logged sets', () {
    final r = Rig();
    final before = r.engine.muscleStatus(gymId: r.gymId);
    expect(before['chest']!.daysSince, isNull);
    expect(before['chest']!.resting, isFalse);
    r.run(r.engine.suggest(gymId: r.gymId, muscleIds: ['chest'], minutes: 30));
    r.now += day;
    var st = r.engine.muscleStatus(gymId: r.gymId);
    expect(st['chest']!.daysSince, 1);
    expect(st['chest']!.resting, isTrue);
    expect(st['chest']!.lit, isTrue);
    expect(st['quads']!.daysSince, isNull);
    r.now += 2 * day;
    st = r.engine.muscleStatus(gymId: r.gymId);
    expect(st['chest']!.resting, isFalse);
    expect(st['chest']!.daysSince, 3);
  });

  test('a resting muscle is only hit if picked', () {
    final r = Rig();
    r.run(
      r.engine.suggest(gymId: r.gymId, muscleIds: ['triceps'], minutes: 30),
    );
    r.now += day;
    expect(r.engine.muscleStatus(gymId: r.gymId)['triceps']!.resting, isTrue);
    final p = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 60,
    );
    for (final i in p.items) {
      expect(i.primary, isNot(contains('triceps')), reason: i.exerciseId);
    }
  });

  test('progression: one more rep, then the next load this gym has', () {
    final r = Rig();
    final first = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
    );
    final id = first.items.firstWhere((i) => i.unit == LoadUnit.ea).exerciseId;
    final e = Rig.catalog.exercise(id)!;
    final (lo, hi) = r.engine.repRange(e);
    r.run(first, reps: lo, coldLoadG: 20000);
    r.now += 3 * day;
    var p = r.engine.suggest(gymId: r.gymId, muscleIds: ['chest'], minutes: 20);
    var item = p.items.firstWhere((i) => i.exerciseId == id);
    expect(item.sets.first.loadG, 20000);
    expect(item.sets.first.reps, lo + 1);
    expect(item.reason, contains('last time'));
    r.run(p, reps: hi);
    r.now += 3 * day;
    p = r.engine.suggest(gymId: r.gymId, muscleIds: ['chest'], minutes: 20);
    item = p.items.firstWhere((i) => i.exerciseId == id);
    expect(item.sets.first.loadG, 22000); // the gym's next dumbbell up
    expect(item.sets.first.reps, lo);
  });

  test('ceiling (B7): at the top dumbbell, more reps', () {
    final r = Rig();
    final first = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
    );
    final id = first.items.firstWhere((i) => i.unit == LoadUnit.ea).exerciseId;
    final (_, hi) = r.engine.repRange(Rig.catalog.exercise(id)!);
    r.run(first, reps: hi, coldLoadG: 25000);
    r.now += 3 * day;
    final p = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
    );
    final item = p.items.firstWhere((i) => i.exerciseId == id);
    expect(item.sets.first.loadG, 25000);
    expect(item.sets.first.reps, hi + 1);
    expect(item.reason, contains('Top weight'));
  });

  test('suggested load is always one this gym has (review P2)', () {
    final r = Rig();
    final first = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
    );
    final id = first.items.firstWhere((i) => i.unit == LoadUnit.ea).exerciseId;
    r.run(first, reps: 9, coldLoadG: 23000); // typed a weight the gym lacks
    r.now += 3 * day;
    final item = r.engine
        .suggest(gymId: r.gymId, muscleIds: ['chest'], minutes: 20)
        .items
        .firstWhere((i) => i.exerciseId == id);
    expect(item.sets.first.loadG, 22000);
    expect(item.reason, contains('Nearest weight'));
  });

  test('bodyweight at the top of the range: one more rep (B7)', () {
    final r = Rig();
    final p = r.engine.suggest(gymId: r.gymId, muscleIds: ['abs'], minutes: 15);
    final bw = p.items.firstWhere((i) => i.unit == LoadUnit.bodyweight);
    r.run(p, reps: bw.repHi);
    r.now += 3 * day;
    final item = r.engine
        .suggest(gymId: r.gymId, muscleIds: ['abs'], minutes: 15)
        .items
        .firstWhere((i) => i.exerciseId == bw.exerciseId);
    expect(item.sets.first.loadG, isNull);
    expect(item.sets.first.reps, bw.repHi + 1);
    expect(item.reason, contains('Top of the range'));
  });

  test('one-tap rate leaves out cold starts (plan 3)', () {
    final r = Rig();
    r.run(r.engine.suggest(gymId: r.gymId, muscleIds: ['chest'], minutes: 20));
    var c = r.engine.counters();
    expect(c.coldStartSets, greaterThan(0));
    r.now += 3 * day;
    r.run(r.engine.suggest(gymId: r.gymId, muscleIds: ['chest'], minutes: 20));
    c = r.engine.counters();
    expect(c.oneTapRate, greaterThan(c.oneTapRateInclCold));
  });

  test('load steps: gym list, next/prev, bodyweight empty', () {
    final r = Rig();
    final s = r.engine.loadSteps(
      gymId: r.gymId,
      exerciseId: 'dumbbell-bench-press',
    );
    expect(s.unit, LoadUnit.ea);
    expect(s.next(20000), 22000);
    expect(s.prev(20000), 18000);
    expect(s.next(25000), isNull);
    expect(s.next(null), 2000);
    final bw = r.engine.loadSteps(gymId: r.gymId, exerciseId: 'pushups');
    expect(bw.unit, LoadUnit.bodyweight);
    expect(bw.loadsG, isEmpty);
    final stack = r.engine.loadSteps(
      gymId: r.gymId,
      exerciseId: 'triceps-pushdown',
    );
    expect(stack.unit, LoadUnit.kg);
    expect(stack.loadsG, defaultWeightsG['stack']);
  });

  test('last time is per gym', () {
    final r = Rig();
    final p = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
    );
    r.run(p, coldLoadG: 16000);
    final id = p.items.first.exerciseId;
    final lt = r.engine.lastTime(gymId: r.gymId, exerciseId: id)!;
    expect(lt.sets.first.loadG, 16000);
    expect(r.engine.lastTime(gymId: 'other', exerciseId: id), isNull);
  });

  test('summary: volume, delta, PBs, muscles lit; history; counters', () {
    final r = Rig();
    final p1 = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
      typeId: 'push',
    );
    final w1 = r.run(p1, coldLoadG: 20000, reps: 10);
    final s1 = r.engine.summary(w1.workoutUuid);
    expect(s1.pbs, isEmpty); // first time is not a PB
    expect(s1.volumeDeltaPct, isNull);
    expect(s1.musclesLit, contains('chest'));
    expect(s1.volumeKg, greaterThan(0));
    r.now += 2 * day;
    final p2 = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
      typeId: 'push',
    );
    final w2 = r.run(p2, reps: 12, app: '0.1.1');
    final s2 = r.engine.summary(w2.workoutUuid);
    expect(s2.pbs, isNotEmpty);
    expect(s2.pbs.first.kind, 'reps');
    expect(s2.pbs.first.wasReps, 10);
    expect(s2.volumeDeltaPct, greaterThan(0));
    expect(s2.weeklyStreak, 1);

    final h = r.engine.history();
    expect(h.map((x) => x.uuid), [w2.workoutUuid, w1.workoutUuid]);
    expect(h.first.gymName, 'Condo gym');

    final c = r.engine.counters();
    expect(c.sessionsTotal, 2);
    expect(c.sessionsLast14Days, 2);
    expect(c.appVersions, {'0.1.0': 1, '0.1.1': 1});
    expect(c.doneSets, greaterThan(0));
    expect(c.tapUnchangedSets, lessThan(c.doneSets));
  });

  test('weekly streak counts weeks with 2+ sessions', () {
    final r = Rig();
    SessionPlan p() =>
        r.engine.suggest(gymId: r.gymId, muscleIds: ['abs'], minutes: 15);
    // Week 1: two sessions. Week 2: two. Week 3: one so far.
    for (final d in [0, 2, 7, 9, 14]) {
      r.now = monday + d * day;
      r.run(p());
    }
    final ws = r.store.workouts();
    expect(r.engine.weeklyStreak(ws), 2);
    expect(r.engine.weeklyStreak(ws.sublist(0, 2)), 1);
    expect(r.engine.weeklyStreak(ws.sublist(0, 1)), 0);
  });

  test('recover: none, resume, finished-not-stored saved, stored deleted', () {
    final r = Rig();
    expect(r.engine.recover(null).action, RecoveryAction.none);
    expect(r.engine.recover('{"torn').action, RecoveryAction.none);
    final p = r.engine.suggest(
      gymId: r.gymId,
      muscleIds: ['chest'],
      minutes: 20,
    );
    var s = Session.start(p, nowMs: r.now, tzOffsetMin: 480);
    s = Session.done(s, s.currentSet!.setId, nowMs: r.now + 1000, loadG: 10000);
    final open = r.engine.recover('${s.encode()}\n');
    expect(open.action, RecoveryAction.offerResume);
    expect(open.snapshot!.rev, s.rev);
    final fin = Session.finish(s, nowMs: r.now + 2000);
    final j = '${s.encode()}\n${fin.encode()}\n';
    expect(r.engine.recover(j).action, RecoveryAction.savedThenDelete);
    expect(r.engine.isStored(s.workoutUuid), isTrue);
    expect(r.engine.recover(j).action, RecoveryAction.deleteJournal);
    expect(() => r.engine.saveFinished(s), throwsArgumentError);
  });

  test('recover stores hr.jsonl with a finished journal (R2)', () {
    final r = Rig();
    final p = r.engine.suggest(gymId: r.gymId, muscleIds: ['abs'], minutes: 15);
    var s = Session.start(p, nowMs: r.now, tzOffsetMin: 480);
    s = Session.done(s, s.currentSet!.setId, nowMs: r.now + 1000);
    s = Session.finish(s, nowMs: r.now + 2000);
    final res = r.engine.recover(
      '${s.encode()}\n',
      hrText: '{"t_ms":1,"e_ms":1,"bpm":100}\n{"t_ms":2,"e_ms":2,"bpm":101}\n{"t_ms":3,"b',
    );
    expect(res.action, RecoveryAction.savedThenDelete);
    expect(r.store.hrSamples(s.workoutUuid), hasLength(2));
  });

  test('an empty start-then-finish is not a session in counters', () {
    final r = Rig();
    final p = r.engine.suggest(gymId: r.gymId, muscleIds: ['abs'], minutes: 15);
    final s = Session.finish(
      Session.start(p, nowMs: r.now, tzOffsetMin: 480),
      nowMs: r.now + 1000,
    );
    r.engine.saveFinished(s);
    expect(r.engine.counters().sessionsTotal, 0);
    expect(r.engine.history(), hasLength(1));
  });

  test('saveFinished is idempotent by uuid', () {
    final r = Rig();
    final w = r.run(
      r.engine.suggest(gymId: r.gymId, muscleIds: ['abs'], minutes: 15),
    );
    r.engine.saveFinished(w);
    expect(r.store.workouts(), hasLength(1));
  });

  test('export: JSON bundle and CSV with formula escaping', () {
    final r = Rig();
    r.engine.saveGym(r.store.gym(r.gymId)!.copyWith(name: '=HYPERLINK("x")'));
    r.run(r.engine.suggest(gymId: r.gymId, muscleIds: ['chest'], minutes: 20));
    final x = r.engine.export(
      appVersion: '0.1.0',
      native: {'rest_alerts_fired': 3},
    );
    final j = jsonDecode(x.json) as Map<String, Object?>;
    expect(j['export_format'], 2);
    expect(j['snapshot_schema'], 1);
    expect((j['counters'] as Map)['native'], {'rest_alerts_fired': 3});
    expect((j['workouts'] as List), hasLength(1));
    final csv = x.csv.split('\r\n');
    expect(csv.first, GymEngine.csvHeader.join(','));
    expect(csv[1], contains('"\'=HYPERLINK(""x"")"'));
    expect(csvField('-5'), '-5');
    expect(csvField('@a'), "'@a");
    expect(csvField('a,b'), '"a,b"');
  });

  test('suggestions are deterministic for a seed', () {
    final r = Rig();
    List<String> ids(int seed) => [
      for (final i
          in r.engine
              .suggest(
                gymId: r.gymId,
                muscleIds: ['chest', 'triceps'],
                seed: seed,
              )
              .items)
        i.exerciseId,
    ];
    expect(ids(3), ids(3));
    expect(ids(0), ids(0));
  });

  test('ceiling with a harder variant points at it (B7)', () {
    Exercise ex(String id, {String? harder}) => Exercise(
      id: id,
      name: id == 'a' ? 'Floor Press' : 'Bench Press',
      primary: const ['chest'],
      secondary: const [],
      equipmentSets: const [
        {'dumbbells'},
      ],
      load: 'dumbbell',
      unilateral: false,
      cue: '',
      harderThan: harder,
    );
    final base = Rig.catalog;
    final cat = Catalog(
      muscles: base.muscles,
      equipment: base.equipment,
      presets: base.presets,
      exercises: [
        ex('a'),
        ex('b', harder: 'a'),
      ],
    );
    final e = GymEngine(catalog: cat, store: MemoryStore(), nowMs: () => 0);
    final steps = const LoadSteps(LoadUnit.ea, [20000, 25000]);
    final p = e.progress(
      cat.exercise('a')!,
      const LastTime(
        workoutUuid: 'w',
        atMs: 0,
        sets: [PlannedSet(loadG: 25000, reps: 12)],
      ),
      steps,
    );
    expect(p.loadG, 25000);
    expect(p.reps, [13]);
    expect(p.note, contains('try Bench Press'));
  });
}
