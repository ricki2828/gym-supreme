import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_engine/gym_engine.dart' as eng;
import 'package:gym_supreme/screens/flows/flows.dart';
import 'package:gym_supreme/screens/live_controller.dart';
import 'package:gym_supreme/screens/live_screen.dart';
import 'package:gym_supreme/widgets/lit_widgets.dart';

import 'fixtures.dart';
import 'flaky_port.dart';
import 'live_fixtures.dart';

/// 0.3.1 R2: "What's next?" after an exercise, the Change order sheet, and a
/// drag that takes first time. Real engine, stub port.
class _CountingPort extends FlakyPort {
  int submits = 0;
  @override
  Future<int> submitSnapshot(String snapshotJson, int baseRev) {
    submits++;
    return super.submitSnapshot(snapshotJson, baseRev);
  }
}

void main() {
  final catalog = eng.Catalog.fromJson(
    File('assets/exercises_taxonomy.json').readAsStringSync(),
    File('assets/exercises.json').readAsStringSync(),
  );
  late int now;
  late eng.GymEngine engine;
  late _CountingPort port;
  late LiveController c;
  late String gymId;
  var disposed = false;

  LiveController newController() => LiveController(
    engine: engine,
    port: port,
    nowMs: () => now,
    tzOffsetMin: 480,
    tick: const Duration(days: 1),
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 24, 1).millisecondsSinceEpoch;
    engine = eng.GymEngine(
      catalog: catalog,
      store: eng.MemoryStore(),
      nowMs: () => now,
      tzOffsetMin: () => 480,
      random: Random(7),
    );
    final g = engine.gymFromPreset('condo').withWeights('dumbbells', [
      for (var kg = 2; kg <= 24; kg += 2) kg * 1000,
    ]);
    engine.saveGym(g);
    gymId = g.id;
    port = _CountingPort();
    c = newController();
    disposed = false;
  });
  tearDown(() {
    if (!disposed) c.dispose();
  });

  Future<void> endLive(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    disposed = true;
  }

  Future<void> startPush() => c.start(
    engine.suggest(
      gymId: gymId,
      muscleIds: const ['chest', 'front-delts', 'side-delts', 'triceps'],
      typeId: 'push',
    ),
  );

  List<String> order() => [for (final e in c.snapshot!.exercises) e.exerciseId];
  String cur() =>
      c.snapshot!.exercises[c.snapshot!.current!.exercise].exerciseId;

  /// Logs the current exercise's remaining sets, stopping on its last one
  /// when [leaveLast] (so the next Done finishes the exercise).
  Future<void> finishCurrent({bool leaveLast = false}) async {
    final id = cur();
    var guard = 0;
    while (cur() == id && guard++ < 20) {
      final ex = c.snapshot!.exercises[c.snapshot!.current!.exercise];
      final left = ex.sets.where((s) => s.state == eng.SetState.pending);
      if (leaveLast && left.length == 1) return;
      now += 1000; // sets get distinct end times, as they do for real
      await c.done();
    }
  }

  /// "Do this one now" as the screen does it: by the exercise's id.
  Future<void> pick(int queueIndex) =>
      c.pickNow(c.view()!.queue[queueIndex].exerciseId);

  group('pickNow', () {
    test('pickNow(1) is exactly Do later', () async {
      await startPush();
      final o = order();
      await pick(1);
      expect(order(), [o[1], o[0], ...o.skip(2)]);
      expect(cur(), o[1]);
    });

    test(
      'pickNow(2): the picked exercise first, the rest keep order',
      () async {
        await startPush();
        final o = order();
        expect(o.length, greaterThanOrEqualTo(4));
        await pick(2);
        expect(order(), [o[2], o[0], o[1], ...o.skip(3)]);
        expect(cur(), o[2]);
      },
    );

    test('tap after tap: the pick walks round and nets to zero', () async {
      await startPush();
      final o = order();
      final n = o.length;
      // Picking the last one n times rotates the list right, one a tap.
      for (var k = 1; k <= n; k++) {
        await pick(n - 1);
        final want = [for (var i = 0; i < n; i++) o[(i - k) % n]];
        expect(order(), want, reason: 'tap $k');
        expect(cur(), want[0]);
      }
      expect(order(), o, reason: 'n taps net to zero');
    });

    test('pickNow(0) and out of range do nothing, no rev', () async {
      await startPush();
      final rev = c.snapshot!.rev;
      await pick(0);
      await c.pickNow('no-such-exercise');
      expect(c.snapshot!.rev, rev);
    });
  });

  group('atExerciseEnd', () {
    test('true only between the last set of one exercise and the first '
        'of the next', () async {
      await startPush();
      expect(c.view()!.atExerciseEnd, isFalse, reason: 'fresh start');
      await c.load(1);
      await finishCurrent(leaveLast: true);
      expect(c.view()!.atExerciseEnd, isFalse, reason: 'mid exercise');
      await c.done(); // the last set
      final v = c.view()!;
      expect(v.atExerciseEnd, isTrue);
      expect(v.restLeftS, isNotNull, reason: 'the rest runs');
      expect(v.queue.length, greaterThan(1));
      await c.done(); // first set of the next exercise
      expect(c.view()!.atExerciseEnd, isFalse);
    });

    test('Do later mid-exercise is not an exercise end', () async {
      await startPush();
      await c.load(1);
      await c.done();
      await c.doLater();
      expect(c.view()!.atExerciseEnd, isFalse);
    });

    test('a pick keeps it on, and it survives a kill and resume', () async {
      await startPush();
      await c.load(1);
      await finishCurrent();
      expect(c.view()!.atExerciseEnd, isTrue);
      final o = order();
      await pick(2);
      expect(c.view()!.atExerciseEnd, isTrue);
      final saved = eng.SessionSnapshot.decode(
        (await port.readPendingJournal())!,
      );
      final c2 = newController();
      addTearDown(c2.dispose);
      await c2.resume(saved);
      expect(c2.view()!.atExerciseEnd, isTrue);
      expect(
        c2.snapshot!.exercises[c2.snapshot!.current!.exercise].exerciseId,
        o[3],
      );
    });

    test('off when only one exercise is left', () async {
      await startPush();
      final n = order().length;
      for (var i = 0; i < n - 1; i++) {
        await c.load(1);
        await finishCurrent();
      }
      expect(c.view()!.queue.length, 1);
      expect(c.view()!.atExerciseEnd, isFalse);
    });
  });

  group('boundary and identity', () {
    test('still on when the new current exercise is part done', () async {
      await startPush();
      final o = order();
      await c.load(1);
      now += 1000;
      await c.done(); // one set of o0, then it goes later
      await c.doLater();
      expect(cur(), o[1]);
      expect(c.view()!.atExerciseEnd, isFalse, reason: 'mid exercise');
      await finishCurrent(); // o1 done in full; o0 (part done) is current
      expect(cur(), o[0]);
      expect(c.snapshot!.exercises[0].anyLogged, isTrue);
      final v = c.view()!;
      expect(v.atExerciseEnd, isTrue, reason: 'an exercise just ended');
      expect(v.queue.first.exerciseId, o[0]);
      // Picking the part-done exercise's neighbour keeps the choice on.
      await pick(1);
      expect(c.view()!.atExerciseEnd, isTrue);
      // Logging a set of the new current exercise ends it.
      await c.done();
      expect(c.view()!.atExerciseEnd, isFalse);
    });

    test('a double tap on DO NOW moves once', () async {
      await startPush();
      await c.load(1);
      await finishCurrent();
      final o = order();
      final id = c.view()!.queue[2].exerciseId;
      await Future.wait([c.pickNow(id), c.pickNow(id)]);
      expect(order(), [o[0], o[3], o[1], o[2], ...o.skip(4)]);
      expect(cur(), o[3]);
    });

    test('a lock-screen Done that lands before the pick never moves the '
        'wrong exercise', () async {
      await startPush();
      await c.load(1);
      await finishCurrent();
      final o = order();
      final target = c.view()!.queue[2].exerciseId; // o3
      final h = eng.SessionSnapshot.decode((await port.readPendingJournal())!);
      final moved = eng.Session.done(
        h,
        h.currentSet!.setId,
        nowMs: now += 30000,
        source: eng.SetSource.lockscreen,
      );
      port.foreignWrite(moved.encode());
      // The tap is queued before the adopt is delivered.
      final tap = c.pickNow(target);
      await tap;
      await pumpEventQueue();
      expect(c.lastError, isNull);
      final done = [
        for (final e in c.snapshot!.exercises)
          e.sets.where((x) => x.state == eng.SetState.done).length,
      ];
      expect(done[order().indexOf(o[1])], 1, reason: 'the lock-screen set');
      if (order().join() != [...o].join()) {
        // Applied after the adopt: the tapped exercise, nobody else.
        expect(cur(), target);
        expect(order().where((e) => e != target).toList(), [
          for (final e in o)
            if (e != target) e,
        ]);
      }
    });

    test('the menu moves by id: a step each way nets to zero, a gone id '
        'does nothing', () async {
      await startPush();
      final o = order();
      await c.moveQueueItem(o[1], 1);
      expect(order(), [o[0], o[2], o[1], ...o.skip(3)]);
      await c.moveQueueItem(o[1], -1);
      expect(order(), o);
      final rev = c.snapshot!.rev;
      await c.moveQueueItem('no-such-exercise', 1);
      await c.moveQueueItem(o.last, 1); // off the end
      await c.moveQueueItem(o[0], -1); // off the top
      expect(c.snapshot!.rev, rev);
    });

    test('a true rest of 0: no rest screen, the choice is on the set screen '
        'data', () async {
      await startPush();
      // The first exercise has no rest at all.
      final j = jsonDecode(c.snapshot!.encode()) as Map<String, dynamic>;
      (j['exercises'] as List<dynamic>)[0]['rest_s'] = 0;
      j['rev'] = c.snapshot!.rev + 1;
      port.foreignWrite(jsonEncode(j));
      await pumpEventQueue();
      expect(c.snapshot!.exercises[0].restS, 0);
      await c.load(1);
      await finishCurrent();
      final v = c.view()!;
      expect(c.snapshot!.rest, isNull);
      expect(v.restLeftS, isNull);
      expect(v.atExerciseEnd, isTrue);
    });
  });

  group('the default path is unchanged', () {
    test(
      'last set, rest, auto-advance: no submit beyond the Done itself',
      () async {
        await startPush();
        await c.load(1);
        await finishCurrent(leaveLast: true);
        final o = order();
        final before = port.submits;
        await c.done();
        expect(port.submits, before + 1, reason: 'one submit for the Done');
        expect(cur(), o[1], reason: 'the default is current at once');
        final rev = c.snapshot!.rev;
        // The rest runs out on the clock: nothing is submitted, nothing moves.
        now += (c.view()!.restLeftS! + 5) * 1000;
        expect(c.view()!.restLeftS, isNull, reason: 'rest over');
        expect(port.submits, before + 1);
        expect(c.snapshot!.rev, rev);
        expect(order(), o);
        expect(cur(), o[1]);
      },
    );
  });

  group('lock-screen Done follows a pick', () {
    test('it logs a set of the picked exercise', () async {
      await startPush();
      await c.load(1);
      await finishCurrent();
      final o = order();
      await pick(2); // queue index 2 = the third remaining exercise
      final want = c.snapshot!.exercises[c.snapshot!.current!.exercise];
      final h = eng.SessionSnapshot.decode((await port.readPendingJournal())!);
      expect(h.currentSet!.setId, want.sets.first.setId);
      final moved = eng.Session.done(
        h,
        h.currentSet!.setId,
        nowMs: now += 30000,
        source: eng.SetSource.lockscreen,
      );
      port.foreignWrite(moved.encode());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final logged = c.snapshot!.exercises
          .expand((e) => e.sets.map((s) => (e.exerciseId, s)))
          .where((x) => x.$2.setId == h.currentSet!.setId)
          .single;
      expect(logged.$1, isNot(o[0]));
      expect(logged.$1, want.exerciseId);
      expect(logged.$2.state, eng.SetState.done);
    });
  });

  group('screens', () {
    Future<void> pumpLive(WidgetTester tester, {double scale = 1.0}) async {
      phone(tester, textScale: scale);
      c.dispose();
      c = newController();
      await startPush();
      await tester.pumpWidget(
        MaterialApp(
          home: LiveFlow(controller: c, catalog: catalog),
        ),
      );
      await tester.pump();
    }

    void small(WidgetTester tester, {double scale = 1.3}) {
      tester.view.physicalSize = const Size(640, 1160);
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = const FakeViewPadding(top: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 48);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    Future<void> reveal(WidgetTester tester, Finder f) async {
      if (f.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          f,
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      final f = find.byKey(Key(key));
      await reveal(tester, f);
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    /// Finishes exercise 1 through the controller: rest screen, "What's next?".
    Future<void> toBoundary(WidgetTester tester) async {
      await c.load(1);
      await finishCurrent();
      await tester.pumpAndSettle();
    }

    testWidgets('rest: pick exercise 3, it becomes current; lock-screen Done '
        'targets it', (tester) async {
      await pumpLive(tester);
      await toBoundary(tester);
      final o = order();
      expect(find.text("WHAT'S NEXT?"), findsOneWidget);
      expect(find.text('STARTS WHEN THE REST ENDS'), findsOneWidget);
      expect(find.byKey(const Key('whatsnext.start')), findsOneWidget);
      // queue: [o1 (default), o2, o3, ...]; pick row 2 = o3.
      await tapKey(tester, 'whatsnext.pick.2');
      expect(order(), [o[0], o[3], o[1], o[2], ...o.skip(4)]);
      expect(cur(), o[3]);
      // The card now leads with the pick; the former default is a row.
      expect(find.byKey(const Key('whatsnext.default')), findsOneWidget);
      final h = eng.SessionSnapshot.decode((await port.readPendingJournal())!);
      final moved = eng.Session.done(
        h,
        h.currentSet!.setId,
        nowMs: now += 30000,
        source: eng.SetSource.lockscreen,
      );
      port.foreignWrite(moved.encode());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      final doneIn = [
        for (final e in c.snapshot!.exercises)
          e.sets.where((s) => s.state == eng.SetState.done).length,
      ];
      expect(doneIn[order().indexOf(o[3])], 1);
      expect(doneIn[order().indexOf(o[1])], 0);
      await endLive(tester);
    });

    testWidgets('rest: the default card is one tap (Start now = Skip rest)', (
      tester,
    ) async {
      await pumpLive(tester);
      await toBoundary(tester);
      final o = order();
      final before = port.submits;
      await tapKey(tester, 'whatsnext.start');
      expect(find.text('SKIP REST'), findsNothing);
      expect(c.view()!.restLeftS, isNull);
      expect(cur(), o[1], reason: 'the default stayed current');
      expect(port.submits, before + 1, reason: 'one submit: skip rest');
      await endLive(tester);
    });

    testWidgets('set screen variant: rest 0 shows the rows under DONE', (
      tester,
    ) async {
      await pumpLive(tester);
      await toBoundary(tester);
      // The rest runs out: the set screen of the default keeps the choice.
      now += (c.view()!.restLeftS! + 5) * 1000;
      await c.reps(1); // any controller change repaints the clock
      await c.reps(-1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('whatsnext.title')), findsOneWidget);
      expect(find.byKey(const Key('whatsnext.default')), findsNothing);
      final o = order();
      await tapKey(tester, 'whatsnext.pick.1');
      expect(cur(), o[2]);
      await endLive(tester);
    });

    testWidgets('a true rest of 0: the rows are inline on the set screen', (
      tester,
    ) async {
      await pumpLive(tester);
      final j = jsonDecode(c.snapshot!.encode()) as Map<String, dynamic>;
      (j['exercises'] as List<dynamic>)[0]['rest_s'] = 0;
      j['rev'] = c.snapshot!.rev + 1;
      port.foreignWrite(jsonEncode(j));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await c.load(1);
      await finishCurrent();
      await tester.pumpAndSettle();
      expect(find.text('SKIP REST'), findsNothing, reason: 'no rest screen');
      final o = order();
      await tapKey(tester, 'whatsnext.pick.1');
      expect(cur(), o[2]);
      await endLive(tester);
    });

    testWidgets('Change order sheet: NOW tag, Move down, Move up', (
      tester,
    ) async {
      await pumpLive(tester);
      final o = order();
      await tapKey(tester, 'live.change_order');
      final sheet = find.byType(ReorderSheet);
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('NOW')),
        findsOneWidget,
      );
      Finder inSheet(String key) =>
          find.descendant(of: sheet, matching: find.byKey(Key(key)));
      // Row 1 down one place, then up again: net zero, one move per tap.
      await tester.tap(inSheet('plan.menu.1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan.down.1')));
      await tester.pumpAndSettle();
      expect(order(), [o[0], o[2], o[1], ...o.skip(3)]);
      await tester.tap(inSheet('plan.menu.2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan.up.2')));
      await tester.pumpAndSettle();
      expect(order(), o);
      // The current exercise down: the next one becomes current at once.
      await tester.tap(inSheet('plan.menu.0'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan.down.0')));
      await tester.pumpAndSettle();
      expect(cur(), o[1]);
      expect(
        find.descendant(
          of: find.descendant(of: sheet, matching: find.byType(Column)),
          matching: find.text('NOW'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('order.close')));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      await endLive(tester);
    });

    testWidgets('long-press anywhere on a row drags it', (tester) async {
      await pumpLive(tester);
      final o = order();
      await tapKey(tester, 'live.change_order');
      final sheet = find.byType(ReorderSheet);
      final row = find.descendant(
        of: sheet,
        matching: find.text(c.snapshot!.exercises[1].name),
      );
      final g = await tester.startGesture(tester.getCenter(row));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(0, -8));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(order(), [o[1], o[0], ...o.skip(2)]);
      await endLive(tester);
    });

    testWidgets('the handle: 48 x 48 at least, drags after a short hold', (
      tester,
    ) async {
      await pumpLive(tester);
      final o = order();
      await tapKey(tester, 'live.change_order');
      final sheet = find.byType(ReorderSheet);
      final handle = find.descendant(
        of: sheet,
        matching: find.byKey(const Key('plan.handle.2')),
      );
      final size = tester.getSize(handle);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      // Hit it off-centre but inside the 48 dp box: still a drag.
      final at = tester.getTopLeft(handle) + const Offset(6, 40);
      final g = await tester.startGesture(at);
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 0; i < 7; i++) {
        await g.moveBy(const Offset(0, -8));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(order(), [o[0], o[2], o[1], ...o.skip(3)]);
      await endLive(tester);
    });

    testWidgets('the menu is the sure way: every row has a 48 dp one', (
      tester,
    ) async {
      await pumpLive(tester);
      await tapKey(tester, 'live.change_order');
      final sheet = find.byType(ReorderSheet);
      for (var i = 0; i < c.view()!.queue.length; i++) {
        final m = find.descendant(
          of: sheet,
          matching: find.byKey(Key('plan.menu.$i')),
        );
        expect(m, findsOneWidget, reason: 'row $i');
        expect(tester.getSize(m).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(m).height, greaterThanOrEqualTo(48));
      }
      await endLive(tester);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('rest "What\'s next?" fits 320x580 at text x$scale', (
        tester,
      ) async {
        small(tester, scale: scale);
        var skipped = 0;
        final picked = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: LiveScreen(
              view: liveView(restLeftS: 60, atExerciseEnd: true),
              onSkipRest: () => skipped++,
              onRestDelta: (_) {},
              onPickNext: picked.add,
              onChangeOrder: () {},
              onReorder: (_, _) {},
              onFinish: () {},
              onReps: (_) {},
              onLoad: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text("WHAT'S NEXT?"), findsOneWidget);
        final start = find.byKey(const Key('whatsnext.start'));
        await reveal(tester, start);
        expect(tester.getRect(start).right, lessThanOrEqualTo(320));
        expect(tester.getSize(start).height, greaterThanOrEqualTo(48));
        await tester.tap(start);
        expect(skipped, 1);
        final row = find.byKey(const Key('whatsnext.pick.2'));
        await reveal(tester, row);
        expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
        expect(tester.getRect(row).right, lessThanOrEqualTo(320));
        await tester.tap(row);
        expect(picked, [liveView().queue[2].exerciseId]);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'set screen entry, Do later and rows fit 320x580 at x$scale',
        (tester) async {
          small(tester, scale: scale);
          var order = 0, later = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: LiveScreen(
                view: liveView(atExerciseEnd: true),
                onChangeOrder: () => order++,
                onDoLater: () => later++,
                onPickNext: (_) {},
                onReorder: (_, _) {},
                onFinish: () {},
                onDone: () {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await reveal(tester, find.byKey(const Key('whatsnext.title')));
          expect(find.byKey(const Key('whatsnext.title')), findsOneWidget);
          final entry = find.byKey(const Key('live.change_order'));
          await reveal(tester, entry);
          expect(entry, findsOneWidget);
          expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(entry).right, lessThanOrEqualTo(320));
          await tester.tap(entry);
          expect(order, 1);
          final dl = find.byKey(const Key('live.do_later'));
          await reveal(tester, dl);
          expect(tester.getSize(dl).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(dl).right, lessThanOrEqualTo(320));
          await tester.tap(dl);
          expect(later, 1);
        },
      );
    }

    testWidgets('the sheet fits 320x580 at 1.3x text', (tester) async {
      small(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showReorderSheet(
                ctx,
                listenable: ValueNotifier(0),
                view: () => liveView(),
                onMove: (_, _) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ReorderSheet), findsOneWidget);
      expect(
        tester.getRect(find.byType(ReorderSheet)).bottom,
        lessThanOrEqualTo(580),
      );
      expect(find.byKey(const Key('order.close')), findsOneWidget);
    });

    testWidgets('timer block next: the rows and Move up on row 1 are off', (
      tester,
    ) async {
      small(tester, scale: 1.0);
      final picked = <String>[];
      final moved = <(int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(
            view: liveView(
              atExerciseEnd: true,
              timerBlock: true,
              canDoLater: false,
              restLeftS: 30,
            ),
            onPickNext: picked.add,
            onChangeOrder: () {},
            onReorder: (a, b) => moved.add((a, b)),
            onSkipRest: () {},
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('whatsnext.pick.1'));
      await reveal(tester, row);
      await tester.tap(row);
      expect(picked, isEmpty, reason: 'a block cannot move');
      expect(moved, isEmpty);
      expect(find.textContaining('cannot be moved'), findsWidgets);
    });

    testWidgets('timer block: the sheet locks row 0 and Move up on row 1', (
      tester,
    ) async {
      small(tester, scale: 1.0);
      final moved = <(int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReorderSheet(
              view: liveView(timerBlock: true),
              onMove: (a, b) => moved.add((a, b)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Row 0: no menu at all. Row 1: Move up is greyed out, Move down is not.
      await tester.tap(
        find.byKey(const Key('plan.menu.0')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan.down.0')), findsNothing);
      await tester.tap(find.byKey(const Key('plan.menu.1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plan.up.1')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(moved, isEmpty, reason: 'Move up into the running block');
      await tester.tap(find.byKey(const Key('plan.down.1')));
      await tester.pumpAndSettle();
      expect(moved, [(1, 2)]);
    });

    // DONE is the one-tap path: it must sit above the pinned Finish bar on a
    // 393x851 phone with a status bar (48 dp) and a gesture/nav area (34 dp),
    // without scrolling, at 1.0x and 1.3x text.
    void phone393(WidgetTester tester, double scale) {
      tester.view.physicalSize = const Size(393 * 3, 851 * 3);
      tester.view.devicePixelRatio = 3.0;
      tester.view.padding = const FakeViewPadding(top: 144, bottom: 102);
      tester.view.viewPadding = const FakeViewPadding(top: 144, bottom: 102);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    final doneCases = <String, (LiveView, List<double>)>{
      'normal': (liveView(), [1.0, 1.3]),
      'cold start': (liveView(loadG: null, targetLoadG: null), [1.0, 1.3]),
      'what\'s next, set 1': (liveView(atExerciseEnd: true), [1.0, 1.3]),
      'three-line name': (
        liveView(name: 'Single arm standing cable chest press with rotation'),
        [1.0],
      ),
    };
    for (final e in doneCases.entries) {
      for (final scale in e.value.$2) {
        testWidgets('DONE stays above the Finish bar: ${e.key}, 393x851, '
            'text x$scale', (tester) async {
          phone393(tester, scale);
          await tester.pumpWidget(
            MaterialApp(
              home: LiveScreen(
                view: e.value.$1,
                onDone: () {},
                onReps: (_) {},
                onLoad: (_) {},
                onRestDelta: (_) {},
                onChangeOrder: () {},
                onDoLater: () {},
                onPickNext: (_) {},
                onReorder: (_, _) {},
                onFinish: () {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final done = find.ancestor(
            of: find.text('DONE'),
            matching: find.byType(BigButton),
          );
          final finishTop = tester
              .getRect(find.byKey(const Key('live.finish')))
              .top;
          final r = tester.getRect(done);
          expect(r.top, greaterThan(48), reason: 'below the status bar');
          expect(
            r.bottom,
            lessThanOrEqualTo(finishTop),
            reason: 'DONE ${r.bottom} vs Finish bar $finishTop',
          );
          expect(r.bottom, lessThanOrEqualTo(851 - 86));
        });
      }
    }

    testWidgets('the Do later and Change order buttons sit below DONE, side '
        'by side, 48 dp or more', (tester) async {
      phone393(tester, 1.0);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(
            view: liveView(),
            onDone: () {},
            onChangeOrder: () {},
            onDoLater: () {},
            onReorder: (_, _) {},
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final done = tester.getRect(
        find.ancestor(of: find.text('DONE'), matching: find.byType(BigButton)),
      );
      final later = tester.getRect(find.byKey(const Key('live.do_later')));
      final order = tester.getRect(find.byKey(const Key('live.change_order')));
      expect(later.top, greaterThan(done.bottom));
      expect(order.top, greaterThan(done.bottom));
      expect(later.top, order.top, reason: 'one row');
      expect(later.height, greaterThanOrEqualTo(48));
      expect(order.height, greaterThanOrEqualTo(48));
      expect(find.byKey(const Key('live.up_next')), findsOneWidget);
    });

    testWidgets('a press under 120 ms on the handle still scrolls the page', (
      tester,
    ) async {
      phone393(tester, 1.0);
      final moved = <(int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: LiveScreen(
            view: liveView(),
            onDone: () {},
            onChangeOrder: () {},
            onDoLater: () {},
            onReorder: (a, b) => moved.add((a, b)),
            onMoveItem: (_, _) {},
            onFinish: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final handle = find.byKey(const Key('plan.handle.2'));
      await reveal(tester, handle);
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final before = scrollable.position.pixels;
      expect(before, greaterThan(0));
      final g = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 40));
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(0, 14)); // finger down: page scrolls up
        await tester.pump(const Duration(milliseconds: 10));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, lessThan(before), reason: 'scrolled');
      expect(moved, isEmpty, reason: 'and nothing was dragged');
    });
  });
}
