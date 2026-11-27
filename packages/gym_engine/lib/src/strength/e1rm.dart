/// Estimated one-rep max (B1 strength design, section 3). Pure functions.
library;

/// Highest rep count whose e1RM is used at all.
const int e1rmMaxReps = 12;

/// Highest rep count that is not tagged rough.
const int e1rmSolidMaxReps = 10;

/// An estimated one-rep max in grams.
class E1rm {
  const E1rm(this.grams, {required this.rough});

  final double grams;

  /// True for 11-12 reps: computed, but kept out of PBs, bands and Health Age.
  final bool rough;

  double get kg => grams / 1000;

  @override
  bool operator ==(Object other) =>
      other is E1rm && other.grams == grams && other.rough == rough;

  @override
  int get hashCode => Object.hash(grams, rough);

  @override
  String toString() =>
      'E1rm(${kg.toStringAsFixed(1)} kg${rough ? ', rough' : ''})';
}

/// Epley: w x (1 + r/30), with r = 1 meaning the weight itself. Null when
/// the inputs give no estimate (load or reps missing, reps over 12).
E1rm? e1rm(int? loadG, int? reps) {
  if (loadG == null || reps == null || loadG <= 0 || reps < 1) return null;
  if (reps > e1rmMaxReps) return null;
  final g = reps == 1 ? loadG.toDouble() : loadG * (1 + reps / 30);
  return E1rm(g, rough: reps > e1rmSolidMaxReps);
}

/// Brzycki: w x 36 / (37 - r). A cross-check only; null for reps outside
/// 1-12.
double? brzyckiG(int loadG, int reps) {
  if (loadG <= 0 || reps < 1 || reps > e1rmMaxReps) return null;
  return loadG * 36 / (37 - reps);
}
