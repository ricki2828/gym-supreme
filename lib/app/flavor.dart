import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart' show appFlavor;

/// The Android product flavour, set by `flutter build --flavor` (play or
/// dogfood); null in `flutter test` and plain `flutter run`.
String get flavor => appFlavor ?? (kReleaseMode ? 'unknown' : 'debug');

/// Set by CI with `--dart-define=BUILD_SHA=<sha>`.
const String kBuildSha = String.fromEnvironment(
  'BUILD_SHA',
  defaultValue: 'local',
);

String get buildLabel =>
    kBuildSha.length > 7 ? kBuildSha.substring(0, 7) : kBuildSha;

/// Diagnostics (and the spike checklist) show only in dogfood builds and
/// non-release runs. Fails closed: a release build of an unknown flavour hides
/// them.
bool get showDiagnostics =>
    flavor == 'dogfood' || (!kReleaseMode && flavor != 'play');
