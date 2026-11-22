/// Pure Dart engine (no Flutter). Lane C builds the exercise data and the
/// coverage check here; lane B's journal codec gets its Dart twin here.
library;

export 'src/catalog.dart';
export 'src/coverage.dart';

/// Bumped when the Kotlin/Dart journal contract changes.
const int contractFixtureVersion = 0;
