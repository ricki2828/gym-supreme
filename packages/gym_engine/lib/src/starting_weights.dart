/// Starting weights (0.3 S1): a working weight he types once per lift, so
/// the first suggestion and ghost are not blank when there is no history to
/// read (Whoop has no sets or weights to import).
///
/// Not history: no workout row, no set, so no PB, streak, counter or volume
/// reads it. Stored as the raw setting key [startingWeightsSettingKey] =
/// `{"<exercise id>": <grams>}` (same per-hand convention as a set's
/// `load_g`: dumbbells are per hand). A plain setting row, so no schema
/// change; the backup snapshot copies the whole database and carries it.
///
/// Used only while the lift has no logged history (a done, non-skipped,
/// non-timed set in any workout that is not deleted, at any gym): the first
/// real set supersedes it, and deleting or editing that history away falls
/// back to it again (it is never cleared by logging).
library;

import 'dart:convert';

import 'api.dart' show LoadUnit;
import 'model.dart';
import 'store.dart';

const String startingWeightsSettingKey = 'starting_weights';

/// Heaviest starting weight accepted (a typo guard, not a ceiling on him).
const int startingWeightMaxG = 500000;

/// The stored starting weights by exercise id. An unreadable value reads as
/// none rather than failing the screens that ask.
Map<String, int> loadStartingWeights(HistoryStore store) {
  final raw = store.setting(startingWeightsSettingKey);
  if (raw == null) return const {};
  final Object? j;
  try {
    j = jsonDecode(raw);
  } on FormatException {
    return const {};
  }
  if (j is! Map) return const {};
  return {
    for (final e in j.entries)
      if (e.key is String &&
          e.value is int &&
          validStartingWeight(e.value as int))
        e.key as String: e.value as int,
  };
}

void saveStartingWeights(HistoryStore store, Map<String, int> weights) {
  final ids = weights.keys.toList()..sort();
  store.saveSetting(
    startingWeightsSettingKey,
    jsonEncode({for (final id in ids) id: weights[id]}),
  );
}

bool validStartingWeight(int loadG) => loadG > 0 && loadG <= startingWeightMaxG;

/// True when [exerciseId] has a done, non-skipped, non-timed set in any of
/// [workouts]: then history drives its suggestion and ghost, not the
/// starting weight.
bool hasLoggedHistory(String exerciseId, Iterable<WorkoutRecord> workouts) {
  for (final w in workouts) {
    for (final s in w.sets) {
      if (s.exerciseId == exerciseId && !s.skipped && s.kind != SetKind.timed) {
        return true;
      }
    }
  }
  return false;
}

/// One row of the starting-weights screen.
class StartingWeightLift {
  const StartingWeightLift({
    required this.exerciseId,
    required this.name,
    required this.unit,
    required this.typeId,
    required this.loadG,
    required this.hasHistory,
  });

  final String exerciseId;
  final String name;

  /// kg (total) or ea (per hand). Bodyweight and timed lifts are not listed.
  final LoadUnit unit;

  /// The workout type his next session of it plans this lift for (push,
  /// pull, legs, core); null for every other lift listed.
  final String? typeId;

  /// The stored starting weight, or null when none is set.
  final int? loadG;

  /// History exists: the starting weight is kept but not used.
  final bool hasHistory;
}
