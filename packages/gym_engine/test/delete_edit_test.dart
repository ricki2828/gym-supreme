// 0.2.1 D1: soft delete, undo, history edits, the rotation rule and
// export v2 (plan gym-supreme-0.3 §3, engine table). Every stat test runs on
// both stores; SQLite-only checks (snapshot_json, backup) are marked.
import 'dart:convert';
import 'dart:io';

import 'package:gym_engine/cut2.dart';
import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:test/test.dart';

const day = 86400000;
const min = 60000;
const bench = 'dumbbell-bench-press';
const row = 'one-arm-dumbbell-row';

// Mon 16-Nov-2026 09:00 +08:00 (week 3); weeks 1 and 2 before it.
final monday = DateTime.utc(2026, 11, 16, 1).millisecondsSinceEpoch;

final catalog = Catalog.fromJson(
  File('../../assets/exercises_taxonomy.json').readAsStringSync(),
  File('../../assets/exercises.json').readAsStringSync(),
);

/// One set: done unless [skipped]; [timed] for a block.
typedef S = ({String ex, int? load, int? reps, bool skipped, bool timed});

S done(String ex, int? load, int reps) =>
    (ex: ex, load: load, reps: reps, skipped: false, timed: false);
S skipped(String ex) =>
    (ex: ex, load: null, reps: null, skipped: true, timed: false);
S timed(String ex) =>
    (ex: ex, load: null, reps: null, skipped: false, timed: true);

WorkoutRecord rec(String uuid, String gym, String? type, int at, List<S> sets) {
  final pos = <String, int>{};
  final ord = <String, int>{};
  return WorkoutRecord(
    uuid: uuid,
    gymId: gym,
    typeId: type,
    muscles: const ['chest'],
    startedAtMs: at,
    tzOffsetMin: 480,
    endedAtMs: at + 40 * min,
    appVersion: '0.2.1',
    sets: [
      for (var i = 0; i < sets.length; i++)
        SetRecord(
          setId: '$uuid:$i',
          exerciseId: sets[i].ex,
          exerciseName: sets[i].ex,
          exercisePosition: pos.putIfAbsent(sets[i].ex, () => pos.length),
          setOrdinal: ord[sets[i].ex] = (ord[sets[i].ex] ?? 0) + 1,
          kind: sets[i].timed ? SetKind.timed : SetKind.reps,
          loadG: sets[i].load,
          reps: sets[i].reps,
          skipped: sets[i].skipped,
          completion: sets[i].skipped ? null : Completion.tapUnchanged,
          startedAtMs: at + i * 2 * min,
          endedAtMs: at + (i + 1) * 2 * min,
          offsetMs: (i + 1) * 2 * min,
          blockJson: sets[i].timed ? '{"type":"emom"}' : null,
        ),
    ],
  );
}

/// The fixture: six workouts across two gyms and three weeks.
/// Week 1: w1 push g1, w2 pull g1. Week 2: w3 push g1, w4 pull g2, w5 push
/// g1. Week 3: w6 push g1 (latest).
List<WorkoutRecord> fixture(String g1, String g2) => [
  rec('w1', g1, 'push', monday - 14 * day, [
    done(bench, 20000, 10),
    done(bench, 20000, 10),
  ]),
  rec('w2', g1, 'pull', monday - 11 * day, [
    done(row, 20000, 10),
    done(row, 20000, 10),
  ]),
  rec('w3', g1, 'push', monday - 7 * day, [
    done(bench, 22000, 10),
    done(bench, 22000, 8),
  ]),
  rec('w4', g2, 'pull', monday - 5 * day, [
    done(row, 22000, 10),
    done(row, 22000, 10),
  ]),
  rec('w5', g1, 'push', monday - 3 * day, [
    done(bench, 22000, 11),
    done(bench, 22000, 10),
  ]),
  rec('w6', g1, 'push', monday, [
    done(bench, 24000, 8),
    done(bench, 22000, 10),
  ]),
];

class Rig {
  Rig(this.store, {Iterable<String> skip = const []}) {
    engine = GymEngine(
      catalog: catalog,
      store: store,
      nowMs: () => now,
      tzOffsetMin: () => 480,
    );
    final a = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
      25000,
    ]);
    engine.saveGym(a);
    g1 = a.id;
    engine.saveGym(
      engine.gymFromPreset('condo', name: 'Hotel').withWeights('dumbbells', [
        for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
      ]),
    );
    g2 = engine.gyms().firstWhere((g) => g.id != g1).id;
    for (final w in fixture(g1, g2)) {
      if (skip.contains(w.uuid)) continue;
      store.upsertWorkout(
        w,
        snapshotJson: '{"as":"finished","uuid":"${w.uuid}"}',
        hr: [HrSample(w.startedAtMs + 1000, 120)],
      );
    }
  }

  final HistoryStore store;
  late final GymEngine engine;
  late final String g1;
  late final String g2;
  int now = monday + 2 * 3600 * 1000;

  List<String> uuids() => [for (final w in store.workouts()) w.uuid];
  WorkoutRecord w(String uuid) => store.workout(uuid)!;
  String sid(String uuid, int i) => '$uuid:$i';
}

void main() {
  for (final (name, make) in <(String, HistoryStore Function())>[
    ('memory store', MemoryStore.new),
    ('sqlite store', SqliteStore.inMemory),
  ]) {
    group(name, () => stats(make));
  }

  group('memory store only', memoryOnly);
  group('sqlite only', sqliteOnly);

  test('guard: workout / set_row SQL only in the allowed store members', () {
    // Soft delete is one filter in SqliteStore.workouts()/workout(). A new
    // reader that skips it would leak deleted workouts into a stat.
    RegExp sql(String table) => RegExp('\\b(FROM|JOIN)\\s+$table\\b');
    final allowed = {
      'workout': {
        'workouts', // filtered reader
        'workout', // filtered reader
        'hasWorkout', // unfiltered on purpose: recovery
        'deletedWorkoutUuids', // tombstones only
        '_workoutCount', // backup guard counts tombstones (E2)
      },
      'set_row': {'workouts', 'workout', 'upsertWorkout'},
    };
    // Split sqlite_store.dart into members (2-space declarations; column-0
    // lines start a top-level one) and join each member's adjacent string
    // literals, so `'... FROM '` + `'workout ...'` on two lines still counts.
    // Lines inside ''' strings never start a member: the migrations list
    // stays 'migrations', so a data migration reading workout is flagged.
    final members = <String, StringBuffer>{};
    var member = '<top>';
    final decl = RegExp(r'^  (?:static )?[\w<>?,\s]*?\b(\w+)\s*[(=]');
    final top = RegExp(r'^[\w].*?\b(\w+)\s*[(=]');
    var inTriple = false;
    for (final line in File('lib/src/sqlite_store.dart').readAsLinesSync()) {
      final t = line.trimLeft();
      final wasInTriple = inTriple;
      if ("'''".allMatches(line).length.isOdd) inTriple = !inTriple;
      if (!wasInTriple && !t.startsWith('//') && !t.startsWith('@')) {
        final m = line.startsWith('  ') && !line.startsWith('   ')
            ? decl.firstMatch(line)
            : top.firstMatch(line);
        if (m != null) member = m.group(1)!;
      }
      (members[member] ??= StringBuffer()).writeln(line);
    }
    String joined(String text) => text
        .replaceAll(RegExp(r"'\s*\n\s*'"), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    final hits = <String>[];
    var seen = 0;
    for (final e in members.entries) {
      final text = joined(e.value.toString());
      for (final table in allowed.keys) {
        if (!sql(table).hasMatch(text)) continue;
        seen++;
        if (!allowed[table]!.contains(e.key)) {
          hits.add('sqlite_store.dart ${e.key}: $table');
        }
      }
    }
    // Nothing else in the engine, the app or Kotlin reads either table.
    for (final root in ['lib', '../../lib', '../../android', '../../tools']) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!RegExp(r'\.(dart|kt|java|py|sh)$').hasMatch(f.path)) continue;
        if (f.path.endsWith('sqlite_store.dart')) continue;
        final text = joined(f.readAsStringSync());
        for (final table in allowed.keys) {
          if (sql(table).hasMatch(text)) hits.add('${f.path}: $table');
        }
      }
    }
    expect(hits, isEmpty);
    expect(seen, greaterThanOrEqualTo(7), reason: 'guard sees the readers');
  });
}

void stats(HistoryStore Function() make) {
  Rig rig({Iterable<String> skip = const []}) => Rig(make(), skip: skip);

  /// Everything a stat reads, for "delete X" == "never had X".
  Object view(Rig r) {
    final e = r.engine;
    return jsonEncode({
      'history': [
        for (final h in e.history())
          [h.uuid, h.gymName, h.volumeKg, h.setCount],
      ],
      'muscles': {
        for (final m in e.muscleStatus(gymId: r.g1).values)
          m.muscleId: [m.lastTrainedAtMs, m.daysSince, m.resting],
      },
      'summaries': {
        for (final u in r.uuids())
          u: () {
            final s = e.summary(u);
            return [
              s.volumeKg,
              s.volumeDeltaPct,
              s.weeklyStreak,
              [for (final p in s.pbs) '${p.exerciseId}/${p.kind}/${p.loadG}'],
            ];
          }(),
      },
      'last': [
        for (final g in [r.g1, r.g2])
          for (final x in [bench, row])
            e.lastTime(gymId: g, exerciseId: x)?.workoutUuid,
      ],
      'suggest': [
        for (final g in [r.g1, r.g2])
          for (final item
              in e
                  .suggest(gymId: g, muscleIds: ['chest', 'lats'], seed: 3)
                  .items)
            [
              item.exerciseId,
              item.reason,
              [for (final s in item.sets) '${s.loadG}x${s.reps}'],
            ],
      ],
      'counters': () {
        final c = e.counters();
        return [
          c.sessionsTotal,
          c.sessionsLast14Days,
          c.doneSets,
          c.oneTapRate,
        ];
      }(),
    });
  }

  group('history (H)', () {
    test('H1 deleted: gone from history/workouts/workout, hasWorkout true', () {
      final r = rig();
      final d = r.engine.deleteWorkout('w3')!;
      expect(d.uuid, 'w3');
      expect(d.deletedAtMs, r.now);
      expect(r.engine.history().map((h) => h.uuid), isNot(contains('w3')));
      expect(r.uuids(), ['w1', 'w2', 'w4', 'w5', 'w6']);
      expect(r.store.workout('w3'), isNull);
      expect(r.store.hasWorkout('w3'), isTrue);
      expect(r.engine.isStored('w3'), isTrue);
      expect(r.store.deletedWorkoutUuids(), ['w3']);
      expect(() => r.engine.summary('w3'), throwsArgumentError);
    });

    test('H2 undo brings it back with HR samples and the same sets', () {
      final r = rig();
      final before = r.w('w3');
      r.engine.deleteWorkout('w3');
      expect(r.engine.undoDelete('w3'), isTrue);
      final after = r.w('w3');
      expect(r.store.deletedWorkoutUuids(), isEmpty);
      expect(r.store.hrSamples('w3').single.bpm, 120);
      expect(
        [for (final s in after.sets) '${s.setId}/${s.setOrdinal}/${s.loadG}'],
        [for (final s in before.sets) '${s.setId}/${s.setOrdinal}/${s.loadG}'],
      );
      expect(r.uuids(), ['w1', 'w2', 'w3', 'w4', 'w5', 'w6']);
    });

    test('delete == never had it, for every stat; undo == untouched', () {
      for (final u in ['w1', 'w2', 'w3', 'w4', 'w5', 'w6']) {
        final r = rig();
        final untouched = view(r);
        r.engine.deleteWorkout(u);
        expect(view(r), view(rig(skip: [u])), reason: 'delete $u');
        r.engine.undoDelete(u);
        expect(view(r), untouched, reason: 'undo $u');
      }
    });

    test(
      'double delete, unknown uuid and undo of a live one change nothing',
      () {
        final r = rig();
        expect(r.engine.deleteWorkout('nope'), isNull);
        expect(r.engine.undoDelete('w1'), isFalse);
        final first = r.engine.deleteWorkout('w1')!;
        r.now += 5000;
        expect(r.engine.deleteWorkout('w1'), isNull);
        expect(r.store.deleteWorkout('w1', r.now), isFalse);
        expect(r.store.restoreWorkout('nope'), isFalse);
        expect(r.store.deletedWorkoutUuids(), ['w1']);
        expect(first.deletedAtMs, r.now - 5000);
      },
    );

    test('deletedWorkoutUuids is ordered by delete time', () {
      final r = rig();
      r.engine.deleteWorkout('w5');
      r.now += 1;
      r.engine.deleteWorkout('w2');
      expect(r.store.deletedWorkoutUuids(), ['w5', 'w2']);
    });
  });

  group('PBs (P)', () {
    test('P1 delete the load-PB workout: the next one now reports it', () {
      final r = rig();
      // w5 (22 kg x 11) is a reps PB over w3 (22 kg x 10).
      expect(r.engine.summary('w5').pbs.single.kind, 'reps');
      r.engine.deleteWorkout('w3');
      final pb = r.engine.summary('w5').pbs.single;
      expect([pb.kind, pb.loadG, pb.wasLoadG], ['load', 22000, 20000]);
    });

    test('P2 delete the baseline: a later first-time lift is not a PB', () {
      final r = rig();
      expect(r.engine.summary('w4').pbs.single.kind, 'load');
      r.engine.deleteWorkout('w2');
      expect(r.engine.summary('w4').pbs, isEmpty);
    });

    test('P3 edit the PB load down: gone; back up: there again', () {
      final r = rig();
      expect(r.engine.summary('w6').pbs.single.loadG, 24000);
      r.engine.editWorkout('w6', [
        WorkoutEdit.setValues(r.sid('w6', 0), loadG: 22000, reps: 8),
      ]);
      expect(r.engine.summary('w6').pbs, isEmpty);
      r.engine.editWorkout('w6', [
        WorkoutEdit.setValues(r.sid('w6', 0), loadG: 26000, reps: 8),
      ]);
      expect(r.engine.summary('w6').pbs.single.loadG, 26000);
    });

    test('P4 remove the PB set', () {
      final r = rig();
      r.engine.editWorkout('w6', [WorkoutEdit.removeSet(r.sid('w6', 0))]);
      expect(r.engine.summary('w6').pbs, isEmpty);
    });
  });

  group('days-since (DS)', () {
    test('DS1 delete the latest chest workout: back to the one before', () {
      final r = rig();
      int? chest() =>
          r.engine.muscleStatus(gymId: r.g1)['chest']!.lastTrainedAtMs;
      expect(chest(), r.w('w6').endedAtMs);
      final w5End = r.w('w5').endedAtMs;
      r.engine.deleteWorkout('w6');
      expect(chest(), w5End);
      for (final u in ['w1', 'w3', 'w5']) {
        r.engine.deleteWorkout(u);
      }
      expect(chest(), isNull);
      expect(r.engine.muscleStatus(gymId: r.g1)['chest']!.daysSince, isNull);
    });

    test('DS2 a value edit keeps it; removing a set below "hard" moves it', () {
      final r = rig();
      int? chest() =>
          r.engine.muscleStatus(gymId: r.g1)['chest']!.lastTrainedAtMs;
      r.engine.editWorkout('w6', [
        WorkoutEdit.setValues(r.sid('w6', 1), loadG: 2000, reps: 1),
      ]);
      expect(chest(), r.w('w6').endedAtMs);
      // Two chest sets is the "trained hard" line; one left is under it.
      r.engine.editWorkout('w6', [WorkoutEdit.removeSet(r.sid('w6', 0))]);
      expect(chest(), r.w('w5').endedAtMs);
    });
  });

  group('streak (S)', () {
    test('S1 delete from a week of exactly 2: streak drops; undo restores', () {
      final r = rig();
      expect(r.engine.summary('w6').weeklyStreak, 2);
      r.engine.deleteWorkout('w2');
      expect(r.engine.summary('w6').weeklyStreak, 1);
      r.engine.undoDelete('w2');
      expect(r.engine.summary('w6').weeklyStreak, 2);
    });

    test('S2 delete from a week of 3: unchanged', () {
      final r = rig();
      r.engine.deleteWorkout('w4');
      expect(r.engine.summary('w6').weeklyStreak, 2);
    });

    test('S3 delete the latest: streak anchored on the new latest', () {
      final r = rig();
      r.engine.deleteWorkout('w6');
      expect(r.store.workouts().last.uuid, 'w5');
      expect(r.engine.weeklyStreak(r.store.workouts()), 2);
      r.engine.deleteWorkout('w5');
      r.engine.deleteWorkout('w4');
      // Week 2 now has one (w3): it no longer counts, week 1 does.
      expect(r.engine.weeklyStreak(r.store.workouts()), 1);
    });
  });

  group('volume delta (V)', () {
    double vol(List<(int, int)> s) =>
        s.fold(0.0, (a, x) => a + x.$1 * x.$2) / 1000.0;

    test('V1 the next same-type workout compares with the one before', () {
      final r = rig();
      final w5 = vol([(22000, 11), (22000, 10)]);
      double pct(double now, double was) => (now - was) / was * 100;
      expect(
        r.engine.summary('w5').volumeDeltaPct,
        closeTo(pct(w5, vol([(22000, 10), (22000, 8)])), 1e-9),
      );
      r.engine.deleteWorkout('w3');
      expect(
        r.engine.summary('w5').volumeDeltaPct,
        closeTo(pct(w5, vol([(20000, 10), (20000, 10)])), 1e-9),
      );
    });

    test('V2 an edit changes volumeKg and the later delta', () {
      final r = rig();
      final before = r.engine.summary('w5').volumeDeltaPct!;
      r.engine.editWorkout('w3', [
        WorkoutEdit.setValues(r.sid('w3', 1), loadG: 22000, reps: 10),
      ]);
      expect(r.engine.summary('w3').volumeKg, vol([(22000, 10), (22000, 10)]));
      expect(r.engine.summary('w5').volumeDeltaPct, lessThan(before));
    });
  });

  group('ghost (G)', () {
    SessionPlan plan(String gym, String ex) => SessionPlan(
      gymId: gym,
      typeId: 'push',
      muscles: const ['chest'],
      estimatedMinutes: 20,
      uncovered: const [],
      items: [
        PlannedItem(
          exerciseId: ex,
          name: ex,
          unit: LoadUnit.ea,
          sets: const [
            PlannedSet(loadG: 22000, reps: 10),
            PlannedSet(loadG: 22000, reps: 10),
            PlannedSet(loadG: 22000, reps: 10),
          ],
          repLo: 8,
          repHi: 12,
          restS: 60,
          reason: '',
          primary: const ['chest'],
        ),
      ],
    );

    SessionSnapshot live(Rig r, String gym, String ex) => Session.start(
      plan(gym, ex),
      nowMs: r.now,
      tzOffsetMin: 480,
      workoutUuid: 'live',
    );

    test('G1 ghosts never use a deleted workout; fall back or hide', () {
      final r = rig();
      final a = live(r, r.g1, bench);
      expect(ghostsForSession(a, r.store.workouts())[bench]!.workoutUuid, 'w6');
      r.engine.deleteWorkout('w6');
      expect(ghostsForSession(a, r.store.workouts())[bench]!.workoutUuid, 'w5');
      final b = live(r, r.g2, row);
      expect(ghostsForSession(b, r.store.workouts())[row]!.workoutUuid, 'w4');
      r.engine.deleteWorkout('w4');
      expect(ghostsForSession(b, r.store.workouts())[row], isNull);
      for (final u in r.store.workouts()) {
        expect(u.uuid, isNot(anyOf('w4', 'w6')));
      }
    });

    test('G2 ghostTotalForRecord of a later workout recomputes', () {
      final r = rig();
      final t0 = ghostTotalForRecord(r.w('w6'), r.store.workouts())!;
      r.engine.deleteWorkout('w5');
      final t1 = ghostTotalForRecord(r.w('w6'), r.store.workouts())!;
      // w5 (22x11 + 22x10) vs w3 (22x10 + 22x8).
      expect(t0.ghostFullGReps, 22000 * 21);
      expect(t1.ghostFullGReps, 22000 * 18);
    });

    test('G3 remove set 2 of 3: ordinals 1,2; later set 2 meets old set 3', () {
      final r = rig();
      r.store.upsertWorkout(
        rec('g3', r.g1, 'push', r.now - 3600 * 1000, [
          done(bench, 20000, 10),
          done(bench, 21000, 9),
          done(bench, 23000, 7),
          skipped(row),
          done(row, 20000, 10),
          skipped(row),
        ]),
      );
      final w = r.engine.editWorkout('g3', [
        WorkoutEdit.removeSet(r.sid('g3', 1)),
        WorkoutEdit.removeSet(r.sid('g3', 4)),
      ]);
      String ords(String ex) => [
        for (final s in w.sets)
          if (s.exerciseId == ex)
            '${s.setId}#${s.setOrdinal}${s.skipped ? 's' : ''}',
      ].join(' ');
      expect(ords(bench), 'g3:0#1 g3:2#2');
      // Skipped sets keep their place and take a number.
      expect(ords(row), 'g3:3#1s g3:5#2s');
      final a = live(r, r.g1, bench);
      final g = ghostsForSession(a, r.store.workouts())[bench]!;
      expect(g.workoutUuid, 'g3');
      final line = compareSet(ghost: g, setOrdinal: 2, loadG: 23000, reps: 8);
      expect([line.ghostLoadG, line.ghostReps], [23000, 7]);
    });

    test(
      'G4 delete while a session is paused: ghosts on resume exclude it',
      () {
        final r = rig();
        var s = live(r, r.g1, bench);
        s = Session.done(s, s.currentSet!.setId, nowMs: r.now + min);
        s = Session.pause(s, nowMs: r.now + 2 * min);
        expect(
          ghostsForSession(s, r.store.workouts())[bench]!.workoutUuid,
          'w6',
        );
        r.engine.deleteWorkout('w6');
        // Resume builds a new controller from the journal: ghosts recomputed.
        final resumed = Session.resume(
          SessionSnapshot.decode(s.encode()),
          nowMs: r.now + 10 * min,
        );
        final g = ghostsForSession(resumed, r.store.workouts())[bench]!;
        expect(g.workoutUuid, 'w5');
        expect(
          r.engine.lastTime(gymId: r.g1, exerciseId: bench)!.workoutUuid,
          'w5',
        );
      },
    );

    test('G4e an edit made while paused: ghost and lastTime show it', () {
      final r = rig();
      var s = live(r, r.g1, bench);
      s = Session.pause(s, nowMs: r.now + min);
      expect(
        ghostsForSession(s, r.store.workouts())[bench]!.byOrdinal(1)!.loadG,
        24000,
      );
      r.engine.editWorkout('w6', [
        WorkoutEdit.setValues(r.sid('w6', 0), loadG: 23000, reps: 9),
        WorkoutEdit.removeSet(r.sid('w6', 1)),
      ]);
      final resumed = Session.resume(
        SessionSnapshot.decode(s.encode()),
        nowMs: r.now + 10 * min,
      );
      final g = ghostsForSession(resumed, r.store.workouts())[bench]!;
      expect(g.workoutUuid, 'w6');
      expect([g.byOrdinal(1)!.loadG, g.byOrdinal(1)!.reps], [23000, 9]);
      expect(g.byOrdinal(2), isNull);
      final last = r.engine.lastTime(gymId: r.g1, exerciseId: bench)!;
      expect([for (final x in last.sets) '${x.loadG}x${x.reps}'], ['23000x9']);
    });
  });

  group('last time / suggest (L)', () {
    test('L1 lastTime skips the deleted workout', () {
      final r = rig();
      expect(
        r.engine.lastTime(gymId: r.g1, exerciseId: bench)!.workoutUuid,
        'w6',
      );
      r.engine.deleteWorkout('w6');
      expect(
        r.engine.lastTime(gymId: r.g1, exerciseId: bench)!.workoutUuid,
        'w5',
      );
      expect(
        r.engine.lastTime(gymId: r.g2, exerciseId: row)!.workoutUuid,
        'w4',
      );
      r.engine.deleteWorkout('w4');
      expect(r.engine.lastTime(gymId: r.g2, exerciseId: row), isNull);
    });

    test('L2 suggest uses the earlier session (same as never logged)', () {
      final r = rig();
      final before = r.engine.suggest(
        gymId: r.g1,
        muscleIds: ['chest'],
        seed: 1,
      );
      r.engine.deleteWorkout('w6');
      final after = r.engine.suggest(
        gymId: r.g1,
        muscleIds: ['chest'],
        seed: 1,
      );
      final n = rig(skip: ['w6']);
      final never = n.engine.suggest(
        gymId: n.g1,
        muscleIds: ['chest'],
        seed: 1,
      );
      String flat(SessionPlan p) => [
        for (final i in p.items)
          '${i.exerciseId}:${[for (final s in i.sets) '${s.loadG}x${s.reps}']}',
      ].join('|');
      expect(flat(after), flat(never));
      expect(flat(after), isNot(flat(before)));
    });
  });

  group('rotation (R)', () {
    Rotation rot(Rig r) => loadRotation(r.store);
    void finish(Rig r, String uuid) =>
        rotationAfterFinish(r.store, r.w(uuid).typeId, workoutUuid: uuid);

    test('R1 latest advancing workout, untouched since: pointer back', () {
      final r = rig();
      finish(r, 'w6');
      expect(rot(r).nextId, 'pull');
      final d = r.engine.deleteWorkout('w6', rotation: true)!;
      expect(rot(r).nextId, 'push');
      expect(d.rotationBefore!.nextId, 'pull');
    });

    test('R2 pointer moved by hand since: unchanged', () {
      final r = rig();
      finish(r, 'w6');
      saveRotation(r.store, rot(r).skip()); // pull skipped → legs
      final d = r.engine.deleteWorkout('w6', rotation: true)!;
      expect(rot(r).nextId, 'legs');
      expect(d.rotationBefore, isNull);
    });

    test('R3 an older workout: unchanged', () {
      final r = rig();
      finish(r, 'w5');
      finish(r, 'w6');
      final d = r.engine.deleteWorkout('w5', rotation: true)!;
      expect(rot(r).nextId, 'pull');
      expect(d.rotationBefore, isNull);
    });

    test('R4 undo restores the exact prior rotation', () {
      final r = rig();
      finish(r, 'w6');
      final prior = rot(r);
      final d = r.engine.deleteWorkout('w6', rotation: true)!;
      expect(rot(r), isNot(prior));
      expect(
        r.engine.undoDelete('w6', rotationBefore: d.rotationBefore),
        isTrue,
      );
      expect(rot(r), prior);
      // A second undo is refused and leaves the rotation alone.
      saveRotation(r.store, rot(r).skip());
      final now = rot(r);
      expect(
        r.engine.undoDelete('w6', rotationBefore: d.rotationBefore),
        isFalse,
      );
      expect(rot(r), now);
    });

    test('R5 mixed / null / out-of-rotation type: unchanged', () {
      final r = rig();
      for (final (uuid, type) in [('m1', null), ('m2', 'mixed')]) {
        r.store.upsertWorkout(
          rec(uuid, r.g1, type, r.now, [done(bench, 20000, 10)]),
        );
        finish(r, 'w6');
        rotationAfterFinish(r.store, type, workoutUuid: uuid);
        final before = rot(r);
        expect(
          r.engine.deleteWorkout(uuid, rotation: true)!.rotationBefore,
          isNull,
        );
        expect(rot(r), before);
      }
    });

    test('R4b undo keeps a rotation change he made after the delete', () {
      final r = rig();
      finish(r, 'w6');
      final d = r.engine.deleteWorkout('w6', rotation: true)!;
      expect(rot(r).nextId, 'push');
      saveRotation(r.store, rot(r).pointAt('legs')); // he taps Legs
      final his = rot(r);
      expect(
        r.engine.undoDelete('w6', rotationBefore: d.rotationBefore),
        isTrue,
      );
      expect(rot(r), his);
      expect(r.uuids(), contains('w6'));
    });

    test('R5b without the flag the rotation is never touched', () {
      final r = rig();
      finish(r, 'w6');
      final d = r.engine.deleteWorkout('w6')!;
      expect(rot(r).nextId, 'pull');
      expect(d.rotationBefore, isNull);
    });

    test('R6 recovery of a deleted workout never advances the rotation', () {
      final r = rig();
      final plan = SessionPlan(
        gymId: r.g1,
        typeId: 'legs',
        muscles: const ['quads'],
        estimatedMinutes: 10,
        uncovered: const [],
        items: const [],
      );
      var s = Session.start(plan, nowMs: r.now, tzOffsetMin: 480);
      s = Session.finish(s, nowMs: r.now + min);
      r.engine.saveFinished(s);
      finish(r, 'w6'); // last advance is another workout
      r.engine.deleteWorkout(s.workoutUuid, rotation: true);
      final before = rot(r);
      final rec0 = r.engine.recover('${s.encode()}\n');
      expect(rec0.action, RecoveryAction.deleteJournal);
      // What flows.dart _recover does for a finished journal:
      rotationAfterFinish(r.store, s.typeId, workoutUuid: s.workoutUuid);
      expect(rot(r), before);
    });
  });

  group('counters (C)', () {
    test('C1 sessions and sets exclude deleted; workouts_deleted counts', () {
      final r = rig();
      final c0 = r.engine.counters();
      expect([c0.sessionsTotal, c0.doneSets, c0.workoutsDeleted], [6, 12, 0]);
      r.engine.deleteWorkout('w6');
      r.engine.deleteWorkout('w1');
      final c1 = r.engine.counters();
      expect([c1.sessionsTotal, c1.doneSets, c1.workoutsDeleted], [4, 8, 2]);
      expect(c1.sessionsLast14Days, c0.sessionsLast14Days - 1);
      expect(c1.firstSessionAtMs, r.w('w2').startedAtMs);
    });

    test('C2 an edit keeps completion; a removed set leaves the counts', () {
      final r = rig();
      final c0 = r.engine.counters();
      r.engine.editWorkout('w6', [
        WorkoutEdit.setValues(r.sid('w6', 0), loadG: 20000, reps: 12),
      ]);
      final c1 = r.engine.counters();
      expect(c1.tapUnchangedSets, c0.tapUnchangedSets);
      expect(c1.oneTapRate, c0.oneTapRate);
      expect(r.w('w6').sets.first.completion, Completion.tapUnchanged);
      r.engine.editWorkout('w6', [WorkoutEdit.removeSet(r.sid('w6', 0))]);
      final c2 = r.engine.counters();
      expect(c2.doneSets, c0.doneSets - 1);
      expect(c2.tapUnchangedSets, c0.tapUnchangedSets - 1);
    });
  });

  group('export (E)', () {
    test('E1 v2: deleted out of JSON and CSV, uuids listed, edited_at_ms', () {
      final r = rig();
      r.engine.deleteWorkout('w2');
      r.now += 1000;
      r.engine.editWorkout('w5', [
        WorkoutEdit.setValues(r.sid('w5', 0), loadG: 22000, reps: 12),
      ]);
      final x = r.engine.export(appVersion: '0.2.1');
      final j = jsonDecode(x.json) as Map<String, Object?>;
      expect(j['export_format'], 2);
      final ws = (j['workouts'] as List).cast<Map<String, Object?>>();
      expect(ws.map((w) => w['uuid']), ['w1', 'w3', 'w4', 'w5', 'w6']);
      expect(j['deleted_workout_uuids'], ['w2']);
      expect((j['counters'] as Map)['workouts_deleted'], 1);
      expect((j['counters'] as Map)['sessions_total'], 5);
      final w5 = ws.firstWhere((w) => w['uuid'] == 'w5');
      expect(w5['edited_at_ms'], r.now);
      expect(ws.first.containsKey('edited_at_ms'), isTrue);
      expect(ws.first['edited_at_ms'], isNull);
      expect(x.csv, isNot(contains('w2,')));
      expect(x.csv, contains('w5,'));
    });
  });

  group('recovery (X)', () {
    test('X1 finished journal of a deleted uuid: deleteJournal, not saved', () {
      final r = rig();
      final plan = SessionPlan(
        gymId: r.g1,
        typeId: 'push',
        muscles: const ['chest'],
        estimatedMinutes: 10,
        uncovered: const [],
        items: const [],
      );
      var s = Session.start(plan, nowMs: r.now, tzOffsetMin: 480);
      s = Session.finish(s, nowMs: r.now + min);
      r.engine.saveFinished(s);
      r.engine.deleteWorkout(s.workoutUuid);
      final res = r.engine.recover('${s.encode()}\n');
      expect(res.action, RecoveryAction.deleteJournal);
      expect(r.store.workout(s.workoutUuid), isNull);
      expect(r.store.deletedWorkoutUuids(), [s.workoutUuid]);
    });

    test(
      'X2 upsert of a deleted uuid keeps the tombstone and the edit stamp',
      () {
        final r = rig();
        final edited = r.engine.editWorkout('w3', [
          WorkoutEdit.setValues(r.sid('w3', 0), loadG: 21000, reps: 10),
        ]);
        r.engine.deleteWorkout('w3');
        r.store.upsertWorkout(fixture(r.g1, r.g2)[2]); // a re-save, no stamp
        expect(r.store.workout('w3'), isNull);
        expect(r.store.deletedWorkoutUuids(), ['w3']);
        r.engine.undoDelete('w3');
        expect(r.w('w3').editedAtMs, edited.editedAtMs);
      },
    );

    test('X2b a Finish retry (saveFinished again) never overwrites an edit '
        'or a delete', () {
      final r = rig();
      final plan = SessionPlan(
        gymId: r.g1,
        typeId: 'push',
        muscles: const ['chest'],
        estimatedMinutes: 10,
        uncovered: const [],
        items: const [
          PlannedItem(
            exerciseId: bench,
            name: bench,
            unit: LoadUnit.ea,
            sets: [
              PlannedSet(loadG: 20000, reps: 10),
              PlannedSet(loadG: 20000, reps: 10),
            ],
            repLo: 8,
            repHi: 12,
            restS: 60,
            reason: '',
            primary: ['chest'],
          ),
        ],
      );
      var s = Session.start(plan, nowMs: r.now, tzOffsetMin: 480);
      for (final x in [...s.exercises.first.sets]) {
        s = Session.done(s, x.setId, nowMs: r.now += min);
      }
      s = Session.finish(s, nowMs: r.now += min);
      final u = s.workoutUuid;
      r.engine.saveFinished(s);
      final first = r.w(u).sets.first.setId;
      final last = r.w(u).sets.last.setId;
      final edited = r.engine.editWorkout(u, [
        WorkoutEdit.setValues(first, loadG: 18000, reps: 7),
        WorkoutEdit.removeSet(last),
      ]);
      String sets(WorkoutRecord w) => [
        for (final x in w.sets)
          '${x.setId}#${x.setOrdinal}:${x.loadG}x${x.reps}',
      ].join(' ');
      r.engine.saveFinished(s); // the retry
      expect(sets(r.w(u)), sets(edited));
      expect(sets(r.w(u)), '$first#1:18000x7');
      expect(r.w(u).editedAtMs, edited.editedAtMs);
      r.engine.deleteWorkout(u);
      r.engine.saveFinished(s);
      expect(r.store.workout(u), isNull);
      expect(r.store.deletedWorkoutUuids(), [u]);
    });
  });

  group('edit rules (ED)', () {
    test('ED1 values saved, edited_at_ms set, HR kept, ids unchanged', () {
      final r = rig();
      r.now += 777;
      final w = r.engine.editWorkout('w3', [
        WorkoutEdit.setValues(r.sid('w3', 1), loadG: null, reps: 12),
      ]);
      expect(w.editedAtMs, r.now);
      expect(r.w('w3').editedAtMs, r.now);
      final s = r.w('w3').sets[1];
      expect([s.setId, s.setOrdinal, s.loadG, s.reps], ['w3:1', 2, null, 12]);
      expect(
        [s.completion, s.source],
        [Completion.tapUnchanged, SetSource.app],
      );
      expect(r.store.hrSamples('w3').single.bpm, 120);
      expect(r.w('w1').editedAtMs, isNull);
    });

    test('ED2 reps 0 / negative load refused; nothing written', () {
      final r = rig();
      final before = view(r);
      for (final bad in <List<WorkoutEdit>>[
        [WorkoutEdit.setValues(r.sid('w3', 0), loadG: 20000, reps: 0)],
        [WorkoutEdit.setValues(r.sid('w3', 0), loadG: -1, reps: 5)],
        [WorkoutEdit.setValues('w3:99', loadG: 1, reps: 5)],
        // All or nothing: a good edit before a bad one is not written.
        [
          WorkoutEdit.removeSet(r.sid('w3', 0)),
          WorkoutEdit.setValues(r.sid('w3', 1), loadG: 1, reps: 0),
        ],
        // Removed in the same call: the later edit finds no set.
        [
          WorkoutEdit.removeSet(r.sid('w3', 0)),
          WorkoutEdit.setValues(r.sid('w3', 0), loadG: 1, reps: 5),
        ],
      ]) {
        expect(() => r.engine.editWorkout('w3', bad), throwsArgumentError);
      }
      expect(view(r), before);
      expect(r.w('w3').editedAtMs, isNull);
      expect(
        () => r.engine.editWorkout('nope', [WorkoutEdit.removeSet('x')]),
        throwsArgumentError,
      );
      r.engine.deleteWorkout('w3');
      expect(
        () => r.engine.editWorkout('w3', [WorkoutEdit.removeSet('w3:0')]),
        throwsArgumentError,
      );
    });

    test('ED2b an empty edit list changes nothing (no stamp)', () {
      final r = rig();
      expect(r.engine.editWorkout('w3', const []).editedAtMs, isNull);
      expect(r.w('w3').editedAtMs, isNull);
    });

    test('ED3 remove the last done set: 0-set workout, out of counters', () {
      final r = rig();
      final c0 = r.engine.counters();
      final w = r.engine.editWorkout('w1', [
        WorkoutEdit.removeSet(r.sid('w1', 0)),
        WorkoutEdit.removeSet(r.sid('w1', 1)),
      ]);
      expect(w.sets, isEmpty);
      expect(r.uuids(), contains('w1'));
      final c1 = r.engine.counters();
      expect(c1.sessionsTotal, c0.sessionsTotal - 1);
      expect(r.engine.history().firstWhere((h) => h.uuid == 'w1').setCount, 0);
    });

    test('ED4 timed set: values refused, remove allowed; skipped likewise', () {
      final r = rig();
      r.store.upsertWorkout(
        rec('t', r.g1, 'push', r.now, [
          timed('plank'),
          skipped(bench),
          done(bench, 20000, 10),
        ]),
      );
      expect(
        () => r.engine.editWorkout('t', [
          WorkoutEdit.setValues('t:0', loadG: null, reps: 1),
        ]),
        throwsArgumentError,
      );
      expect(
        () => r.engine.editWorkout('t', [
          WorkoutEdit.setValues('t:1', loadG: 20000, reps: 10),
        ]),
        throwsArgumentError,
      );
      final w = r.engine.editWorkout('t', [
        WorkoutEdit.removeSet('t:0'),
        WorkoutEdit.removeSet('t:1'),
      ]);
      expect([for (final s in w.sets) '${s.setId}#${s.setOrdinal}'], ['t:2#1']);
    });
  });
}

void memoryOnly() {
  test('a rotation write error never fails the delete or the undo', () {
    final store = _FailingRotationStore();
    final r = Rig(store);
    rotationAfterFinish(store, 'push', workoutUuid: 'w6');
    final before = loadRotation(store);
    expect(before.nextId, 'pull');
    // Delete: the pointer-back write throws; the delete stands.
    store.fail = true;
    final d = r.engine.deleteWorkout('w6', rotation: true)!;
    expect(store.failedWrites, 1);
    expect(d.rotationBefore, isNull);
    expect(store.workout('w6'), isNull);
    expect(store.deletedWorkoutUuids(), ['w6']);
    // Undo: put the rotation where the delete would have left it, so the
    // undo's restore is attempted and throws; the restore stands.
    store.fail = false;
    saveRotation(store, before.pointAt('push'));
    store.fail = true;
    expect(r.engine.undoDelete('w6', rotationBefore: before), isTrue);
    expect(store.failedWrites, 2);
    expect(store.workout('w6'), isNotNull);
    expect(loadRotation(store).nextId, 'push');
  });

  test('summaryOrNull: null for unknown and deleted, else the summary', () {
    final r = Rig(MemoryStore());
    expect(r.engine.summaryOrNull('nope'), isNull);
    expect(r.engine.summaryOrNull('w6')!.uuid, 'w6');
    r.engine.deleteWorkout('w6');
    expect(r.engine.summaryOrNull('w6'), isNull);
  });
}

void sqliteOnly() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gs-d1'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('ED1 snapshot_json is the as-finished copy after an edit', () {
    final store = SqliteStore.inMemory();
    final r = Rig(store);
    String? snap() =>
        store.db
                .select("SELECT snapshot_json FROM workout WHERE uuid = 'w3'")
                .first['snapshot_json']
            as String?;
    final before = snap();
    r.engine.editWorkout('w3', [WorkoutEdit.removeSet('w3:0')]);
    expect(snap(), before);
    expect(before, contains('"uuid":"w3"'));
  });

  test(
    'E2 delete the only workout: writeSnapshot still writes the tombstone',
    () {
      final snapPath = '${dir.path}/backup/gym-snapshot.db';
      final a = SqliteStore.open('${dir.path}/gym.db');
      final ra = Rig(a, skip: ['w1', 'w2', 'w3', 'w4', 'w5']);
      expect(a.writeSnapshot(snapPath), isTrue);
      expect(ra.engine.deleteWorkout('w6'), isNotNull);
      expect(a.writeSnapshot(snapPath), isTrue);
      a.close();
      final check = SqliteStore.open(snapPath);
      expect(check.deletedWorkoutUuids(), ['w6']);
      expect(check.workouts(), isEmpty);
      check.close();
    },
  );

  test('E3 restore from that snapshot: history empty, still tombstoned', () {
    final snapPath = '${dir.path}/snap.db';
    final a = SqliteStore.open('${dir.path}/old.db');
    final ra = Rig(a, skip: ['w1', 'w2', 'w3', 'w4', 'w5']);
    ra.engine.deleteWorkout('w6');
    expect(a.writeSnapshot(snapPath), isTrue);
    a.close();
    final dbPath = '${dir.path}/gym.db';
    expect(
      SqliteStore.restoreSnapshotIfMissing(dbPath, snapPath),
      RestoreResult.restored,
    );
    final b = SqliteStore.open(dbPath);
    final e = GymEngine(catalog: catalog, store: b);
    expect(e.history(), isEmpty);
    expect(e.isStored('w6'), isTrue);
    expect(b.deletedWorkoutUuids(), ['w6']);
    b.close();
  });
}

/// Throws on rotation writes once [fail] is set (fix 1 of the Opus review).
class _FailingRotationStore extends MemoryStore {
  bool fail = false;
  int failedWrites = 0;

  @override
  void saveSetting(String key, String json) {
    if (fail && key == rotationSettingKey) {
      failedWrites++;
      throw StateError('disk full');
    }
    super.saveSetting(key, json);
  }
}
