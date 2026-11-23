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
}
