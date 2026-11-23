import 'dart:io';

import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:gym_engine/src/fsync_dir.dart';
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
      swaps: 2,
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
            completion: i == 1 ? null : Completion.tapUnchanged,
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
    expect(r.swaps, 2);
    expect(r.sets, hasLength(2));
    final a = r.sets[0];
    expect(
      [a.setOrdinal, a.offsetMs, a.loadG, a.reps, a.source, a.completion],
      [1, 990, 22500, 10, SetSource.lockscreen, Completion.tapUnchanged],
    );
    expect(r.sets[1].skipped, isTrue);
    expect(r.sets[1].completion, isNull);
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

  test('v1 fixture DDL equals migration v1 (R7: fresh = upgraded)', () {
    String schema(Database db) => db
        .select(
          "SELECT type, name, sql FROM sqlite_master "
          "WHERE name NOT LIKE 'sqlite_%' ORDER BY name",
        )
        .map(
          (r) =>
              '${r['type']}|${r['name']}|'
              '${(r['sql'] as String?)?.replaceAll(RegExp(r'\s+'), ' ')}',
        )
        .join('\n');
    final fresh = sqlite3.openInMemory();
    SqliteStore.migrate(fresh);
    final fixture = sqlite3.openInMemory()
      ..execute(File('test/fixtures/db/v1.sql').readAsStringSync());
    expect(schema(fixture), schema(fresh));
  });

  test(
    'every past schema fixture migrates and reads through the store (R7)',
    () {
      final files = Directory('test/fixtures/db')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'));
      expect(files, isNotEmpty);
      for (final f in files) {
        final store = SqliteStore.fromDatabase(
          sqlite3.openInMemory()..execute(f.readAsStringSync()),
        );
        expect(store.schemaVersion, latestSchemaVersion, reason: f.path);
        final w = store.workouts();
        expect(w, isNotEmpty, reason: f.path);
        expect(w.first.sets, isNotEmpty);
        expect(w.first.sets.first.offsetMs, isNotNull);
        expect(store.gyms(), isNotEmpty);
        expect(store.settings().bodyweightG, 80000);
        expect(store.hrSamples(w.first.uuid), isNotEmpty);
        store.close();
      }
    },
  );

  test('migrate is a no-op when re-run', () {
    final db = sqlite3.openInMemory();
    SqliteStore.migrate(db);
    SqliteStore.migrate(db);
    expect(
      db.select('PRAGMA user_version').first.columnAt(0),
      latestSchemaVersion,
    );
  });

  group('snapshot backup (#15)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gymsnap'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('round trip: write, lose the db, restore, read', () {
      final dbPath = '${dir.path}/gym.db';
      final snapPath = '${dir.path}/backup/gym-snapshot.db'; // dir made
      final a = SqliteStore.open(dbPath);
      a.upsertWorkout(workout('w1'), hr: const [HrSample(5, 99)]);
      expect(a.writeSnapshot(snapPath), isTrue);
      expect(a.writeSnapshot(snapPath), isTrue); // overwrite is fine
      expect(File('$snapPath.tmp').existsSync(), isFalse);
      a.close();
      for (final f in dir.listSync().whereType<File>()) {
        f.deleteSync(); // fresh install: db, wal, shm gone
      }
      File('$dbPath-wal').writeAsStringSync('stale'); // must be discarded
      expect(
        SqliteStore.restoreSnapshotIfMissing(dbPath, snapPath),
        RestoreResult.restored,
      );
      expect(File('$dbPath-wal').existsSync(), isFalse);
      expect(File(snapPath).existsSync(), isTrue); // kept
      final b = SqliteStore.open(dbPath);
      expect(b.workout('w1')!.sets, hasLength(2));
      expect(b.hrSamples('w1').single.bpm, 99);
      b.close();
      // db now present: never overwritten by the snapshot.
      expect(
        SqliteStore.restoreSnapshotIfMissing(dbPath, snapPath),
        RestoreResult.notNeeded,
      );
    });

    test('corrupt or junk snapshot is refused and the db stays missing', () {
      final dbPath = '${dir.path}/gym.db';
      final snapPath = '${dir.path}/snap.db';
      final a = SqliteStore.open('${dir.path}/src.db');
      for (var i = 0; i < 40; i++) {
        a.upsertWorkout(workout('w$i', sets: 20));
      }
      expect(a.writeSnapshot(snapPath), isTrue);
      a.close();
      // Damage pages past the header.
      final bytes = File(snapPath).readAsBytesSync();
      expect(bytes.length, greaterThan(8192));
      for (var i = 4096; i < bytes.length - 100; i += 7) {
        bytes[i] = 0xA5;
      }
      File(snapPath).writeAsBytesSync(bytes);
      expect(
        SqliteStore.restoreSnapshotIfMissing(dbPath, snapPath),
        RestoreResult.refused,
      );
      expect(File(snapPath).existsSync(), isFalse); // moved, not deleted
      expect(
        dir.listSync().where((f) => f.path.contains('refused-snapshot-')),
        hasLength(1),
      );
      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath.restore').existsSync(), isFalse);

      File(snapPath).writeAsStringSync('not a database at all');
      expect(
        SqliteStore.restoreSnapshotIfMissing(dbPath, snapPath),
        RestoreResult.refused,
      );
      expect(File(dbPath).existsSync(), isFalse);
    });

    test('a snapshot from a newer build is refused, not opened', () {
      final dbPath = '${dir.path}/gym.db';
      final snapPath = '${dir.path}/snap.db';
      final a = SqliteStore.open('${dir.path}/src.db');
      expect(a.writeSnapshot(snapPath), isTrue);
      a.close();
      sqlite3.open(snapPath)
        ..execute('PRAGMA user_version = 99')
        ..close();
      expect(
        SqliteStore.restoreSnapshotIfMissing(dbPath, snapPath),
        RestoreResult.refused,
      );
      expect(File(dbPath).existsSync(), isFalse);
    });

    test('an unreadable snapshot is kept for a retry (not deleted)', () {
      final dbPath = '${dir.path}/gym.db';
      final snapDir = Directory('${dir.path}/snapdir')..createSync();
      // A directory where the file should be: copy fails → retryLater.
      expect(
        SqliteStore.restoreSnapshotIfMissing(dbPath, snapDir.path),
        RestoreResult.notNeeded, // not a file: nothing to restore
      );
      final snapPath = '${dir.path}/snap.db';
      final a = SqliteStore.open('${dir.path}/src.db');
      expect(a.writeSnapshot(snapPath), isTrue);
      a.close();
      Directory('$dbPath.restore').createSync(); // blocks the tmp copy
      expect(
        SqliteStore.restoreSnapshotIfMissing(dbPath, snapPath),
        RestoreResult.retryLater,
      );
      expect(File(snapPath).existsSync(), isTrue);
      expect(File(dbPath).existsSync(), isFalse);
    });

    test(
      'writeSnapshot never replaces a snapshot with workouts by an empty db',
      () {
        final snapPath = '${dir.path}/snap.db';
        final full = SqliteStore.open('${dir.path}/full.db');
        full.upsertWorkout(workout('w1'));
        expect(full.writeSnapshot(snapPath), isTrue);
        full.close();
        final empty = SqliteStore.open('${dir.path}/empty.db');
        expect(empty.writeSnapshot(snapPath), isFalse);
        empty.close();
        final check = SqliteStore.open(snapPath);
        expect(check.hasWorkout('w1'), isTrue);
        check.close();
      },
    );

    test('directory fsync works on this platform', () {
      expect(fsyncDirectory(dir.path), Platform.isLinux || Platform.isAndroid);
      expect(fsyncDirectory('${dir.path}/missing'), isFalse);
    });

    test('no snapshot: nothing happens', () {
      expect(
        SqliteStore.restoreSnapshotIfMissing(
          '${dir.path}/gym.db',
          '${dir.path}/none.db',
        ),
        RestoreResult.notNeeded,
      );
    });
  });
}
