import 'dart:io';
import 'dart:math';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

/// Goldens on Ricki's real condo kit (plan 5): fixed clock, seed and kit.
/// Regenerate after a deliberate rules change:
///   UPDATE_GOLDENS=1 dart test test/suggest_golden_test.dart
/// and review the diff of test/goldens/suggest_condo.txt like code.
void main() {
  test('condo suggestions match the golden', () {
    final catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
    final engine = GymEngine(
      catalog: catalog,
      store: MemoryStore(),
      nowMs: () => DateTime.utc(2026, 11, 23, 1).millisecondsSinceEpoch,
      tzOffsetMin: () => 480,
      random: Random(1),
    );
    final gym = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
      25000,
    ]);
    engine.saveGym(gym);

    final out = StringBuffer();
    for (final t in workoutTypes.where((t) => t.muscles.isNotEmpty)) {
      for (final minutes in [30, 45, 60]) {
        final p = engine.suggest(
          gymId: gym.id,
          muscleIds: t.muscles,
          minutes: minutes,
          typeId: t.id,
        );
        out.writeln(
          '## ${t.id} ${minutes}min est=${p.estimatedMinutes} '
          'uncovered=${p.uncovered}',
        );
        for (final i in p.items) {
          final kit = gym.equipmentIds;
          final e = catalog.exercise(i.exerciseId)!;
          expect(e.availableWith(kit), isTrue);
          out.writeln(
            '${i.exerciseId} ${i.setCount}x${i.sets.first.reps} '
            'rest=${i.restS} ${i.unit.name}',
          );
        }
        expect(p.estimatedMinutes, lessThanOrEqualTo(minutes));
      }
    }
    final golden = File('test/goldens/suggest_condo.txt');
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync(out.toString());
    }
    expect(out.toString(), golden.readAsStringSync());
  });
}
