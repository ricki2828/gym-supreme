import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/widgets/body_map.dart';

import 'fixtures.dart';

void main() {
  test('the map draws all 16 taxonomy muscles', () {
    expect(BodyGeometry.muscleIds, allMuscles.toSet());
  });

  test('picker groups cover each muscle exactly once', () {
    final ids = [for (final g in MuscleGroup.picker) ...g.muscleIds];
    expect(ids.toSet(), allMuscles.toSet());
    expect(ids.length, 16);
  });

  test('hit testing finds front and back muscles', () {
    expect(BodyGeometry.hit(const Offset(49, 69)), 'chest');
    expect(BodyGeometry.hit(const Offset(60, 110)), 'abs');
    expect(BodyGeometry.hit(const Offset(48, 190)), 'quads');
    expect(BodyGeometry.hit(const Offset(190, 60)), 'traps');
    expect(BodyGeometry.hit(const Offset(178, 200)), 'hamstrings');
    expect(BodyGeometry.hit(const Offset(60, 24)), isNull, reason: 'head');
  });

  test('formatting', () {
    expect(kg(22000), '22');
    expect(thousands(7220), '7,220');
    expect(thousands(999), '999');
    expect(thousands(1234567), '1,234,567');
    expect(kg(22500), '22.5');
    expect(kg(1250), '1.25');
    expect(daysLabel(null), 'new');
    expect(daysLabel(1), '1 day');
    expect(clock(90), '1:30');
    expect(prescription(pushPlan.items.first), '3 × 10 · 22 kg ea');
    expect(prescription(corePlan.items.last), '3 × 0:45');
  });
}
