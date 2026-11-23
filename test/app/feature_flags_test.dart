import 'package:flutter_test/flutter_test.dart';
import 'package:gym_supreme/app/feature_flags.dart';

/// The flags follow GS_FEATURES exactly: all off without it (APK 0.1.x), on
/// for the names it lists (CI also runs the suite with GS_FEATURES=all).
const String _features = String.fromEnvironment('GS_FEATURES');

bool _want(String name) =>
    _features == 'all' ||
    _features.split(',').map((s) => s.trim()).contains(name);

void main() {
  test('cut-2 flags follow GS_FEATURES (default: all off)', () {
    expect(Features.timers, _want('timers'));
    expect(Features.ghost, _want('ghost'));
    expect(Features.rotation, _want('rotation'));
    expect(Features.plateMath, _want('plates'));
    if (_features.isEmpty) {
      expect([
        Features.timers,
        Features.ghost,
        Features.rotation,
        Features.plateMath,
      ], everyElement(isFalse));
    }
  });
}
