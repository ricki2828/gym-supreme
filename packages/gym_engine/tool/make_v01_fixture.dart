// R7 migration fixture generator. It ran ONCE, on the v0.1.0-dogfood tag (4c9f1a6), in a worktree:
//   git worktree add --detach <dir> v0.1.0-dogfood; cd <dir>/packages/gym_engine
//   dart run tool/make_v01_fixture.dart <out>   (then copy v0_1.db + v0_1_expect.json here)
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
  final gym = engine.gymFromPreset('condo', name: 'Condo');
  engine.saveGym(gym);
  for (final (i, muscles) in [
    ['chest'],
    ['lats'],
    ['quads'],
  ].indexed) {
    final plan = engine.suggest(
      gymId: gym.id,
      muscleIds: muscles,
      minutes: 30,
      seed: i,
    );
    var s = Session.start(
      plan,
      nowMs: now,
      tzOffsetMin: 480,
      appVersion: '0.1.0',
      random: Random(i),
    );
    for (final e in s.exercises) {
      for (final x in e.sets) {
        now += 120000;
        s = x.targetLoadG == null && e.loadKind != 'bodyweight'
            ? Session.done(
                s,
                x.setId,
                nowMs: now,
                loadG: 12500,
                reps: x.targetReps,
              )
            : Session.done(s, x.setId, nowMs: now, reps: x.targetReps);
      }
    }
    s = Session.finish(s, nowMs: now += 60000);
    engine.saveFinished(s);
    now += const Duration(days: 2).inMilliseconds;
  }
  store.checkpoint();
  final rows = engine.history(limit: 50);
  final expect = {
    'made_by': 'v0.1.0-dogfood (4c9f1a6), packages/gym_engine/tool/make_v01_fixture.dart',
    'gyms': [
      for (final g in engine.gyms()) {'id': g.id, 'name': g.name},
    ],
    'sessions_total': engine.counters().sessionsTotal,
    'history': [
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
    ],
  };
  store.close();
  File('$out/v0_1_expect.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(expect)}\n',
  );
  stdout.writeln('wrote $db and v0_1_expect.json: ${rows.length} workouts');
}
