/// Build flavour from `--dart-define=FLAVOR=...` (CI: dogfood). Debug and
/// local runs default to `debug`. Diagnostics (and the spike checklist) show
/// in every flavour except `play`.
const String kFlavor = String.fromEnvironment('FLAVOR', defaultValue: 'debug');

/// Set by CI with `--dart-define=BUILD_SHA=<sha>`.
const String kBuildSha = String.fromEnvironment(
  'BUILD_SHA',
  defaultValue: 'local',
);

String get buildLabel =>
    kBuildSha.length > 7 ? kBuildSha.substring(0, 7) : kBuildSha;

bool get showDiagnostics => kFlavor != 'play';
