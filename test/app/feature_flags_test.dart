import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/feature_flags.dart';

void main() {
  test('cut-2 features are off unless GS_FEATURES enables them', () {
    expect(Features.timers, isFalse);
    expect(Features.ghost, isFalse);
    expect(Features.rotation, isFalse);
    expect(Features.plateMath, isFalse);
  });
}
