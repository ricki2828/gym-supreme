/// Pure Dart engine for Gym Supreme (no Flutter): exercise catalog, gyms and
/// kit, days-since, suggestions, the cut-1 session transitions, the session
/// snapshot codec, history stats and export. API v0: `lib/src/api.dart`.
library;

export 'src/api.dart';
export 'src/catalog.dart';
export 'src/coverage.dart';
export 'src/engine.dart';
export 'src/import.dart'
    show
        ImportCounts,
        ImportRefused,
        importMaxExportFormat,
        importMaxSchemaVersion;
export 'src/model.dart';
export 'src/session.dart';
export 'src/snapshot.dart';
export 'src/store.dart';

/// Bumped when the Kotlin/Dart journal contract changes.
const int contractFixtureVersion = 1;
