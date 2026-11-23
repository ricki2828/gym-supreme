// R7 migration fixture generator. It ran ONCE, on the v0.1.0-dogfood tag (4c9f1a6), in a worktree:
//   git worktree add --detach <dir> v0.1.0-dogfood; cd <dir>/packages/gym_engine
//   dart run tool/make_v01_fixture.dart <out>   (then copy the three outputs here)
// Never re-run it on newer code: the fixture must stay data written by the 0.1 store.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';

void main(List<String> args) {
  final out = args.single;
  final db = '$out/v0_1.db';
  for (final f in [db, '$db-wal', '$db-shm']) {
    if (File(f).existsSync()) File(f).deleteSync();
  }
  final catalog = Catalog.fromJson(
    File('../../assets/exercises_taxonomy.json').readAsStringSync(),
    File('../../assets/exercises.json').readAsStringSync(),
  );
  var now = DateTime.utc(2026, 11, 23, 7).millisecondsSinceEpoch;
  final store = SqliteStore.open(db);
  final engine = GymEngine(
    catalog: catalog,
    store: store,
    nowMs: () => now,
    tzOffsetMin: () => 480,
    random: Random(7),
  );
  engine.saveSettings(
    const Settings(
      bodyweightG: 82500,
      defaultMinutes: 40,
      restCompoundS: 110,
      restIsolationS: 70,
    ),
  );
  final condo = engine.gymFromPreset('condo', name: 'Condo');
  engine.saveGym(condo);
  final hotel = engine.gymFromPreset('condo', name: 'Hotel gym – 2nd floor');
  engine.saveGym(hotel);

  // Varied workouts: types, both gyms, adjusted loads/reps, a skipped set, a swap, HR.
  final specs = <(String gymId, String? typeId, List<String> muscles)>[
    (condo.id, 'push', ['chest', 'triceps']),
    (condo.id, 'pull', ['lats', 'biceps']),
    (hotel.id, null, ['quads']),
    (condo.id, 'push', ['chest']),
  ];
  for (final (i, (gymId, typeId, muscles)) in specs.indexed) {
    final plan = engine.suggest(
      gymId: gymId,
      muscleIds: muscles,
      minutes: 30,
      typeId: typeId,
      seed: i,
    );
    var s = Session.start(
      plan,
      nowMs: now,
      tzOffsetMin: i.isEven ? 480 : -300,
      appVersion: '0.1.0',
      random: Random(100 + i),
    );
    if (i == 1 && plan.items.length > 1) {
      s = Session.swap(s, 1, plan.items.last);
    }
    var n = 0;
    for (final e in s.exercises) {
      for (final x in e.sets) {
        now += 95000 + 7000 * n;
        n++;
        if (i == 0 && n == 3) {
          s = Session.skip(s, x.setId, nowMs: now);
          continue;
        }
        final reps = (x.targetReps ?? 8) + (n % 3) - 1;
        s = x.targetLoadG == null && e.loadKind != 'bodyweight'
            ? Session.done(
                s,
                x.setId,
                nowMs: now,
                loadG: 10000 + 2500 * (n % 4),
                reps: reps,
              )
            : Session.done(s, x.setId, nowMs: now, reps: reps);
      }
    }
    s = Session.finish(s, nowMs: now += 60000);
    final hr = i == 1
        ? [
            for (var t = 0; t < 12; t++)
              HrSample(s.startedAtMs + t * 10000, 95 + t * 3),
          ]
        : const <HrSample>[];
    engine.saveFinished(s, hr: hr);
    now += Duration(days: 1 + i).inMilliseconds;
  }
  store.checkpoint();

  // Engine-level read-back (what 0.1 shows him).
  final rows = engine.history(limit: 50);
  final expect = {
    'made_by': 'v0.1.0-dogfood (4c9f1a6), packages/gym_engine/tool/make_v01_fixture.dart',
    'gyms': [
      for (final g in engine.gyms())
        {'id': g.id, 'name': g.name, 'kit': g.kit.length},
    ],
    'settings': engine.settings().toJson(),
    'sessions_total': engine.counters().sessionsTotal,
    'history': [
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
    ],
  };
  // Table-level dump: every 0.1 table, every 0.1 column, rows in key order. The test compares the
  // migrated db against it with plain SQL, independent of the engine API.
  final tables = [
    for (final r in store.db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ))
      r['name'] as String,
  ];
  final dump = <String, Object?>{
    'user_version': store.db.select('PRAGMA user_version').first.columnAt(0),
  };
  for (final t in tables) {
    final cols = [
      for (final c in store.db.select('PRAGMA table_info($t)'))
        c['name'] as String,
    ];
    final rs = store.db.select(
      'SELECT ${cols.join(', ')} FROM $t ORDER BY ${cols.join(', ')}',
    );
    dump[t] = {
      'columns': cols,
      'rows': [
        for (final r in rs) [for (final c in cols) r[c]],
      ],
    };
  }
  store.close();
  const enc = JsonEncoder.withIndent('  ');
  File('$out/v0_1_expect.json').writeAsStringSync('${enc.convert(expect)}\n');
  File('$out/v0_1_tables.json').writeAsStringSync('${enc.convert(dump)}\n');
  // The caller pins `sha256sum v0_1.db` in v0_1.db.sha256.
  stdout.writeln('wrote ${rows.length} workouts, tables ${tables.join(',')}');
}
