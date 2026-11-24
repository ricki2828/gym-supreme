/// SQLite is the source of truth for finished workouts, gyms, kit and
/// settings (plan 7). Schema versions run through `PRAGMA user_version`;
/// every version keeps a fixture database built by the previous release
/// (R7: install over 0.1 with data intact).
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'api.dart';
import 'fsync_dir.dart';
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
  completion TEXT CHECK (completion IS NULL OR completion IN ('tap_unchanged','adjusted','typed','cold_start')),
  skipped INTEGER NOT NULL CHECK (skipped IN (0,1)),
  source TEXT NOT NULL CHECK (source IS NOT NULL AND source IN ('app','lockscreen')),
  started_at_ms INTEGER,
  ended_at_ms INTEGER,
  offset_ms INTEGER,
  block_json TEXT,
  CHECK ((skipped = 1) = (completion IS NULL))
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
  // v2 (0.2.1). Soft delete and history edits: NULL = live / as logged.
  // Only workouts() and workout() hide deleted rows; hasWorkout and the
  // backup guard still see them.
  '''
ALTER TABLE workout ADD COLUMN deleted_at_ms INTEGER;
ALTER TABLE workout ADD COLUMN edited_at_ms INTEGER;
''',
];

int get latestSchemaVersion => migrations.length;

enum RestoreResult {
  /// The db exists, or there is no snapshot: open as usual.
  notNeeded,

  /// The snapshot passed quick_check and is now the db.
  restored,

  /// The snapshot is definitely bad (corrupt or from a newer build). It was
  /// moved to `<dbPath>.refused-snapshot-<ms>` (outside backup/, kept for a
  /// manual look). Open a fresh db and count `restore_failed`.
  refused,

  /// Could not tell (I/O, busy, out of memory). Nothing changed and the
  /// snapshot is kept. DANGER for the caller: do not create a fresh db at
  /// dbPath and do not writeSnapshot this launch, or the next pause
  /// overwrites the only backup with an empty db. Retry, or run this launch
  /// on an in-memory store and try again next launch.
  retryLater,
}

class SqliteStore implements HistoryStore {
  SqliteStore._(this.db) {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    migrate(db);
  }

  /// Wraps an open database (tests, fixtures); migrates it.
  factory SqliteStore.fromDatabase(Database db) => SqliteStore._(db);

  /// Opens (and creates or migrates) the database file.
  factory SqliteStore.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('PRAGMA journal_mode = WAL');
    return SqliteStore._(db);
  }

  factory SqliteStore.inMemory() => SqliteStore._(sqlite3.openInMemory());

  final Database db;

  /// Runs every migration above the database's `user_version`, each in its
  /// own transaction. Refuses a database newer than this build.
  static void migrate(Database db) {
    int version() => db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version() > migrations.length) {
      throw StateError(
        'database schema v${version()} is newer than this build '
        '(v${migrations.length})',
      );
    }
    while (version() < migrations.length) {
      // Re-read inside the write lock: a second opener may have migrated.
      db.execute('BEGIN IMMEDIATE');
      try {
        final v = version();
        if (v < migrations.length) {
          db.execute(migrations[v]);
          db.execute('PRAGMA user_version = ${v + 1}');
        }
        db.execute('COMMIT');
      } catch (_) {
        if (!db.autocommit) db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  /// Checkpoint the WAL into the main file (before Auto Backup, plan 7).
  /// Returns false if the checkpoint could not finish (busy).
  bool checkpoint() {
    final r = db.select('PRAGMA wal_checkpoint(TRUNCATE)');
    return r.isEmpty || (r.first.columnAt(0) as int) == 0;
  }

  void close() => db.close();

  /// Backup source (plan 7, B6; t5t #15): a consistent single-file copy via
  /// `VACUUM INTO <path>.tmp`, fsync, then rename onto [path]. Auto Backup
  /// copies only this file, never the live db/WAL pair. Returns false if the
  /// database was busy (try again later); other errors throw.
  ///
  /// Guard: never replaces a snapshot that has workouts with a db that has
  /// none (a caller that ignored [RestoreResult.retryLater] would otherwise
  /// overwrite the only backup with an empty db). Returns false then too.
  /// Deleted (tombstoned) workouts count as rows here on purpose: deleting
  /// the only workout must not freeze the backup.
  bool writeSnapshot(String path) {
    if (_workoutCount(db) == 0 && _snapshotWorkouts(path) > 0) return false;
    final tmp = File('$path.tmp'); // same dir: rename stays atomic
    tmp.parent.createSync(recursive: true);
    if (tmp.existsSync()) tmp.deleteSync();
    try {
      db.execute('VACUUM INTO ?', [tmp.path]);
    } on SqliteException catch (e) {
      if (tmp.existsSync()) tmp.deleteSync();
      if ((e.resultCode & 0xff) == 5 || (e.resultCode & 0xff) == 6) {
        return false; // SQLITE_BUSY / SQLITE_LOCKED
      }
      rethrow;
    }
    final raf = tmp.openSync(mode: FileMode.append);
    try {
      raf.flushSync(); // fsync
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(path);
    fsyncDirectory(tmp.parent.path); // make the rename durable
    return true;
  }

  static int _workoutCount(Database d) =>
      d.select('SELECT count(*) AS n FROM workout').first['n'] as int;

  /// Workouts in an existing snapshot; 0 if none or unreadable.
  static int _snapshotWorkouts(String path) {
    if (!File(path).existsSync()) return 0;
    try {
      final d = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        return _workoutCount(d);
      } finally {
        d.close();
      }
    } on SqliteException {
      return 0;
    }
  }

  /// Before [SqliteStore.open]: if [dbPath] is missing and [snapshotPath]
  /// exists (a fresh install restored by Auto Backup), put the snapshot in
  /// place, but only after `PRAGMA integrity_check` says ok and its schema
  /// is one this build can open. Stray `-wal`/`-shm`/`-journal` files of the
  /// missing db are deleted first so they cannot be replayed onto it. The
  /// snapshot is kept after a restore.
  ///
  /// The snapshot may be the user's only copy, so it is never deleted:
  /// definite corruption (check failed, SQLITE_CORRUPT/NOTADB, or a newer
  /// schema) moves it to `<dbPath>.refused-snapshot` and returns
  /// [RestoreResult.refused]; any other error (SQLite or file system, at any
  /// step) keeps it untouched and returns [RestoreResult.retryLater].
  static RestoreResult restoreSnapshotIfMissing(
    String dbPath,
    String snapshotPath,
  ) {
    if (File(dbPath).existsSync()) return RestoreResult.notNeeded;
    final snap = File(snapshotPath);
    if (!snap.existsSync()) return RestoreResult.notNeeded;
    final tmp = File('$dbPath.restore');
    try {
      for (final suffix in ['-wal', '-shm', '-journal']) {
        final f = File('$dbPath$suffix');
        if (f.existsSync()) f.deleteSync();
      }
      if (tmp.existsSync()) tmp.deleteSync();
      snap.copySync(tmp.path);
      bool? ok; // null = could not tell
      try {
        final check = sqlite3.open(tmp.path, mode: OpenMode.readOnly);
        try {
          final r = check.select('PRAGMA integrity_check');
          final v =
              check.select('PRAGMA user_version').first.columnAt(0) as int;
          ok =
              r.length == 1 &&
              r.first.columnAt(0) == 'ok' &&
              v >= 1 &&
              v <= latestSchemaVersion;
        } finally {
          check.close();
        }
      } on SqliteException catch (e) {
        final code = e.resultCode & 0xff;
        ok = (code == 11 || code == 26) ? false : null; // CORRUPT, NOTADB
      }
      if (ok != true) {
        tmp.deleteSync();
        if (ok == null) return RestoreResult.retryLater;
        // Keep every refused copy: never overwrite an earlier one.
        snap.renameSync(
          '$dbPath.refused-snapshot-${DateTime.now().millisecondsSinceEpoch}',
        );
        return RestoreResult.refused;
      }
      final raf = tmp.openSync(mode: FileMode.append);
      try {
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      tmp.renameSync(dbPath);
      fsyncDirectory(tmp.parent.path);
      return RestoreResult.restored;
    } on FileSystemException {
      // Any I/O failure: the snapshot is never touched here. Best-effort
      // cleanup of our own tmp only.
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on FileSystemException {
        // ignore
      }
      return RestoreResult.retryLater;
    }
  }

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
      if (!db.autocommit) db.execute('ROLLBACK');
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
      'snapshot_json, edited_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(uuid) DO UPDATE SET '
      'gym_id = excluded.gym_id, type_id = excluded.type_id, '
      'muscles = excluded.muscles, started_at_ms = excluded.started_at_ms, '
      'tz_offset_min = excluded.tz_offset_min, '
      'ended_at_ms = excluded.ended_at_ms, paused_ms = excluded.paused_ms, '
      'app_version = excluded.app_version, swaps = excluded.swaps, '
      'snapshot_json = coalesce(excluded.snapshot_json, snapshot_json), '
      // deleted_at_ms is never touched here: a re-save keeps the tombstone.
      'edited_at_ms = coalesce(excluded.edited_at_ms, edited_at_ms)',
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
        w.editedAtMs,
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
          s.completion?.wire,
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

  /// Unfiltered on purpose: true for deleted uuids too (recovery).
  @override
  bool hasWorkout(String uuid) =>
      db.select('SELECT 1 FROM workout WHERE uuid = ?', [uuid]).isNotEmpty;

  // The only two readers of workout rows for history. Every derived stat
  // reads through them, so the deleted_at_ms filter here is the whole of
  // soft delete (test: no other `FROM workout` reader).
  @override
  WorkoutRecord? workout(String uuid) {
    final rows = db.select(
      'SELECT * FROM workout WHERE uuid = ? AND deleted_at_ms IS NULL',
      [uuid],
    );
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
        'SELECT * FROM set_row WHERE workout_uuid IN '
        '(SELECT uuid FROM workout WHERE deleted_at_ms IS NULL) '
        'ORDER BY workout_uuid, exercise_position, set_ordinal',
      ),
    );
    return _readWorkouts(
      db.select(
        'SELECT * FROM workout WHERE deleted_at_ms IS NULL '
        'ORDER BY started_at_ms, uuid',
      ),
      sets,
    );
  }

  @override
  bool deleteWorkout(String uuid, int atMs) => _tx(() {
    db.execute(
      'UPDATE workout SET deleted_at_ms = ? '
      'WHERE uuid = ? AND deleted_at_ms IS NULL',
      [atMs, uuid],
    );
    return db.updatedRows == 1;
  });

  @override
  bool restoreWorkout(String uuid) => _tx(() {
    db.execute(
      'UPDATE workout SET deleted_at_ms = NULL '
      'WHERE uuid = ? AND deleted_at_ms IS NOT NULL',
      [uuid],
    );
    return db.updatedRows == 1;
  });

  @override
  List<String> deletedWorkoutUuids() => [
    for (final r in db.select(
      'SELECT uuid FROM workout WHERE deleted_at_ms IS NOT NULL '
      'ORDER BY deleted_at_ms, uuid',
    ))
      r['uuid'] as String,
  ];

  /// Unfiltered on purpose (deleted workouts keep HR for undo).
  @override
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
          completion: r['completion'] == null
              ? null
              : Completion.fromWire(r['completion'] as String),
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
        editedAtMs: r['edited_at_ms'] as int?,
        sets: sets[r['uuid'] as String] ?? const [],
      ),
  ];
}
