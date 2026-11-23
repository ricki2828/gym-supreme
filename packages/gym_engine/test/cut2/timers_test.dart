import 'dart:convert';

import 'package:gym_engine/src/cut2/timers.dart';
import 'package:test/test.dart';

List<(String, int)> kindsAt(TimerBlock b) => [
  for (final c in b.cues()) (c.kind.wire, c.atMs),
];

void main() {
  group('EMOM', () {
    test('20 minutes: 20 cues on the minute, then block_end at 20:00', () {
      final b = TimerBlock.emom(rounds: 20);
      final cues = b.cues();
      expect(cues, hasLength(21));
      for (var k = 0; k < 20; k++) {
        expect(cues[k].kind, TimerCueKind.emomMinute);
        expect(cues[k].atMs, k * 60000); // anchored, never "previous + period"
        expect(cues[k].label, 'EMOM ${k + 1} of 20');
      }
      expect(cues.last.kind, TimerCueKind.blockEnd);
      expect(cues.last.atMs, 20 * 60000);
      expect(b.totalMs, 20 * 60000);
      expect([for (final c in cues) c.index], List.generate(21, (i) => i));
    });

    test('lead-in shifts every cue', () {
      final b = TimerBlock.emom(rounds: 2, periodMs: 30000, leadInMs: 10000);
      expect(kindsAt(b), [
        ('emom_minute', 10000),
        ('emom_minute', 40000),
        ('block_end', 70000),
      ]);
    });

    test('stateAt walks the periods', () {
      final b = TimerBlock.emom(rounds: 3, leadInMs: 5000);
      expect(b.stateAt(0).phase, TimerPhase.leadIn);
      expect(b.stateAt(0).phaseRemainingMs, 5000);
      expect(b.stateAt(-50).phase, TimerPhase.leadIn);
      final s = b.stateAt(5000 + 61000);
      expect(s.phase, TimerPhase.work);
      expect(s.round, 2);
      expect(s.phaseRemainingMs, 59000);
      expect(s.totalRemainingMs, 3 * 60000 - 61000);
      expect(b.stateAt(5000 + 180000).phase, TimerPhase.done);
      expect(b.stateAt(999999999).totalRemainingMs, 0);
    });
  });

  group('interval', () {
    test('tabata 8 x 20/10: work and rest cues, no rest after the last', () {
      final b = TimerBlock.interval(workMs: 20000, restMs: 10000, rounds: 8);
      final cues = b.cues();
      expect(
        cues.where((c) => c.kind == TimerCueKind.intervalWork),
        hasLength(8),
      );
      expect(
        cues.where((c) => c.kind == TimerCueKind.intervalRest),
        hasLength(7),
      );
      expect(cues.last.kind, TimerCueKind.blockEnd);
      expect(b.blockMs, 8 * 20000 + 7 * 10000);
      expect(cues.last.atMs, b.blockMs);
      expect(kindsAt(b).take(4), [
        ('interval_work', 0),
        ('interval_rest', 20000),
        ('interval_work', 30000),
        ('interval_rest', 50000),
      ]);
      for (var i = 1; i < cues.length; i++) {
        expect(cues[i].atMs, greaterThan(cues[i - 1].atMs));
      }
    });

    test('rest 0 gives work cues only', () {
      final b = TimerBlock.interval(workMs: 30000, restMs: 0, rounds: 3);
      expect(kindsAt(b), [
        ('interval_work', 0),
        ('interval_work', 30000),
        ('interval_work', 60000),
        ('block_end', 90000),
      ]);
    });

    test('stateAt work vs rest', () {
      final b = TimerBlock.interval(workMs: 20000, restMs: 10000, rounds: 2);
      expect(b.stateAt(5000).phase, TimerPhase.work);
      expect(b.stateAt(5000).phaseRemainingMs, 15000);
      expect(b.stateAt(25000).phase, TimerPhase.rest);
      expect(b.stateAt(25000).phaseRemainingMs, 5000);
      expect(b.stateAt(25000).round, 1);
      expect(b.stateAt(30000).phase, TimerPhase.work);
      expect(b.stateAt(30000).round, 2);
      expect(b.stateAt(49999).phaseRemainingMs, 1);
      expect(b.stateAt(50000).phase, TimerPhase.done);
    });
  });

  group('AMRAP', () {
    test('12:00 with lead-in: go, warning, end', () {
      final b = TimerBlock.amrap(capMs: 12 * 60000, leadInMs: 10000);
      expect(kindsAt(b), [
        ('go', 10000),
        ('amrap_warn', 10000 + 11 * 60000),
        ('block_end', 10000 + 12 * 60000),
      ]);
      expect(b.cues()[1].label, '1:00 left');
    });

    test('no lead-in, no warning: end only', () {
      final b = TimerBlock.amrap(capMs: 5 * 60000, warnMs: 0);
      expect(kindsAt(b), [('block_end', 300000)]);
      final s = b.stateAt(60000);
      expect(s.phase, TimerPhase.work);
      expect(s.rounds, 0);
      expect(s.phaseRemainingMs, 240000);
    });
  });

  group('validation', () {
    test('rejects out-of-range blocks', () {
      expect(() => TimerBlock.emom(rounds: 0), throwsArgumentError);
      expect(() => TimerBlock.emom(rounds: 100), throwsArgumentError);
      expect(
        () => TimerBlock.emom(rounds: 5, periodMs: 1000),
        throwsArgumentError,
      );
      expect(
        () => TimerBlock.emom(rounds: 5, leadInMs: -1),
        throwsArgumentError,
      );
      expect(() => TimerBlock.amrap(capMs: 30000), throwsArgumentError);
      expect(
        () => TimerBlock.amrap(capMs: 60000, warnMs: 60000),
        throwsArgumentError,
      );
      expect(
        () => TimerBlock.interval(workMs: 20000, restMs: -1, rounds: 3),
        throwsArgumentError,
      );
      // 99 x 10 min = 16.5 h: past the 2 h wake-lock bound.
      expect(
        () => TimerBlock.emom(rounds: 99, periodMs: 10 * 60000),
        throwsArgumentError,
      );
    });

    test('presets are valid and decode to themselves', () {
      for (final p in timerPresets) {
        final round = TimerBlock.fromJson(
          jsonDecode(jsonEncode(p.block.toJson())) as Map<String, Object?>,
        );
        expect(round, p.block, reason: p.id);
      }
    });

    test('fromJson re-validates and rejects unknown types', () {
      expect(
        () => TimerBlock.fromJson({
          'type': 'emom',
          'work_ms': 60000,
          'rounds': 0,
        }),
        throwsArgumentError,
      );
      expect(
        () => TimerBlock.fromJson({'type': 'tabata'}),
        throwsFormatException,
      );
    });
  });

  group('snapshot block (t5v contract)', () {
    test('fresh: definition + every cue, anchor null until Start', () {
      final b = TimerBlock.emom(rounds: 2, leadInMs: 10000);
      final j = b.toSnapshotBlock();
      expect(j['type'], 'emom');
      expect(j['started_at_wall_ms'], isNull);
      expect(j['elapsed_before_ms'], 0);
      expect(j['cues'], [
        {
          'index': 0,
          'at_ms': 10000,
          'kind': 'emom_minute',
          'label': 'EMOM 1 of 2',
        },
        {
          'index': 1,
          'at_ms': 70000,
          'kind': 'emom_minute',
          'label': 'EMOM 2 of 2',
        },
        {'index': 2, 'at_ms': 130000, 'kind': 'block_end', 'label': 'Done'},
      ]);
      // The block still decodes as a definition (extra keys ignored).
      expect(TimerBlock.fromJson(j), b);
    });

    test('a cue at 0 survives a fresh start', () {
      final j = TimerBlock.emom(rounds: 1).toSnapshotBlock(startedAtWallMs: 5);
      expect((j['cues'] as List).first, containsPair('at_ms', 0));
    });

    test(
      'resume after pause: past cues dropped, rest re-based, index kept',
      () {
        final b = TimerBlock.emom(rounds: 3);
        final j = b.toSnapshotBlock(
          startedAtWallMs: 1700000000000,
          elapsedBeforeMs: 90000,
        );
        expect(j['started_at_wall_ms'], 1700000000000);
        expect(j['cues'], [
          {
            'index': 2,
            'at_ms': 30000,
            'kind': 'emom_minute',
            'label': 'EMOM 3 of 3',
          },
          {'index': 3, 'at_ms': 90000, 'kind': 'block_end', 'label': 'Done'},
        ]);
      },
    );

    test('a cue exactly at the pause point counts as fired', () {
      final j = TimerBlock.emom(rounds: 3)
          .toSnapshotBlock(elapsedBeforeMs: 60000);
      expect([for (final c in j['cues'] as List) (c as Map)['index']], [2, 3]);
    });

    test('elapsedBeforeMs outside the block is rejected', () {
      final b = TimerBlock.emom(rounds: 1);
      expect(() => b.toSnapshotBlock(elapsedBeforeMs: -1), throwsArgumentError);
      expect(
        () => b.toSnapshotBlock(elapsedBeforeMs: 60001),
        throwsArgumentError,
      );
    });

    test('size stays small (t5v: 20-min EMOM ~20, 30-round interval ~60)', () {
      expect(TimerBlock.emom(rounds: 20).cues(), hasLength(21));
      expect(
        TimerBlock.interval(workMs: 30000, restMs: 15000, rounds: 30).cues(),
        hasLength(60),
      );
    });
  });

  group('TimedResult', () {
    final amrap = TimerBlock.amrap(capMs: 600000);
    final emom = TimerBlock.emom(rounds: 5);

    test('round trip', () {
      const r = TimedResult(
        roundMarksMs: [50000, 110000],
        amrapRounds: 7,
        amrapExtraReps: 3,
      );
      expect(
        TimedResult.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
        ),
        r,
      );
      expect(r.problems(amrap), isEmpty);
    });

    test('problems', () {
      expect(
        const TimedResult(roundMarksMs: [5000, 4000]).problems(emom),
        contains('marks not ascending'),
      );
      expect(
        const TimedResult(roundMarksMs: [400000]).problems(emom),
        contains('mark 400000 outside block'),
      );
      expect(
        const TimedResult(amrapRounds: 3).problems(emom),
        contains('AMRAP fields on a emom block'),
      );
      expect(const TimedResult(amrapRounds: -1).problems(amrap), isNotEmpty);
      expect(
        const TimedResult(stoppedAtMs: 700000).problems(amrap),
        isNotEmpty,
      );
      expect(const TimedResult(stoppedAtMs: 30000).problems(amrap), isEmpty);
    });
  });

  test('formatClock rounds up to whole seconds', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(1), '0:01');
    expect(formatClock(59999), '1:00');
    expect(formatClock(60000), '1:00');
    expect(formatClock(61001), '1:02');
    expect(formatClock(3600000), '1:00:00');
    expect(formatClock(-5), '0:00');
  });

  test('titles', () {
    expect(TimerBlock.emom(rounds: 20).title, 'EMOM 20 × 1:00');
    expect(TimerBlock.amrap(capMs: 720000).title, 'AMRAP 12:00');
    expect(
      TimerBlock.interval(workMs: 20000, restMs: 10000, rounds: 8).title,
      'Interval 8 × 0:20 / 0:10',
    );
  });
}
