import 'package:gym_engine/src/api.dart';
import 'package:gym_engine/src/cut2/timer_session.dart';
import 'package:gym_engine/src/cut2/timers.dart';
import 'package:gym_engine/src/model.dart';
import 'package:gym_engine/src/session.dart';
import 'package:gym_engine/src/snapshot.dart';
import 'package:test/test.dart';

const t0 = 1700000000000;

SessionSnapshot start() => Session.start(
  const SessionPlan(
    gymId: 'g',
    muscles: ['quads'],
    estimatedMinutes: 20,
    uncovered: [],
    items: [
      PlannedItem(
        exerciseId: 'goblet-squat',
        name: 'Goblet squat',
        unit: LoadUnit.ea,
        sets: [PlannedSet(loadG: 20000, reps: 10)],
        repLo: 8,
        repHi: 12,
        restS: 60,
        reason: '',
        primary: ['quads'],
      ),
      PlannedItem(
        exerciseId: 'burpee',
        name: 'Burpee',
        unit: LoadUnit.timed,
        sets: [PlannedSet(loadG: null, reps: 0)],
        repLo: 0,
        repHi: 0,
        restS: 0,
        reason: '',
        primary: ['quads'],
      ),
    ],
  ),
  nowMs: t0,
  tzOffsetMin: 0,
  workoutUuid: 'u',
);

const timed = 'u:1';
const reps = 'u:0';

SnapshotSet setOf(SessionSnapshot s, String id) =>
    s.exercises.expand((e) => e.sets).firstWhere((x) => x.setId == id);

/// Journal round trip: what Kotlin stores and returns must decode the same.
SessionSnapshot rt(SessionSnapshot s) => SessionSnapshot.decode(s.encode());

void main() {
  final emom = TimerBlock.emom(rounds: 3, leadInMs: 10000);

  test('the fixture has a timed set', () {
    expect(setOf(start(), timed).kind, SetKind.timed);
  });

  group('attach', () {
    test('puts the definition + all cues, anchor null; rev bumps', () {
      final s0 = start();
      final s = rt(TimerSession.attach(s0, timed, emom));
      expect(s.rev, s0.rev + 1);
      final b = setOf(s, timed).block!;
      expect(b['type'], 'emom');
      expect(b['started_at_wall_ms'], isNull);
      expect((b['cues'] as List).length, 4);
      expect(TimerSession.blockOf(s, timed), emom);
      expect(TimerSession.isRunning(s, timed), isFalse);
      expect(TimerSession.elapsedMs(s, timed, t0 + 99999), 0);
    });

    test('not on a reps set; replaces an unstarted block only', () {
      final s0 = start();
      expect(identical(TimerSession.attach(s0, reps, emom), s0), isTrue);
      final other = TimerBlock.amrap(capMs: 300000);
      var s = TimerSession.attach(s0, timed, emom);
      s = TimerSession.attach(s, timed, other);
      expect(TimerSession.blockOf(s, timed), other);
      s = TimerSession.start(s, timed, nowWallMs: t0);
      final started = s;
      s = TimerSession.attach(s, timed, emom);
      expect(identical(s, started), isTrue);
    });
  });

  group('run', () {
    SessionSnapshot started() => TimerSession.start(
      TimerSession.attach(start(), timed, emom),
      timed,
      nowWallMs: t0 + 1000,
    );

    test('start anchors once; elapsed derives from the anchor', () {
      final s = rt(started());
      final b = setOf(s, timed).block!;
      expect(b['started_at_wall_ms'], t0 + 1000);
      expect(TimerSession.isRunning(s, timed), isTrue);
      expect(TimerSession.elapsedMs(s, timed, t0 + 1000 + 75000), 75000);
      // clamped to the total
      expect(TimerSession.elapsedMs(s, timed, t0 + 99999999), emom.totalMs);
      final again = TimerSession.start(s, timed, nowWallMs: t0 + 5000);
      expect(identical(again, s), isTrue);
    });

    test('pause freezes elapsed and clears cues; resume rebases', () {
      var s = started();
      s = TimerSession.pause(s, nowMs: t0 + 1000 + 75000);
      s = rt(s);
      expect(s.state, SessionState.paused);
      final p = setOf(s, timed).block!;
      expect(p['started_at_wall_ms'], isNull);
      expect(p['elapsed_before_ms'], 75000);
      expect(p['cues'], isEmpty);
      expect(TimerSession.elapsedMs(s, timed, t0 + 9999999), 75000);

      final revBefore = s.rev;
      s = rt(TimerSession.resume(s, nowMs: t0 + 500000));
      expect(s.rev, revBefore + 1);
      expect(s.state, SessionState.active);
      final r = setOf(s, timed).block!;
      expect(r['started_at_wall_ms'], t0 + 500000);
      expect(r['elapsed_before_ms'], 75000);
      // lead-in 10 s: minute 1 at 10 s, minute 2 at 70 s (behind, > 1 s
      // grace: dropped), minute 3 at 130 s → 55 s after resume.
      expect([for (final c in r['cues'] as List) (c as Map)['index']], [2, 3]);
      expect(((r['cues'] as List).first as Map)['at_ms'], 55000);
      expect(TimerSession.elapsedMs(s, timed, t0 + 500000 + 5000), 80000);
    });

    test('pause with no block running is plain Session.pause', () {
      final s0 = start();
      final a = TimerSession.pause(s0, nowMs: t0 + 5);
      final b = Session.pause(s0, nowMs: t0 + 5);
      expect(a.encode(), b.encode());
      expect(
        TimerSession.resume(a, nowMs: t0 + 9).encode(),
        Session.resume(b, nowMs: t0 + 9).encode(),
      );
    });

    test('an attached but unstarted block stays unstarted across pause', () {
      var s = TimerSession.attach(start(), timed, emom);
      s = TimerSession.pause(s, nowMs: t0 + 5);
      s = TimerSession.resume(s, nowMs: t0 + 9);
      expect(setOf(s, timed).block!['started_at_wall_ms'], isNull);
      expect((setOf(s, timed).block!['cues'] as List).length, 4);
    });

    test('marks: block time without lead-in, ascending, kept over pause', () {
      var s = started();
      s = TimerSession.mark(s, timed, nowMs: t0 + 1000 + 5000); // lead-in
      expect(setOf(s, timed).block!['round_marks_ms'], isNull);
      s = TimerSession.mark(s, timed, nowMs: t0 + 1000 + 50000);
      s = TimerSession.pause(s, nowMs: t0 + 1000 + 60000);
      s = TimerSession.mark(s, timed, nowMs: t0 + 1000 + 61000); // paused
      s = TimerSession.resume(s, nowMs: t0 + 200000);
      s = TimerSession.mark(s, timed, nowMs: t0 + 200000 + 50000);
      expect(setOf(rt(s), timed).block!['round_marks_ms'], [40000, 100000]);
    });
  });

  group('finish', () {
    test('at the end: done, no stop, no load/reps, cues empty', () {
      var s = TimerSession.attach(start(), timed, emom);
      s = TimerSession.start(s, timed, nowWallMs: t0);
      final end = t0 + emom.totalMs + 300;
      final before = s.rev;
      s = rt(TimerSession.finish(s, timed, nowMs: end));
      expect(s.rev, before + 1);
      final x = setOf(s, timed);
      expect(x.state, SetState.done);
      expect(x.loadG, isNull);
      expect(x.reps, isNull);
      expect(x.block!['cues'], isEmpty);
      expect(x.block!['started_at_wall_ms'], isNull);
      expect(x.block!['stopped_at_ms'], isNull);
      expect(x.block!['round_marks_ms'], isEmpty);
      expect(x.block!['type'], 'emom'); // definition kept for history
    });

    test('early stop records stopped_at_ms from block start', () {
      var s = TimerSession.attach(start(), timed, emom);
      s = TimerSession.start(s, timed, nowWallMs: t0);
      s = TimerSession.finish(s, timed, nowMs: t0 + 10000 + 42000);
      expect(setOf(rt(s), timed).block!['stopped_at_ms'], 42000);
    });

    test('AMRAP rounds entered at the end; ignored on other types', () {
      final a = TimerBlock.amrap(capMs: 120000);
      var s = TimerSession.attach(start(), timed, a);
      s = TimerSession.start(s, timed, nowWallMs: t0);
      s = TimerSession.finish(
        s,
        timed,
        nowMs: t0 + 120000,
        amrapRounds: 7,
        amrapExtraReps: 3,
      );
      final b = setOf(rt(s), timed).block!;
      expect(b['amrap_rounds'], 7);
      expect(b['amrap_extra_reps'], 3);

      var e = TimerSession.attach(start(), timed, emom);
      e = TimerSession.start(e, timed, nowWallMs: t0);
      e = TimerSession.finish(e, timed, nowMs: t0 + 1, amrapRounds: 7);
      expect(setOf(e, timed).block!['amrap_rounds'], isNull);
    });

    test('bad AMRAP entry throws; no block or not pending is a no-op', () {
      final a = TimerBlock.amrap(capMs: 120000);
      var s = TimerSession.attach(start(), timed, a);
      s = TimerSession.start(s, timed, nowWallMs: t0);
      expect(
        () => TimerSession.finish(s, timed, nowMs: t0 + 1, amrapRounds: -1),
        throwsArgumentError,
      );
      final s0 = start();
      expect(identical(TimerSession.finish(s0, timed, nowMs: t0), s0), isTrue);
      final done = TimerSession.finish(s, timed, nowMs: t0 + 5);
      expect(
        identical(TimerSession.finish(done, timed, nowMs: t0 + 9), done),
        isTrue,
      );
    });
  });

  group('review fixes', () {
    SessionSnapshot started() => TimerSession.start(
      TimerSession.attach(start(), timed, emom),
      timed,
      nowWallMs: t0,
    );

    test('reset re-arms a frozen block', () {
      var s = TimerSession.pause(started(), nowMs: t0 + 30000);
      s = TimerSession.resume(s, nowMs: t0 + 40000);
      s = TimerSession.mark(s, timed, nowMs: t0 + 70000);
      s = TimerSession.pause(s, nowMs: t0 + 75000); // reset refuses running
      s = TimerSession.reset(s, timed);
      final b = setOf(s, timed).block!;
      expect(b['started_at_wall_ms'], isNull);
      expect(b['elapsed_before_ms'], 0);
      expect((b['cues'] as List).length, 4);
      expect(b.containsKey('round_marks_ms'), isFalse);
      s = TimerSession.resume(s, nowMs: t0 + 80000);
      expect(TimerSession.isRunning(s, timed), isFalse); // armed, not resumed
      s = TimerSession.start(s, timed, nowWallMs: t0 + 90000);
      expect(TimerSession.isRunning(s, timed), isTrue);
    });

    test('TimerSession.undo: block re-armed in one rev; no phantom', () {
      var s = TimerSession.finish(started(), timed, nowMs: t0 + 20000);
      final rev = s.rev;
      s = TimerSession.undo(s, timed);
      expect(s.rev, rev + 1);
      final b = setOf(s, timed).block!;
      expect(setOf(s, timed).state, SetState.pending);
      expect(b['started_at_wall_ms'], isNull);
      expect((b['cues'] as List).length, 4);
      expect(b['stopped_at_ms'], isNull);
      // Pause/resume leaves it unstarted (no phantom timer).
      s = TimerSession.pause(s, nowMs: t0 + 30000);
      s = TimerSession.resume(s, nowMs: t0 + 40000);
      expect(TimerSession.isRunning(s, timed), isFalse);
      s = TimerSession.start(s, timed, nowWallMs: t0 + 50000);
      expect(TimerSession.isRunning(s, timed), isTrue);
    });

    test('TimerSession.undo on a reps set is plain Session.undo', () {
      var s = Session.done(started(), reps, nowMs: t0 + 1);
      expect(
        TimerSession.undo(s, reps).encode(),
        Session.undo(s, reps).encode(),
      );
    });

    test('skip while running stops the block in one rev', () {
      final s0 = started();
      final s = TimerSession.skip(s0, timed, nowMs: t0 + 5000);
      expect(s.rev, s0.rev + 1);
      final x = setOf(rt(s), timed);
      expect(x.state, SetState.skipped);
      expect(x.block!['started_at_wall_ms'], isNull);
      expect(x.block!['cues'], isEmpty);
    });

    test('undo after a running skip: armed, not running', () {
      // Plain Session.skip leaves the anchor (the review's failing input).
      var s = Session.skip(started(), timed, nowMs: t0 + 5000);
      s = TimerSession.undo(s, timed);
      final b = setOf(s, timed).block!;
      expect(b['started_at_wall_ms'], isNull);
      expect((b['cues'] as List).length, 4);
      expect(TimerSession.isRunning(s, timed), isFalse);
    });

    test('settle stops a block left running by a direct Done', () {
      final s0 = Session.done(started(), timed, nowMs: t0 + 5000);
      final s = TimerSession.settle(s0);
      expect(s.rev, s0.rev + 1);
      expect(setOf(s, timed).block!['started_at_wall_ms'], isNull);
      expect(setOf(s, timed).block!['cues'], isEmpty);
      expect(identical(TimerSession.settle(s), s), isTrue);
      final live = started();
      expect(identical(TimerSession.settle(live), live), isTrue);
    });

    test('run: kept by start/pause/resume, bumped by every re-arm', () {
      int run(SessionSnapshot s) => setOf(s, timed).block!['run'] as int;
      var s = TimerSession.attach(start(), timed, emom);
      expect(run(s), 0);
      s = TimerSession.start(s, timed, nowWallMs: t0);
      s = TimerSession.pause(s, nowMs: t0 + 20000);
      s = TimerSession.resume(s, nowMs: t0 + 30000);
      expect(run(rt(s)), 0); // same run: already-fired cues stay deduped
      s = TimerSession.pause(s, nowMs: t0 + 40000);
      s = TimerSession.reset(s, timed);
      expect(run(s), 1);
      s = TimerSession.resume(s, nowMs: t0 + 41000);
      s = TimerSession.start(s, timed, nowWallMs: t0 + 42000);
      s = TimerSession.finish(s, timed, nowMs: t0 + 50000);
      s = TimerSession.undo(s, timed);
      expect(run(rt(s)), 2);
      s = TimerSession.attach(s, timed, TimerBlock.amrap(capMs: 120000));
      expect(run(s), 3);
    });

    test('reset refuses while running', () {
      final s = started();
      expect(identical(TimerSession.reset(s, timed), s), isTrue);
    });

    test('finish on a finished session is a no-op (same rev)', () {
      final f = Session.finish(started(), nowMs: t0 + 5);
      expect(
        identical(TimerSession.finish(f, timed, nowMs: t0 + 9), f),
        isTrue,
      );
    });

    test('pause in the same ms as Start still resumes', () {
      var s = TimerSession.pause(started(), nowMs: t0);
      expect(setOf(s, timed).block!['elapsed_before_ms'], 0);
      s = TimerSession.resume(s, nowMs: t0 + 1000);
      expect(TimerSession.isRunning(s, timed), isTrue);
      expect((setOf(s, timed).block!['cues'] as List).length, 4);
    });

    test('only one block can be started at a time', () {
      // Second timed set on the same exercise.
      var s = Session.addSet(started(), 1);
      final second = s.exercises[1].sets[1].setId;
      s = TimerSession.attach(s, second, TimerBlock.amrap(capMs: 120000));
      final before = s;
      s = TimerSession.start(s, second, nowWallMs: t0 + 5);
      expect(identical(s, before), isTrue);
      // Frozen by a pause still counts as started.
      s = TimerSession.pause(s, nowMs: t0 + 10);
      expect(
        identical(TimerSession.start(s, second, nowWallMs: t0 + 20), s),
        isTrue,
      );
    });

    test('clock stepping back never makes stop precede a mark', () {
      var s = TimerSession.mark(started(), timed, nowMs: t0 + 10000 + 50000);
      s = TimerSession.finish(s, timed, nowMs: t0 + 10000 + 40000);
      final b = setOf(s, timed).block!;
      expect(b['round_marks_ms'], [50000]);
      expect(b['stopped_at_ms'], 50000);
    });
  });

  test('a garbled block reads as no block (never crashes the screen)', () {
    final s = Session.replaceSet(
      start(),
      timed,
      (x) => x.copyWith(block: {'type': 'nope'}),
    );
    expect(TimerSession.blockOf(s, timed), isNull);
    expect(TimerSession.elapsedMs(s, timed, t0 + 5), 0);
    expect(identical(TimerSession.start(s, timed, nowWallMs: t0), s), isTrue);
  });
}
