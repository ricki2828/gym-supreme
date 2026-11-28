import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

const day = 86400000;
const bench = 'barbell-bench-press-medium-grip';

WorkoutRecord w(String id, int startMs, int kg, String setId) => WorkoutRecord(
  uuid: id,
  gymId: 'g1',
  startedAtMs: startMs,
  tzOffsetMin: 0,
  endedAtMs: startMs + 3600000,
  sets: [
    SetRecord(
      setId: setId,
      exerciseId: bench,
      exerciseName: bench,
      exercisePosition: 0,
      setOrdinal: 1,
      loadG: kg * 1000,
      reps: 5,
      completion: Completion.adjusted,
    ),
  ],
);

void main() {
  test('a parked set says which way it was parked', () {
    final catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
    final t0 = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;
    for (final (kg, low) in [(10, true), (200, false)]) {
      final a = StrengthAnalysis(
        workouts: [w('a', t0, 100, 'a1'), w('b', t0 + 10 * day, kg, 'b1')],
        catalog: catalog,
        nowMs: t0 + 12 * day,
      );
      final v = a.verdicts.firstWhere((v) => v.set.setId == 'b1');
      expect(v.reason, RejectReason.typoUnconfirmed);
      expect(v.parkedLow, low, reason: '$kg kg');
      expect(
        a.verdicts.firstWhere((v) => v.set.setId == 'a1').parkedLow,
        isFalse,
      );
    }
  });
}
