import 'package:gym_engine/src/cut2/display.dart';
import 'package:gym_engine/src/cut2/ghost.dart';
import 'package:gym_engine/src/cut2/plates.dart';
import 'package:gym_engine/src/cut2/rotation.dart';
import 'package:gym_engine/src/cut2/timers.dart';
import 'package:test/test.dart';

void main() {
  group('loadReps', () {
    test('forms', () {
      expect(loadReps(22500, 10), '22.5 × 10');
      expect(loadReps(22500, 10, perHand: true), '22.5 ea × 10');
      expect(loadReps(null, 8), '× 8');
      expect(loadReps(0, 8), '× 8');
      expect(loadReps(40000, null), '40 kg');
      expect(loadReps(22500, null, perHand: true), '22.5 kg ea');
      expect(loadReps(null, null), '');
    });
  });

  group('ghostSetText', () {
    test('ahead with both deltas', () {
      const l = SetGhostLine(
        verdict: GhostVerdict.ahead,
        ghostLoadG: 22500,
        ghostReps: 10,
        loadDeltaG: 2500,
        repsDelta: -1,
      );
      expect(ghostSetText(l), 'Last time 22.5 × 10 · +2.5 kg, −1 rep');
      expect(ghostSetSemantics(l), contains('Ahead of last time'));
    });

    test('pending shows last time only', () {
      const l = SetGhostLine(
        verdict: GhostVerdict.pending,
        ghostLoadG: 20000,
        ghostReps: 8,
      );
      expect(ghostSetText(l, perHand: true), 'Last time 20 ea × 8');
      expect(ghostSetSemantics(l), 'Last time 20 kilos for 8 reps');
    });

    test('level and new set', () {
      const level = SetGhostLine(
        verdict: GhostVerdict.level,
        ghostLoadG: 20000,
        ghostReps: 8,
        loadDeltaG: 0,
        repsDelta: 0,
      );
      expect(ghostSetText(level), 'Last time 20 × 8 · level');
      expect(
        ghostSetText(const SetGhostLine(verdict: GhostVerdict.newSet)),
        'New set — none last time',
      );
    });

    test('bodyweight reps delta', () {
      const l = SetGhostLine(
        verdict: GhostVerdict.ahead,
        ghostReps: 8,
        repsDelta: 3,
      );
      expect(ghostSetText(l), 'Last time × 8 · +3 reps');
      expect(ghostSetSemantics(l), 'Ahead of last time, 8 reps');
    });

    test('nothing known: null', () {
      expect(
        ghostSetText(const SetGhostLine(verdict: GhostVerdict.pending)),
        isNull,
      );
      expect(
        ghostSetSemantics(const SetGhostLine(verdict: GhostVerdict.pending)),
        'No values from last time',
      );
    });
  });

  group('sessionTotalText', () {
    SessionGhostTotal t(int v, int so, {int n = 2}) => SessionGhostTotal(
      volumeGReps: v,
      ghostSoFarGReps: so,
      ghostFullGReps: so * 2,
      exercisesCompared: n,
    );

    test('percent up, down, level', () {
      expect(
        sessionTotalText(t(250000, 225000)),
        '+11% on last time · 2 lifts compared',
      );
      expect(
        sessionTotalText(t(200000, 225000, n: 1)),
        '−11% on last time · 1 lift compared',
      );
      expect(
        sessionTotalText(t(225000, 225000)),
        'Level with last time · 2 lifts compared',
      );
    });

    test('under half a percent reads as level', () {
      expect(sessionTotalText(t(225900, 225000)), startsWith('Level'));
      expect(sessionTotalText(t(223875, 225000)), startsWith('−1%'));
    });

    test('hidden before anything compared is done; null total hidden', () {
      expect(sessionTotalText(t(0, 0)), isNull);
      expect(sessionTotalText(null), isNull);
    });

    test('ghost had no volume (bodyweight): volume only', () {
      expect(
        sessionTotalText(t(1234500, 0)),
        'Volume 1,235 kg · 2 lifts compared',
      );
    });
  });

  test('rotationChipText', () {
    const names = {'push': 'Push', 'pull': 'Pull', 'legs': 'Legs'};
    expect(
      rotationChipText(Rotation.defaults().skip(), names),
      'Next: Pull · then Legs, Push',
    );
    expect(rotationChipText(Rotation(['core']), names), 'Next: core');
    expect(rotationChipText(Rotation(const []), names), isNull);
  });

  group('timer text', () {
    test('EMOM running and lead-in', () {
      final b = TimerBlock.emom(rounds: 20, leadInMs: 10000);
      final lead = b.stateAt(3000);
      expect(timerPhaseText(b, lead), 'GET READY');
      expect(timerRoundText(b, lead), 'EMOM 20 × 1:00 · starts in 0:07');
      final s = b.stateAt(10000 + 2 * 60000 + 5000);
      expect(timerPhaseText(b, s), 'EMOM');
      expect(timerRoundText(b, s), 'Round 3 of 20 · 17:55 left');
    });

    test('interval rest, AMRAP, done', () {
      final i = TimerBlock.interval(workMs: 20000, restMs: 10000, rounds: 8);
      expect(timerPhaseText(i, i.stateAt(25000)), 'REST');
      expect(timerPhaseText(i, i.stateAt(5000)), 'WORK');
      final a = TimerBlock.amrap(capMs: 720000);
      expect(timerPhaseText(a, a.stateAt(1000)), 'AMRAP');
      expect(timerRoundText(a, a.stateAt(60000)), '11:00 left');
      expect(timerPhaseText(a, a.stateAt(720000)), 'DONE');
      expect(timerRoundText(a, a.stateAt(720000)), 'AMRAP 12:00');
    });
  });

  test('plateText', () {
    expect(plateText(loadBar(62500)), 'Per side 20 + 1.25');
    expect(
      plateText(loadBar(61000)),
      'Can’t make it exactly. Nearest: 60 (20) or 62.5 (20 + 1.25)',
    );
    expect(
      plateText(loadBar(15000)),
      'Can’t make it exactly. Nearest: 20 (bar only)',
    );
  });
}
