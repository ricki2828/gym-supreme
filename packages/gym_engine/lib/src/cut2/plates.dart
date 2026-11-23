/// Plate math (plan 16 Q9: not picked for the first build, phase 2; the condo
/// has no barbell, so this stays behind Features.plateMath). Pure Dart,
/// integer grams throughout.
library;

/// Common plate sizes in grams, heaviest first.
const List<int> standardPlatesG = [
  25000,
  20000,
  15000,
  10000,
  5000,
  2500,
  1250,
];

/// Olympic bar.
const int standardBarG = 20000;

/// A loading for one side of the bar.
class PlateLoad {
  const PlateLoad({required this.barG, required this.perSideG});

  final int barG;

  /// Plates on one side, heaviest first.
  final List<int> perSideG;

  int get totalG => barG + 2 * perSideG.fold(0, (a, b) => a + b);

  /// "20 + 10 + 2.5" per side; "bar only" when empty.
  String get perSideLabel =>
      perSideG.isEmpty ? 'bar only' : perSideG.map(formatKg).join(' + ');

  @override
  bool operator ==(Object other) =>
      other is PlateLoad &&
      other.barG == barG &&
      other.perSideG.length == perSideG.length &&
      [
        for (var i = 0; i < perSideG.length; i++)
          other.perSideG[i] == perSideG[i],
      ].every((x) => x);

  @override
  int get hashCode => Object.hash(barG, Object.hashAll(perSideG));

  @override
  String toString() => 'PlateLoad(${formatKg(totalG)}: $perSideLabel)';
}

/// The answer for a target: [exact] if the plates make it, else the closest
/// loads below and above (either may be null at the ends).
class PlateResult {
  const PlateResult({this.exact, this.below, this.above});
  final PlateLoad? exact;
  final PlateLoad? below;
  final PlateLoad? above;
}

/// Loads a bar to [targetG] with the fewest plates.
///
/// [pairs] maps a plate size to how many *pairs* the gym has (one plate per
/// side each); omit it for unlimited [standardPlatesG]. Exact by dynamic
/// programming over per-side grams, so limited counts are respected (greedy
/// fails e.g. for 15+15 when only one 20 and no 10 exist).
PlateResult loadBar(
  int targetG, {
  int barG = standardBarG,
  Map<int, int>? pairs,
}) {
  if (barG < 0) throw ArgumentError('bar $barG');
  final stock = <int>[];
  if (pairs == null) {
    // Unlimited: enough pairs of each to reach any sane load (300 kg).
    for (final p in standardPlatesG) {
      stock.addAll(List.filled(150000 ~/ p + 1, p));
    }
  } else {
    final sizes = pairs.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final p in sizes) {
      final n = pairs[p]!;
      if (p <= 0 || n < 0) throw ArgumentError('plate $p x $n');
      stock.addAll(List.filled(n, p));
    }
  }
  if (stock.isEmpty || targetG <= barG) {
    final bar = PlateLoad(barG: barG, perSideG: const []);
    if (targetG == barG) return PlateResult(exact: bar);
    if (targetG < barG) return PlateResult(above: bar);
    return PlateResult(below: bar);
  }

  // Per-side sums reachable, in units of the gcd of all plate sizes, each
  // with the fewest plates (0/1 knapsack over the stock list).
  final unit = stock.fold(stock.first, _gcd);
  final maxSide = stock.fold(0, (a, b) => a + b) ~/ unit;
  final targetSide2 = targetG - barG; // two sides
  // best[s]: the plate list (heaviest first) for per-side sum s, fewest
  // plates, ties to the heavier plates (25 + 15 over 20 + 20). Whole lists
  // rather than back-pointers: a 1-D 0/1 knapsack's back-pointers can be
  // overwritten by later items and reconstruct a plate twice.
  final best = List<List<int>?>.filled(maxSide + 1, null);
  best[0] = const [];
  for (var i = 0; i < stock.length; i++) {
    final w = stock[i] ~/ unit;
    for (var s = maxSide; s >= w; s--) {
      final b = best[s - w];
      if (b == null) continue;
      final cand = [...b, stock[i]]..sort((x, y) => y.compareTo(x));
      final cur = best[s];
      if (cur == null || _better(cand, cur)) best[s] = cand;
    }
  }

  PlateLoad build(int s) => PlateLoad(barG: barG, perSideG: best[s]!);

  PlateLoad? exact;
  if (targetSide2.isEven && (targetSide2 ~/ 2) % unit == 0) {
    final s = targetSide2 ~/ 2 ~/ unit;
    if (s <= maxSide && best[s] != null) exact = build(s);
  }
  if (exact != null) return PlateResult(exact: exact);

  final want = targetSide2 / 2 / unit;
  PlateLoad? below;
  PlateLoad? above;
  for (var s = want.floor().clamp(0, maxSide).toInt(); s >= 0; s--) {
    if (best[s] != null && s < want) {
      below = build(s);
      break;
    }
  }
  for (var s = want.ceil(); s <= maxSide; s++) {
    if (best[s] != null && s > want) {
      above = build(s);
      break;
    }
  }
  return PlateResult(below: below, above: above);
}

/// Every total the bar can make with [pairs], ascending: the load steps for a
/// barbell exercise at that gym.
List<int> barSteps({int barG = standardBarG, required Map<int, int> pairs}) {
  final sums = <int>{0};
  for (final e in pairs.entries) {
    for (var n = 0; n < e.value; n++) {
      sums.addAll([for (final s in sums) s + e.key]);
    }
  }
  return [for (final s in sums) barG + 2 * s]..sort();
}

/// The closest available load to [targetG] in ascending [stepsG]; ties go
/// down (the lighter weight is the safer suggestion). Null when empty.
int? nearestStep(int targetG, List<int> stepsG) {
  int? best;
  for (final s in stepsG) {
    if (best == null || (s - targetG).abs() < (best - targetG).abs()) best = s;
  }
  return best;
}

/// The jump from [fromG] to the next step up, as a percentage (dumbbell
/// steps: 10 -> 12.5 kg is +25 %, which the UI flags as a big jump).
double? nextStepJumpPct(int fromG, List<int> stepsG) {
  if (fromG <= 0) return null;
  for (final s in stepsG) {
    if (s > fromG) return (s - fromG) * 100 / fromG;
  }
  return null;
}

/// "22.5", "20", "1.25": kilograms without trailing zeros.
String formatKg(int g) {
  final whole = g ~/ 1000;
  final frac = (g % 1000)
      .toString()
      .padLeft(3, '0')
      .replaceAll(RegExp(r'0+$'), '');
  return frac.isEmpty ? '$whole' : '$whole.$frac';
}

/// Fewer plates wins; on a tie, the heavier plates first.
bool _better(List<int> a, List<int> b) {
  if (a.length != b.length) return a.length < b.length;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
