// 0.3 S1: starting weights (plan gym-supreme-0.3 §9). A weight typed once
// per lift seeds the first suggestion and ghost while the lift has no logged
// history; it is never history (no workout, PB, streak or counter). Every
// test runs on both stores; SQLite-only checks are marked. The fixture (six
// workouts, two gyms, bench and row only) comes from delete_edit_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:gym_engine/cut2.dart';
import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:test/test.dart';

import 'delete_edit_test.dart' as d;
import 'import_test.dart' show comparable, decode, view;

/// A dumbbell press with no history in the fixture (condo has dumbbells).
const incline = 'incline-dumbbell-press';

/// A stack lift with no history in the fixture.
const pushdown = 'triceps-pushdown';

void main() {
  for (final kind in ['memory', 'sqlite']) {
    group(kind, () {
      late d.Rig r;
      late Directory dir;

      HistoryStore make() => kind == 'memory'
          ? MemoryStore()
          : SqliteStore.open(
              '${dir.path}/db-${DateTime.now().microsecondsSinceEpoch}.db',
            );

      setUp(() {
        dir = Directory.systemTemp.createTempSync('gs-s1-');
        r = d.Rig(make());
      });
      tearDown(() {
        final s = r.store;
        if (s is SqliteStore) s.close();
        dir.deleteSync(recursive: true);
      });

      PlannedItem? item(String gymId, String exerciseId) => r.engine
          .suggest(
            gymId: gymId,
            muscleIds: const ['chest', 'front-delts', 'triceps'],
            typeId: 'push',
            minutes: 60,
          )
          .items
          .where((i) => i.exerciseId == exerciseId)
          .firstOrNull;

      group('store and validation', () {
        test('set, read, replace, clear', () {
          final e = r.engine;
          expect(e.startingWeights(), isEmpty);
          e.setStartingWeight(incline, 20000);
          e.setStartingWeight(pushdown, 30000);
          expect(e.startingWeights(), {incline: 20000, pushdown: 30000});
          e.setStartingWeight(incline, 22000);
          expect(e.startingWeights()[incline], 22000);
          e.setStartingWeight(incline, null);
          expect(e.startingWeights(), {pushdown: 30000});
          e.setStartingWeight(incline, null); // clearing nothing is fine
          expect(e.startingWeights(), {pushdown: 30000});
        });

        test('refuses unknown, bodyweight and out-of-range values', () {
          final e = r.engine;
          expect(
            () => e.setStartingWeight('no-such-lift', 10000),
            throwsArgumentError,
          );
          expect(
            () => e.setStartingWeight('pushups', 10000),
            throwsArgumentError,
          );
          expect(() => e.setStartingWeight(incline, 0), throwsArgumentError);
          expect(() => e.setStartingWeight(incline, -1), throwsArgumentError);
          expect(
            () => e.setStartingWeight(incline, startingWeightMaxG + 1),
            throwsArgumentError,
          );
          expect(e.startingWeights(), isEmpty);
        });

        test('an unreadable stored value reads as none', () {
          r.store.saveSetting(startingWeightsSettingKey, '{not json');
          expect(r.engine.startingWeights(), isEmpty);
          r.store.saveSetting(
            startingWeightsSettingKey,
            jsonEncode({incline: 20000, 'x': -5, 'y': 'heavy'}),
          );
          expect(r.engine.startingWeights(), {incline: 20000});
        });
      });

      group('suggestion source priority', () {
        test('no history, no starting weight: no load (first time here)', () {
          final i = item(r.g1, incline)!;
          expect(i.sets.map((s) => s.loadG).toSet(), {null});
          expect(i.reason, contains('First time here'));
        });

        test('no history + starting weight: the starting weight', () {
          r.engine.setStartingWeight(incline, 20000);
          final i = item(r.g1, incline)!;
          expect(i.sets.map((s) => s.loadG).toSet(), {20000});
          expect(i.sets.first.reps, 10, reason: 'rep range low end + 2');
          expect(i.reason, contains('Starting weight you set: 20 kg ea.'));
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: incline),
            20000,
          );
        });

        test('snapped down to a load this gym has', () {
          r.engine.setStartingWeight(incline, 21000); // 2 kg steps here
          final i = item(r.g1, incline)!;
          expect(i.sets.first.loadG, 20000);
          expect(i.reason, contains('Nearest weight here is 20 kg ea.'));
          expect(r.engine.startingWeights()[incline], 21000, reason: 'kept');
          // Lighter than every weight here: the lightest one.
          r.engine.setStartingWeight(incline, 500);
          expect(item(r.g1, incline)!.sets.first.loadG, 2000);
        });

        test('history at this gym beats the starting weight', () {
          r.engine.setStartingWeight(d.bench, 5000);
          final i = item(r.g1, d.bench)!;
          expect(i.sets.first.loadG, isNot(5000));
          expect(i.reason, contains('last time'));
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: d.bench),
            isNull,
          );
        });

        test('history at another gym only: superseded too (any gym)', () {
          // Bench is logged at g1 only (w1, w3, w5, w6): no last time at g2,
          // yet the starting weight stays unused there too.
          r.engine.setStartingWeight(d.bench, 5000);
          expect(
            r.engine.startingLoad(gymId: r.g2, exerciseId: d.bench),
            isNull,
          );
        });

        test('the first real set supersedes it', () {
          r.engine.setStartingWeight(incline, 20000);
          r.store.upsertWorkout(
            d.rec('n1', r.g1, 'push', d.monday + 3600000, [
              d.done(incline, 16000, 9),
            ]),
          );
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: incline),
            isNull,
          );
          final i = item(r.g1, incline)!;
          expect(i.sets.first.loadG, 16000, reason: 'from history now');
          expect(r.engine.startingWeights()[incline], 20000, reason: 'kept');
        });

        test('a skipped set is not history: the starting weight stays', () {
          r.engine.setStartingWeight(incline, 20000);
          r.store.upsertWorkout(
            d.rec('n1', r.g1, 'push', d.monday + 3600000, [
              d.done(d.bench, 20000, 10),
              d.skipped(incline),
            ]),
          );
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: incline),
            20000,
          );
        });
      });

      group('history changes fall back to the starting weight', () {
        setUp(() {
          r.engine.setStartingWeight(incline, 20000);
          r.store.upsertWorkout(
            d.rec('n1', r.g1, 'push', d.monday + 3600000, [
              d.done(d.bench, 20000, 10),
              d.done(incline, 16000, 12),
            ]),
          );
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: incline),
            isNull,
          );
        });

        test('delete the only workout with it, then undo', () {
          final del = r.engine.deleteWorkout('n1');
          expect(del, isNotNull);
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: incline),
            20000,
          );
          expect(item(r.g1, incline)!.sets.first.loadG, 20000);
          expect(r.engine.undoDelete('n1'), isTrue);
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: incline),
            isNull,
          );
        });

        test('edit its only set out of history', () {
          final setId = r
              .w('n1')
              .sets
              .firstWhere((s) => s.exerciseId == incline)
              .setId;
          r.engine.editWorkout('n1', [WorkoutEdit.removeSet(setId)]);
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: incline),
            20000,
          );
          expect(item(r.g1, incline)!.sets.first.loadG, 20000);
        });
      });

      test('not history: no workout, PB, streak, counter or order change', () {
        String everything() => jsonEncode([
          view(r.engine, r.g1, r.g2),
          [for (final h in r.engine.history()) h.uuid],
          r.engine.counters().sessionsTotal,
          r.engine.counters().doneSets,
          [
            for (final m in r.engine.muscleStatus(gymId: r.g1).values)
              m.daysSince,
          ],
        ]);
        final before = everything();
        // Lifts the view reads (bench, row) have history; the others are
        // new. Nothing in the view may move.
        r.engine.setStartingWeight(d.bench, 60000);
        r.engine.setStartingWeight(d.row, 60000);
        r.engine.setStartingWeight(pushdown, 20000); // not in the view
        expect(everything(), before);
        expect(r.store.workouts().length, 6);
      });

      group('ghost', () {
        SessionSnapshot live(String gymId) => Session.start(
          r.engine.suggest(
            gymId: gymId,
            muscleIds: const ['chest', 'front-delts', 'triceps'],
            typeId: 'push',
            minutes: 60,
          ),
          nowMs: r.now,
          tzOffsetMin: 480,
          workoutUuid: 'live',
        );

        test('a starting-weight ghost only for a lift with no history', () {
          r.engine.setStartingWeight(incline, 20000);
          r.engine.setStartingWeight(d.bench, 5000);
          final s = live(r.g1);
          final g = ghostsForSession(
            s,
            r.store.workouts(),
            startingWeights: r.engine.startingWeights(),
          );
          expect(g[incline]!.baseline, isTrue);
          expect(g[incline]!.sets.single.loadG, 20000);
          expect(g[d.bench]!.baseline, isFalse, reason: 'history wins');
          expect(g[d.bench]!.workoutUuid, 'w6');
          // Without starting weights nothing changes from before S1.
          expect(ghostsForSession(s, r.store.workouts())[incline], isNull);
        });

        test('never judges and never counts in the session total', () {
          r.engine.setStartingWeight(incline, 20000);
          final g = ghostsForSession(
            live(r.g2), // no bench history at g2 either: no real ghost
            r.store.workouts(),
            startingWeights: r.engine.startingWeights(),
          );
          final line = compareSet(
            ghost: g[incline]!,
            setOrdinal: 3,
            loadG: 22000,
            reps: 12,
          );
          expect(line.verdict, GhostVerdict.pending);
          expect(line.baseline, isTrue);
          expect(line.ghostLoadG, 20000);
          expect(line.loadDeltaG, 2000);
          expect(ghostSetText(line, perHand: true), 'Starting weight 20 kg ea');
          expect(ghostSetSemantics(line), 'Your starting weight, 20 kilos');
          expect(
            sessionTotal(
              ghosts: g,
              done: [
                (exerciseId: incline, setOrdinal: 1, volumeGReps: 22000 * 12),
              ],
            ),
            isNull,
            reason: 'only starting weights: no "lifts compared" line',
          );
        });

        test('deleting the history brings the starting-weight ghost back', () {
          r.engine.setStartingWeight(incline, 20000);
          r.store.upsertWorkout(
            d.rec('n1', r.g1, 'push', d.monday + 3600000, [
              d.done(incline, 16000, 12),
            ]),
          );
          r.now = d.monday + 5 * 3600000;
          Map<String, ExerciseGhost?> ghosts() => ghostsForSession(
            live(r.g1),
            r.store.workouts(),
            startingWeights: r.engine.startingWeights(),
          );
          expect(ghosts()[incline]!.baseline, isFalse);
          r.engine.deleteWorkout('n1');
          expect(ghosts()[incline]!.baseline, isTrue);
        });
      });

      group('export and import', () {
        HistoryStore fresh() => make();

        test('round trip: export carries them, import restores them', () {
          r.engine.setStartingWeight(incline, 20000);
          r.engine.setStartingWeight(pushdown, 30000);
          final file = r.engine.export(appVersion: 'x').json;
          expect(decode(file)['starting_weights'], [
            {'exercise_id': incline, 'load_g': 20000},
            {'exercise_id': pushdown, 'load_g': 30000},
          ]);
          final dst = GymEngine(
            catalog: d.catalog,
            store: fresh(),
            nowMs: () => r.now,
          );
          final p = dst.previewImport(file);
          expect(p.startingWeightsAdded, 2);
          expect(
            dst.startingWeights(),
            isEmpty,
            reason: 'preview writes nothing',
          );
          final c = dst.importBundle(file);
          expect(c.startingWeightsAdded, 2);
          expect(dst.startingWeights(), {incline: 20000, pushdown: 30000});
          expect(comparable(dst), comparable(r.engine));
          // Again: nothing new.
          final again = dst.importBundle(file);
          expect(again.startingWeightsAdded, 0);
          expect(again.startingWeightsKept, 2);
          expect(again.isNoOp, isTrue);
          final st = dst.store;
          if (st is SqliteStore) st.close();
        });

        test('his own starting weight is kept', () {
          r.engine.setStartingWeight(incline, 20000);
          final file = r.engine.export(appVersion: 'x').json;
          final dst = GymEngine(catalog: d.catalog, store: fresh());
          dst.setStartingWeight(incline, 12000);
          final c = dst.importBundle(file);
          expect(c.startingWeightsAdded, 0);
          expect(c.startingWeightsKept, 1);
          expect(dst.startingWeights(), {incline: 12000});
          final st = dst.store;
          if (st is SqliteStore) st.close();
        });

        test('a file with only starting weights new is not a no-op', () {
          final dst = GymEngine(catalog: d.catalog, store: fresh());
          final base = decode(dst.export(appVersion: 'x').json);
          base['starting_weights'] = [
            {'exercise_id': incline, 'load_g': 20000},
          ];
          final c = dst.previewImport(jsonEncode(base));
          expect(c.workoutsAdded, 0);
          expect(c.startingWeightsAdded, 1);
          expect(c.isNoOp, isFalse);
          final st = dst.store;
          if (st is SqliteStore) st.close();
        });

        test('a format 2 file without the key (0.2.x) imports, none added', () {
          final j = decode(r.engine.export(appVersion: 'x').json)
            ..remove('starting_weights');
          expect(j['export_format'], 2);
          final dst = GymEngine(catalog: d.catalog, store: fresh());
          final c = dst.importBundle(jsonEncode(j));
          expect(c.workoutsAdded, 6);
          expect(c.startingWeightsAdded, 0);
          expect(dst.startingWeights(), isEmpty);
          final st = dst.store;
          if (st is SqliteStore) st.close();
        });

        test('the 0.2.0 (format 1) fixture still imports', () {
          final dst = GymEngine(catalog: d.catalog, store: fresh());
          final c = dst.importBundle(
            File('test/fixtures/export_v1_from_0.2.0.json').readAsStringSync(),
          );
          expect(c.startingWeightsAdded, 0);
          expect(dst.startingWeights(), isEmpty);
          final st = dst.store;
          if (st is SqliteStore) st.close();
        });

        test('a bad starting weight refuses the whole file', () {
          final dst = GymEngine(catalog: d.catalog, store: fresh());
          final file = decode(r.engine.export(appVersion: 'x').json);
          for (final bad in [
            [
              {'exercise_id': incline, 'load_g': 0},
            ],
            [
              {'exercise_id': incline, 'load_g': '20'},
            ],
            [
              {'exercise_id': '', 'load_g': 20000},
            ],
            [
              {'exercise_id': incline, 'load_g': 20000},
              {'exercise_id': incline, 'load_g': 22000},
            ],
            'x',
          ]) {
            file['starting_weights'] = bad;
            expect(
              () => dst.importBundle(jsonEncode(file)),
              throwsA(isA<ImportRefused>()),
              reason: '$bad',
            );
          }
          expect(dst.store.workouts(), isEmpty);
          expect(dst.startingWeights(), isEmpty);
          final st = dst.store;
          if (st is SqliteStore) st.close();
        });
      });

      group('the entry screen list', () {
        test(
          'next sessions first, then every loaded lift; history flagged',
          () {
            final lifts = r.engine.startingWeightLifts(gymId: r.g1);
            expect(lifts, isNotEmpty);
            for (final l in lifts) {
              expect(l.unit, anyOf(LoadUnit.kg, LoadUnit.ea), reason: l.name);
            }
            expect(
              lifts.map((l) => l.exerciseId).toSet().length,
              lifts.length,
              reason: 'no duplicates',
            );
            final typed = lifts.takeWhile((l) => l.typeId != null).toList();
            expect({for (final l in typed) l.typeId}, {'push', 'pull', 'legs'});
            final more = lifts.skip(typed.length).toList();
            expect(more, isNotEmpty);
            expect(more.every((l) => l.typeId == null), isTrue);
            expect([
              for (final l in more) l.name,
            ], [for (final l in more) l.name]..sort());
            final row = lifts.where((l) => l.exerciseId == d.row).firstOrNull;
            if (row != null) expect(row.hasHistory, isTrue);
            expect(lifts.where((l) => l.hasHistory == false), isNotEmpty);
          },
        );

        test('every loaded lift any picker seed plans is listed', () {
          // The picker seeds with sessions + 1 and ties between lifts with
          // no history break on it, so later sessions can pick lifts the
          // next one does not: all of them must be on the screen.
          final ids = {
            for (final l in r.engine.startingWeightLifts(gymId: r.g1))
              l.exerciseId,
          };
          for (var seed = 0; seed <= 12; seed++) {
            for (final t in ['push', 'pull', 'legs', 'core']) {
              for (final minutes in [30, 45, 60]) {
                final plan = r.engine.suggest(
                  gymId: r.g1,
                  muscleIds: workoutType(t)!.muscles,
                  typeId: t,
                  minutes: minutes,
                  seed: seed,
                );
                for (final i in plan.items) {
                  if (i.unit != LoadUnit.kg && i.unit != LoadUnit.ea) continue;
                  expect(ids, contains(i.exerciseId), reason: '$t seed $seed');
                }
              }
            }
          }
        });

        test('a stored weight shows, also for a lift this gym cannot do', () {
          final planned = r.engine.startingWeightLifts(gymId: r.g1);
          final first = planned.firstWhere((l) => !l.hasHistory);
          r.engine.setStartingWeight(first.exerciseId, 14000);
          // A loaded lift the condo kit cannot do (barbell): listed only
          // because it has a starting weight.
          final off = d.catalog.exercises.firstWhere(
            (e) =>
                e.load == 'barbell' &&
                !planned.any((l) => l.exerciseId == e.id),
          );
          r.engine.setStartingWeight(off.id, 60000);
          final lifts = r.engine.startingWeightLifts(gymId: r.g1);
          expect(
            lifts.firstWhere((l) => l.exerciseId == first.exerciseId).loadG,
            14000,
          );
          final o = lifts.firstWhere((l) => l.exerciseId == off.id);
          expect(o.typeId, isNull);
          expect(o.loadG, 60000);
        });

        test('an imported weight on an unloaded lift is never used', () {
          r.store.saveSetting(
            startingWeightsSettingKey,
            jsonEncode({'pushups': 20000}),
          );
          expect(r.engine.startingWeights(), {'pushups': 20000});
          expect(
            r.engine.startingLoad(gymId: r.g1, exerciseId: 'pushups'),
            isNull,
          );
        });
      });

      if (kind == 'sqlite') {
        test('sqlite only: survives a reopen, no schema change', () {
          final path = '${dir.path}/reopen.db';
          final a = SqliteStore.open(path);
          final ea = GymEngine(catalog: d.catalog, store: a);
          ea.setStartingWeight(incline, 20000);
          expect(a.schemaVersion, latestSchemaVersion);
          expect(latestSchemaVersion, 2, reason: 'S1 adds no migration');
          a.close();
          final b = SqliteStore.open(path);
          expect(GymEngine(catalog: d.catalog, store: b).startingWeights(), {
            incline: 20000,
          });
          b.close();
        });
      }
    });
  }
}
