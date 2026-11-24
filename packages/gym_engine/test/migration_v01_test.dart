import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// R7: every APK after 0.1 must open data written by the 0.1 store, intact.
///
/// test/fixtures/db/v0_1.db was written by the v0.1.0-dogfood code
/// (tool/make_v01_fixture.dart, run once on that tag): 2 gyms, settings, 4
/// typed workouts in two time zones with a swap, a skipped set, varied loads
/// and HR samples. v0_1_tables.json is every 0.1 table and column as 0.1 wrote
/// it; v0_1_expect.json is what the 0.1 engine read back. This build opens a
/// copy (running any newer migrations) and must return the same rows. If a
/// future migration transforms data on purpose, update this test with the
/// mapping; never regenerate the fixture on newer code.
const fixtures = 'test/fixtures/db';

Map<String, dynamic> json(String name) =>
    jsonDecode(File('$fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

String freshCopy() {
  final dir = Directory.systemTemp.createTempSync('gs-r7');
  addTearDown(() => dir.deleteSync(recursive: true));
  final db = '${dir.path}/gym.db';
  File('$fixtures/v0_1.db').copySync(db);
  return db;
}

void main() {
  test('the fixture is the pinned 0.1 database (schema v1)', () {
    final bytes = File('$fixtures/v0_1.db').readAsBytesSync();
    expect(
      sha256.convert(bytes).toString(),
      File('$fixtures/v0_1.db.sha256').readAsStringSync().trim(),
    );
    final raw = sqlite3.open(freshCopy());
    addTearDown(raw.close);
    expect(raw.select('PRAGMA user_version').first.columnAt(0), 1);
    // The dump is pinned too: it must match the raw (unmigrated) 0.1 db, so
    // nobody can edit it to fit a broken migration.
    final want = json('v0_1_tables.json');
    for (final t in want.keys.where((k) => k != 'user_version')) {
      final spec = want[t] as Map<String, dynamic>;
      final cols = (spec['columns'] as List).cast<String>();
      final rows = raw.select(
        'SELECT ${cols.join(', ')} FROM $t ORDER BY ${cols.join(', ')}',
      );
      expect(
        [
          for (final r in rows) [for (final c in cols) r[c]],
        ],
        spec['rows'],
        reason: 'dump vs raw 0.1 db, table $t',
      );
    }
    // The variety the fixture exists for is really in it.
    expect(
      raw
          .select('SELECT count(*) FROM set_row WHERE skipped = 1')
          .first
          .columnAt(0),
      greaterThan(0),
    );
    expect(
      raw.select('SELECT max(swaps) FROM workout').first.columnAt(0),
      greaterThan(0),
    );
    expect(
      raw.select('SELECT count(*) FROM hr_sample').first.columnAt(0),
      greaterThan(0),
    );
    expect(
      raw
          .select('SELECT count(DISTINCT gym_id) FROM workout')
          .first
          .columnAt(0),
      2,
    );
    expect(File('$fixtures/v0_1.db-wal').existsSync(), isFalse);
  });

  test('every 0.1 table and column reads back unchanged after migration', () {
    final want = json('v0_1_tables.json');
    final store = SqliteStore.open(freshCopy()); // runs any newer migrations
    addTearDown(store.close);
    final tables = want.keys.where((k) => k != 'user_version');
    expect(
      tables,
      containsAll([
        'gym',
        'gym_item',
        'setting',
        'workout',
        'set_row',
        'hr_sample',
      ]),
    );
    for (final t in tables) {
      final spec = want[t] as Map<String, dynamic>;
      final cols = (spec['columns'] as List).cast<String>();
      final rows = store.db.select(
        'SELECT ${cols.join(', ')} FROM $t ORDER BY ${cols.join(', ')}',
      );
      expect(
        [
          for (final r in rows) [for (final c in cols) r[c]],
        ],
        spec['rows'],
        reason: 'table $t',
      );
    }
  });

  test('M1: 0.1 db migrates to v2, new columns NULL, fixture untouched', () {
    final pinned = File('$fixtures/v0_1.db.sha256').readAsStringSync().trim();
    final store = SqliteStore.open(freshCopy());
    addTearDown(store.close);
    expect(store.schemaVersion, 2);
    final n = store.db.select('SELECT count(*) FROM workout').first.columnAt(0);
    expect(n, greaterThan(0));
    expect(
      store.db
          .select(
            'SELECT count(*) FROM workout '
            'WHERE deleted_at_ms IS NULL AND edited_at_ms IS NULL',
          )
          .first
          .columnAt(0),
      n,
    );
    expect(store.deletedWorkoutUuids(), isEmpty);
    expect(store.workouts(), hasLength(n as int));
    expect([
      for (final w in store.workouts()) w.editedAtMs,
    ], everyElement(isNull));
    // Migrating a copy never touches the pinned fixture.
    expect(
      sha256.convert(File('$fixtures/v0_1.db').readAsBytesSync()).toString(),
      pinned,
    );
  });

  test('M2: a db stamped v3 is refused, not opened or downgraded', () {
    final path = freshCopy();
    sqlite3.open(path)
      ..execute('PRAGMA user_version = 3')
      ..close();
    expect(() => SqliteStore.open(path), throwsStateError);
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    expect(raw.select('PRAGMA user_version').first.columnAt(0), 3);
  });

  test('the engine shows the same gyms, settings and history as 0.1', () {
    final want = json('v0_1_expect.json');
    final catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
    final store = SqliteStore.open(freshCopy());
    addTearDown(store.close);
    final engine = GymEngine(catalog: catalog, store: store);
    expect([
      for (final g in engine.gyms())
        {'id': g.id, 'name': g.name, 'kit': g.kit.length},
    ], want['gyms']);
    expect(engine.settings().toJson(), want['settings']);
    expect(engine.counters().sessionsTotal, want['sessions_total']);
    final rows = engine.history(limit: 50);
    expect([
      for (final r in rows)
        {
          'uuid': r.uuid,
          'started_at_ms': r.startedAtMs,
          'tz_offset_min': r.tzOffsetMin,
          'gym_id': r.gymId,
          'gym_name': r.gymName,
          'type_id': r.typeId,
          'duration_ms': r.durationMs,
          'volume_kg': r.volumeKg,
          'set_count': r.setCount,
        },
    ], want['history']);
    for (final r in rows) {
      expect(engine.isStored(r.uuid), isTrue);
      expect(engine.summary(r.uuid).uuid, r.uuid);
    }
  });
}
