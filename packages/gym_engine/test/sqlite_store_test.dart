import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

WorkoutRecord workout(String uuid, {int sets = 2, String gym = 'g1'}) =>
    WorkoutRecord(
      uuid: uuid,
      gymId: gym,
      typeId: 'push',
      muscles: const ['chest'],
      startedAtMs: 1000,
      tzOffsetMin: 480,
      endedAtMs: 5000,
      pausedMs: 10,
      appVersion: '0.1.0',
      sets: [
        for (var i = 0; i < sets; i++)
          SetRecord(
            setId: '$uuid:$i',
            exerciseId: 'dumbbell-bench-press',
            exerciseName: 'Dumbbell Bench Press',
            exercisePosition: 0,
            setOrdinal: i + 1,
            loadG: 22500,
            reps: 10,
            completion: Completion.tapUnchanged,
            source: i == 0 ? SetSource.lockscreen : SetSource.app,
            startedAtMs: 1000 + i,
            endedAtMs: 2000 + i,
            offsetMs: 990 + i,
            skipped: i == 1,
            blockJson: i == 1 ? '{"type":"emom"}' : null,
          ),
      ],
    );

void main() {
  test('fresh database migrates to the latest version', () {
    final s = SqliteStore.inMemory();
    expect(s.schemaVersion, latestSchemaVersion);
    expect(latestSchemaVersion, 1);
  });

  test('a newer database is refused, not downgraded', () {
    final db = sqlite3.openInMemory()..execute('PRAGMA user_version = 99');
    expect(() => SqliteStore.migrate(db), throwsStateError);
  });

  test('workout round-trips every field (R6 ghost fields included)', () {
    final s = SqliteStore.inMemory();
    final w = workout('w1');
    s.upsertWorkout(w, snapshotJson: '{}', hr: const [HrSample(1500, 120)]);
    final r = s.workout('w1')!;
    expect(r.gymId, 'g1');
    expect(r.typeId, 'push');
    expect(r.muscles, ['chest']);
    expect(r.pausedMs, 10);
    expect(r.appVersion, '0.1.0');
    expect(r.sets, hasLength(2));
    final a = r.sets[0];
    expect(
      [a.setOrdinal, a.offsetMs, a.loadG, a.reps, a.source, a.completion],
      [1, 990, 22500, 10, SetSource.lockscreen, Completion.tapUnchanged],
    );
    expect(r.sets[1].skipped, isTrue);
    expect(r.sets[1].blockJson, '{"type":"emom"}');
    expect(s.hrSamples('w1').single.bpm, 120);
  });

  test('upsert by uuid is idempotent and replaces children', () {
    final s = SqliteStore.inMemory();
    s.upsertWorkout(workout('w1', sets: 3), hr: const [HrSample(1, 1)]);
    s.upsertWorkout(workout('w1', sets: 1));
    expect(s.workouts(), hasLength(1));
    expect(s.workout('w1')!.sets, hasLength(1));
    expect(s.hrSamples('w1'), hasLength(1)); // a re-save keeps HR
  });

  test('a failing upsert rolls back whole (one transaction)', () {
    final s = SqliteStore.inMemory();
    s.upsertWorkout(workout('w1'));
    // Same set ids as w1 → PK clash on set_row after the workout row insert.
    final clash = WorkoutRecord(
      uuid: 'w2',
      gymId: 'g1',
      startedAtMs: 2000,
      tzOffsetMin: 0,
      endedAtMs: 3000,
      sets: workout('w1').sets,
    );
    expect(() => s.upsertWorkout(clash), throwsA(isA<SqliteException>()));
    expect(s.hasWorkout('w2'), isFalse);
    expect(s.workout('w1')!.sets, hasLength(2));
  });

  test('gyms and kit round-trip; delete keeps workouts', () {
    final s = SqliteStore.inMemory();
    final g = Gym(
      id: 'g1',
      name: 'Condo',
      presetId: 'condo',
      createdAtMs: 5,
      kit: const {
        'dumbbells': KitItem(
          equipmentId: 'dumbbells',
          source: KitSource.preset,
          confirmed: false,
          weightsG: [2000, 4000],
        ),
      },
    );
    s.upsertGym(g);
    s.upsertGym(
      g.toggle('leg-extension').withWeights('dumbbells', [6000, 2000]),
    );
    final back = s.gym('g1')!;
    expect(back.kit.keys, unorderedEquals(['dumbbells', 'leg-extension']));
    expect(back.kit['dumbbells']!.weightsG, [2000, 6000]);
    expect(back.kit['dumbbells']!.source, KitSource.preset);
    expect(back.kit['dumbbells']!.confirmed, isTrue);
    s.upsertWorkout(workout('w1'));
    s.deleteGym('g1');
    expect(s.gyms(), isEmpty);
    expect(s.hasWorkout('w1'), isTrue);
  });

  test('settings and raw settings', () {
    final s = SqliteStore.inMemory();
    expect(s.settings().defaultMinutes, 45);
    s.saveSettings(const Settings(bodyweightG: 80000, defaultMinutes: 30));
    expect(s.settings().bodyweightG, 80000);
    expect(s.setting('rotation'), isNull);
    s.saveSetting('rotation', '{"order":["push","pull"],"next":1}');
    expect(s.setting('rotation'), contains('pull'));
    expect(() => s.saveSetting('settings', '{}'), throwsArgumentError);
  });

  test('file database: WAL, survives reopen, checkpoint', () {
    final dir = Directory.systemTemp.createTempSync('gymdb');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/gym.db';
    final a = SqliteStore.open(path);
    a.upsertWorkout(workout('w1'));
    a.checkpoint();
    a.close();
    final b = SqliteStore.open(path);
    expect(b.workout('w1')!.sets, hasLength(2));
    expect(b.schemaVersion, latestSchemaVersion);
    b.close();
  });

  test('every past schema fixture migrates and reads (R7)', () {
    final dir = Directory('test/fixtures/db');
    final files = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.sql'),
    );
    expect(files, isNotEmpty);
    for (final f in files) {
      final db = sqlite3.openInMemory()..execute(f.readAsStringSync());
      SqliteStore.migrate(db);
      final v = db.select('PRAGMA user_version').first.columnAt(0);
      expect(v, latestSchemaVersion, reason: f.path);
      expect(
        db.select('SELECT count(*) AS n FROM set_row').first['n'],
        greaterThan(0),
      );
      db.close();
    }
  });
}
