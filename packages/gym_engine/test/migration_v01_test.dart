import 'dart:convert';
import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:test/test.dart';

/// R7: every APK after 0.1 must open data written by the 0.1 store, intact.
/// test/fixtures/db/v0_1.db was written by the v0.1.0-dogfood code
/// (tool/make_v01_fixture.dart, run once on that tag) and v0_1_expect.json is
/// what the 0.1 engine read back from it. This build opens a copy (running any
/// newer migrations) and must read back exactly the same.
void main() {
  test('0.1 data opens intact in this build (R7)', () {
    final dir = Directory.systemTemp.createTempSync('gs-r7');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = '${dir.path}/gym.db';
    File('test/fixtures/db/v0_1.db').copySync(db);
    final want = jsonDecode(
      File('test/fixtures/db/v0_1_expect.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    final catalog = Catalog.fromJson(
      File('../../assets/exercises_taxonomy.json').readAsStringSync(),
      File('../../assets/exercises.json').readAsStringSync(),
    );
    final store = SqliteStore.open(db);
    addTearDown(store.close);
    final engine = GymEngine(catalog: catalog, store: store);

    expect([
      for (final g in engine.gyms()) {'id': g.id, 'name': g.name},
    ], want['gyms']);
    expect(engine.counters().sessionsTotal, want['sessions_total']);
    final rows = engine.history(limit: 50);
    expect([
      for (final r in rows)
        {
          'uuid': r.uuid,
          'started_at_ms': r.startedAtMs,
          'tz_offset_min': r.tzOffsetMin,
          'gym_id': r.gymId,
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

  test('the fixture is a 0.1 database, not regenerated', () {
    final want = jsonDecode(
      File('test/fixtures/db/v0_1_expect.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(want['made_by'], startsWith('v0.1.0-dogfood (4c9f1a6)'));
    expect(File('test/fixtures/db/v0_1.db-wal').existsSync(), isFalse);
  });
}
