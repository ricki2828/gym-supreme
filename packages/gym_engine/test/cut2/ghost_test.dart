import 'package:gym_engine/src/cut2/ghost.dart';
import 'package:test/test.dart';

GhostInputSet s(
  String ex,
  int ord, {
  int? load,
  int? reps,
  int? off,
  bool skipped = false,
  bool timed = false,
}) => GhostInputSet(
  exerciseId: ex,
  setOrdinal: ord,
  loadG: load,
  reps: reps,
  offsetMs: off,
  skipped: skipped,
  timed: timed,
);

GhostInputWorkout w(String id, String gym, int at, List<GhostInputSet> sets) =>
    GhostInputWorkout(uuid: id, gymId: gym, startedAtMs: at, sets: sets);

void main() {
  final history = [
    w('w1', 'condo', 1000, [
      s('db-press', 1, load: 20000, reps: 10, off: 60000),
      s('db-press', 2, load: 20000, reps: 8, off: 180000),
    ]),
    w('w3', 'condo', 3000, [
      s('db-press', 2, load: 22500, reps: 8, off: 200000),
      s('db-press', 1, load: 22500, reps: 10, off: 70000),
      s('lat-pulldown', 1, load: 50000, reps: 12, off: 400000),
    ]),
    w('w2', 'condo', 2000, [s('lat-pulldown', 1, load: 45000, reps: 12)]),
    w('w4', 'hotel', 4000, [s('db-press', 1, load: 30000, reps: 5)]),
  ];

  group('ghostFor', () {
    test('latest earlier session at this gym with this exercise', () {
      final g = ghostFor(
        gymId: 'condo',
        exerciseId: 'db-press',
        beforeMs: 5000,
        workouts: history,
      )!;
      expect(g.workoutUuid, 'w3');
      expect([for (final x in g.sets) x.setOrdinal], [1, 2]); // sorted
      expect(g.volumeGReps, 22500 * 10 + 22500 * 8);
    });

    test('different gym is ignored', () {
      final g = ghostFor(
        gymId: 'hotel',
        exerciseId: 'db-press',
        beforeMs: 5000,
        workouts: history,
      )!;
      expect(g.workoutUuid, 'w4');
      expect(
        ghostFor(
          gymId: 'hotel',
          exerciseId: 'lat-pulldown',
          beforeMs: 5000,
          workouts: history,
        ),
        isNull,
      );
    });

    test('only sessions before the current one count', () {
      final g = ghostFor(
        gymId: 'condo',
        exerciseId: 'db-press',
        beforeMs: 3000, // w3 itself is not its own ghost
        workouts: history,
      )!;
      expect(g.workoutUuid, 'w1');
    });

    test('first session: hidden', () {
      expect(
        ghostFor(
          gymId: 'condo',
          exerciseId: 'db-press',
          beforeMs: 1000,
          workouts: history,
        ),
        isNull,
      );
      expect(
        ghostFor(
          gymId: 'condo',
          exerciseId: 'db-press',
          beforeMs: 9,
          workouts: const [],
        ),
        isNull,
      );
    });

    test('a later session with only skipped or timed sets is passed over', () {
      final h = [
        ...history,
        w('w5', 'condo', 5000, [
          s('db-press', 1, skipped: true),
          s('db-press', 2, timed: true),
        ]),
      ];
      final g = ghostFor(
        gymId: 'condo',
        exerciseId: 'db-press',
        beforeMs: 6000,
        workouts: h,
      )!;
      expect(g.workoutUuid, 'w3');
    });

    test('an edited history flows through (computed when shown)', () {
      final edited = [
        for (final x in history)
          x.uuid == 'w3'
              ? w('w3', 'condo', 3000, [
                  s('db-press', 1, load: 25000, reps: 10),
                ])
              : x,
      ];
      final g = ghostFor(
        gymId: 'condo',
        exerciseId: 'db-press',
        beforeMs: 5000,
        workouts: edited,
      )!;
      expect(g.byOrdinal(1)!.loadG, 25000);
      expect(g.byOrdinal(2), isNull);
    });
  });

  group('compareSet', () {
    final g = ghostFor(
      gymId: 'condo',
      exerciseId: 'db-press',
      beforeMs: 5000,
      workouts: history,
    )!;

    test('more load, same reps: ahead, with deltas and pace', () {
      final l = compareSet(
        ghost: g,
        setOrdinal: 1,
        loadG: 25000,
        reps: 10,
        offsetMs: 65000,
      );
      expect(l.verdict, GhostVerdict.ahead);
      expect(l.ghostLoadG, 22500);
      expect(l.ghostReps, 10);
      expect(l.loadDeltaG, 2500);
      expect(l.repsDelta, 0);
      expect(l.paceDeltaMs, -5000);
    });

    test('fewer reps: behind; equal: level', () {
      expect(
        compareSet(ghost: g, setOrdinal: 2, loadG: 22500, reps: 7).verdict,
        GhostVerdict.behind,
      );
      expect(
        compareSet(ghost: g, setOrdinal: 2, loadG: 22500, reps: 8).verdict,
        GhostVerdict.level,
      );
    });

    test('equal volume, heavier load: ahead', () {
      // 22.5 x 8 = 180 kg-reps last time; 30 x 6 = 180.
      expect(
        compareSet(ghost: g, setOrdinal: 2, loadG: 30000, reps: 6).verdict,
        GhostVerdict.ahead,
      );
    });

    test('an extra set beyond last time is new', () {
      final l = compareSet(ghost: g, setOrdinal: 3, loadG: 22500, reps: 8);
      expect(l.verdict, GhostVerdict.newSet);
      expect(l.ghostLoadG, isNull);
    });

    test('missing values give null deltas, not a crash', () {
      final l = compareSet(ghost: g, setOrdinal: 1);
      expect(l.loadDeltaG, isNull);
      expect(l.repsDelta, isNull);
      expect(l.paceDeltaMs, isNull);
      expect(l.verdict, GhostVerdict.behind);
    });
  });

  group('sessionTotal (N3)', () {
    final press = ghostFor(
      gymId: 'condo',
      exerciseId: 'db-press',
      beforeMs: 5000,
      workouts: history,
    );
    final lat = ghostFor(
      gymId: 'condo',
      exerciseId: 'lat-pulldown',
      beforeMs: 5000,
      workouts: history,
    );

    test('matched through the same ordinals; new exercises left out', () {
      final t = sessionTotal(
        ghosts: {'db-press': press, 'lat-pulldown': lat, 'curl': null},
        done: [
          (exerciseId: 'db-press', setOrdinal: 1, volumeGReps: 250000),
          (exerciseId: 'curl', setOrdinal: 1, volumeGReps: 99999),
        ],
      )!;
      expect(t.volumeGReps, 250000);
      expect(t.ghostSoFarGReps, 225000); // press set 1 only; lat not started
      expect(t.ghostFullGReps, 22500 * 18 + 50000 * 12);
      expect(t.exercisesCompared, 2);
      expect(t.deltaGReps, 25000);
      expect(t.deltaPct, closeTo(11.11, 0.01));
    });

    test('hidden when nothing has a ghost', () {
      expect(
        sessionTotal(
          ghosts: {'curl': null},
          done: [(exerciseId: 'curl', setOrdinal: 1, volumeGReps: 5)],
        ),
        isNull,
      );
      expect(sessionTotal(ghosts: const {}, done: const []), isNull);
    });

    test('nothing done yet: zero against zero, pct null', () {
      final t = sessionTotal(ghosts: {'db-press': press}, done: const [])!;
      expect(t.volumeGReps, 0);
      expect(t.ghostSoFarGReps, 0);
      expect(t.deltaPct, isNull);
    });
  });
}
