import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/progress_model.dart';
import 'package:gym_supreme/screens/progress_screen.dart';
import 'package:gym_supreme/screens/settings_profile.dart';

import 'fixtures.dart';
import 'flaky_port.dart';
import 'progress_fixtures.dart';

Future<void> pumpScreen(
  WidgetTester tester,
  ProgressView v, {
  void Function(IgnoredSet)? onConfirm,
  void Function(LiftCard)? onOpen,
  VoidCallback? onProfile,
}) async {
  phone(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: ProgressScreen(
        view: v,
        onOpenProfile: onProfile ?? () {},
        onOpenLift: onOpen ?? (_) {},
        onConfirm: onConfirm ?? (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no profile: nudge, no × bodyweight', (tester) async {
    await pumpScreen(tester, noProfile());
    expect(find.byKey(const Key('progress.noProfile')), findsOneWidget);
    expect(find.textContaining('× bodyweight'), findsNothing);
  });

  testWidgets('stale bodyweight: says from when', (tester) async {
    await pumpScreen(tester, staleBodyweight());
    expect(find.textContaining('Bodyweight from 20 Aug'), findsOneWidget);
    expect(find.textContaining('× bodyweight'), findsWidgets);
  });

  testWidgets('rough e1RM is labelled', (tester) async {
    await pumpScreen(tester, roughE1rm());
    expect(find.byKey(const Key('progress.rough')), findsOneWidget);
    expect(find.textContaining('needs a heavier set'), findsOneWidget);
  });

  testWidgets('first data note, cold start line, no trend yet', (tester) async {
    await pumpScreen(tester, firstData());
    expect(find.byKey(const Key('progress.firstData')), findsOneWidget);
    expect(find.textContaining('First session at Hotel gym'), findsOneWidget);
    expect(find.text('No counted set yet'), findsOneWidget);
    expect(find.textContaining('Trend shows after a second'), findsWidgets);
  });

  testWidgets('empty history', (tester) async {
    await pumpScreen(tester, view(const []));
    expect(find.byKey(const Key('progress.empty')), findsOneWidget);
  });

  testWidgets('typo flag: nudge confirms; sheet lists reasons', (tester) async {
    final confirmed = <IgnoredSet>[];
    LiftCard? opened;
    final v = view(typoWorkouts());
    await pumpScreen(
      tester,
      v,
      onConfirm: confirmed.add,
      onOpen: (c) => opened = c,
    );
    expect(find.text('Confirm big number?'), findsOneWidget);
    await tester.tap(find.textContaining('Yes'));
    expect(confirmed.single.setId, v.flagged.single.$2.setId);

    await tester.tap(find.byKey(Key('progress.lift.$bench')));
    expect(opened, isNotNull);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiftSheet(card: opened!, onConfirm: confirmed.add),
        ),
      ),
    );
    expect(find.textContaining('Big jump'), findsOneWidget);
    expect(find.textContaining('Warm-up'), findsNothing);
    await tester.tap(find.text('It is right'));
    expect(confirmed.length, 2);
  });

  testWidgets('sheet with nothing ignored', (tester) async {
    final c = view([
      workout('c', 2, [set(bench, 1, 70, 5)]),
    ]).cards.single;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiftSheet(card: c, onConfirm: (_) {}),
        ),
      ),
    );
    expect(find.text('Every set counted.'), findsOneWidget);
  });

  testWidgets('failed profile save keeps the old value', (tester) async {
    phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsProfileScreen(
          initial: const Profile(),
          today: '2026-11-26',
          onSave: (_) => false,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('profile.sex.male')));
    await tester.pump();
    expect(find.text('Could not save. Try again.'), findsOneWidget);
    final chip = tester.widget<ChoiceChip>(
      find.byKey(const Key('profile.sex.male')),
    );
    expect(chip.selected, isFalse);
  });

  testWidgets('sheet shows the bodyweight the ratio used', (tester) async {
    final p = const Profile().withWeighIn('2026-10-01', 90000);
    final c = view([
      workout('a', 30, [set(squat, 1, 120, 5)]),
    ], profile: p).cards.single;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiftSheet(card: c, onConfirm: (_) {}),
        ),
      ),
    );
    expect(find.textContaining('vs 90 kg (1 Oct 2026)'), findsOneWidget);
  });

  testWidgets('undated legacy bodyweight nudges for a dated weigh-in', (
    tester,
  ) async {
    await pumpScreen(tester, view(sixWeeks(), legacyG: 85000));
    expect(find.text('ADD A DATED WEIGH-IN'), findsOneWidget);
  });

  group('Progress tab over the engine', () {
    late eng.MemoryStore store;
    late GymDeps deps;
    int persisted = 0;

    setUp(() {
      persisted = 0;
      progressRunner = buildProgressInline;
      store = eng.MemoryStore()
        ..upsertGym(
          const eng.Gym(id: 'g1', name: 'Condo gym', kit: {}, createdAtMs: 1),
        );
      for (final w in typoWorkouts()) {
        store.upsertWorkout(w);
      }
      final engine = eng.GymEngine(
        catalog: progressCatalog,
        store: store,
        nowMs: () => progressNow,
        tzOffsetMin: () => 0,
        random: Random(5),
      );
      deps = GymDeps(
        engine: engine,
        port: FlakyPort(),
        catalog: progressCatalog,
        nowMs: () => progressNow,
        tzOffsetMin: () => 0,
        store: store,
        persist: () => persisted++,
      );
    });

    Future<void> openTab(WidgetTester tester, {bool settle = true}) async {
      phone(tester);
      await tester.pumpWidget(MaterialApp(home: GymRoot(deps: deps)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Progress'));
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
    }

    testWidgets('shows a placeholder until the analysis returns', (
      tester,
    ) async {
      final done = Completer<ProgressView>();
      progressRunner = (_) => done.future;
      await openTab(tester, settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      done.complete(
        buildProgressFrom(
          ProgressInput(
            workouts: store.workouts(),
            catalog: progressCatalog,
            gymNames: gymNames,
            profile: const Profile(),
            nowMs: progressNow,
            tzOffsetMin: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('PROGRESS'), findsOneWidget);
    });

    testWidgets('confirm saves the set id and refreshes', (tester) async {
      await openTab(tester);
      expect(find.text('Confirm big number?'), findsOneWidget);
      await tester.tap(find.textContaining('Yes'));
      await tester.pumpAndSettle();
      expect(loadConfirmed(store), hasLength(1));
      expect(loadConfirmed(store).single.loadG, 200000);
      expect(persisted, 1);
      expect(find.text('Confirm big number?'), findsNothing);
    });

    testWidgets('profile: add a weigh-in, cards show × bodyweight', (
      tester,
    ) async {
      await openTab(tester);
      expect(find.byKey(const Key('progress.noProfile')), findsOneWidget);
      await tester.tap(find.byKey(const Key('progress.profile')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('profile.year')), '1990');
      await tester.tap(find.byKey(const Key('profile.sex.male')));
      await tester.enterText(find.byKey(const Key('profile.kg')), '82,5');
      await tester.tap(find.byKey(const Key('profile.add')));
      await tester.pumpAndSettle();
      final saved = Profile.load(store);
      expect(saved.birthYear, 1990);
      expect(saved.sex, 'male');
      expect(saved.log.single.grams, 82500);
      expect(saved.log.single.date, '2026-11-26');
      expect(persisted, greaterThan(0));
      expect(find.text('82.5 kg · 26 Nov'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('progress.noProfile')), findsNothing);
      expect(find.textContaining('× bodyweight'), findsWidgets);
    });

    testWidgets('profile: bad inputs are refused', (tester) async {
      await openTab(tester);
      await tester.tap(find.byKey(const Key('progress.profile')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('profile.kg')), '5');
      await tester.tap(find.byKey(const Key('profile.add')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter your weight'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('profile.year')), '1850');
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter a year'), findsOneWidget);
      expect(Profile.load(store).isEmpty, isTrue);
    });

    testWidgets('profile: remove a weigh-in', (tester) async {
      Profile.parse(null).withWeighIn('2026-11-01', 80000).save(store);
      await openTab(tester);
      await tester.tap(find.byKey(const Key('progress.profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile.remove.2026-11-01')));
      await tester.pumpAndSettle();
      expect(Profile.load(store).log, isEmpty);
    });
  });
}
