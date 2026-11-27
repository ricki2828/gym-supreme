import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/self_checks.dart';

/// Builds counters the way android SelfCheckLog writes them.
Map<String, int> cues(
  List<({int late, int flags, int blk})> list, {
  int start = 1,
}) {
  final m = <String, int>{};
  for (var i = 0; i < list.length; i++) {
    final seq = start + i;
    final slot = 'sc_cue_${(seq % 60).toString().padLeft(2, '0')}';
    m['${slot}_seq'] = seq;
    m['${slot}_wall'] = 1000 * seq;
    m['${slot}_late'] = list[i].late;
    m['${slot}_flags'] = list[i].flags;
    m['${slot}_blk'] = list[i].blk;
  }
  return m;
}

Map<String, int> locks(List<({int act, int out, int set, int wall})> list) {
  final m = <String, int>{};
  for (var i = 0; i < list.length; i++) {
    final slot = 'sc_lock_${((i + 1) % 20).toString().padLeft(2, '0')}';
    m['${slot}_seq'] = i + 1;
    m['${slot}_wall'] = list[i].wall;
    m['${slot}_act'] = list[i].act;
    m['${slot}_out'] = list[i].out;
    m['${slot}_set'] = list[i].set;
  }
  return m;
}

Map<String, int> health(List<({int op, int out, int n})> list) {
  final m = <String, int>{};
  for (var i = 0; i < list.length; i++) {
    final slot = 'sc_health_${((i + 1) % 10).toString().padLeft(2, '0')}';
    m['${slot}_seq'] = i + 1;
    m['${slot}_wall'] = 1700000000000 + i * 60000;
    m['${slot}_op'] = list[i].op;
    m['${slot}_out'] = list[i].out;
    m['${slot}_n'] = list[i].n;
  }
  return m;
}

void main() {
  group('timer cues and rest alerts', () {
    test('no evidence: no verdict', () {
      expect(cueVerdict(cueEvidence({})), isNull);
    });

    test('all within 1 s is good, with the worst lateness', () {
      final v = cueVerdict(
        cueEvidence(
          cues([
            for (var i = 0; i < 20; i++)
              (late: i == 7 ? 1000 : 40, flags: 0, blk: 7),
          ]),
        ),
      )!;
      expect(v.state, CheckState.good);
      expect(v.text, startsWith('All good: 20 of 20 on time'));
      expect(v.text, contains('worst 1.0 s'));
    });

    test('1001 ms is late', () {
      final v = cueVerdict(
        cueEvidence(
          cues([(late: 1001, flags: 0, blk: 1), (late: 5, flags: 0, blk: 1)]),
        ),
      )!;
      expect(v.state, CheckState.off);
      expect(v.text, contains('1 late (worst 1.0 s), 1 of 2 on time'));
    });

    test('missed and tone failures are reported', () {
      final v = cueVerdict(
        cueEvidence(
          cues([
            (late: 0, flags: 1, blk: 1),
            (late: 0, flags: 16, blk: 1),
            (late: 30, flags: 0, blk: 1),
          ]),
        ),
      )!;
      expect(v.state, CheckState.off);
      expect(v.text, contains('1 missed'));
      expect(v.text, contains('tone failed on 1'));
      expect(v.text, contains('1 of 3 on time'));
    });

    test('late cues name the device state they ran in', () {
      final v = cueVerdict(
        cueEvidence(
          cues([
            (late: 2400, flags: 2 | 4, blk: 1),
            (late: 1500, flags: 2 | 4 | 8, blk: 1),
            (late: 10, flags: 0, blk: 1),
          ]),
        ),
      )!;
      expect(v.text, contains('2 late (worst 2.4 s)'));
      expect(v.text, contains('battery saver on for 2'));
      expect(v.text, contains('Doze for 1'));
      expect(v.text, contains('screen off for 2'));
    });

    test('only the last five timed blocks count; rest alerts join', () {
      // Block 1 is bad but is six blocks back; blocks 2-6 are clean.
      final v = cueVerdict(
        cueEvidence(
          cues([
            (late: 9000, flags: 0, blk: 1),
            for (var b = 2; b <= 6; b++) (late: 10, flags: 0, blk: b),
            (late: 20, flags: 32, blk: 0),
          ]),
        ),
      )!;
      expect(v.state, CheckState.good);
      expect(v.text, contains('6 of 6 on time'));
      expect(v.text, contains('5 timed sessions, 1 rest alert'));
    });

    test('a late rest alert under battery saver is reported', () {
      final v = cueVerdict(
        cueEvidence(cues([(late: 3000, flags: 32 | 4, blk: 0)])),
      )!;
      expect(v.state, CheckState.off);
      expect(v.text, contains('battery saver on for 1'));
    });

    test('ring order is by seq, not slot, after wrap-around', () {
      final m = cues([
        for (var i = 0; i < 70; i++) (late: i, flags: 0, blk: 1),
      ]);
      final e = cueEvidence(m);
      expect(e.length, 60);
      expect(e.first.lateMs, 10);
      expect(e.last.lateMs, 69);
    });
  });

  group('lock-screen Done', () {
    test('five taps on five sets is good', () {
      final v = lockVerdict(
        lockEvidence(
          locks([
            for (var i = 0; i < 5; i++)
              (act: 1, out: 0, set: 100 + i, wall: 10000 * i),
          ]),
        ),
      )!;
      expect(v.state, CheckState.good);
      expect(
        v.text,
        startsWith('All good: 5 Done taps recorded, none doubled'),
      );
    });

    test('same set recorded twice inside the window is a double', () {
      final v = lockVerdict(
        lockEvidence(
          locks([
            (act: 1, out: 0, set: 5, wall: 10000),
            (act: 1, out: 0, set: 5, wall: 12000),
          ]),
        ),
      )!;
      expect(v.state, CheckState.off);
      expect(v.text, contains('1 set recorded twice within 5 s'));
    });

    test('the same set far apart is not flagged', () {
      final v = lockVerdict(
        lockEvidence(
          locks([
            (act: 1, out: 0, set: 5, wall: 10000),
            (act: 1, out: 0, set: 5, wall: 10000 + doubleRecordWindowMs + 1),
          ]),
        ),
      )!;
      expect(v.state, CheckState.good);
    });

    test('a held-back double tap is the design working', () {
      final v = lockVerdict(
        lockEvidence(
          locks([
            (act: 1, out: 0, set: 5, wall: 10000),
            (act: 1, out: 1, set: 5, wall: 10200),
          ]),
        ),
      )!;
      expect(v.state, CheckState.good);
      expect(v.text, contains('1 double-tap held back'));
    });

    test('stale and failed taps are off; other actions are ignored', () {
      final v = lockVerdict(
        lockEvidence(
          locks([
            (act: 1, out: 2, set: 1, wall: 1000),
            (act: 1, out: 4, set: 2, wall: 2000),
            (act: 2, out: 0, set: 3, wall: 3000),
          ]),
        ),
      )!;
      expect(v.state, CheckState.off);
      expect(v.text, contains('1 tap failed'));
      expect(v.text, contains('1 tap not recorded (old notification)'));
      expect(v.text, contains('0 recorded'));
    });

    test('no Done taps: no verdict', () {
      expect(
        lockVerdict(lockEvidence(locks([(act: 3, out: 0, set: 1, wall: 1)]))),
        isNull,
      );
    });
  });

  group('Health Connect', () {
    test('last write ok is good', () {
      final v = healthVerdict(
        healthEvidence(health([(op: 0, out: 1, n: 1), (op: 0, out: 0, n: 2)])),
      )!;
      expect(v.state, CheckState.good);
      expect(v.text, startsWith('All good: last write ok (2,'));
    });

    test('last write failed is off even after an earlier ok', () {
      final v = healthVerdict(
        healthEvidence(health([(op: 0, out: 0, n: 1), (op: 0, out: 1, n: 0)])),
      )!;
      expect(v.state, CheckState.off);
      expect(v.text, contains('last write failed'));
    });

    test('a failed delete is off', () {
      final v = healthVerdict(
        healthEvidence(health([(op: 0, out: 0, n: 1), (op: 1, out: 2, n: 0)])),
      )!;
      expect(v.state, CheckState.off);
      expect(v.text, contains('last delete permission denied'));
    });

    test('switch off is quiet, not a failure', () {
      final v = healthVerdict(healthEvidence(health([(op: 0, out: 4, n: 0)])))!;
      expect(v.state, CheckState.quiet);
      expect(v.text, startsWith('Not recorded to Health Connect'));
    });
  });

  group('evaluateSelfChecks', () {
    test('nothing and no flags: no section', () {
      expect(evaluateSelfChecks({}), isEmpty);
    });

    test('flag on without evidence waits', () {
      final v = evaluateSelfChecks({}, timers: true, health: true);
      expect(v.map((e) => e.id), ['cues', 'health']);
      expect(v.every((e) => e.state == CheckState.quiet), isTrue);
    });

    test('evidence shows even with the flag off; keys are recognised', () {
      final v = evaluateSelfChecks(health([(op: 0, out: 0, n: 1)]));
      expect(v.single.id, 'health');
      expect(isSelfCheckKey('sc_cue_01_late'), isTrue);
      expect(isSelfCheckKey('rest_alerts_fired'), isFalse);
    });
  });
}
