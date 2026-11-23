/// SQLite is the source of truth for finished workouts, gyms, kit and
/// settings (plan 7). Schema versions run through `PRAGMA user_version`;
/// every version keeps a fixture database built by the previous release
/// (R7: install over 0.1 with data intact).
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'api.dart';
import 'model.dart';
import 'store.dart';

/// Ordered migrations. Index i takes the database from version i to i+1.
/// Never edit a shipped entry; append.
const List<String> migrations = [
  // v1 (APK 0.1). R6 ghost fields and the R2 hr table from day one.
  '''
CREATE TABLE gym (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  preset_id TEXT,
  created_at_ms INTEGER NOT NULL
);
CREATE TABLE gym_item (
  gym_id TEXT NOT NULL REFERENCES gym(id) ON DELETE CASCADE,
  equipment_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IS NOT NULL AND source IN ('preset','manual','scan')),
  confirmed INTEGER NOT NULL CHECK (confirmed IN (0,1)),
  weights_g TEXT NOT NULL DEFAULT '[]',
  PRIMARY KEY (gym_id, equipment_id)
);
CREATE TABLE setting (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE workout (
  uuid TEXT PRIMARY KEY,
  gym_id TEXT NOT NULL,
  type_id TEXT,
  muscles TEXT NOT NULL DEFAULT '[]',
  started_at_ms INTEGER NOT NULL,
  tz_offset_min INTEGER NOT NULL,
  ended_at_ms INTEGER NOT NULL,
  paused_ms INTEGER NOT NULL DEFAULT 0,
  app_version TEXT NOT NULL DEFAULT '',
  swaps INTEGER NOT NULL DEFAULT 0,
  snapshot_json TEXT
);
CREATE INDEX workout_started ON workout(started_at_ms);
CREATE TABLE set_row (
  set_id TEXT PRIMARY KEY,
  workout_uuid TEXT NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
  gym_id TEXT NOT NULL,
  exercise_id TEXT NOT NULL,
  exercise_name TEXT NOT NULL,
  exercise_position INTEGER NOT NULL,
  set_ordinal INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IS NOT NULL AND kind IN ('reps','timed')),
  load_g INTEGER,
  reps INTEGER,
  completion TEXT NOT NULL CHECK (completion IS NOT NULL AND completion IN ('tap_unchanged','adjusted','typed','cold_start')),
  skipped INTEGER NOT NULL CHECK (skipped IN (0,1)),
  source TEXT NOT NULL CHECK (source IS NOT NULL AND source IN ('app','lockscreen')),
  started_at_ms INTEGER,
  ended_at_ms INTEGER,
  offset_ms INTEGER,
  block_json TEXT
);
CREATE INDEX set_ghost ON set_row(gym_id, exercise_id, workout_uuid);
CREATE INDEX set_workout ON set_row(workout_uuid);
CREATE TABLE hr_sample (
  workout_uuid TEXT NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
  t_ms INTEGER NOT NULL,
  bpm INTEGER NOT NULL,
  PRIMARY KEY (workout_uuid, t_ms)
);
''',
];

int get latestSchemaVersion => migrations.length;

class SqliteStore implements HistoryStore {
  SqliteStore._(this.db) {
    db.execute('PRAGMA foreign_keys = ON');
    migrate(db);
  }

  /// Opens (and creates or migrates) the database file.
  factory SqliteStore.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    return SqliteStore._(db);
  }

  factory SqliteStore.inMemory() => SqliteStore._(sqlite3.openInMemory());

  final Database db;

  /// Runs every migration above the database's `user_version`, each in its
  /// own transaction. Refuses a database newer than this build.
  static void migrate(Database db) {
    final v = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (v > migrations.length) {
      throw StateError(
        'database schema v$v is newer than this build (v${migrations.length})',
      );
    }
    for (var i = v; i < migrations.length; i++) {
      db.execute('BEGIN');
      try {
        db.execute(migrations[i]);
        db.execute('PRAGMA user_version = ${i + 1}');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  /// Checkpoint the WAL into the main file (before Auto Backup, plan 7).
  void checkpoint() => db.execute('PRAGMA wal_checkpoint(TRUNCATE)');

  void close() => db.close();

  @override
  int get schemaVersion =>
      db.select('PRAGMA user_version').first.columnAt(0) as int;

  T _tx<T>(T Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      db.execute('COMMIT');
      return r;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ----------------------------------------------------------- gyms

  @override
  List<Gym> gyms() => [
    for (final r in db.select('SELECT id FROM gym ORDER BY created_at_ms, id'))
      gym(r['id'] as String)!,
  ];

  @override
  Gym? gym(String id) {
    final rows = db.select('SELECT * FROM gym WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final g = rows.first;
    final items = db.select(
      'SELECT * FROM gym_item WHERE gym_id = ? ORDER BY equipment_id',
      [id],
    );
    return Gym(
      id: g['id'] as String,
      name: g['name'] as String,
      presetId: g['preset_id'] as String?,
      createdAtMs: g['created_at_ms'] as int,
      kit: {
        for (final r in items)
          r['equipment_id'] as String: KitItem(
            equipmentId: r['equipment_id'] as String,
            source: KitSource.values.byName(r['source'] as String),
            confirmed: (r['confirmed'] as int) == 1,
            weightsG: [
              for (final w in jsonDecode(r['weights_g'] as String) as List)
                w as int,
            ],
          ),
      },
    );
  }

  @override
  void upsertGym(Gym gym) => _tx(() {
    db.execute(
      'INSERT INTO gym (id, name, preset_id, created_at_ms) VALUES (?,?,?,?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
      'preset_id = excluded.preset_id',
      [gym.id, gym.name, gym.presetId, gym.createdAtMs],
    );
    db.execute('DELETE FROM gym_item WHERE gym_id = ?', [gym.id]);
    final ins = db.prepare(
      'INSERT INTO gym_item (gym_id, equipment_id, source, confirmed, '
      'weights_g) VALUES (?,?,?,?,?)',
    );
    try {
      for (final k in gym.kit.values) {
        ins.execute([
          gym.id,
          k.equipmentId,
          k.source.name,
          k.confirmed ? 1 : 0,
          jsonEncode(k.weightsG),
        ]);
      }
    } finally {
      ins.close();
    }
  });

  /// Deletes the gym and its kit. Workouts logged there are kept (history
  /// is never deleted by a gym edit); they show with an empty gym name.
  @override
  void deleteGym(String id) =>
      _tx(() => db.execute('DELETE FROM gym WHERE id = ?', [id]));

  // ------------------------------------------------------- settings

  @override
  Settings settings() {
    final rows = db.select("SELECT value FROM setting WHERE key = 'settings'");
    if (rows.isEmpty) return const Settings();
    return Settings.fromJson(
      (jsonDecode(rows.first['value'] as String) as Map)
          .cast<String, Object?>(),
    );
  }

  @override
  void saveSettings(Settings settings) => db.execute(
    "INSERT INTO setting (key, value) VALUES ('settings', ?) "
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [jsonEncode(settings.toJson())],
  );

  @override
  String? setting(String key) {
    final rows = db.select('SELECT value FROM setting WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  void saveSetting(String key, String json) {
    if (key == 'settings') throw ArgumentError('reserved key');
    db.execute(
      'INSERT INTO setting (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, json],
    );
  }

  // ------------------------------------------------------- workouts

  @override
  void upsertWorkout(
    WorkoutRecord w, {
    String? snapshotJson,
    List<HrSample> hr = const [],
  }) => _tx(() {
    // Upsert the row and replace its sets. HR samples are only ever added
    // (INSERT OR IGNORE): a second save without samples must not wipe them.
    db.execute(
      'INSERT INTO workout (uuid, gym_id, type_id, muscles, started_at_ms, '
      'tz_offset_min, ended_at_ms, paused_ms, app_version, swaps, '
      'snapshot_json) VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(uuid) DO UPDATE SET '
      'gym_id = excluded.gym_id, type_id = excluded.type_id, '
      'muscles = excluded.muscles, started_at_ms = excluded.started_at_ms, '
      'tz_offset_min = excluded.tz_offset_min, '
      'ended_at_ms = excluded.ended_at_ms, paused_ms = excluded.paused_ms, '
      'app_version = excluded.app_version, swaps = excluded.swaps, '
      'snapshot_json = coalesce(excluded.snapshot_json, snapshot_json)',
      [
        w.uuid,
        w.gymId,
        w.typeId,
        jsonEncode(w.muscles),
        w.startedAtMs,
        w.tzOffsetMin,
        w.endedAtMs,
        w.pausedMs,
        w.appVersion,
        w.swaps,
        snapshotJson,
      ],
    );
    db.execute('DELETE FROM set_row WHERE workout_uuid = ?', [w.uuid]);
    final ins = db.prepare(
      'INSERT INTO set_row (set_id, workout_uuid, gym_id, exercise_id, '
      'exercise_name, exercise_position, set_ordinal, kind, load_g, reps, '
      'completion, skipped, source, started_at_ms, ended_at_ms, offset_ms, '
      'block_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    );
    try {
      for (final s in w.sets) {
        ins.execute([
          s.setId,
          w.uuid,
          w.gymId,
          s.exerciseId,
          s.exerciseName,
          s.exercisePosition,
          s.setOrdinal,
          s.kind.name,
          s.loadG,
          s.reps,
          s.completion.wire,
          s.skipped ? 1 : 0,
          s.source.name,
          s.startedAtMs,
          s.endedAtMs,
          s.offsetMs,
          s.blockJson,
        ]);
      }
    } finally {
      ins.close();
    }
    final hrIns = db.prepare(
      'INSERT OR IGNORE INTO hr_sample (workout_uuid, t_ms, bpm) '
      'VALUES (?,?,?)',
    );
    try {
      for (final h in hr) {
        hrIns.execute([w.uuid, h.tMs, h.bpm]);
      }
    } finally {
      hrIns.close();
    }
  });

  @override
  bool hasWorkout(String uuid) =>
      db.select('SELECT 1 FROM workout WHERE uuid = ?', [uuid]).isNotEmpty;

  @override
  WorkoutRecord? workout(String uuid) {
    final rows = db.select('SELECT * FROM workout WHERE uuid = ?', [uuid]);
    if (rows.isEmpty) return null;
    return _readWorkouts(rows, {
      uuid:
          _readSets(
            db.select(
              'SELECT * FROM set_row WHERE workout_uuid = ? '
              'ORDER BY exercise_position, set_ordinal',
              [uuid],
            ),
          )[uuid] ??
          const [],
    }).first;
  }

  @override
  List<WorkoutRecord> workouts() {
    final sets = _readSets(
      db.select(
        'SELECT * FROM set_row ORDER BY workout_uuid, exercise_position, '
        'set_ordinal',
      ),
    );
    return _readWorkouts(
      db.select('SELECT * FROM workout ORDER BY started_at_ms, uuid'),
      sets,
    );
  }

  List<HrSample> hrSamples(String uuid) => [
    for (final r in db.select(
      'SELECT t_ms, bpm FROM hr_sample WHERE workout_uuid = ? ORDER BY t_ms',
      [uuid],
    ))
      HrSample(r['t_ms'] as int, r['bpm'] as int),
  ];

  Map<String, List<SetRecord>> _readSets(ResultSet rows) {
    final out = <String, List<SetRecord>>{};
    for (final r in rows) {
      (out[r['workout_uuid'] as String] ??= []).add(
        SetRecord(
          setId: r['set_id'] as String,
          exerciseId: r['exercise_id'] as String,
          exerciseName: r['exercise_name'] as String,
          exercisePosition: r['exercise_position'] as int,
          setOrdinal: r['set_ordinal'] as int,
          kind: SetKind.values.byName(r['kind'] as String),
          loadG: r['load_g'] as int?,
          reps: r['reps'] as int?,
          completion: Completion.fromWire(r['completion'] as String),
          skipped: (r['skipped'] as int) == 1,
          source: SetSource.values.byName(r['source'] as String),
          startedAtMs: r['started_at_ms'] as int?,
          endedAtMs: r['ended_at_ms'] as int?,
          offsetMs: r['offset_ms'] as int?,
          blockJson: r['block_json'] as String?,
        ),
      );
    }
    return out;
  }

  List<WorkoutRecord> _readWorkouts(
    ResultSet rows,
    Map<String, List<SetRecord>> sets,
  ) => [
    for (final r in rows)
      WorkoutRecord(
        uuid: r['uuid'] as String,
        gymId: r['gym_id'] as String,
        typeId: r['type_id'] as String?,
        muscles: [
          for (final m in jsonDecode(r['muscles'] as String) as List)
            m as String,
        ],
        startedAtMs: r['started_at_ms'] as int,
        tzOffsetMin: r['tz_offset_min'] as int,
        endedAtMs: r['ended_at_ms'] as int,
        pausedMs: r['paused_ms'] as int,
        appVersion: r['app_version'] as String,
        swaps: r['swaps'] as int,
        sets: sets[r['uuid'] as String] ?? const [],
      ),
  ];
}
