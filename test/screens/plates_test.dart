// 0.3 P1: plate math UI (plan gym-supreme-0.3 P1). Flag off: nothing new on
// screen. Flag on: a per-side plate line under a barbell load that sums to
// the load, bar and pairs set in gym setup, and +/- only on makeable loads.
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/cut2.dart' as c2;
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/app/feature_flags.dart';
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/gym_setup_screen.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/screens/view_models.dart';
import 'package:gym_supreme/screens/weight_list_screen.dart';

import 'fixtures.dart';
import 'flaky_port.dart';
import 'gym_setup_fixtures.dart';

void main() {
  const lift = 'barbell-bench-press-medium-grip';
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  const now = 1790000000000;
  late eng.GymEngine engine;
  late String gymId;

  void rig({List<int> bar = const [], List<int> plates = const []}) {
    engine = eng.GymEngine(
      catalog: catalog,
      store: eng.MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 0,
      random: Random(3),
    );
    final base = engine.gymFromPreset('condo');
    var g = base.copyWith(
      kit: {
        ...base.kit,
        for (final id in ['barbell', 'squat-rack', 'flat-bench', 'plates'])
          id: eng.KitItem(equipmentId: id),
      },
    );
    if (bar.isNotEmpty) g = g.withWeights('barbell', bar);
    if (plates.isNotEmpty) g = g.withWeights('plates', plates);
    engine.saveGym(g);
    gymId = g.id;
  }

  Future<LiveController> start(bool plateMath, {int? loadG}) async {
    final c = LiveController(
      plateMath: plateMath,
      engine: engine,
      port: FlakyPort(),
      nowMs: () => now,
      tzOffsetMin: 0,
      tick: const Duration(days: 1),
    );
    addTearDown(c.dispose);
    await c.start(
      eng.SessionPlan(
        gymId: gymId,
        typeId: 'push',
        muscles: const ['chest'],
        uncovered: const [],
        estimatedMinutes: 20,
        items: [
          eng.PlannedItem(
            exerciseId: lift,
            name: 'Barbell bench press',
            unit: eng.LoadUnit.kg,
            sets: [
              eng.PlannedSet(loadG: loadG ?? 62500, reps: 8),
              eng.PlannedSet(loadG: loadG ?? 62500, reps: 8),
            ],
            repLo: 8,
            repHi: 12,
            restS: 120,
            reason: '',
            primary: const ['chest'],
          ),
        ],
      ),
    );
    return c;
  }

  group('controller line', () {
    test('flag off: no plate line, even on a barbell lift', () async {
      rig();
      final c = await start(false);
      expect(c.view()!.plateLine, isNull);
    });

    test('flag on, standard plates: per side sums to the load', () async {
      rig();
      final c = await start(true);
      expect(c.view()!.plateLine, 'Per side 20 + 1.25');
    });

    test('flag on, his bar and pairs: the line comes from them', () async {
      // 15 kg bar; 2 x 10 and 1 x 5 per side, so 55 kg is 15 + 2 x 20.
      rig(bar: [15000], plates: [10000, 10000, 5000]);
      final c = await start(true, loadG: 55000);
      expect(c.view()!.plateLine, 'Per side 10 + 10');
    });

    test('a load he typed that the bar cannot make says so', () async {
      rig(bar: [15000], plates: [10000, 10000, 5000]);
      final c = await start(true, loadG: 51000);
      final line = c.view()!.plateLine!;
      expect(line, startsWith('Can’t make it exactly'));
      expect(line, contains('Nearest'));
    });

    test('+/- only ever lands on a load the bar makes', () async {
      rig(bar: [15000], plates: [10000, 10000, 5000]);
      final c = await start(true, loadG: 15000);
      final steps = engine.loadSteps(gymId: gymId, exerciseId: lift).loadsG;
      final bar = engine.barSetup(gymId: gymId, exerciseId: lift)!;
      var guard = 0;
      while (c.view()!.canLoadUp && guard++ < 50) {
        await c.load(1);
        final v = c.view()!;
        expect(steps, contains(v.loadG));
        final e = c2.loadBar(v.loadG!, barG: bar.barG, pairs: bar.pairs).exact;
        expect(e, isNotNull, reason: '${v.loadG} g');
        expect(e!.totalG, v.loadG);
        expect(v.plateLine, 'Per side ${e.perSideLabel}');
      }
      expect(guard, greaterThan(3));
      expect(c.view()!.loadG, 15000 + 2 * 25000);
    });

    test('not a barbell lift: no line even with the flag on', () async {
      rig();
      final c = LiveController(
        plateMath: true,
        engine: engine,
        port: FlakyPort(),
        nowMs: () => now,
        tzOffsetMin: 0,
        tick: const Duration(days: 1),
      );
      addTearDown(c.dispose);
      await c.start(
        eng.SessionPlan(
          gymId: gymId,
          typeId: 'push',
          muscles: const ['chest'],
          uncovered: const [],
          estimatedMinutes: 10,
          items: [
            eng.PlannedItem(
              exerciseId: 'pushups',
              name: 'Pushups',
              unit: eng.LoadUnit.bodyweight,
              sets: const [eng.PlannedSet(loadG: null, reps: 10)],
              repLo: 8,
              repHi: 12,
              restS: 60,
              reason: '',
              primary: const ['chest'],
            ),
          ],
        ),
      );
      expect(c.view()!.plateLine, isNull);
    });
  });

  group('live screen', () {
    Future<void> pump(WidgetTester tester, LiveView v) async {
      phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(view: v, onLoad: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
    }

    LiveView view({String? plateLine, int? restLeftS}) => LiveView(
      plateLine: plateLine,
      type: WorkoutType.push,
      exerciseName: 'Barbell bench press',
      lift: 1,
      lifts: 5,
      set: 1,
      sets: 3,
      rail: const [SetTile.current, SetTile.pending, SetTile.pending],
      reps: 8,
      loadG: 62500,
      unit: LoadUnit.kg,
      targetReps: 8,
      targetLoadG: 62500,
      restS: 120,
      upNext: const [],
      queue: pushPlan.items,
      elapsedS: 100,
      restLeftS: restLeftS,
    );

    testWidgets('flag off (no line): nothing under the load', (tester) async {
      await pump(tester, view());
      expect(find.byKey(const Key('live.plates')), findsNothing);
      expect(find.textContaining('Per side'), findsNothing);
    });

    testWidgets('flag on: the line is under the load', (tester) async {
      await pump(tester, view(plateLine: 'Per side 20 + 1.25'));
      expect(find.byKey(const Key('live.plates')), findsOneWidget);
      expect(find.text('Per side 20 + 1.25'), findsOneWidget);
    });

    testWidgets('the rest screen shows it for the next set', (tester) async {
      await pump(tester, view(plateLine: 'Per side 20 + 1.25', restLeftS: 60));
      expect(find.byKey(const Key('rest.plates')), findsOneWidget);
    });
  });

  group('gym setup', () {
    Widget screen({
      List<PlateRow> rows = const [],
      ValueChanged<String>? onEdit,
    }) => MaterialApp(
      home: GymSetupScreen(
        gyms: const [condo],
        currentGymId: 'condo',
        kit: condo.kit,
        equipment: equipmentFixture,
        presets: presetsFixture,
        plateRows: rows,
        onEditPlates: onEdit,
        firstRun: true,
      ),
    );

    testWidgets('flag off (no rows): no bar and plates section', (
      tester,
    ) async {
      phone(tester);
      await tester.pumpWidget(screen());
      expect(find.text('BAR & PLATES'), findsNothing);
    });

    testWidgets('flag on: rows show and open their editor by id', (
      tester,
    ) async {
      phone(tester);
      final got = <String>[];
      await tester.pumpWidget(
        screen(
          onEdit: got.add,
          rows: const [
            PlateRow(
              id: 'barbell',
              name: 'Barbell bar',
              summary: '20 kg',
              fromDefaults: true,
            ),
            PlateRow(id: 'plates', name: 'Plates', summary: '2 × 20 kg a side'),
          ],
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Barbell bar'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('BAR & PLATES'), findsOneWidget);
      expect(find.text('20 kg · app guesses, set yours'), findsOneWidget);
      await tester.tap(find.text('Barbell bar'));
      await tester.tap(find.text('2 × 20 kg a side'));
      expect(got, ['barbell', 'plates']);
    });
  });

  group('pairs editor', () {
    testWidgets('pairs count up and down; Save returns one entry per pair', (
      tester,
    ) async {
      phone(tester);
      List<int>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                saved = await Navigator.of(ctx).push<List<int>>(
                  MaterialPageRoute(
                    builder: (_) => const PlatePairsScreen(pairsG: [5000]),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plates.count.5000')), findsOneWidget);
      Future<void> tapKey(String k, [int times = 1]) async {
        final f = find.byKey(Key(k));
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        for (var i = 0; i < times; i++) {
          await tester.tap(f);
          await tester.pump();
        }
      }

      await tapKey('plates.plus.20000', 2);
      await tapKey('plates.plus.5000');
      await tapKey('plates.minus.5000', 2);
      await tapKey('plates.plus.1250');
      await tester.tap(find.textContaining('SAVE'));
      await tester.pumpAndSettle();
      expect(saved, [1250, 20000, 20000]);
    });

    testWidgets('no pairs saves an empty list: standard plates', (
      tester,
    ) async {
      phone(tester);
      List<int>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                saved = await Navigator.of(ctx).push<List<int>>(
                  MaterialPageRoute(
                    builder: (_) => const PlatePairsScreen(pairsG: []),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('SAVE · STANDARD'), findsOneWidget);
      await tester.tap(find.text('SAVE · STANDARD'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
    });

    testWidgets('fits 320x580 at 1.3x text: counts and rows do not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 1160);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      // The widest counts: two-figure numbers at the largest text.
      await tester.pumpWidget(
        MaterialApp(
          home: PlatePairsScreen(
            pairsG: [
              for (var i = 0; i < 10; i++) 20000,
              for (var i = 0; i < 10; i++) 1250,
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('10'), findsNWidgets(2));
      // Each count sits between its two 48 dp buttons without wrapping.
      final box = tester.getSize(find.byKey(const Key('plates.count.20000')));
      expect(box.height, lessThanOrEqualTo(60), reason: 'one line');
      await tester.pumpWidget(
        MaterialApp(
          home: GymSetupScreen(
            gyms: const [condo],
            currentGymId: 'condo',
            kit: {...condo.kit, 'barbell', 'plates'},
            equipment: equipmentFixture,
            presets: const [],
            plateRows: const [
              PlateRow(
                id: 'plates',
                name: 'Plates',
                summary:
                    '2 × 20 · 2 × 15 · 2 × 10 · 1 × 2.5 · 1 × 1.25 kg a side',
              ),
            ],
            onEditPlates: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'plate rows');
    });

    test('summary reads largest first', () {
      expect(platePairsSummary([]), 'standard plates');
      expect(
        platePairsSummary([2500, 10000, 20000, 20000]),
        '2 × 20 · 1 × 10 · 1 × 2.5 kg a side',
      );
    });
  });

  // Runs in both CI passes: GS_FEATURES unset (section absent) and `all`
  // (section present, bar weight saved to the stored gym).
  group('gym flow, by flag', () {
    testWidgets('bar and plates section follows Features.plateMath', (
      tester,
    ) async {
      rig();
      phone(tester);
      final deps = GymDeps(
        engine: engine,
        port: FlakyPort(),
        catalog: catalog,
        appVersion: 'test',
        nowMs: () => now,
        tzOffsetMin: () => 0,
        store: eng.MemoryStore(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GymFlow(
            deps: deps,
            gym: engine.gym(gymId),
            firstRun: false,
            onSaved: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(Scrollable).first;
      if (!Features.plateMath) {
        await tester.drag(list, const Offset(0, -4000));
        await tester.pumpAndSettle();
        expect(find.text('BAR & PLATES'), findsNothing);
        return;
      }
      await tester.scrollUntilVisible(
        find.text('Barbell bar'),
        200,
        scrollable: list,
      );
      await tester.pumpAndSettle();
      expect(find.text('BAR & PLATES'), findsOneWidget);
      expect(find.text('20 kg · app guesses, set yours'), findsOneWidget);
      await tester.tap(find.text('Barbell bar'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('live.keypad')), '15');
      await tester.tap(find.byKey(const Key('live.keypad.set')));
      await tester.pumpAndSettle();
      expect(engine.gym(gymId)!.kit['barbell']!.weightsG, [15000]);
      expect(find.text('15 kg'), findsOneWidget);
    });
  });
}
