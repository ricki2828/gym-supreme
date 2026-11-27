import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

const day = 86400000;

/// 2026-11-23 is a Monday; all fixtures sit at UTC (offset 0).
final monday = DateTime.utc(2026, 11, 23, 9).millisecondsSinceEpoch;
final now = monday + 3 * day; // Thursday of that week.

const bench = 'barbell-bench-press-medium-grip';
const squat = 'barbell-squat';

int _n = 0;

SetRecord s(
  String ex,
  int ord,
  int? kg,
  int? reps, {
  Completion? completion = Completion.adjusted,
  bool skipped = false,
  SetKind kind = SetKind.reps,
  int pos = 0,
}) => SetRecord(
  setId: 'set${_n++}',
  exerciseId: ex,
  exerciseName: ex,
  exercisePosition: pos,
  setOrdinal: ord,
  loadG: kg == null ? null : kg * 1000,
  reps: reps,
  completion: skipped ? null : completion,
  skipped: skipped,
  kind: kind,
);

WorkoutRecord w(
  String id,
  int startMs,
  List<SetRecord> sets, {
  String gym = 'g1',
  int tz = 0,
}) => WorkoutRecord(
  uuid: id,
  gymId: gym,
  startedAtMs: startMs,
  tzOffsetMin: tz,
  endedAtMs: startMs + 3600000,
  sets: sets,
);

StrengthAnalysis analyse(
  List<WorkoutRecord> ws, {
  Set<String> deleted = const {},
  Set<String> confirmed = const {},
  int? at,
}) => StrengthAnalysis(
  workouts: ws,
  catalog: catalog,
  nowMs: at ?? now,
  deletedUuids: deleted,
  confirmedSetIds: confirmed,
);

late Catalog catalog;

Set<RejectReason?> reasonsOf(StrengthAnalysis a) => {
  for (final v in a.verdicts) v.reason,
};

void main() {
  setUpAll(() {
    catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
  });

  group('rejection rules', () {
    test('skipped, timed, no load, no reps', () {
      final a = analyse([
        w('a', monday, [
          s(bench, 1, 100, 5, skipped: true),
          s(bench, 2, 100, 5, kind: SetKind.timed),
          s(bench, 3, null, 5),
          s(bench, 4, 0, 5),
          s(bench, 5, 100, 0),
          s(bench, 6, 80, 5),
        ]),
      ]);
      final r = [for (final v in a.verdicts) v.reason];
      expect(r, [
        RejectReason.skipped,
        RejectReason.timed,
        RejectReason.noLoad,
        RejectReason.noLoad,
        RejectReason.noReps,
        null,
      ]);
      expect(a.bestFor(bench)!.best.loadG, 80000);
    });

    test('over 12 reps is excluded; 11-12 counted rough', () {
      final a = analyse([
        w('a', monday, [s(bench, 1, 60, 15), s(bench, 2, 60, 12)]),
      ]);
      expect(a.verdicts[0].reason, RejectReason.repsOver12);
      final b = a.bestFor(bench)!;
      expect(b.best.e1rm.rough, isTrue);
      expect(b.bestSolid, isNull);
    });

    test('cold_start is rejected as a candidate', () {
      final a = analyse([
        w('a', monday, [
          s(bench, 1, 100, 5, completion: Completion.coldStart),
          s(bench, 2, 70, 5),
        ]),
      ]);
      expect(a.verdicts[0].reason, RejectReason.coldStart);
      expect(a.bestFor(bench)!.best.loadG, 70000);
    });

    test('warm-up: leading sets under 60% of the heaviest', () {
      final a = analyse([
        w('a', monday, [
          s(bench, 1, 40, 8),
          s(bench, 2, 59, 5), // 59% of 100: warm-up
          s(bench, 3, 60, 5), // exactly 60%: a work set
          s(bench, 4, 100, 5),
        ]),
      ]);
      final r = [for (final v in a.verdicts) v.reason];
      expect(r, [RejectReason.warmUp, RejectReason.warmUp, null, null]);
      expect(a.verdicts[3].isTop, isTrue);
    });

    test('a light set later in the workout is not a warm-up', () {
      final a = analyse([
        w('a', monday, [s(bench, 1, 100, 5), s(bench, 2, 40, 12)]),
      ]);
      expect(a.verdicts[1].reason, isNull);
    });

    test('single set is never a warm-up', () {
      final a = analyse([
        w('a', monday, [s(bench, 1, 40, 5)]),
      ]);
      expect(a.verdicts.single.reason, isNull);
    });

    test('soft-deleted workout is rejected and invisible everywhere', () {
      final a = analyse(
        [
          w('keep', monday, [s(bench, 1, 80, 5)]),
          w('gone', monday + day, [s(bench, 1, 85, 5), s(squat, 1, 100, 5)]),
        ],
        deleted: {'gone'},
      );
      expect(
        a.verdicts.where((v) => v.workoutUuid == 'gone').map((v) => v.reason),
        everyElement(RejectReason.workoutDeleted),
      );
      expect(a.bestFor(bench)!.best.loadG, 80000);
      expect(a.bestFor(squat), isNull);
      expect(a.weekly(weeks: 1).single.workouts, 1);
    });

    test('top set per exercise per workout is the highest e1RM', () {
      final a = analyse([
        w('a', monday, [
          s(bench, 1, 80, 8),
          s(bench, 2, 90, 5),
          s(bench, 3, 90, 3),
        ]),
      ]);
      // 80x8 = 101.3, 90x5 = 105, 90x3 = 99.
      expect(a.verdicts.where((v) => v.isTop).single.set.reps, 5);
      expect(a.bestFor(bench)!.points, hasLength(1));
    });
  });

  group('typo guard', () {
    final base = monday - 30 * day;
    WorkoutRecord prior() => w('p', base, [s(bench, 1, 100, 5)]);

    test('1000 instead of 100 is parked, not counted', () {
      final a = analyse([
        prior(),
        w('t', monday, [s(bench, 1, 1000, 5)]),
      ]);
      final v = a.verdicts.last;
      expect(v.reason, RejectReason.typoUnconfirmed);
      expect(v.isTop, isFalse);
      expect(a.bestFor(bench)!.best.loadG, 100000);
      expect(a.pbHistory(bench), hasLength(1));
    });

    test('too low (< 0.4x) is parked too', () {
      final a = analyse([
        prior(),
        w('t', monday, [s(bench, 1, 10, 5)]),
      ]);
      expect(a.verdicts.last.reason, RejectReason.typoUnconfirmed);
    });

    test('exactly 1.2x of prior best is accepted, just above is parked', () {
      // Prior 100 kg x 1 = exactly 100 kg e1RM (no division involved).
      WorkoutRecord one() => w('p1', base, [s(bench, 1, 100, 1)]);
      final at = analyse([
        one(),
        w('t', monday, [s(bench, 1, 120, 1)]),
      ]);
      expect(at.verdicts.last.reason, isNull);
      final above = analyse([
        one(),
        w('t', monday, [s(bench, 1, 121, 1)]),
      ]);
      expect(above.verdicts.last.reason, RejectReason.typoUnconfirmed);
    });

    test('a later workout within 10% confirms the parked set', () {
      final a = analyse([
        prior(),
        w('t1', monday - 7 * day, [s(bench, 1, 150, 5)]),
        w('t2', monday, [s(bench, 1, 155, 5)]),
      ]);
      final v = [for (final v in a.verdicts) v.reason];
      expect(v, [null, null, null]);
      expect(a.bestFor(bench)!.best.loadG, 155000);
      expect(a.pbHistory(bench).map((p) => p.point.workoutUuid), [
        'p',
        't1',
        't2',
      ]);
    });

    test('a later workout outside 10% does not confirm', () {
      final a = analyse([
        prior(),
        w('t1', monday - 7 * day, [s(bench, 1, 150, 5)]),
        w('t2', monday, [s(bench, 1, 110, 5)]),
      ]);
      expect(a.verdicts[1].reason, RejectReason.typoUnconfirmed);
      expect(a.bestFor(bench)!.best.loadG, 110000);
    });

    test('explicit confirm by set id accepts it', () {
      final typed = s(bench, 1, 1000, 5);
      final a = analyse(
        [
          prior(),
          w('t', monday, [typed]),
        ],
        confirmed: {typed.setId},
      );
      expect(a.verdicts.last.reason, isNull);
      expect(a.bestFor(bench)!.best.loadG, 1000000);
    });

    test('no prior best in 90 days: no guard', () {
      final a = analyse([
        w('old', monday - 200 * day, [s(bench, 1, 100, 5)]),
        w('t', monday, [s(bench, 1, 300, 5)]),
      ]);
      expect(a.verdicts.last.reason, isNull);
    });
  });

  group('90 day best', () {
    test('window edges and rough/solid split', () {
      final a = analyse([
        w('old', now - 91 * day, [s(bench, 1, 150, 5)]),
        w('in', now - 89 * day, [s(bench, 1, 100, 5), s(bench, 2, 60, 12)]),
        w('future', now + day, [s(bench, 1, 120, 5)]),
      ]);
      final b = a.bestFor(bench)!;
      expect(b.best.workoutUuid, 'in');
      expect(b.best.loadG, 100000);
      expect(b.points.map((p) => p.workoutUuid), ['in']);
    });

    test('90 days back is inclusive, one ms older is out', () {
      final edge = analyse([
        w('on', now - 90 * day, [s(bench, 1, 100, 5)]),
      ]);
      expect(edge.bestFor(bench), isNotNull);
      final out = analyse([
        w('off', now - 90 * day - 1, [s(bench, 1, 100, 5)]),
      ]);
      expect(out.bestFor(bench), isNull);
    });

    test('rough-only best has no solid best', () {
      final a = analyse([
        w('a', monday, [s(bench, 1, 50, 12)]),
      ]);
      expect(a.bestFor(bench)!.bestSolid, isNull);
    });

    test('gym filter, and bestIn90Days lists lifts', () {
      final a = analyse([
        w('a', monday - day, [s(bench, 1, 100, 5)], gym: 'g1'),
        w('b', monday, [
          s(bench, 1, 90, 5),
          s(squat, 1, 120, 5, pos: 1),
        ], gym: 'g2'),
      ]);
      expect(a.bestFor(bench)!.best.gymId, 'g1');
      expect(a.bestFor(bench, gymId: 'g2')!.best.loadG, 90000);
      expect(a.bestIn90Days().keys, {bench, squat});
      expect(a.bestIn90Days(gymId: 'g1').keys, {bench});
    });

    test('rejected sets listed for the detail sheet', () {
      final a = analyse([
        w('a', monday, [s(bench, 1, 40, 5), s(bench, 2, 100, 5)]),
      ]);
      expect(a.bestFor(bench)!.rejected.map((v) => v.reason), [
        RejectReason.warmUp,
      ]);
      expect(a.rejectedSets(exerciseId: squat), isEmpty);
    });
  });

  group('PB history', () {
    test('only strictly higher non-rough bests, with previous', () {
      final a = analyse([
        w('1', monday - 40 * day, [s(bench, 1, 100, 5)]),
        w('2', monday - 30 * day, [s(bench, 1, 95, 5)]),
        w('3', monday - 20 * day, [s(bench, 1, 70, 12)]), // rough, ignored
        w('4', monday - 10 * day, [s(bench, 1, 105, 5)]),
      ]);
      final h = a.pbHistory(bench);
      expect(h.map((p) => p.point.workoutUuid), ['1', '4']);
      expect(h[0].previousG, isNull);
      expect(h[1].previousG, closeTo(100000 * (1 + 5 / 30), 1e-6));
    });

    test('is window independent', () {
      final a = analyse([
        w('1', now - 400 * day, [s(bench, 1, 100, 5)]),
      ]);
      expect(a.pbHistory(bench), hasLength(1));
      expect(a.bestFor(bench), isNull);
    });
  });

  group('weekly', () {
    test('volume, hard sets by muscle, weeks Monday-start, empties filled', () {
      final a = analyse([
        // Week of 16-Nov (Sunday 22nd local still that week).
        w('prev', monday - day, [s(bench, 1, 90, 5)]),
        w('this1', monday, [
          s(bench, 1, 40, 8), // warm-up: volume yes, hard set no
          s(bench, 2, 100, 5),
          s(bench, 3, 100, 5),
          s(bench, 4, 100, 5, skipped: true),
          s(bench, 5, 100, 0), // zero reps: no hard set
          s(squat, 1, 120, 5, pos: 1, completion: Completion.coldStart),
        ]),
        w('this2', monday + 2 * day, [s(bench, 1, 100, 5)]),
      ]);
      final wk = a.weekly(weeks: 3);
      expect(wk.map((x) => x.weekStart), [
        DateTime.utc(2026, 11, 9),
        DateTime.utc(2026, 11, 16),
        DateTime.utc(2026, 11, 23),
      ]);
      expect(wk[0].workouts, 0);
      expect(wk[0].hardSetsByMuscle, isEmpty);
      expect(wk[1].volumeGReps, 450000);
      expect(wk[1].hardSetsByMuscle['chest'], const HardSets(primary: 1));
      final cur = wk[2];
      expect(cur.workouts, 2);
      expect(
        cur.volumeGReps,
        (40 * 8 + 100 * 5 * 2 + 120 * 5 + 100 * 5) * 1000,
      );
      expect(cur.hardSetsByMuscle['chest'], const HardSets(primary: 3));
      expect(cur.hardSetsByMuscle['triceps'], const HardSets(secondary: 3));
      expect(cur.hardSetsByMuscle['quads'], const HardSets(primary: 1));
      expect(cur.hardSetsByMuscle['glutes'], const HardSets(secondary: 1));
    });

    test('local week uses the stored tz offset', () {
      // Sunday 23:30 UTC at +120 min is Monday local: next week.
      final sunUtc = monday - 1 * day + 14 * 3600000 + 30 * 60000;
      final a = analyse([
        w('a', sunUtc, [s(bench, 1, 100, 5)], tz: 120),
      ]);
      final wk = a.weekly(weeks: 2);
      expect(wk.last.workouts, 1);
    });
  });

  group('review round 1', () {
    final prior = w('prior', monday - 30 * day, [s(bench, 1, 100, 5)]);

    test('P1-1 a typo set does not turn real sets into warm-ups', () {
      final a = analyse([
        prior,
        w('t', monday, [
          s(bench, 1, 100, 5),
          s(bench, 2, 100, 5),
          s(bench, 3, 1000, 5),
        ]),
      ]);
      final r = [
        for (final v in a.verdicts.where((v) => v.workoutUuid == 't')) v.reason,
      ];
      expect(r, [null, null, RejectReason.typoUnconfirmed]);
      // The workout contributes a point (its top is a real 100 x 5).
      expect(a.bestFor(bench)!.points.map((p) => p.workoutUuid), [
        'prior',
        't',
      ]);
      expect(a.bestFor(bench)!.best.loadG, 100000);
      final wk = a.weekly(weeks: 1).single;
      expect(wk.hardSetsByMuscle['chest'], const HardSets(primary: 3));
      // P2 volume: the parked typo set carries no volume.
      expect(wk.volumeGReps, 2 * 100 * 5 * 1000);
    });

    test('P1-2 a rough top set does not hide a solid set', () {
      final a = analyse([
        w('a', monday, [s(bench, 1, 100, 8), s(bench, 2, 95, 12)]),
      ]);
      final b = a.bestFor(bench)!;
      expect(b.best.reps, 12); // 95 x 12 = 133 kg, the rough top
      expect(b.bestSolid, isNotNull);
      expect(b.bestSolid!.loadG, 100000);
      expect(a.pbHistory(bench), hasLength(1));
      expect(a.pbHistory(bench).single.point.loadG, 100000);
    });

    test('P2 stack lifts are per gym: the typo guard does not merge gyms', () {
      final a = analyse([
        w('a', monday - 20 * day, [s('leg-press', 1, 200, 8)], gym: 'g1'),
        w('b', monday, [s('leg-press', 1, 70, 8)], gym: 'g2'),
      ]);
      expect(a.verdicts.last.reason, isNull);
      expect(a.bestFor('leg-press', gymId: 'g1')!.best.loadG, 200000);
      expect(a.bestFor('leg-press', gymId: 'g2')!.best.loadG, 70000);
      // No gym given: the gym trained most recently, never a merge.
      expect(a.bestFor('leg-press')!.best.loadG, 70000);
      expect(a.bestIn90Days().keys, {'leg-press@g1', 'leg-press@g2'});
      expect(a.pbHistory('leg-press', gymId: 'g1'), hasLength(1));
      expect(a.pbHistory('leg-press'), hasLength(1));
    });

    test('barbell lifts still merge across gyms for the guard', () {
      final a = analyse([
        w('a', monday - 20 * day, [s(bench, 1, 100, 5)], gym: 'g1'),
        w('b', monday, [s(bench, 1, 1000, 5)], gym: 'g2'),
      ]);
      expect(a.verdicts.last.reason, RejectReason.typoUnconfirmed);
    });

    test('P3 tied top sets pick the same set whatever the input order', () {
      final x = s(bench, 1, 100, 5), y = s(bench, 1, 100, 5);
      String topOf(List<SetRecord> sets) =>
          analyse([w('a', monday, sets)]).verdicts
              .singleWhere((v) => v.isTop)
              .set
              .setId;
      final lower = x.setId.compareTo(y.setId) < 0 ? x.setId : y.setId;
      expect(topOf([x, y]), lower);
      expect(topOf([y, x]), lower);
    });

    test(
      'P3 ramp 40/60/80/100: only 40 is a warm-up; 60 and 80 are hard sets',
      () {
        final a = analyse([
          w('a', monday, [
            s(bench, 1, 40, 5),
            s(bench, 2, 60, 5),
            s(bench, 3, 80, 5),
            s(bench, 4, 100, 5),
          ]),
        ]);
        expect(a.verdicts.first.reason, RejectReason.warmUp);
        expect(
          a.weekly(weeks: 1).single.hardSetsByMuscle['chest'],
          const HardSets(primary: 3),
        );
      },
    );

    test('perf: thousands of workouts and many lifts stay fast', () {
      final ex = [
        for (final e in catalog.exercises.where((e) => e.load == 'barbell'))
          e.id,
      ];
      final ws = [
        for (var i = 0; i < 1500; i++)
          w('w$i', now - i * day ~/ 3, [
            for (var k = 0; k < ex.length; k++)
              s(ex[k], 1, 60 + i % 7, 5, pos: k),
          ]),
      ];
      final sw = Stopwatch()..start();
      final a = analyse(ws);
      a.bestIn90Days();
      a.weekly();
      for (final id in ex) {
        a.pbHistory(id);
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });

  group('review round 2', () {
    test('P1 a done set with null reps does not throw', () {
      final a = analyse([
        w('p', monday - 10 * day, [s(bench, 1, 100, 5)]),
        w('t', monday, [s(bench, 1, 100, null), s(bench, 2, 100, 0)]),
      ]);
      final r = [
        for (final v in a.verdicts.where((v) => v.workoutUuid == 't')) v.reason,
      ];
      expect(r, [RejectReason.noReps, RejectReason.noReps]);
      expect(a.bestFor(bench)!.best.workoutUuid, 'p');
    });

    test('P2 warm-up stays a warm-up when the real sets are parked', () {
      final a = analyse([
        w('p', monday - 10 * day, [s(bench, 1, 50, 10)]),
        w('t', monday, [
          s(bench, 1, 40, 8),
          s(bench, 2, 100, 5),
          s(bench, 3, 100, 5),
        ]),
      ]);
      final t = a.verdicts.where((v) => v.workoutUuid == 't').toList();
      expect(t[0].reason, RejectReason.warmUp);
      expect(t[0].isTop, isFalse);
      expect(t[1].reason, RejectReason.typoUnconfirmed);
      expect(a.bestFor(bench)!.points.map((p) => p.workoutUuid), ['p']);
    });

    test(
      'P2 a first, cold-start workout at a new gym switches the stack gym',
      () {
        final a = analyse([
          w('a', monday - 20 * day, [s('leg-press', 1, 200, 8)], gym: 'g1'),
          w('b', monday, [
            s('leg-press', 1, 70, 8, completion: Completion.coldStart),
          ], gym: 'g2'),
        ]);
        // g2 is where he trained last; it has no accepted point yet, so no
        // g1 number is shown in its place.
        expect(a.bestFor('leg-press'), isNull);
        expect(a.bestFor('leg-press', gymId: 'g1')!.best.loadG, 200000);
      },
    );
  });

  test('deterministic: same input, same output', () {
    final ws = [
      w('a', monday - 3 * day, [
        s(bench, 1, 100, 5),
        s(squat, 1, 120, 5, pos: 1),
      ]),
      w('b', monday, [s(bench, 1, 102, 5)]),
    ];
    String dump(StrengthAnalysis a) => [
      for (final e in a.bestIn90Days().entries)
        '${e.key}:${e.value.best.e1rm.grams}',
      for (final v in a.verdicts) '${v.set.setId}:${v.reason}:${v.isTop}',
    ].join('|');
    expect(dump(analyse(ws)), dump(analyse(ws.reversed.toList())));
  });
}
