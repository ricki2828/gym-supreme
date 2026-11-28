import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/progress_model.dart';

import 'progress_fixtures.dart';

void main() {
  group('Profile', () {
    test('round-trips and drops junk', () {
      final p = const Profile(
        birthYear: 1990,
        sex: 'female',
      ).withWeighIn('2026-11-01', 80000).withWeighIn('2026-10-01', 81000);
      final back = Profile.parse(p.toJsonText());
      expect(back.birthYear, 1990);
      expect(back.sex, 'female');
      expect([for (final e in back.log) e.date], ['2026-10-01', '2026-11-01']);
      expect(Profile.parse('nope').isEmpty, isTrue);
      expect(Profile.parse(null).isEmpty, isTrue);
      expect(
        Profile.parse(
          '{"sex":"x","bodyweight":[{"d":"bad","g":1},{"d":"2026-01-01","g":-5}]}',
        ).isEmpty,
        isTrue,
      );
    });

    test('birth year outside 1900-2100 is dropped', () {
      expect(Profile.parse('{"birth_year":1850}').birthYear, isNull);
      expect(Profile.parse('{"birth_year":1990}').birthYear, 1990);
    });

    test('same-day weigh-in replaces', () {
      final p = const Profile()
          .withWeighIn('2026-11-01', 80000)
          .withWeighIn('2026-11-01', 79000);
      expect(p.log.single.grams, 79000);
    });

    test('bodyweight: newest on or before today, stale after 60 days', () {
      final p = const Profile()
          .withWeighIn('2026-09-27', 80000)
          .withWeighIn('2026-12-30', 99000);
      final r = p.bodyweight('2026-11-26')!;
      expect(r.kg, 80);
      expect(r.ageDays, 60);
      expect(r.stale, isFalse);
      expect(p.bodyweight('2026-11-27')!.stale, isTrue);
      expect(const Profile().bodyweight('2026-11-26'), isNull);
    });

    test('legacy undated bodyweight is a fallback, never stale', () {
      final r = const Profile().bodyweight('2026-11-26', legacyG: 85000)!;
      expect(r.kg, 85);
      expect(r.date, isNull);
      expect(r.stale, isFalse);
      expect(
        const Profile()
            .withWeighIn('2026-11-01', 80000)
            .bodyweight('2026-11-26', legacyG: 85000)!
            .kg,
        80,
      );
    });

    test('stored in the raw setting, Settings untouched', () {
      final st = eng.MemoryStore();
      expect(Profile.load(st).isEmpty, isTrue);
      const Profile(birthYear: 1985).save(st);
      expect(Profile.load(st).birthYear, 1985);
      expect(st.settings().toJson(), const eng.Settings().toJson());
    });
  });

  test('the analysis crosses to a background isolate', () async {
    final v = await progressRunner(
      ProgressInput(
        workouts: sixWeeks(),
        catalog: progressCatalog,
        gymNames: gymNames,
        profile: weighed('2026-11-20'),
        nowMs: progressNow,
        tzOffsetMin: 0,
        confirmed: const [Confirmation('x', 1, 1)],
      ),
    );
    expect(v.cards.length, 2);
    expect(v.cards.first.ratio, isNotNull);
  });

  group('buildProgress', () {
    test('empty history', () {
      final v = view(const []);
      expect(v.isEmpty, isTrue);
      expect(v.cards, isEmpty);
    });

    test('cards: best, × bodyweight, trend', () {
      final v = view(sixWeeks(), profile: weighed('2026-11-20'));
      final b = v.cards.firstWhere((c) => c.key == bench);
      expect(b.bestKg, closeTo(77.5 * (1 + 5 / 30), 0.01));
      expect(b.bestKg, closeTo(90.4167, 0.001));
      expect(b.ratio, closeTo(1.0959, 0.001)); // 90.4167 / 82.5
      expect(b.trend.length, trendWeeks);
      expect(b.trendPoints, greaterThanOrEqualTo(2));
      expect(b.trend.last, isNull); // last session was last week
      expect(b.trend[trendWeeks - 2], isNotNull);
      expect(v.bodyweight!.stale, isFalse);
    });

    test('no bodyweight: no ratio', () {
      final v = noProfile();
      expect(v.cards.every((c) => c.ratio == null), isTrue);
      expect(v.bodyweight, isNull);
    });

    test('stale bodyweight is flagged with its date', () {
      final v = staleBodyweight();
      expect(v.bodyweight!.stale, isTrue);
      expect(v.bodyweight!.date, '2026-08-20');
      expect(v.cards.first.ratio, isNotNull);
    });

    test('rough e1RM is labelled and has no solid fallback', () {
      final b = roughE1rm().cards.single;
      expect(b.rough, isTrue);
      expect(b.solidKg, isNull);
      expect(b.bestKg, closeTo(55 * (1 + 12 / 30), 0.01));
    });

    test('stack lift is per gym and found via bestFor; cold start shown', () {
      final v = firstData();
      final lp = v.cards.firstWhere((c) => c.key == '$legPress@g2');
      expect(lp.gymName, 'Hotel gym');
      expect(lp.bestKg, isNull);
      expect(lp.firstAtGym, isTrue);
      expect(lp.ignored.single.reason, contains('First session'));
      expect(v.firstData, isTrue);
    });

    test('a stack lift at two gyms: two cards, separate PBs', () {
      final v = view([
        workout('a', 12, [set(legPress, 1, 100, 5)], gym: 'g1'),
        workout('b', 6, [set(legPress, 1, 60, 5)], gym: 'g2'),
        workout('c', 2, [set(legPress, 1, 110, 5)], gym: 'g1'),
      ]);
      final cards = v.cards.where((c) => c.key.startsWith(legPress)).toList();
      expect(cards.map((c) => c.key).toSet(), {'$legPress@g1', '$legPress@g2'});
      final g1 = cards.firstWhere((c) => c.gymName == 'Condo gym');
      final g2 = cards.firstWhere((c) => c.gymName == 'Hotel gym');
      expect(g1.bestKg, closeTo(110 * (1 + 5 / 30), 0.01));
      expect(g2.bestKg, closeTo(60 * (1 + 5 / 30), 0.01));
      final pbs = v.pbs.map((p) => p.lift).toList();
      expect(pbs.where((l) => l.contains('Condo gym')).length, 2);
      expect(pbs.where((l) => l.contains('Hotel gym')).length, 1);
    });

    test('typo flag: listed, confirm clears it (two parked sets too)', () {
      final ws = typoWorkouts();
      final v = view(ws);
      expect(v.flagged.length, 1);
      final c = confirmationOf(v.flagged.single.$2);
      expect(v.cards.single.hasTypoFlag, isTrue);
      expect(v.flagged.single.$2.light, isFalse);
      final after = view(ws, confirmed: [c]);
      expect(after.flagged, isEmpty);
      expect(after.cards.single.bestKg, greaterThan(150));

      // Two parked sets in one workout: confirming one leaves the other.
      final two = [
        workout('a', 20, [set(bench, 1, 70, 5)]),
        workout('b', 1, [set(bench, 1, 200, 5), set(bench, 2, 210, 5)]),
      ];
      final v2 = view(two);
      expect(v2.flagged.length, 2);
      final first = confirmationOf(v2.flagged.first.$2);
      expect(view(two, confirmed: [first]).flagged.length, 1);
      expect(
        view(
          two,
          confirmed: [for (final f in v2.flagged) confirmationOf(f.$2)],
        ).flagged,
        isEmpty,
      );
    });

    test('confirmations persist; old id-only values read as unconfirmed', () {
      final st = eng.MemoryStore();
      expect(loadConfirmed(st), isEmpty);
      saveConfirmed(st, [const Confirmation('a', 1000, 5)]);
      final back = loadConfirmed(st).single;
      expect([back.setId, back.loadG, back.reps], ['a', 1000, 5]);
      st.saveSetting(confirmedKey, '["a","b"]');
      expect(loadConfirmed(st), isEmpty);
      st.saveSetting(confirmedKey, 'garbage');
      expect(loadConfirmed(st), isEmpty);
    });

    test('an edit after confirming voids the confirmation', () {
      final ws = typoWorkouts();
      final c = confirmationOf(view(ws).flagged.single.$2);
      expect(view(ws, confirmed: [c]).flagged, isEmpty);
      // The same set edited 200 kg -> 2000 kg.
      final edited = [
        for (final w in ws)
          eng.WorkoutRecord(
            uuid: w.uuid,
            gymId: w.gymId,
            startedAtMs: w.startedAtMs,
            tzOffsetMin: w.tzOffsetMin,
            endedAtMs: w.endedAtMs,
            sets: [
              for (final s in w.sets)
                s.setId == c.setId ? _withLoad(s, 2000000) : s,
            ],
          ),
      ];
      final v = view(edited, confirmed: [c]);
      expect(v.flagged.single.$2.what, '2000 kg × 5');
      expect(v.cards.single.bestKg, lessThan(150));
    });

    test('light outlier gets light wording', () {
      final ws = [
        workout('a', 20, [set(bench, 1, 100, 5)]),
        workout('b', 1, [set(bench, 1, 10, 5)]),
      ];
      final f = view(ws).flagged.single.$2;
      expect(f.light, isTrue);
      expect(f.reason, lightReason);
      expect(view(ws).cards.single.hasLightFlag, isTrue);
    });

    test('x bodyweight uses the weight on the best\'s day, not today', () {
      final ws = [
        workout('a', 30, [set(squat, 1, 120, 5)]), // 26 Oct
      ];
      final p = const Profile()
          .withWeighIn('2026-10-01', 90000)
          .withWeighIn('2026-11-20', 80000);
      final c = view(ws, profile: p).cards.single;
      expect(c.bwKg, 90);
      expect(c.bwDate, '2026-10-01');
      expect(c.ratio, closeTo(120 * (1 + 5 / 30) / 90, 0.001));
      // Today's weight still drives the banner.
      expect(view(ws, profile: p).bodyweight!.kg, 80);
      // Older than the first weigh-in: the earliest entry.
      final early = const Profile().withWeighIn('2026-11-10', 85000);
      expect(view(ws, profile: early).cards.single.bwKg, 85);
      // Undated legacy only with an empty log.
      final l = view(ws, legacyG: 88000).cards.single;
      expect([l.bwKg, l.bwDate], [88, null]);
    });

    test('trend weeks follow each workout\'s own offset', () {
      // Sunday 22 Nov 23:00 UTC at +8h is Monday 23 Nov local: this week.
      final w = eng.WorkoutRecord(
        uuid: 'tz',
        gymId: 'g1',
        startedAtMs: DateTime.utc(2026, 11, 22, 23).millisecondsSinceEpoch,
        tzOffsetMin: 480,
        endedAtMs: DateTime.utc(2026, 11, 23, 1).millisecondsSinceEpoch,
        sets: [set(bench, 1, 70, 5)],
      );
      final c = view([w]).cards.single;
      expect(c.trend.last, isNotNull);
    });

    test('weekly volume and hard sets by muscle', () {
      final v = view(sixWeeks());
      expect(v.weeks.length, trendWeeks);
      expect(v.weeks.last.kgReps, 0); // nothing this week
      expect(v.weeks.any((w) => w.kgReps > 0), isTrue);
      // Last week: 2 bench + 2 squat working sets per session (warm-up
      // excluded), sessions on 16 and 21 Nov fall in the weeks of 16 and 23.
      final chest = v.muscles.firstWhere((m) => m.name == 'Chest');
      expect(chest.thisWeek, 0);
      expect(chest.lastWeek, 4);
      expect(
        v.muscles.map((m) => m.thisWeek + m.lastWeek).toList(),
        orderedEquals(
          [...v.muscles.map((m) => m.thisWeek + m.lastWeek)]
            ..sort((a, b) => b.compareTo(a)),
        ),
      );
    });

    test('PBs: newest first, first best has no gain', () {
      final v = view(sixWeeks());
      expect(v.pbs, isNotEmpty);
      expect(v.pbs.length, 12); // capped, newest kept
      expect(v.pbs.first.gainKg, isNotNull);
      expect(v.pbs.first.date, '21 Nov');
      expect(v.pbs.last.date, '27 Oct');
      expect(v.pbs.first.kg, greaterThan(v.pbs[2].kg));
      final first = firstData().pbs;
      expect(first.every((p) => p.gainKg == null), isTrue);
    });
  });
}

eng.SetRecord _withLoad(eng.SetRecord s, int loadG) => eng.SetRecord(
  setId: s.setId,
  exerciseId: s.exerciseId,
  exerciseName: s.exerciseName,
  exercisePosition: s.exercisePosition,
  setOrdinal: s.setOrdinal,
  completion: s.completion,
  loadG: loadG,
  reps: s.reps,
);
