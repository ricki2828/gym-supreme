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
      expect(b.ratio, closeTo(b.bestKg! / 82.5, 0.001));
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

    test('typo flag: listed, confirm clears it (two parked sets too)', () {
      final ws = typoWorkouts();
      final v = view(ws);
      expect(v.flagged.length, 1);
      final id = v.flagged.single.$2.setId;
      expect(v.cards.single.hasTypoFlag, isTrue);
      final after = view(ws, confirmed: {id});
      expect(after.flagged, isEmpty);
      expect(after.cards.single.bestKg, greaterThan(150));

      // Two parked sets in one workout: confirming one leaves the other.
      final two = [
        workout('a', 20, [set(bench, 1, 70, 5)]),
        workout('b', 1, [set(bench, 1, 200, 5), set(bench, 2, 210, 5)]),
      ];
      final v2 = view(two);
      expect(v2.flagged.length, 2);
      final first = v2.flagged.first.$2.setId;
      expect(view(two, confirmed: {first}).flagged.length, 1);
      expect(
        view(two, confirmed: {for (final f in v2.flagged) f.$2.setId}).flagged,
        isEmpty,
      );
    });

    test('confirmed ids persist in the raw setting', () {
      final st = eng.MemoryStore();
      expect(loadConfirmed(st), isEmpty);
      saveConfirmed(st, {'b', 'a'});
      expect(loadConfirmed(st), {'a', 'b'});
    });

    test('weekly volume and hard sets by muscle', () {
      final v = view(sixWeeks());
      expect(v.weeks.length, trendWeeks);
      expect(v.weeks.last.kgReps, 0); // nothing this week
      expect(v.weeks.any((w) => w.kgReps > 0), isTrue);
      final names = [for (final m in v.muscles) m.name];
      expect(names, isNotEmpty);
    });

    test('PBs: newest first, first best has no gain', () {
      final v = view(sixWeeks());
      expect(v.pbs, isNotEmpty);
      expect(v.pbs.length, 12); // capped, newest kept
      expect(v.pbs.first.gainKg, isNotNull);
      final first = firstData().pbs;
      expect(first.every((p) => p.gainKg == null), isTrue);
    });
  });
}
