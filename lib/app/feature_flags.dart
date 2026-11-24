/// Cut-2 features ship dark in APK 0.1 (t3x, 23-Nov): timers, ghost session,
/// rotation, plate math. Turn them on per build with
/// `--dart-define=GS_FEATURES=timers,ghost,rotation,plates` (or `all`).
/// The lane building them (gym2-features) adds code behind these checks;
/// lane A owns this file and decides what each APK enables.
const String _features = String.fromEnvironment('GS_FEATURES');

bool _on(String name) =>
    _features == 'all' ||
    _features.split(',').map((s) => s.trim()).contains(name);

abstract final class Features {
  static bool get timers => _on('timers');
  static bool get ghost => _on('ghost');
  static bool get rotation => _on('rotation');
  static bool get plateMath => _on('plates');

  /// 0.3 native cuts. Kotlin reads the same GS_FEATURES (from Gradle's
  /// dart-defines, `android/app/build.gradle.kts`) into `BuildConfig`; these
  /// Dart getters exist so both sides log and test the same names.
  static bool get lockDone => _on('lockdone');
  static bool get health => _on('health');
}

/// One startup log line (`GymSupreme/features ghost=1 ...`); the CI emulator
/// smoke checks it against the GS_FEATURES the build was given.
String featuresLogLine() =>
    'GymSupreme/features timers=${Features.timers ? 1 : 0} '
    'ghost=${Features.ghost ? 1 : 0} rotation=${Features.rotation ? 1 : 0} '
    'plates=${Features.plateMath ? 1 : 0} '
    'lockdone=${Features.lockDone ? 1 : 0} health=${Features.health ? 1 : 0}';
