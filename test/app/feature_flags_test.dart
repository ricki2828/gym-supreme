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
    expect(Features.lockDone, _want('lockdone'));
    expect(Features.health, _want('health'));
    if (_features == 'all') {
      // Direct check, independent of the parser copy above.
      expect([
        Features.timers,
        Features.ghost,
        Features.rotation,
        Features.plateMath,
        Features.lockDone,
        Features.health,
      ], everyElement(isTrue));
    }
    if (_features.isEmpty) {
      expect([
        Features.timers,
        Features.ghost,
        Features.rotation,
        Features.plateMath,
        Features.lockDone,
        Features.health,
      ], everyElement(isFalse));
    }
  });

  test('the startup line names every flag in the order the smoke reads', () {
    // tools/emulator_smoke.sh compares this line with the native one
    // (android/app/.../workout/Features.kt): same names, same order.
    final names = RegExp(r' (\w+)=[01]')
        .allMatches(featuresLogLine())
        .map((m) => m.group(1))
        .toList();
    expect(names, [
      'timers',
      'ghost',
      'rotation',
      'plates',
      'lockdone',
      'health',
    ]);
  });
}
