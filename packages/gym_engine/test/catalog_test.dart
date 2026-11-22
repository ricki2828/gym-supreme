import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

/// Reads the built assets (python3 tools/build_exercises.py writes them).
Catalog loadCatalog() => Catalog.fromJson(
  File('../../assets/exercises_taxonomy.json').readAsStringSync(),
  File('../../assets/exercises.json').readAsStringSync(),
);

void main() {
  late Catalog catalog;
  setUpAll(() => catalog = loadCatalog());

  test('16 muscles, valid ids, unique exercise ids', () {
    expect(catalog.muscles, hasLength(16));
    expect(catalog.validate(), isEmpty);
    expect(catalog.exercises, isNotEmpty);
  });

  test('condo preset covers every muscle or lists it as uncovered', () {
    final r = coverageFor(catalog, catalog.preset('condo').equipment);
    expect(r.byMuscle.keys, catalog.muscles.map((m) => m.id));
    expect(r.covered.length + r.uncovered.length, 16);
    // Today the condo kit covers all 16. If this changes it must be a decision.
    expect(r.uncovered, isEmpty, reason: 'uncovered: ${r.uncovered}');
  });

  test('kit filter: barbell lifts are not offered at the condo', () {
    final kit = catalog.preset('condo').equipment;
    final bench = catalog.exercises.firstWhere(
      (e) => e.id == 'barbell-bench-press-medium-grip',
    );
    expect(bench.availableWith(kit), isFalse);
    expect(
      bench.availableWith({...kit, 'barbell', 'squat-rack', 'flat-bench'}),
      isTrue,
    );
  });

  test('an empty kit still offers bodyweight work only', () {
    final r = coverageFor(catalog, <String>{});
    final ids = {for (final l in r.byMuscle.values) ...l.map((e) => e.id)};
    expect(ids, contains('pushups'));
    expect(ids, isNot(contains('dumbbell-bench-press')));
  });

  test('every offered exercise at the condo has a cue', () {
    final kit = catalog.preset('condo').equipment;
    for (final e in catalog.exercises.where((e) => e.availableWith(kit))) {
      expect(e.cue.trim(), isNotEmpty, reason: e.id);
    }
  });

  test('unknown ids are rejected', () {
    final tax = File('../../assets/exercises_taxonomy.json').readAsStringSync();
    const bad =
        '{"exercises":[{"id":"x","name":"X","primary":["wings"],'
        '"secondary":[],"equipment_sets":[["bodyweight"]],"load":"bodyweight",'
        '"unilateral":false,"cue":"c"}]}';
    expect(() => Catalog.fromJson(tax, bad), throwsFormatException);
  });
}
