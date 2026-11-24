/// Import (0.3 I1): the counterpart of `GymEngine.export`. Parses an export
/// bundle (`export_format` 1 or 2) strictly into records before anything is
/// written; the engine then applies it in one store transaction.
library;

import 'dart:convert';

import 'api.dart';
import 'model.dart';
import 'snapshot.dart';
import 'starting_weights.dart';

/// The newest database schema an export may come from. Kept in step with
/// `latestSchemaVersion` in sqlite_store.dart (test: import_test.dart).
const int importMaxSchemaVersion = 2;

/// The newest `export_format` this build reads.
const int importMaxExportFormat = 2;

/// A file import refuses as a whole: nothing is written. [message] is
/// written for him (the Diagnostics result line).
class ImportRefused implements Exception {
  const ImportRefused(this.message);
  final String message;

  @override
  String toString() => 'ImportRefused: $message';
}

/// What an import adds or would add ([GymApi.previewImport] /
/// [GymApi.importBundle]).
class ImportCounts {
  const ImportCounts({
    required this.exportFormat,
    required this.workoutsInFile,
    required this.workoutsAdded,
    required this.skippedExisting,
    required this.skippedDeleted,
    required this.gymsAdded,
    required this.gymsKept,
    required this.hrSamplesAdded,
    required this.settingsRestored,
    required this.deletedInFile,
    this.endsClamped = 0,
    this.startingWeightsAdded = 0,
    this.startingWeightsKept = 0,
  });

  final int exportFormat;
  final int workoutsInFile;

  /// New uuids: inserted.
  final int workoutsAdded;

  /// Uuids already in history: left exactly as they are.
  final int skippedExisting;

  /// Uuids he deleted on this phone: stay deleted, never resurrected.
  final int skippedDeleted;

  /// Gym ids new to this phone, with their kit.
  final int gymsAdded;

  /// Gym ids already here: name and kit on this phone kept.
  final int gymsKept;

  /// HR samples of the added workouts. Exports carry none today; a file
  /// with a per-workout `hr` list (`[t_ms, bpm]` pairs) is read.
  final int hrSamplesAdded;

  /// True when this phone still had default settings and the file's were
  /// applied; false when his own settings were kept (or the file had none,
  /// or they are the defaults too).
  final bool settingsRestored;

  /// `deleted_workout_uuids` in the file: information only, not imported.
  final int deletedInFile;

  /// Added workouts whose end was before their start (a wall-clock step back
  /// during the session) and were imported with the end set to the start.
  final int endsClamped;

  /// Starting weights (0.3 S1) for lifts that had none on this phone.
  final int startingWeightsAdded;

  /// Starting weights in the file for lifts that already have one here:
  /// his own kept.
  final int startingWeightsKept;

  /// Nothing to add: importing would change nothing.
  bool get isNoOp =>
      workoutsAdded == 0 &&
      gymsAdded == 0 &&
      startingWeightsAdded == 0 &&
      !settingsRestored;
}

/// One workout of the file, ready for `HistoryStore.upsertWorkout`.
class ImportWorkout {
  const ImportWorkout(this.record, this.hr, {this.endClamped = false});
  final WorkoutRecord record;
  final List<HrSample> hr;

  /// The file's end was before its start; [record] ends at its start, with
  /// no pause (duration 0).
  final bool endClamped;
}

/// A parsed, validated bundle.
class ImportBundle {
  const ImportBundle({
    required this.exportFormat,
    required this.gyms,
    required this.workouts,
    required this.settings,
    required this.deletedInFile,
    this.startingWeights = const {},
  });

  final int exportFormat;
  final List<Gym> gyms;

  /// `starting_weights` (0.3 S1, optional in format 2): exercise id to
  /// grams. Empty when the file has none (any 0.2.x export).
  final Map<String, int> startingWeights;
  final List<ImportWorkout> workouts;

  /// Null when the file carries no `settings` object.
  final Settings? settings;
  final int deletedInFile;
}

/// Parses [text] strictly. Throws [ImportRefused] for anything that is not
/// a whole, well-typed export this build understands: no partial reads.
ImportBundle parseImportBundle(String text) {
  // Some editors and Windows tools save UTF-8 with a byte-order mark;
  // jsonDecode refuses it.
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final Object? root;
  try {
    root = jsonDecode(text);
  } on FormatException {
    throw const ImportRefused(
      'This is not a Gym Supreme export (not valid JSON, or cut short).',
    );
  }
  if (root is! Map<String, Object?>) {
    throw const ImportRefused('This is not a Gym Supreme export.');
  }
  final format = root['export_format'];
  if (format is! int) {
    throw const ImportRefused(
      'This is not a Gym Supreme export (no export_format).',
    );
  }
  if (format > importMaxExportFormat) {
    throw ImportRefused(
      'This export was made by a newer version of Gym Supreme (format '
      '$format). Update the app, then import again.',
    );
  }
  if (format < 1) {
    throw ImportRefused('Unknown export format $format.');
  }
  final schema = root['schema_version'];
  if (schema != null && (schema is! int || schema > importMaxSchemaVersion)) {
    throw ImportRefused(
      'This export was made by a newer version of Gym Supreme (database '
      'v$schema). Update the app, then import again.',
    );
  }
  final snap = root['snapshot_schema'];
  if (snap != null && (snap is! int || snap > snapshotSchema)) {
    throw ImportRefused(
      'This export was made by a newer version of Gym Supreme (snapshot '
      'v$snap). Update the app, then import again.',
    );
  }
  try {
    final r = _Reader('export');
    final gyms = [
      for (final (i, g) in r.list(root, 'gyms').indexed)
        _gym(_Reader('gyms[$i]').map(g)),
    ];
    final seenGyms = <String>{};
    for (final g in gyms) {
      if (!seenGyms.add(g.id)) throw _Bad('gym ${g.id} appears twice');
    }
    final workouts = [
      for (final (i, w) in r.list(root, 'workouts').indexed)
        _workout(_Reader('workouts[$i]').map(w)),
    ];
    final seenUuids = <String>{};
    final seenSets = <String>{};
    for (final w in workouts) {
      if (!seenUuids.add(w.record.uuid)) {
        throw _Bad('workout ${w.record.uuid} appears twice');
      }
      for (final s in w.record.sets) {
        if (!seenSets.add(s.setId)) throw _Bad('set ${s.setId} appears twice');
      }
    }
    final settingsJson = root['settings'];
    Settings? settings;
    if (settingsJson != null) {
      final m = r.map(settingsJson);
      final s = _Reader('settings');
      settings = Settings(
        bodyweightG: s.intOrNull(m, 'bodyweight_g'),
        defaultMinutes: s.intOr(m, 'default_minutes', 45),
        restCompoundS: s.intOr(m, 'rest_compound_s', 120),
        restIsolationS: s.intOr(m, 'rest_isolation_s', 75),
      );
      if ((settings.bodyweightG ?? 1) <= 0 ||
          settings.defaultMinutes <= 0 ||
          settings.restCompoundS < 0 ||
          settings.restIsolationS < 0) {
        throw const _Bad('settings hold a zero or negative value');
      }
    }
    final deleted = root['deleted_workout_uuids'];
    var deletedInFile = 0;
    if (deleted != null) {
      final l = r.list(root, 'deleted_workout_uuids');
      for (final u in l) {
        if (u is! String) throw _Bad('deleted_workout_uuids: not a string');
      }
      deletedInFile = l.length;
    }
    final starting = <String, int>{};
    for (final (i, x)
        in r.list(root, 'starting_weights', optional: true).indexed) {
      final sr = _Reader('starting_weights[$i]');
      final m = sr.map(x);
      final id = sr.str(m, 'exercise_id');
      final g = sr.int_(m, 'load_g');
      if (!validStartingWeight(g)) {
        throw _Bad('starting weight for $id is out of range ($g g)');
      }
      if (starting.containsKey(id)) {
        throw _Bad('starting weight for $id appears twice');
      }
      starting[id] = g;
    }
    return ImportBundle(
      exportFormat: format,
      gyms: gyms,
      workouts: workouts,
      settings: settings,
      deletedInFile: deletedInFile,
      startingWeights: starting,
    );
  } on _Bad catch (e) {
    throw ImportRefused('This export is damaged: ${e.what}. Nothing imported.');
  }
}

Gym _gym(Map<String, Object?> j) {
  final r = _Reader('gym');
  final id = r.str(j, 'id');
  final kit = <String, KitItem>{};
  for (final k in r.list(j, 'kit', optional: true)) {
    final m = r.map(k);
    final kr = _Reader('gym $id kit');
    final item = KitItem(
      equipmentId: kr.str(m, 'equipment_id'),
      source: kr.enumOr(m, 'source', KitSource.values, KitSource.manual),
      confirmed: kr.boolOr(m, 'confirmed', true),
      weightsG: kr.intList(m, 'weights_g'),
    );
    if (kit.containsKey(item.equipmentId)) {
      throw _Bad('gym $id lists ${item.equipmentId} twice');
    }
    kit[item.equipmentId] = item;
  }
  return Gym(
    id: id,
    name: r.str(j, 'name', allowEmpty: true),
    presetId: r.strOrNull(j, 'preset_id'),
    createdAtMs: r.intOr(j, 'created_at_ms', 0),
    kit: kit,
  );
}

ImportWorkout _workout(Map<String, Object?> j) {
  final r = _Reader('workout');
  final uuid = r.str(j, 'uuid');
  final w = _Reader('workout $uuid');
  final sets = <SetRecord>[];
  for (final s in w.list(j, 'sets')) {
    final m = w.map(s);
    final sr = _Reader('workout $uuid set');
    final completionWire = sr.strOrNull(m, 'completion');
    final Completion? completion;
    try {
      completion = completionWire == null
          ? null
          : Completion.fromWire(completionWire);
    } on FormatException {
      throw _Bad('workout $uuid: unknown completion "$completionWire"');
    }
    final skipped = sr.boolOr(m, 'skipped', false);
    if (skipped != (completion == null)) {
      throw _Bad('workout $uuid: a set is both skipped and done, or neither');
    }
    final block = m['block'];
    if (block != null && block is! Map) {
      throw _Bad('workout $uuid: a set block is not an object');
    }
    final set = SetRecord(
      setId: sr.str(m, 'set_id'),
      exerciseId: sr.str(m, 'exercise_id'),
      exerciseName: sr.str(m, 'exercise_name', allowEmpty: true),
      exercisePosition: sr.int_(m, 'exercise_position'),
      setOrdinal: sr.int_(m, 'set_ordinal'),
      kind: sr.enumOr(m, 'kind', SetKind.values, SetKind.reps),
      loadG: sr.intOrNull(m, 'load_g'),
      reps: sr.intOrNull(m, 'reps'),
      completion: completion,
      skipped: skipped,
      source: sr.enumOr(m, 'source', SetSource.values, SetSource.app),
      startedAtMs: sr.intOrNull(m, 'started_at_ms'),
      endedAtMs: sr.intOrNull(m, 'ended_at_ms'),
      offsetMs: sr.intOrNull(m, 'offset_ms'),
      blockJson: block == null ? null : jsonEncode(block),
    );
    // The value rules of a history edit (D1 editWorkout): a done reps set
    // has at least 1 rep, no load is negative, and time runs forward.
    if (set.loadG != null && set.loadG! < 0) {
      throw _Bad('workout $uuid: a negative load');
    }
    final minReps = !set.skipped && set.kind == SetKind.reps ? 1 : 0;
    if (set.reps != null && set.reps! < minReps) {
      throw _Bad('workout $uuid: a set with ${set.reps} reps');
    }
    if (set.startedAtMs != null &&
        set.endedAtMs != null &&
        set.endedAtMs! < set.startedAtMs!) {
      throw _Bad('workout $uuid: a set ends before it starts');
    }
    sets.add(set);
  }
  final hr = <HrSample>[];
  final seenT = <int>{};
  for (final p in w.list(j, 'hr', optional: true)) {
    if (p is! List || p.length != 2 || p[0] is! int || p[1] is! int) {
      throw _Bad('workout $uuid: an hr sample is not [t_ms, bpm]');
    }
    if (seenT.add(p[0] as int)) hr.add(HrSample(p[0] as int, p[1] as int));
  }
  final muscles = <String>[];
  for (final m in w.list(j, 'muscles', optional: true)) {
    if (m is! String) throw _Bad('workout $uuid: a muscle is not a string');
    muscles.add(m);
  }
  final started = w.int_(j, 'started_at_ms');
  // Workout start and end are both wall-clock reads, so a clock step back
  // during a session can leave end < start in a real export: clamp the end
  // to the start rather than refusing the whole file. Set times keep their
  // ordering check above (the session caps those). A clamped workout's
  // pause is zeroed too, so its duration is 0, never negative.
  final fileEnded = w.int_(j, 'ended_at_ms');
  final endClamped = fileEnded < started;
  final ended = endClamped ? started : fileEnded;
  final filePaused = w.intOr(j, 'paused_ms', 0);
  if (filePaused < 0) throw _Bad('workout $uuid: a negative pause');
  final paused = endClamped ? 0 : filePaused;
  return ImportWorkout(
    WorkoutRecord(
      uuid: uuid,
      gymId: w.str(j, 'gym_id'),
      typeId: w.strOrNull(j, 'type_id'),
      muscles: muscles,
      startedAtMs: started,
      tzOffsetMin: w.int_(j, 'tz_offset_min'),
      endedAtMs: ended,
      pausedMs: paused,
      appVersion: w.strOr(j, 'app_version', ''),
      swaps: w.intOr(j, 'swaps', 0),
      editedAtMs: w.intOrNull(j, 'edited_at_ms'),
      sets: sets,
    ),
    hr,
    endClamped: endClamped,
  );
}

class _Bad implements Exception {
  const _Bad(this.what);
  final String what;
}

/// Typed field reads that throw [_Bad] naming [where] and the key.
class _Reader {
  const _Reader(this.where);
  final String where;

  Never _fail(String key, String want) =>
      throw _Bad('$where: "$key" is missing or not $want');

  Map<String, Object?> map(Object? v) {
    if (v is! Map<String, Object?>) throw _Bad('$where: not an object');
    return v;
  }

  List<Object?> list(
    Map<String, Object?> j,
    String key, {
    bool optional = false,
  }) {
    final v = j[key];
    if (v == null && optional) return const [];
    if (v is! List<Object?>) _fail(key, 'a list');
    return v;
  }

  String str(Map<String, Object?> j, String key, {bool allowEmpty = false}) {
    final v = j[key];
    if (v is! String || (!allowEmpty && v.isEmpty)) _fail(key, 'text');
    return v;
  }

  String? strOrNull(Map<String, Object?> j, String key) {
    final v = j[key];
    if (v != null && v is! String) _fail(key, 'text');
    return v as String?;
  }

  String strOr(Map<String, Object?> j, String key, String or) =>
      strOrNull(j, key) ?? or;

  int int_(Map<String, Object?> j, String key) {
    final v = j[key];
    if (v is! int) _fail(key, 'a whole number');
    return v;
  }

  int? intOrNull(Map<String, Object?> j, String key) {
    final v = j[key];
    if (v != null && v is! int) _fail(key, 'a whole number');
    return v as int?;
  }

  int intOr(Map<String, Object?> j, String key, int or) =>
      intOrNull(j, key) ?? or;

  bool boolOr(Map<String, Object?> j, String key, bool or) {
    final v = j[key];
    if (v == null) return or;
    if (v is! bool) _fail(key, 'true/false');
    return v;
  }

  List<int> intList(Map<String, Object?> j, String key) {
    final out = <int>[];
    for (final x in list(j, key, optional: true)) {
      if (x is! int) _fail(key, 'a list of whole numbers');
      out.add(x);
    }
    return out;
  }

  T enumOr<T extends Enum>(
    Map<String, Object?> j,
    String key,
    List<T> values,
    T or,
  ) {
    final v = j[key];
    if (v == null) return or;
    if (v is! String) _fail(key, 'text');
    for (final e in values) {
      if (e.name == v) return e;
    }
    throw _Bad('$where: unknown $key "$v"');
  }
}
