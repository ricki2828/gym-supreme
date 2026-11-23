import 'package:gym_engine/gym_engine.dart';
import 'package:test/test.dart';

/// Review P1-3: the picker's rows are muscle groups, so natural picks carry
/// muscles outside the type's default list. Rows: Chest; Shoulders = front,
/// side, rear delts; Triceps; Back = lats, traps, lower back; Biceps,
/// forearms; Core = abs, obliques; Quads, calves; Glutes, hams.
void main() {
  const chest = ['chest'];
  const shoulders = ['front-delts', 'side-delts', 'rear-delts'];
  const triceps = ['triceps'];
  const back = ['lats', 'traps', 'lower-back'];
  const arms = ['biceps', 'forearms'];
  const core = ['abs', 'obliques'];
  const quadsCalves = ['quads', 'calves'];
  const glutesHams = ['glutes', 'hamstrings'];

  test('Chest + Shoulders + Triceps is Push', () {
    expect(typeForGroups([chest, shoulders, triceps]), 'push');
  });
  test('Back + Biceps/forearms is Pull', () {
    expect(typeForGroups([back, arms]), 'pull');
  });
  test('both leg rows are Legs; Core is Core', () {
    expect(typeForGroups([quadsCalves, glutesHams]), 'legs');
    expect(typeForGroups([core]), 'core');
  });
  test('single rows keep their type', () {
    expect(typeForGroups([chest]), 'push');
    expect(typeForGroups([shoulders]), 'push');
    expect(typeForGroups([back]), 'pull');
  });
  test('a real mix is untyped', () {
    expect(typeForGroups([chest, back]), isNull);
    expect(typeForGroups([chest, quadsCalves]), isNull);
    expect(typeForGroups(const []), isNull);
  });
  test('a part-picked row still votes; majority of rows decides', () {
    // He un-ticks rear delts inside Shoulders: still Push.
    expect(
      typeForGroups([
        chest,
        ['front-delts', 'side-delts'],
        triceps,
      ]),
      'push',
    );
    // Chest + Triceps + Back: 2 of 3 rows are Push.
    expect(typeForGroups([chest, triceps, back]), 'push');
  });
  test('a full upper-body day is mixed, not Push (3 of 5 rows)', () {
    expect(typeForGroups([chest, shoulders, triceps, back, arms]), isNull);
    expect(typeForGroups([chest, shoulders, triceps, back]), 'push'); // 3 of 4
  });
  test('a lone rear-delts pick is Pull', () {
    expect(
      typeForGroups([
        ['rear-delts'],
      ]),
      'pull',
    );
  });
}
