// 0.3 X1: rename and delete a gym. History keeps every workout and set of a
// deleted gym (no FK from workout / set_row to gym); a rename shows in
// history at once; an export taken afterwards imports cleanly (the file
// names a gym it does not list). Both stores, as the app runs SQLite.
import 'package:gym_engine/gym_engine.dart';
import 'package:gym_engine/sqlite_store.dart';
import 'package:test/test.dart';

import 'delete_edit_test.dart' as d;

void main() {
  for (final (label, make) in <(String, HistoryStore Function())>[
    ('memory store', MemoryStore.new),
    ('sqlite store', SqliteStore.inMemory),
  ]) {
    group(label, () {
      GymEngine engineOn(HistoryStore s) => GymEngine(
        catalog: d.catalog,
        store: s,
        nowMs: () => d.monday + 2 * 3600 * 1000,
        tzOffsetMin: () => 480,
      );

      late HistoryStore store;
      late GymEngine e;
      late Gym away;
      late Gym home;

      setUp(() {
        store = make();
        e = engineOn(store);
        home = e.gymFromPreset('condo', name: 'Condo');
        away = e.gymFromPreset('condo', name: 'Basement');
        e.saveGym(home);
        e.saveGym(away);
        store.upsertWorkout(
          d.rec('w-home', home.id, 'push', d.monday - 3 * d.day, [
            d.done(d.bench, 10000, 10),
          ]),
        );
        store.upsertWorkout(
          d.rec('w-away', away.id, 'push', d.monday - 2 * d.day, [
            d.done(d.bench, 12000, 10),
            d.done(d.bench, 12000, 9),
          ]),
        );
      });

      test('delete: the gym is gone, its workouts and sets stay', () {
        e.deleteGym(away.id);
        expect(e.gyms().map((g) => g.id), [home.id]);
        expect(e.gym(away.id), isNull);
        final w = store.workout('w-away')!;
        expect(w.gymId, away.id);
        expect(w.doneSets, hasLength(2));
        final rows = {for (final r in e.history()) r.uuid: r};
        expect(rows.keys, containsAll(['w-home', 'w-away']));
        expect(rows['w-away']!.gymName, '');
        expect(rows['w-away']!.setCount, 2);
        expect(rows['w-home']!.gymName, 'Condo');
        // Stats that read the workout still work.
        expect(e.summary('w-away').volumeKg, greaterThan(0));
        expect(e.lastTime(gymId: away.id, exerciseId: d.bench), isNotNull);
      });

      test('rename shows in history at once; the rows are the same', () {
        e.saveGym(e.gym(away.id)!.copyWith(name: 'Flat gym'));
        final rows = {for (final r in e.history()) r.uuid: r};
        expect(rows['w-away']!.gymName, 'Flat gym');
        expect(rows['w-away']!.gymId, away.id, reason: 'id never changes');
        expect(rows['w-home']!.gymName, 'Condo');
        expect(e.history(), hasLength(2));
      });

      test('an export after a delete imports cleanly into a fresh phone', () {
        e.deleteGym(away.id);
        final file = e.export(appVersion: 'x').json;
        final dst = engineOn(make());
        final counts = dst.importBundle(file);
        expect(counts.workoutsAdded, 2);
        final rows = {for (final r in dst.history()) r.uuid: r};
        expect(
          rows['w-away']!.gymName,
          '',
          reason: 'its gym is not in the file',
        );
        expect(rows['w-away']!.setCount, 2);
        expect(rows['w-home']!.gymName, 'Condo');
      });
    });
  }
}
