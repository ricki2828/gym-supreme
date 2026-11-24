// 0.3 I1: import, the counterpart of export (plan gym-supreme-0.3 §2 I1).
// Every test runs on both stores; SQLite-only checks are marked. The
// fixture (six workouts, two gyms) comes from delete_edit_test.dart.
import 'dart:convert';

import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:test/test.dart';

import 'delete_edit_test.dart' as d;

GymEngine engineOn(HistoryStore store, {int Function()? now}) => GymEngine(
  catalog: d.catalog,
  store: store,
  nowMs: now ?? () => d.monday + 2 * 3600 * 1000,
  tzOffsetMin: () => 480,
);

Map<String, Object?> decode(String json) =>
    (jsonDecode(json) as Map).cast<String, Object?>();

/// The export minus what legitimately differs between two phones.
Map<String, Object?> comparable(GymEngine e) {
  final j = decode(e.export(appVersion: 'x').json)..remove('exported_at_ms');
  return j;
}

/// Everything a stat reads, keyed by the source rig's gym ids.
String view(GymEngine e, String g1, String g2) => jsonEncode({
  'history': [
    for (final h in e.history()) [h.uuid, h.gymName, h.volumeKg, h.setCount],
  ],
  'muscles': {
    for (final m in e.muscleStatus(gymId: g1).values)
      m.muscleId: [m.lastTrainedAtMs, m.daysSince, m.resting],
  },
  'summaries': {
    for (final w in e.store.workouts())
      w.uuid: () {
        final s = e.summary(w.uuid);
        return [
          s.volumeKg,
          s.volumeDeltaPct,
          s.weeklyStreak,
          [for (final p in s.pbs) '${p.exerciseId}/${p.kind}/${p.loadG}'],
        ];
      }(),
  },
  'last': [
    for (final g in [g1, g2])
      for (final x in [d.bench, d.row])
        e.lastTime(gymId: g, exerciseId: x)?.workoutUuid,
  ],
  'suggest': [
    for (final g in [g1, g2])
      for (final item
          in e.suggest(gymId: g, muscleIds: ['chest', 'lats'], seed: 3).items)
        [
          item.exerciseId,
          item.reason,
          [for (final s in item.sets) '${s.loadG}x${s.reps}'],
        ],
  ],
  'counters': () {
    final c = e.counters();
    return [c.sessionsTotal, c.sessionsLast14Days, c.doneSets, c.oneTapRate];
  }(),
});

void main() {
  test('importMaxSchemaVersion tracks the SQLite schema', () {
    expect(importMaxSchemaVersion, latestSchemaVersion);
    expect(importMaxExportFormat, exportFormat);
  });

  for (final (name, make) in <(String, HistoryStore Function())>[
    ('memory store', MemoryStore.new),
    ('sqlite store', SqliteStore.inMemory),
  ]) {
    group(name, () => cases(make));
  }

  group('sqlite only', () {
    test('a database error mid-batch writes nothing (set id clash)', () {
      final src = d.Rig(SqliteStore.inMemory());
      final file = src.engine.export(appVersion: 'x').json;
      final dst = engineOn(SqliteStore.inMemory());
      // A local workout already owns w6's first set id (set_id is a global
      // primary key). w1..w5 insert first; w6 then fails inside the
      // transaction.
      dst.store.upsertWorkout(
        d.rec('local', 'gx', 'push', d.monday - 30 * d.day, [
          d.done(d.bench, 10000, 10),
        ]),
      );
      final clash = decode(file);
      final w6 = (clash['workouts'] as List).last as Map;
      ((w6['sets'] as List).first as Map)['set_id'] = 'local:0';
      final before = comparable(dst);
      expect(
        () => dst.importBundle(jsonEncode(clash)),
        throwsA(isA<ImportRefused>()),
      );
      expect(comparable(dst), before);
      expect(dst.store.workouts().map((w) => w.uuid), ['local']);
      expect(dst.gyms(), isEmpty);
    });
  });

  group('memory store only', () {
    test('a store error after workouts were written rolls them back', () {
      final src = d.Rig(MemoryStore());
      final file = src.engine.export(appVersion: 'x').json;
      final store = _FailingGymStore();
      final dst = engineOn(store);
      expect(() => dst.importBundle(file), throwsA(isA<ImportRefused>()));
      expect(store.workouts(), isEmpty);
      expect(store.hrByWorkout.values.expand((x) => x), isEmpty);
      expect(store.gyms(), isEmpty);
    });
  });
}

class _FailingGymStore extends MemoryStore {
  @override
  void upsertGym(Gym gym) => throw StateError('disk full');
}

void cases(HistoryStore Function() make) {
  /// The source phone: six workouts with HR, one edited, non-default
  /// settings.
  d.Rig source() {
    final r = d.Rig(make());
    r.engine.editWorkout('w5', [
      WorkoutEdit.setValues(r.sid('w5', 0), loadG: 23000, reps: 9),
    ]);
    r.store.saveSettings(
      const Settings(bodyweightG: 82000, defaultMinutes: 50),
    );
    return r;
  }

  test('round trip: export -> empty store -> import = same stats', () {
    final src = source();
    final file = src.engine.export(appVersion: 'x').json;
    final dst = engineOn(make());
    final c = dst.importBundle(file);
    expect(c.workoutsAdded, 6);
    expect(c.skippedExisting + c.skippedDeleted, 0);
    expect(c.gymsAdded, 2);
    expect(c.hrSamplesAdded, 6);
    expect(c.settingsRestored, isTrue);
    expect(view(dst, src.g1, src.g2), view(src.engine, src.g1, src.g2));
    // Nothing excluded here (no deletes, settings filled): the whole
    // export matches.
    expect(comparable(dst), comparable(src.engine));
    expect(dst.store.workout('w5')!.editedAtMs, src.w('w5').editedAtMs);
    expect(dst.store.hrSamples('w1').map((h) => h.bpm), [120]);
  });

  test('re-import is a no-op', () {
    final file = source().engine.export(appVersion: 'x').json;
    final dst = engineOn(make());
    dst.importBundle(file);
    final after = comparable(dst);
    final c = dst.importBundle(file);
    expect(c.workoutsAdded, 0);
    expect(c.skippedExisting, 6);
    expect(c.gymsAdded, 0);
    expect(c.gymsKept, 2);
    expect(c.hrSamplesAdded, 0);
    expect(c.settingsRestored, isFalse);
    expect(c.isNoOp, isTrue);
    expect(comparable(dst), after);
  });

  test('partial overlap adds only the new ones; a local edit stays', () {
    final src = source();
    final full = src.engine.export(appVersion: 'x').json;
    final half = decode(full);
    half['workouts'] = (half['workouts'] as List).take(3).toList();
    final dst = engineOn(make());
    expect(dst.importBundle(jsonEncode(half)).workoutsAdded, 3);
    // He edits w2 on the new phone; the file's older w2 must not revert it.
    dst.editWorkout('w2', [
      WorkoutEdit.setValues('w2:0', loadG: 30000, reps: 5),
    ]);
    final preview = dst.previewImport(full);
    final c = dst.importBundle(full);
    for (final x in [preview, c]) {
      expect(x.workoutsAdded, 3);
      expect(x.skippedExisting, 3);
    }
    expect(dst.store.workouts().map((w) => w.uuid), [
      'w1', 'w2', 'w3', 'w4', 'w5', 'w6', //
    ]);
    expect(dst.store.workout('w2')!.sets.first.loadG, 30000);
  });

  test('a uuid deleted here is skipped, never resurrected', () {
    final file = source().engine.export(appVersion: 'x').json;
    final dst = engineOn(make());
    dst.importBundle(file);
    expect(dst.deleteWorkout('w3'), isNotNull);
    final c = dst.importBundle(file);
    expect(c.skippedDeleted, 1);
    expect(c.skippedExisting, 5);
    expect(c.workoutsAdded, 0);
    expect(dst.store.workout('w3'), isNull);
    expect(dst.store.deletedWorkoutUuids(), ['w3']);
    expect(dst.history().map((h) => h.uuid), isNot(contains('w3')));
  });

  test('file tombstones are information only (plan: not imported)', () {
    final src = source();
    src.engine.deleteWorkout('w2');
    final file = src.engine.export(appVersion: 'x').json;
    expect(decode(file)['deleted_workout_uuids'], ['w2']);
    final dst = engineOn(make());
    final c = dst.importBundle(file);
    expect(c.deletedInFile, 1);
    expect(c.workoutsAdded, 5);
    expect(dst.store.deletedWorkoutUuids(), isEmpty);
    expect(dst.store.hasWorkout('w2'), isFalse);
    // Stats still match the source: w2 is gone on both.
    expect(view(dst, src.g1, src.g2), view(src.engine, src.g1, src.g2));
    // Named exclusions in the re-export: tombstones and their counter.
    final a = comparable(src.engine), b = comparable(dst);
    expect(a['deleted_workout_uuids'], ['w2']);
    expect(b['deleted_workout_uuids'], isEmpty);
    for (final m in [a, b]) {
      m.remove('deleted_workout_uuids');
      (m['counters'] as Map).remove('workouts_deleted');
    }
    expect(b, a);
  });

  test('a local live workout is never deleted by a file tombstone', () {
    final src = source();
    final first = src.engine.export(appVersion: 'x').json;
    src.engine.deleteWorkout('w4');
    final later = src.engine.export(appVersion: 'x').json;
    final dst = engineOn(make());
    dst.importBundle(first);
    final c = dst.importBundle(later);
    expect(c.skippedExisting, 5);
    expect(dst.store.workout('w4'), isNotNull);
  });

  test('export_format 1 (0.2.0) is accepted', () {
    final j = decode(source().engine.export(appVersion: 'x').json);
    // The 0.2.0 bundle (git show v0.2.0-dogfood:.../engine.dart): no
    // edited_at_ms, deleted_workout_uuids, workouts_deleted or hr.
    j['export_format'] = 1;
    j['schema_version'] = 1;
    j.remove('deleted_workout_uuids');
    (j['counters'] as Map).remove('workouts_deleted');
    for (final w in (j['workouts'] as List).cast<Map>()) {
      w
        ..remove('edited_at_ms')
        ..remove('hr');
    }
    final dst = engineOn(make());
    final c = dst.importBundle(jsonEncode(j));
    expect(c.exportFormat, 1);
    expect(c.workoutsAdded, 6);
    expect(c.hrSamplesAdded, 0);
    expect(dst.store.workout('w5')!.editedAtMs, isNull);
  });

  group('refused, nothing written', () {
    late String file;
    late GymEngine dst;
    late Map<String, Object?> before;

    setUp(() {
      file = source().engine.export(appVersion: 'x').json;
      // A phone with one workout, one gym and its own settings.
      dst = engineOn(make());
      final g = dst.gymFromPreset('condo', name: 'Mine');
      dst.saveGym(g);
      dst.store.upsertWorkout(
        d.rec('mine', g.id, 'push', d.monday - 20 * d.day, [
          d.done(d.bench, 10000, 10),
        ]),
      );
      before = comparable(dst);
    });

    void refused(String text, Matcher message) {
      expect(
        () => dst.previewImport(text),
        throwsA(isA<ImportRefused>().having((e) => e.message, 'm', message)),
      );
      expect(
        () => dst.importBundle(text),
        throwsA(isA<ImportRefused>().having((e) => e.message, 'm', message)),
      );
      expect(comparable(dst), before);
    }

    String edit(void Function(Map<String, Object?> j) f) {
      final j = decode(file);
      f(j);
      return jsonEncode(j);
    }

    Map<String, Object?> set0(Map<String, Object?> j) =>
        (((j['workouts'] as List).last as Map)['sets'] as List).first
            as Map<String, Object?>;

    test('malformed', () {
      refused('not json', contains('not a Gym Supreme export'));
      refused('[1,2]', contains('not a Gym Supreme export'));
      refused('{"workouts": []}', contains('no export_format'));
    });

    test('truncated', () {
      refused(file.substring(0, file.length ~/ 2), contains('cut short'));
      refused(file.substring(0, file.length - 1), contains('cut short'));
    });

    test('future format, schema or snapshot schema', () {
      refused(edit((j) => j['export_format'] = 3), contains('newer version'));
      refused(edit((j) => j['schema_version'] = 3), contains('newer version'));
      refused(edit((j) => j['snapshot_schema'] = 2), contains('newer version'));
    });

    test('a bad field anywhere refuses the whole file', () {
      refused(edit((j) => set0(j)['load_g'] = '20'), contains('load_g'));
      refused(edit((j) => set0(j)['load_g'] = 20.5), contains('load_g'));
      refused(edit((j) => set0(j)['kind'] = 'superset'), contains('kind'));
      refused(
        edit((j) => set0(j)['completion'] = 'maybe'),
        contains('completion'),
      );
      refused(
        edit((j) => set0(j)['skipped'] = true),
        contains('both skipped and done'),
      );
      refused(
        edit((j) => ((j['workouts'] as List).last as Map).remove('uuid')),
        contains('uuid'),
      );
      refused(
        edit(
          (j) => ((j['workouts'] as List).last as Map)['hr'] = [
            [1, 2, 3],
          ],
        ),
        contains('hr sample'),
      );
      refused(
        edit((j) => ((j['gyms'] as List).first as Map)['kit'] = 'x'),
        contains('kit'),
      );
    });

    test('duplicates inside the file', () {
      refused(
        edit((j) {
          final ws = j['workouts'] as List;
          ws.add(ws.first);
        }),
        contains('appears twice'),
      );
      refused(
        edit((j) => set0(j)['set_id'] = 'w1:0'),
        contains('appears twice'),
      );
    });
  });

  group('gyms, kit and settings', () {
    test('a gym id already here keeps its name and kit; new ones are added '
        'with kit', () {
      final src = source();
      final file = decode(src.engine.export(appVersion: 'x').json);
      final dst = engineOn(make());
      final mine = Gym(
        id: src.g1,
        name: 'My name',
        kit: const {'barbell': KitItem(equipmentId: 'barbell')},
      );
      dst.saveGym(mine);
      final c = dst.importBundle(jsonEncode(file));
      expect(c.gymsKept, 1);
      expect(c.gymsAdded, 1);
      expect(dst.gym(src.g1)!.name, 'My name');
      expect(dst.gym(src.g1)!.kit.keys, ['barbell']);
      final g2 = dst.gym(src.g2)!;
      expect(g2.name, 'Hotel');
      expect(g2.kit, src.engine.gym(src.g2)!.kit);
    });

    test('a workout whose gym is in no list still imports', () {
      final j = decode(source().engine.export(appVersion: 'x').json);
      ((j['workouts'] as List).first as Map)['gym_id'] = 'gone-gym';
      final dst = engineOn(make());
      dst.importBundle(jsonEncode(j));
      expect(dst.store.workout('w1')!.gymId, 'gone-gym');
      expect(dst.history().firstWhere((h) => h.uuid == 'w1').gymName, '');
    });

    test('his own settings are kept; defaults are filled from the file', () {
      final file = source().engine.export(appVersion: 'x').json;
      final mine = engineOn(make());
      mine.store.saveSettings(const Settings(restCompoundS: 90));
      expect(mine.previewImport(file).settingsRestored, isFalse);
      expect(mine.importBundle(file).settingsRestored, isFalse);
      expect(mine.store.settings().restCompoundS, 90);
      expect(mine.store.settings().bodyweightG, isNull);

      final fresh = engineOn(make());
      expect(fresh.previewImport(file).settingsRestored, isTrue);
      expect(fresh.store.settings().bodyweightG, isNull, reason: 'preview');
      expect(fresh.importBundle(file).settingsRestored, isTrue);
      expect(fresh.store.settings().bodyweightG, 82000);
      expect(fresh.store.settings().defaultMinutes, 50);
    });

    test('rotation is not imported', () {
      final src = source();
      src.store.saveSetting('rotation', '{"order":["push","pull"],"next":1}');
      final dst = engineOn(make());
      dst.importBundle(src.engine.export(appVersion: 'x').json);
      expect(dst.store.setting('rotation'), isNull);
    });
  });

  group('HR samples', () {
    test('exported with their workout and imported with it', () {
      final src = source();
      src.store.upsertWorkout(
        src.w('w6'),
        hr: [
          for (var i = 0; i < 5; i++)
            HrSample(d.monday + 10000 + i * 1000, 90 + i),
        ],
      );
      final j = decode(src.engine.export(appVersion: 'x').json);
      final w6 = (j['workouts'] as List).cast<Map>().last;
      expect((w6['hr'] as List).length, 6);
      final dst = engineOn(make());
      expect(dst.importBundle(jsonEncode(j)).hrSamplesAdded, 11);
      expect(
        dst.store.hrSamples('w6').map((h) => [h.tMs, h.bpm]),
        src.store.hrSamples('w6').map((h) => [h.tMs, h.bpm]),
      );
    });

    test('a skipped workout keeps its local HR untouched', () {
      final file = decode(source().engine.export(appVersion: 'x').json);
      for (final w in (file['workouts'] as List).cast<Map>()) {
        w['hr'] = [
          [d.monday, 199],
        ];
      }
      final dst = engineOn(make());
      dst.store.upsertWorkout(
        d.rec('w1', 'gx', 'push', d.monday - 14 * d.day, [
          d.done(d.bench, 20000, 10),
        ]),
        hr: const [HrSample(5, 60)],
      );
      final c = dst.importBundle(jsonEncode(file));
      expect(c.skippedExisting, 1);
      expect(c.hrSamplesAdded, 5);
      expect(dst.store.hrSamples('w1').map((h) => h.bpm), [60]);
    });

    test('a workout without HR exports no hr key', () {
      final dst = engineOn(make());
      dst.store.upsertWorkout(
        d.rec('a', 'gx', 'push', d.monday, [d.done(d.bench, 20000, 10)]),
      );
      final w = (decode(dst.export(appVersion: 'x').json)['workouts'] as List)
          .cast<Map>()
          .single;
      expect(w.containsKey('hr'), isFalse);
    });
  });

  test('preview writes nothing', () {
    final file = source().engine.export(appVersion: 'x').json;
    final dst = engineOn(make());
    final before = comparable(dst);
    final c = dst.previewImport(file);
    expect(c.workoutsAdded, 6);
    expect(c.gymsAdded, 2);
    expect(comparable(dst), before);
  });
}
