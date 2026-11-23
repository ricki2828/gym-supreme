/// Plain value types shared by the engine, the store and the UI.
///
/// Units, everywhere: load in integer grams (`loadG`), times in UTC epoch
/// milliseconds (`...Ms`) plus the local offset in minutes (`tzOffsetMin`).
/// Muscle, equipment and exercise ids are permanent slugs; workout ids are
/// UUIDs.
library;

/// Where a gym item came from (plan 4.2). A later camera scan adds `scan`.
enum KitSource { preset, manual, scan }

/// One piece of kit at one gym.
class KitItem {
  const KitItem({
    required this.equipmentId,
    this.source = KitSource.manual,
    this.confirmed = true,
    this.weightsG = const [],
  });

  final String equipmentId;
  final KitSource source;

  /// False for preset items he has not looked at yet.
  final bool confirmed;

  /// The loads this gym actually has, ascending, in grams: dumbbell pairs
  /// (per hand), stack pins, or plate sizes. Empty means "not known yet"
  /// (the engine then falls back to [defaultWeightsG]).
  final List<int> weightsG;

  KitItem copyWith({KitSource? source, bool? confirmed, List<int>? weightsG}) =>
      KitItem(
        equipmentId: equipmentId,
        source: source ?? this.source,
        confirmed: confirmed ?? this.confirmed,
        weightsG: weightsG ?? this.weightsG,
      );

  Map<String, Object?> toJson() => {
    'equipment_id': equipmentId,
    'source': source.name,
    'confirmed': confirmed,
    'weights_g': weightsG,
  };

  factory KitItem.fromJson(Map<String, Object?> j) => KitItem(
    equipmentId: j['equipment_id'] as String,
    source: KitSource.values.byName(j['source'] as String? ?? 'manual'),
    confirmed: j['confirmed'] as bool? ?? true,
    weightsG: [for (final w in (j['weights_g'] as List? ?? const [])) w as int],
  );

  @override
  bool operator ==(Object other) =>
      other is KitItem &&
      other.equipmentId == equipmentId &&
      other.source == source &&
      other.confirmed == confirmed &&
      _listEq(other.weightsG, weightsG);

  @override
  int get hashCode =>
      Object.hash(equipmentId, source, confirmed, Object.hashAll(weightsG));
}

/// A place he trains. Bodyweight is always present and never stored.
class Gym {
  const Gym({
    required this.id,
    required this.name,
    required this.kit,
    this.presetId,
    this.createdAtMs = 0,
  });

  final String id;
  final String name;
  final String? presetId;
  final int createdAtMs;

  /// Keyed by equipment id.
  final Map<String, KitItem> kit;

  Set<String> get equipmentIds => kit.keys.toSet();

  bool has(String equipmentId) => kit.containsKey(equipmentId);

  Gym copyWith({String? name, Map<String, KitItem>? kit}) => Gym(
    id: id,
    name: name ?? this.name,
    kit: kit ?? this.kit,
    presetId: presetId,
    createdAtMs: createdAtMs,
  );

  /// Ticks or unticks one item. Ticking adds it as manual and confirmed.
  Gym toggle(String equipmentId) {
    final next = Map.of(kit);
    if (next.remove(equipmentId) == null) {
      next[equipmentId] = KitItem(equipmentId: equipmentId);
    }
    return copyWith(kit: next);
  }

  Gym withWeights(String equipmentId, List<int> weightsG) {
    final item = kit[equipmentId] ?? KitItem(equipmentId: equipmentId);
    final sorted = {...weightsG}.toList()..sort();
    return copyWith(
      kit: {
        ...kit,
        equipmentId: item.copyWith(weightsG: sorted, confirmed: true),
      },
    );
  }
}

/// Fallback load lists when a gym has not told us its weights yet.
/// Dumbbells 2-25 kg (plan 4.3: condo to about 20-25 kg), stack 5-100 kg.
const Map<String, List<int>> defaultWeightsG = {
  'dumbbell': [
    2000, 4000, 5000, 6000, 7500, 8000, 10000, 12000, 12500, 14000, 15000, //
    16000, 17500, 18000, 20000, 22000, 22500, 24000, 25000,
  ],
  'stack': [
    5000, 10000, 15000, 20000, 25000, 30000, 35000, 40000, 45000, 50000, //
    55000, 60000, 65000, 70000, 75000, 80000, 85000, 90000, 95000, 100000,
  ],
};

/// User settings that the engine reads.
class Settings {
  const Settings({
    this.bodyweightG,
    this.defaultMinutes = 45,
    this.restCompoundS = 120,
    this.restIsolationS = 75,
  });

  final int? bodyweightG;
  final int defaultMinutes;
  final int restCompoundS;
  final int restIsolationS;

  Map<String, Object?> toJson() => {
    'bodyweight_g': bodyweightG,
    'default_minutes': defaultMinutes,
    'rest_compound_s': restCompoundS,
    'rest_isolation_s': restIsolationS,
  };

  factory Settings.fromJson(Map<String, Object?> j) => Settings(
    bodyweightG: j['bodyweight_g'] as int?,
    defaultMinutes: j['default_minutes'] as int? ?? 45,
    restCompoundS: j['rest_compound_s'] as int? ?? 120,
    restIsolationS: j['rest_isolation_s'] as int? ?? 75,
  );
}

/// The five workout types (plan 4.2). A type is a default muscle set.
class WorkoutType {
  const WorkoutType(this.id, this.name, this.muscles);
  final String id;
  final String name;

  /// Lead muscle first.
  final List<String> muscles;
}

const List<WorkoutType> workoutTypes = [
  WorkoutType('push', 'Push', [
    'chest',
    'front-delts',
    'side-delts',
    'triceps',
  ]),
  WorkoutType('pull', 'Pull', [
    'lats',
    'rear-delts',
    'biceps',
    'traps',
    'forearms',
  ]),
  WorkoutType('legs', 'Legs', ['quads', 'hamstrings', 'glutes', 'calves']),
  WorkoutType('core', 'Core', ['abs', 'obliques', 'lower-back']),
  WorkoutType('engine', 'Engine', []),
];

WorkoutType? workoutType(String? id) {
  for (final t in workoutTypes) {
    if (t.id == id) return t;
  }
  return null;
}

/// How a done set was completed (plan 7, R3). Wire names are snake_case.
enum Completion {
  /// One tap on Done with the prefilled values (also every lock-screen Done).
  tapUnchanged('tap_unchanged'),

  /// Done after +/- on load or reps.
  adjusted('adjusted'),

  /// Done after typing a value.
  typed('typed'),

  /// Done with no prefill to start from (first time at this gym).
  coldStart('cold_start');

  const Completion(this.wire);
  final String wire;

  /// Throws [FormatException] on an unknown value (strict, like Kotlin).
  static Completion fromWire(String w) => values.firstWhere(
    (c) => c.wire == w,
    orElse: () => throw FormatException('unknown completion "$w"'),
  );
}

/// Where the Done came from (R3).
enum SetSource { app, lockscreen }

/// `reps` (load x reps) or `timed` (a timer block, R4).
enum SetKind { reps, timed }

/// One finished set as stored. R6 ghost fields are first-class.
class SetRecord {
  const SetRecord({
    required this.setId,
    required this.exerciseId,
    required this.exerciseName,
    required this.exercisePosition,
    required this.setOrdinal,
    this.completion,
    this.skipped = false,
    this.kind = SetKind.reps,
    this.loadG,
    this.reps,
    this.startedAtMs,
    this.endedAtMs,
    this.offsetMs,
    this.source = SetSource.app,
    this.blockJson,
  });

  final String setId;
  final String exerciseId;

  /// The name as it was when logged (ids never change; names may).
  final String exerciseName;

  /// 0-based order of the exercise in the workout as performed.
  final int exercisePosition;

  /// 1-based ordinal of the set within its exercise (R6).
  final int setOrdinal;

  final SetKind kind;
  final int? loadG;
  final int? reps;
  final int? startedAtMs;
  final int? endedAtMs;

  /// Milliseconds from workout start to the set's end (R6 ghost key).
  final int? offsetMs;

  /// Null for skipped sets.
  final Completion? completion;

  /// Skipped sets are kept (ghost and history show them) but carry no
  /// volume and do not count for days-since.
  final bool skipped;
  final SetSource source;

  /// Timer block definition and round marks for `kind == timed` (R4).
  final String? blockJson;

  bool get counts => !skipped;

  /// Load volume in gram-reps. Timed and skipped sets carry none (R4).
  int get volumeGReps =>
      (!counts || kind != SetKind.reps) ? 0 : (loadG ?? 0) * (reps ?? 0);
}

/// One finished workout as stored, with its sets.
class WorkoutRecord {
  const WorkoutRecord({
    required this.uuid,
    required this.gymId,
    required this.startedAtMs,
    required this.tzOffsetMin,
    required this.endedAtMs,
    required this.sets,
    this.typeId,
    this.muscles = const [],
    this.pausedMs = 0,
    this.appVersion = '',
    this.swaps = 0,
  });

  final String uuid;
  final String gymId;
  final String? typeId;

  /// The muscles he picked for this session.
  final List<String> muscles;
  final int startedAtMs;
  final int tzOffsetMin;
  final int endedAtMs;
  final int pausedMs;
  final String appVersion;

  /// Exercises swapped out during the session (plan 3 gate).
  final int swaps;
  final List<SetRecord> sets;

  int get durationMs => endedAtMs - startedAtMs - pausedMs;

  /// Local time as a UTC-based DateTime shifted by the stored offset.
  DateTime get localStart => DateTime.fromMillisecondsSinceEpoch(
    startedAtMs + tzOffsetMin * 60000,
    isUtc: true,
  );

  Iterable<SetRecord> get doneSets => sets.where((s) => s.counts);

  int get volumeGReps => sets.fold(0, (a, s) => a + s.volumeGReps);
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
